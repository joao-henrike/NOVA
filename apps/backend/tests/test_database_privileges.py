from __future__ import annotations

from unittest.mock import MagicMock, Mock, patch
from uuid import uuid4

import psycopg
import pytest
from psycopg import sql
from psycopg.conninfo import make_conninfo
from sqlalchemy.engine import make_url

from app.core.config import settings
from app.db.bootstrap_roles import (
    _ensure_login_role,
    _required_env,
    _revoke_role_memberships,
    _set_current_user_role_option,
    _transfer_schema_objects,
    _validate_role,
    provision_database_roles,
)
from app.db.bootstrap_roles import (
    main as bootstrap_main,
)


def _database_url():
    try:
        url = make_url(settings.sqlalchemy_database_url)
    except RuntimeError:
        pytest.skip("A PostgreSQL database connection is required for this test.")
    if url.get_backend_name() != "postgresql":
        pytest.skip("Database role integration test requires PostgreSQL.")
    return url


def _connection_info(
    *,
    user: str,
    password: str,
    database: str | None = None,
) -> str:
    url = _database_url()

    return make_conninfo(
        host=url.host,
        port=url.port or 5432,
        dbname=database or url.database,
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

    database_name = f"nova_priv_{uuid4().hex[:12]}"
    runtime_role = f"nova_rt_{uuid4().hex[:16]}"
    migrator_role = f"nova_mg_{uuid4().hex[:16]}"
    runtime_inherited_role = f"nova_rti_{uuid4().hex[:14]}"
    migrator_inherited_role = f"nova_mgi_{uuid4().hex[:14]}"
    guest_role = f"nova_guest_{uuid4().hex[:14]}"
    runtime_password = "runtime-test-" + uuid4().hex + uuid4().hex
    migrator_password = "migrator-test-" + uuid4().hex + uuid4().hex
    schema_name = f"nova_test_{uuid4().hex[:16]}"

    provisioner_role = f"nova_pr_{uuid4().hex[:16]}"
    provisioner_password = "provisioner-test-" + uuid4().hex + uuid4().hex
    admin_conninfo = _connection_info(user=admin_user, password=admin_password)
    provisioner_conninfo = _connection_info(
        user=provisioner_role,
        password=provisioner_password,
        database=database_name,
    )

    try:
        # Simulate the RDS master-user capability boundary: this identity can
        # create roles but is not a PostgreSQL superuser.
        with psycopg.connect(admin_conninfo, autocommit=True) as connection:
            connection.execute(
                sql.SQL("CREATE ROLE {} WITH LOGIN CREATEROLE PASSWORD {}").format(
                    sql.Identifier(provisioner_role),
                    sql.Literal(provisioner_password),
                )
            )
            # CREATEROLE administrators receive ADMIN but not SET by default.
            # Enable SET temporarily so the new identity can own its isolated DB.
            connection.execute(
                sql.SQL("GRANT {} TO CURRENT_USER WITH SET TRUE, INHERIT FALSE").format(
                    sql.Identifier(provisioner_role)
                )
            )
            connection.execute(
                sql.SQL("CREATE DATABASE {} OWNER {}").format(
                    sql.Identifier(database_name),
                    sql.Identifier(provisioner_role),
                )
            )

        with psycopg.connect(provisioner_conninfo) as connection:
            provisioner_attributes = connection.execute(
                "SELECT rolsuper, rolcreaterole FROM pg_roles WHERE rolname = current_user"
            ).fetchone()
            assert provisioner_attributes == (False, True)
            connection.execute(
                sql.SQL("CREATE ROLE {} NOLOGIN").format(sql.Identifier(guest_role))
            )
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
            # Simulate stale direct database grants from an older deployment.
            connection.execute(
                sql.SQL("GRANT TEMPORARY ON DATABASE {} TO {}, {}").format(
                    sql.Identifier(database_name),
                    sql.Identifier(runtime_role),
                    sql.Identifier(migrator_role),
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
            assert connection.execute(
                "SELECT has_database_privilege(%s, %s, 'CONNECT')",
                (runtime_role, database_name),
            ).fetchone()[0]
            assert not connection.execute(
                "SELECT has_database_privilege(%s, %s, 'TEMP')",
                (runtime_role, database_name),
            ).fetchone()[0]
            assert connection.execute(
                "SELECT has_database_privilege(%s, %s, 'CONNECT')",
                (migrator_role, database_name),
            ).fetchone()[0]
            assert not connection.execute(
                "SELECT has_database_privilege(%s, %s, 'TEMP')",
                (migrator_role, database_name),
            ).fetchone()[0]
            assert not connection.execute(
                "SELECT has_database_privilege(%s, %s, 'CONNECT')",
                (guest_role, database_name),
            ).fetchone()[0]
            assert not connection.execute(
                "SELECT has_database_privilege(%s, %s, 'TEMP')",
                (guest_role, database_name),
            ).fetchone()[0]
            assert not connection.execute(
                "SELECT has_schema_privilege(%s, %s, 'USAGE')",
                (guest_role, schema_name),
            ).fetchone()[0]
            assert not connection.execute(
                "SELECT has_schema_privilege(%s, %s, 'CREATE')",
                (guest_role, schema_name),
            ).fetchone()[0]

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
            database=database_name,
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
            connection.execute("CREATE TEMP TABLE runtime_temp (id integer)")

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
            database=database_name,
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

            # Inject stale global and schema-specific defaults for tables,
            # sequences and functions. A later object created by Alembic must
            # not silently inherit them.
            for scope in ("", f"IN SCHEMA {sql.Identifier(schema_name).as_string(connection)} "):
                connection.execute(
                    sql.SQL("ALTER DEFAULT PRIVILEGES {}GRANT ALL ON TABLES TO PUBLIC").format(
                        sql.SQL(scope)
                    )
                )
                connection.execute(
                    sql.SQL("ALTER DEFAULT PRIVILEGES {}GRANT ALL ON SEQUENCES TO PUBLIC").format(
                        sql.SQL(scope)
                    )
                )
                connection.execute(
                    sql.SQL("ALTER DEFAULT PRIVILEGES {}GRANT EXECUTE ON FUNCTIONS TO PUBLIC").format(
                        sql.SQL(scope)
                    )
                )
                connection.execute(
                    sql.SQL("ALTER DEFAULT PRIVILEGES {}GRANT ALL ON TABLES TO {}").format(
                        sql.SQL(scope), sql.Identifier(runtime_role)
                    )
                )
                connection.execute(
                    sql.SQL("ALTER DEFAULT PRIVILEGES {}GRANT ALL ON SEQUENCES TO {}").format(
                        sql.SQL(scope), sql.Identifier(runtime_role)
                    )
                )
                connection.execute(
                    sql.SQL("ALTER DEFAULT PRIVILEGES {}GRANT EXECUTE ON FUNCTIONS TO {}").format(
                        sql.SQL(scope), sql.Identifier(runtime_role)
                    )
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
            connection.execute(
                sql.SQL(
                    "CREATE TABLE {}.future_items ("
                    "id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, "
                    "value text NOT NULL)"
                ).format(sql.Identifier(schema_name))
            )

        with psycopg.connect(provisioner_conninfo) as connection:
            future_sequence = connection.execute(
                "SELECT pg_get_serial_sequence(%s, 'id')",
                (f"{schema_name}.future_items",),
            ).fetchone()[0]
            assert future_sequence is not None

            # Stale defaults must not be inherited by objects created later.
            for principal in (runtime_role, guest_role):
                assert not connection.execute(
                    "SELECT has_table_privilege(%s, %s, 'SELECT')",
                    (principal, f"{schema_name}.future_items"),
                ).fetchone()[0]
                assert not connection.execute(
                    "SELECT has_sequence_privilege(%s, %s, 'USAGE')",
                    (principal, future_sequence),
                ).fetchone()[0]
                assert not connection.execute(
                    "SELECT has_function_privilege(%s, %s, 'EXECUTE')",
                    (principal, f"{schema_name}.future_value()"),
                ).fetchone()[0]

            # Bootstrap again after Alembic-style object creation: it should
            # give runtime only the intended table DML and sequence privileges.
            provision_database_roles(
                connection,
                database_name=database_name,
                runtime_role=runtime_role,
                runtime_password=runtime_password,
                migrator_role=migrator_role,
                migrator_password=migrator_password,
                schema_name=schema_name,
            )

            assert not connection.execute(
                "SELECT has_table_privilege(%s, %s, 'SELECT')",
                (guest_role, f"{schema_name}.future_items"),
            ).fetchone()[0]
            assert not connection.execute(
                "SELECT has_sequence_privilege(%s, %s, 'USAGE')",
                (guest_role, future_sequence),
            ).fetchone()[0]
            assert not connection.execute(
                "SELECT has_function_privilege(%s, %s, 'EXECUTE')",
                (guest_role, f"{schema_name}.future_value()"),
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

            connection.execute(
                sql.SQL(
                    "INSERT INTO {}.future_items (value) VALUES ('future-runtime-access')"
                ).format(sql.Identifier(schema_name))
            )
            future_row = connection.execute(
                sql.SQL(
                    "SELECT value FROM {}.future_items WHERE id = 1"
                ).format(sql.Identifier(schema_name))
            ).fetchone()
            assert future_row == ("future-runtime-access",)

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

        with psycopg.connect(admin_conninfo, autocommit=True) as connection:
            # The provisioner owns the disposable database and created all test
            # roles. Drop the database first so its objects/default ACLs vanish.
            connection.execute(
                sql.SQL("SET ROLE {}").format(sql.Identifier(provisioner_role))
            )
            connection.execute(
                sql.SQL("DROP DATABASE {}").format(sql.Identifier(database_name))
            )
            for role in (
                runtime_role,
                migrator_role,
                runtime_inherited_role,
                migrator_inherited_role,
                guest_role,
            ):
                connection.execute(sql.SQL("DROP ROLE {}").format(sql.Identifier(role)))
            connection.execute("RESET ROLE")
            connection.execute(
                sql.SQL("REVOKE {} FROM CURRENT_USER").format(
                    sql.Identifier(provisioner_role)
                )
            )
            connection.execute(
                sql.SQL("DROP ROLE {}").format(sql.Identifier(provisioner_role))
            )
    except Exception:
        # Best-effort cleanup keeps random test objects out of the shared
        # PostgreSQL service even when an assertion exposes a privilege defect.
        try:
            with psycopg.connect(admin_conninfo, autocommit=True) as connection:
                provisioner_exists = connection.execute(
                    "SELECT 1 FROM pg_roles WHERE rolname = %s",
                    (provisioner_role,),
                ).fetchone()
                if provisioner_exists:
                    connection.execute(
                        sql.SQL("SET ROLE {}").format(sql.Identifier(provisioner_role))
                    )
                    connection.execute(
                        sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(
                            sql.Identifier(database_name)
                        )
                    )
                    for role in (
                        runtime_role,
                        migrator_role,
                        runtime_inherited_role,
                        migrator_inherited_role,
                        guest_role,
                    ):
                        if connection.execute(
                            "SELECT 1 FROM pg_roles WHERE rolname = %s",
                            (role,),
                        ).fetchone():
                            connection.execute(
                                sql.SQL("DROP ROLE {}").format(sql.Identifier(role))
                            )
                    connection.execute("RESET ROLE")
                    connection.execute(
                        sql.SQL("REVOKE {} FROM CURRENT_USER").format(
                            sql.Identifier(provisioner_role)
                        )
                    )
                    connection.execute(
                        sql.SQL("DROP ROLE {}").format(sql.Identifier(provisioner_role))
                    )
        except Exception:
            pass
        raise


def test_required_environment_values_are_rejected_when_missing_or_blank(monkeypatch) -> None:
    monkeypatch.delenv("NOVA_TEST_REQUIRED", raising=False)
    with pytest.raises(RuntimeError, match="NOVA_TEST_REQUIRED"):
        _required_env("NOVA_TEST_REQUIRED")

    monkeypatch.setenv("NOVA_TEST_REQUIRED", "   ")
    with pytest.raises(RuntimeError, match="NOVA_TEST_REQUIRED"):
        _required_env("NOVA_TEST_REQUIRED")

    monkeypatch.setenv("NOVA_TEST_REQUIRED", "configured-value")
    assert _required_env("NOVA_TEST_REQUIRED") == "configured-value"


def test_role_validation_rejects_invalid_names_and_weak_passwords() -> None:
    with pytest.raises(RuntimeError, match="valid PostgreSQL role"):
        _validate_role("invalid-role", "x" * 32, env_name="DB_RUNTIME_USER")

    with pytest.raises(RuntimeError, match="DB_MIGRATOR_PASSWORD"):
        _validate_role("valid_role", "short", env_name="DB_MIGRATOR_USER")

    _validate_role("valid_role_2", "x" * 32, env_name="DB_RUNTIME_USER")


def test_ensure_login_role_creates_and_rotates_least_privilege_roles() -> None:
    def run(existing):
        first = Mock()
        first.fetchone.return_value = existing
        attributes = Mock()
        attributes.fetchone.return_value = (False, False, False, False, False)
        connection = Mock()
        connection.execute.side_effect = [first, Mock(), attributes]

        _ensure_login_role(
            connection,
            role_name="nova_runtime",
            password="r" * 32,
        )
        assert connection.execute.call_count == 3
        statement = str(connection.execute.call_args_list[1].args[0])
        if existing:
            assert "ALTER ROLE" in statement
        else:
            assert "CREATE ROLE" in statement
            assert "NOBYPASSRLS" in statement

    run(None)
    run(("nova_runtime",))


def test_ensure_login_role_fails_closed_when_role_attributes_are_unsafe() -> None:
    first = Mock()
    first.fetchone.return_value = None
    attributes = Mock()
    attributes.fetchone.return_value = (True, False, False, False, False)
    connection = Mock()
    connection.execute.side_effect = [first, Mock(), attributes]

    with pytest.raises(RuntimeError, match="elevated attributes"):
        _ensure_login_role(
            connection,
            role_name="nova_runtime",
            password="r" * 32,
        )


def test_revoke_role_memberships_removes_inherited_roles_and_verifies_result() -> None:
    memberships = Mock()
    memberships.fetchall.return_value = [("inherited_role",)]
    remaining = Mock()
    remaining.fetchone.return_value = (False,)
    connection = Mock()
    connection.execute.side_effect = [memberships, Mock(), remaining]

    _revoke_role_memberships(connection, role_name="nova_runtime")
    assert connection.execute.call_count == 3

    no_memberships = Mock()
    no_memberships.fetchall.return_value = []
    no_remaining = Mock()
    no_remaining.fetchone.return_value = (False,)
    clean_connection = Mock()
    clean_connection.execute.side_effect = [no_memberships, no_remaining]
    _revoke_role_memberships(clean_connection, role_name="nova_runtime")


def test_revoke_role_memberships_fails_when_inherited_access_remains() -> None:
    memberships = Mock()
    memberships.fetchall.return_value = []
    remaining = Mock()
    remaining.fetchone.return_value = (True,)
    connection = Mock()
    connection.execute.side_effect = [memberships, remaining]

    with pytest.raises(RuntimeError, match="Unable to remove"):
        _revoke_role_memberships(connection, role_name="nova_runtime")


@pytest.mark.parametrize("can_set", [True, False])
def test_current_user_role_option_is_verified_for_both_states(can_set) -> None:
    membership = Mock()
    membership.fetchone.return_value = (True,)
    connection = Mock()
    connection.execute.side_effect = [Mock(), membership]

    _set_current_user_role_option(
        connection,
        role_name="nova_migrator",
        can_set=can_set,
    )
    assert connection.execute.call_count == 2


def test_current_user_role_option_fails_when_membership_does_not_match() -> None:
    membership = Mock()
    membership.fetchone.return_value = (False,)
    connection = Mock()
    connection.execute.side_effect = [Mock(), membership]

    with pytest.raises(RuntimeError, match="Unable to ensure SET ROLE"):
        _set_current_user_role_option(
            connection,
            role_name="nova_migrator",
            can_set=True,
        )


def test_transfer_schema_objects_skips_owned_objects_and_transfers_legacy_objects() -> None:
    rows = (
        [("owned_table", "nova_migrator"), ("legacy_table", "admin")],
        [("owned_sequence", "nova_migrator"), ("legacy_sequence", "admin")],
        [("owned_view", "nova_migrator"), ("legacy_view", "admin")],
        [("owned_matview", "nova_migrator"), ("legacy_matview", "admin")],
        [
            ("FUNCTION", "public.owned_function()", "nova_migrator"),
            ("FUNCTION", "public.legacy_function()", "admin"),
        ],
    )
    def result_for(result_rows):
        result = Mock()
        result.fetchall.return_value = result_rows
        return result

    def execute(statement, *args, **kwargs):
        query = str(statement)
        if "FROM pg_tables" in query:
            return result_for(rows[0])
        if "relkind = 'S'" in query:
            return result_for(rows[1])
        if "relkind = 'v'" in query:
            return result_for(rows[2])
        if "relkind = 'm'" in query:
            return result_for(rows[3])
        if "pg_get_function_identity_arguments" in query:
            return result_for(rows[4])
        return Mock()

    connection = Mock()
    connection.execute.side_effect = execute

    _transfer_schema_objects(
        connection,
        schema_name="public",
        owner_role="nova_migrator",
    )

    assert connection.execute.call_count == 10


def test_role_provisioning_rejects_invalid_inputs_before_database_changes() -> None:
    connection = Mock()
    password = "p" * 32
    common = {
        "database_name": "nova",
        "runtime_password": password,
        "migrator_password": password,
    }

    with pytest.raises(RuntimeError, match="must be different"):
        provision_database_roles(
            connection,
            runtime_role="same_role",
            migrator_role="same_role",
            **common,
        )

    with pytest.raises(RuntimeError, match="schema identifier"):
        provision_database_roles(
            connection,
            runtime_role="runtime_role",
            migrator_role="migrator_role",
            schema_name="invalid-schema",
            **common,
        )

    connection.execute.return_value.fetchone.return_value = None
    with pytest.raises(RuntimeError, match="Unable to determine"):
        provision_database_roles(
            connection,
            runtime_role="runtime_role",
            migrator_role="migrator_role",
            **common,
        )

    connection.reset_mock()
    connection.execute.return_value.fetchone.return_value = ("another_database",)
    with pytest.raises(RuntimeError, match="does not match DB_NAME"):
        provision_database_roles(
            connection,
            runtime_role="runtime_role",
            migrator_role="migrator_role",
            **common,
        )


def test_bootstrap_main_builds_connection_from_environment(monkeypatch) -> None:
    values = {
        "DB_HOST": "db.example",
        "DB_NAME": "nova",
        "DB_ADMIN_USER": "db_admin",
        "DB_ADMIN_PASSWORD": "a" * 32,
        "DB_RUNTIME_USER": "runtime_role",
        "DB_RUNTIME_PASSWORD": "r" * 32,
        "DB_MIGRATOR_USER": "migrator_role",
        "DB_MIGRATOR_PASSWORD": "m" * 32,
    }
    for name, value in values.items():
        monkeypatch.setenv(name, value)
    monkeypatch.delenv("DB_PORT", raising=False)
    monkeypatch.delenv("DB_SCHEMA_NAME", raising=False)
    monkeypatch.delenv("DB_SSLMODE", raising=False)

    connection = Mock()
    connection_context = MagicMock()
    connection_context.__enter__.return_value = connection
    connect = Mock(return_value=connection_context)

    with (
        patch("app.db.bootstrap_roles.psycopg.connect", connect),
        patch("app.db.bootstrap_roles.provision_database_roles") as provision,
    ):
        bootstrap_main()

    conninfo = connect.call_args.args[0]
    assert "host=db.example" in conninfo
    assert "port=5432" in conninfo
    assert "dbname=nova" in conninfo
    assert "sslmode=prefer" in conninfo
    provision.assert_called_once_with(
        connection,
        database_name="nova",
        runtime_role="runtime_role",
        runtime_password="r" * 32,
        migrator_role="migrator_role",
        migrator_password="m" * 32,
        schema_name="public",
    )


def test_bootstrap_main_rejects_admin_as_application_role(monkeypatch) -> None:
    values = {
        "DB_HOST": "db.example",
        "DB_NAME": "nova",
        "DB_ADMIN_USER": "runtime_role",
        "DB_ADMIN_PASSWORD": "a" * 32,
        "DB_RUNTIME_USER": "runtime_role",
        "DB_RUNTIME_PASSWORD": "r" * 32,
        "DB_MIGRATOR_USER": "migrator_role",
        "DB_MIGRATOR_PASSWORD": "m" * 32,
    }
    for name, value in values.items():
        monkeypatch.setenv(name, value)

    with pytest.raises(RuntimeError, match="RDS master identity"):
        bootstrap_main()


