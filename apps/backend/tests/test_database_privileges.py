from __future__ import annotations

from uuid import uuid4

import psycopg
import pytest
from psycopg import sql
from psycopg.conninfo import make_conninfo
from sqlalchemy.engine import make_url

from app.core.config import settings
from app.db.bootstrap_roles import provision_database_roles


def _database_url():
    try:
        url = make_url(settings.sqlalchemy_database_url)
    except RuntimeError:
        pytest.skip("A PostgreSQL database connection is required for this test.")
    if url.get_backend_name() != "postgresql":
        pytest.skip("Database role integration test requires PostgreSQL.")
    return url


def _connection_info(*, user: str, password: str) -> str:
    url = _database_url()

    return make_conninfo(
        host=url.host,
        port=url.port or 5432,
        dbname=url.database,
        user=user,
        password=password,
        connect_timeout=10,
        application_name="cloudstart-db-role-test",
    )


def test_runtime_role_is_dml_only_and_migrator_can_manage_schema() -> None:
    admin_url = _database_url()
    admin_user = admin_url.username
    admin_password = admin_url.password
    if not admin_user or not admin_password:
        pytest.skip("The PostgreSQL master connection is required for this integration test.")

    database_name = admin_url.database
    runtime_role = f"nova_rt_{uuid4().hex[:16]}"
    migrator_role = f"nova_mg_{uuid4().hex[:16]}"
    runtime_inherited_role = f"nova_rti_{uuid4().hex[:14]}"
    migrator_inherited_role = f"nova_mgi_{uuid4().hex[:14]}"
    runtime_password = "runtime-test-" + uuid4().hex + uuid4().hex
    migrator_password = "migrator-test-" + uuid4().hex + uuid4().hex
    schema_name = f"nova_test_{uuid4().hex[:16]}"

    provisioner_role = f"nova_pr_{uuid4().hex[:16]}"
    provisioner_password = "provisioner-test-" + uuid4().hex + uuid4().hex
    admin_conninfo = _connection_info(user=admin_user, password=admin_password)
    provisioner_conninfo = _connection_info(
        user=provisioner_role,
        password=provisioner_password,
    )

    try:
        # Simulate the RDS master-user capability boundary: this identity can
        # create roles but is not a PostgreSQL superuser.
        with psycopg.connect(admin_conninfo) as connection:
            connection.execute(
                sql.SQL("CREATE ROLE {} WITH LOGIN CREATEROLE PASSWORD {}").format(
                    sql.Identifier(provisioner_role),
                    sql.Literal(provisioner_password),
                )
            )
            connection.execute(
                sql.SQL(
                    "GRANT CONNECT, CREATE ON DATABASE {} TO {} WITH GRANT OPTION"
                ).format(sql.Identifier(database_name), sql.Identifier(provisioner_role))
            )

        with psycopg.connect(provisioner_conninfo) as connection:
            provisioner_attributes = connection.execute(
                "SELECT rolsuper, rolcreaterole FROM pg_roles WHERE rolname = current_user"
            ).fetchone()
            assert provisioner_attributes == (False, True)
            connection.execute(
                sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(schema_name))
            )
            connection.execute(
                sql.SQL("GRANT ALL PRIVILEGES ON SCHEMA {} TO PUBLIC").format(
                    sql.Identifier(schema_name)
                )
            )
            connection.execute(
                sql.SQL(
                    "CREATE FUNCTION {}.private_value() RETURNS text "
                    "LANGUAGE sql SECURITY DEFINER AS {}"
                ).format(
                    sql.Identifier(schema_name),
                    sql.Literal("SELECT 'private-data'::text"),
                )
            )
            connection.execute(
                sql.SQL(
                    "CREATE TABLE {}.items (id integer PRIMARY KEY, name text NOT NULL)"
                ).format(sql.Identifier(schema_name))
            )
            connection.execute(
                sql.SQL(
                    "CREATE TABLE {}.alembic_version (version_num varchar(32) NOT NULL)"
                ).format(sql.Identifier(schema_name))
            )
            connection.execute(
                sql.SQL(
                    "INSERT INTO {}.alembic_version (version_num) VALUES ('test_revision')"
                ).format(sql.Identifier(schema_name))
            )
            connection.execute(
                sql.SQL("INSERT INTO {}.items (id, name) VALUES (1, 'before')")
                .format(sql.Identifier(schema_name))
            )

            # Pre-create the logins so the test can inject privilege drift
            # before the idempotent bootstrap reconciles their attributes.
            connection.execute(
                sql.SQL("CREATE ROLE {} WITH LOGIN").format(
                    sql.Identifier(runtime_role)
                )
            )
            connection.execute(
                sql.SQL("CREATE ROLE {} WITH LOGIN").format(
                    sql.Identifier(migrator_role)
                )
            )

            # Create inherited privilege groups as the non-superuser
            # provisioner. The runtime group receives excessive schema access;
            # both memberships must be removed by the bootstrap reconciliation.
            for inherited_role in (runtime_inherited_role, migrator_inherited_role):
                connection.execute(
                    sql.SQL("CREATE ROLE {} NOLOGIN").format(
                        sql.Identifier(inherited_role)
                    )
                )
            connection.execute(
                sql.SQL(
                    "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA {} TO {}"
                ).format(sql.Identifier(schema_name), sql.Identifier(runtime_inherited_role))
            )
            connection.execute(
                sql.SQL(
                    "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA {} TO {}"
                ).format(sql.Identifier(schema_name), sql.Identifier(runtime_inherited_role))
            )
            connection.execute(
                sql.SQL("GRANT CREATE ON SCHEMA {} TO {}").format(
                    sql.Identifier(schema_name), sql.Identifier(runtime_inherited_role)
                )
            )
            connection.execute(
                sql.SQL("GRANT {} TO {}").format(
                    sql.Identifier(runtime_inherited_role), sql.Identifier(runtime_role)
                )
            )
            connection.execute(
                sql.SQL("GRANT {} TO {}").format(
                    sql.Identifier(migrator_inherited_role), sql.Identifier(migrator_role)
                )
            )

            provision_database_roles(
                connection,
                database_name=database_name,
                runtime_role=runtime_role,
                runtime_password=runtime_password,
                migrator_role=migrator_role,
                migrator_password=migrator_password,
                schema_name=schema_name,
            )

            role_attributes = connection.execute(
                """
                SELECT rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls
                FROM pg_roles
                WHERE rolname = %s
                """,
                (runtime_role,),
            ).fetchone()
            assert role_attributes == (False, False, False, False, False)

            assert not connection.execute(
                "SELECT pg_has_role(%s, %s, 'MEMBER')",
                (runtime_role, runtime_inherited_role),
            ).fetchone()[0]
            assert not connection.execute(
                "SELECT pg_has_role(%s, %s, 'MEMBER')",
                (migrator_role, migrator_inherited_role),
            ).fetchone()[0]
            assert not connection.execute(
                """
                SELECT EXISTS (
                    SELECT 1
                    FROM pg_auth_members AS membership
                    JOIN pg_roles AS granted_role
                      ON granted_role.oid = membership.roleid
                    JOIN pg_roles AS member_role
                      ON member_role.oid = membership.member
                    WHERE granted_role.rolname = %s
                      AND member_role.rolname = current_user
                      AND membership.set_option
                )
                """,
                (migrator_role,),
            ).fetchone()[0]

            owner = connection.execute(
                """
                SELECT tableowner
                FROM pg_tables
                WHERE schemaname = %s AND tablename = 'items'
                """,
                (schema_name,),
            ).fetchone()
            assert owner == (migrator_role,)

            function_owner = connection.execute(
                """
                SELECT pg_get_userbyid(p.proowner)
                FROM pg_proc AS p
                JOIN pg_namespace AS n ON n.oid = p.pronamespace
                WHERE n.nspname = %s AND p.proname = 'private_value'
                """,
                (schema_name,),
            ).fetchone()
            assert function_owner == (migrator_role,)
            assert connection.execute(
                "SELECT has_schema_privilege(%s, %s, 'USAGE')",
                (runtime_role, schema_name),
            ).fetchone()[0]
            assert not connection.execute(
                "SELECT has_schema_privilege(%s, %s, 'CREATE')",
                (runtime_role, schema_name),
            ).fetchone()[0]
            assert not connection.execute(
                "SELECT has_function_privilege(%s, %s, 'EXECUTE')",
                (runtime_role, f"{schema_name}.private_value()"),
            ).fetchone()[0]

        runtime_conninfo = _connection_info(
            user=runtime_role,
            password=runtime_password,
        )
        with psycopg.connect(runtime_conninfo) as connection:
            selected = connection.execute(
                sql.SQL("SELECT name FROM {}.items WHERE id = 1").format(
                    sql.Identifier(schema_name)
                )
            ).fetchone()
            assert selected == ("before",)

            connection.execute(
                sql.SQL("INSERT INTO {}.items (id, name) VALUES (2, 'runtime')")
                .format(sql.Identifier(schema_name))
            )

        with (
            pytest.raises(psycopg.errors.InsufficientPrivilege),
            psycopg.connect(runtime_conninfo) as connection,
        ):
            connection.execute(
                sql.SQL("CREATE TABLE {}.runtime_created (id integer)").format(
                    sql.Identifier(schema_name)
                )
            )

        with (
            pytest.raises(psycopg.errors.InsufficientPrivilege),
            psycopg.connect(runtime_conninfo) as connection,
        ):
            connection.execute(
                sql.SQL(
                    "SELECT version_num FROM {}.alembic_version"
                ).format(sql.Identifier(schema_name))
            ).fetchone()

        migrator_conninfo = _connection_info(
            user=migrator_role,
            password=migrator_password,
        )
        with psycopg.connect(migrator_conninfo) as connection:
            connection.execute(
                sql.SQL("ALTER TABLE {}.items ADD COLUMN migrated boolean DEFAULT true")
                .format(sql.Identifier(schema_name))
            )
            connection.execute(
                sql.SQL(
                    "CREATE TABLE {}.migration_created (id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, name text NOT NULL)"
                ).format(sql.Identifier(schema_name))
            )

        # Simulate privilege drift from an earlier deployment. The second
        # bootstrap must remove these excess grants, not merely add DML grants.
        with psycopg.connect(provisioner_conninfo) as connection:
            connection.execute(
                sql.SQL("GRANT CREATE ON SCHEMA {} TO {}").format(
                    sql.Identifier(schema_name), sql.Identifier(runtime_role)
                )
            )
            connection.execute(
                sql.SQL("GRANT ALL PRIVILEGES ON SCHEMA {} TO PUBLIC").format(
                    sql.Identifier(schema_name)
                )
            )
            # Recreate the temporary SET capability to inject excess table and
            # sequence grants as their actual owner, then return to the admin.
            connection.execute(
                sql.SQL("GRANT {} TO CURRENT_USER WITH SET TRUE, INHERIT FALSE").format(
                    sql.Identifier(migrator_role)
                )
            )
            connection.execute(
                sql.SQL("SET ROLE {}").format(sql.Identifier(migrator_role))
            )
            connection.execute(
                sql.SQL(
                    "GRANT TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA {} TO {}"
                ).format(sql.Identifier(schema_name), sql.Identifier(runtime_role))
            )
            connection.execute(
                sql.SQL(
                    "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA {} TO {}"
                ).format(sql.Identifier(schema_name), sql.Identifier(runtime_role))
            )
            connection.execute(
                sql.SQL(
                    "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA {} TO PUBLIC"
                ).format(sql.Identifier(schema_name))
            )
            connection.execute(
                sql.SQL(
                    "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA {} TO PUBLIC"
                ).format(sql.Identifier(schema_name))
            )
            connection.execute(
                sql.SQL(
                    "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA {} TO PUBLIC"
                ).format(sql.Identifier(schema_name))
            )
            connection.execute("RESET ROLE")

            provision_database_roles(
                connection,
                database_name=database_name,
                runtime_role=runtime_role,
                runtime_password=runtime_password,
                migrator_role=migrator_role,
                migrator_password=migrator_password,
                schema_name=schema_name,
            )

            excess_table_privileges = connection.execute(
                """
                SELECT
                    has_table_privilege(%s, %s, 'TRUNCATE'),
                    has_table_privilege(%s, %s, 'REFERENCES'),
                    has_table_privilege(%s, %s, 'TRIGGER')
                """,
                (
                    runtime_role,
                    f"{schema_name}.items",
                    runtime_role,
                    f"{schema_name}.items",
                    runtime_role,
                    f"{schema_name}.items",
                ),
            ).fetchone()
            assert excess_table_privileges == (False, False, False)

            sequence_name = connection.execute(
                "SELECT pg_get_serial_sequence(%s, 'id')",
                (f"{schema_name}.migration_created",),
            ).fetchone()[0]
            assert sequence_name is not None
            assert not connection.execute(
                "SELECT has_sequence_privilege(%s, %s, 'UPDATE')",
                (runtime_role, sequence_name),
            ).fetchone()[0]
            assert not connection.execute(
                "SELECT has_schema_privilege(%s, %s, 'CREATE')",
                (runtime_role, schema_name),
            ).fetchone()[0]
            assert not connection.execute(
                "SELECT has_function_privilege(%s, %s, 'EXECUTE')",
                (runtime_role, f"{schema_name}.private_value()"),
            ).fetchone()[0]

        # New SECURITY DEFINER functions created by Alembic/migrator must not
        # inherit PostgreSQL's default EXECUTE grant to PUBLIC.
        with psycopg.connect(migrator_conninfo) as connection:
            connection.execute(
                sql.SQL(
                    "CREATE FUNCTION {}.future_value() RETURNS text "
                    "LANGUAGE sql SECURITY DEFINER AS {}"
                ).format(
                    sql.Identifier(schema_name),
                    sql.Literal("SELECT 'future-private-data'::text"),
                )
            )

        with psycopg.connect(admin_conninfo) as connection:
            assert not connection.execute(
                "SELECT has_function_privilege(%s, %s, 'EXECUTE')",
                (runtime_role, f"{schema_name}.future_value()"),
            ).fetchone()[0]

        with psycopg.connect(runtime_conninfo) as connection:
            connection.execute(
                sql.SQL(
                    "INSERT INTO {}.migration_created (name) VALUES ('runtime-after-migration')"
                ).format(sql.Identifier(schema_name))
            )
            row = connection.execute(
                sql.SQL(
                    "SELECT name FROM {}.migration_created WHERE id = 1"
                ).format(sql.Identifier(schema_name))
            ).fetchone()
            assert row == ("runtime-after-migration",)

        with (
            pytest.raises(psycopg.errors.InsufficientPrivilege),
            psycopg.connect(runtime_conninfo) as connection,
        ):
            connection.execute(
                sql.SQL("SELECT {}.private_value()").format(
                    sql.Identifier(schema_name)
                )
            ).fetchone()

        with (
            pytest.raises(psycopg.errors.InsufficientPrivilege),
            psycopg.connect(runtime_conninfo) as connection,
        ):
            connection.execute(
                sql.SQL("SELECT {}.future_value()").format(
                    sql.Identifier(schema_name)
                )
            ).fetchone()

        with psycopg.connect(provisioner_conninfo) as connection:
            connection.execute(
                sql.SQL("DROP SCHEMA {} CASCADE").format(sql.Identifier(schema_name))
            )
            connection.execute(
                sql.SQL("REVOKE CONNECT ON DATABASE {} FROM {}, {}").format(
                    sql.Identifier(database_name),
                    sql.Identifier(runtime_role),
                    sql.Identifier(migrator_role),
                )
            )
            for role in (
                runtime_role,
                migrator_role,
                runtime_inherited_role,
                migrator_inherited_role,
            ):
                connection.execute(sql.SQL("DROP ROLE {}").format(sql.Identifier(role)))
        with psycopg.connect(admin_conninfo) as connection:
            connection.execute(
                sql.SQL("DROP OWNED BY {}").format(sql.Identifier(provisioner_role))
            )
            connection.execute(sql.SQL("DROP ROLE {}").format(sql.Identifier(provisioner_role)))
    except Exception:
        # Best-effort cleanup keeps random test objects out of the shared
        # PostgreSQL service even when an assertion exposes a privilege defect.
        try:
            with psycopg.connect(provisioner_conninfo) as connection:
                connection.execute(
                    sql.SQL("DROP SCHEMA IF EXISTS {} CASCADE").format(
                        sql.Identifier(schema_name)
                    )
                )
                connection.execute(
                    sql.SQL("REVOKE CONNECT ON DATABASE {} FROM {}, {}").format(
                        sql.Identifier(database_name),
                        sql.Identifier(runtime_role),
                        sql.Identifier(migrator_role),
                    )
                )
                for role in (
                    runtime_role,
                    migrator_role,
                    runtime_inherited_role,
                    migrator_inherited_role,
                ):
                    if connection.execute(
                        "SELECT 1 FROM pg_roles WHERE rolname = %s",
                        (role,),
                    ).fetchone():
                        connection.execute(sql.SQL("DROP ROLE {}").format(sql.Identifier(role)))
        except Exception:
            pass
        try:
            with psycopg.connect(admin_conninfo) as connection:
                if connection.execute(
                    "SELECT 1 FROM pg_roles WHERE rolname = %s",
                    (provisioner_role,),
                ).fetchone():
                    connection.execute(
                        sql.SQL("DROP OWNED BY {}").format(sql.Identifier(provisioner_role))
                    )
                    connection.execute(
                        sql.SQL("DROP ROLE {}").format(sql.Identifier(provisioner_role))
                    )
        except Exception:
            pass
        raise
