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
    runtime_password = "runtime-test-" + uuid4().hex + uuid4().hex
    migrator_password = "migrator-test-" + uuid4().hex + uuid4().hex
    schema_name = f"nova_test_{uuid4().hex[:16]}"

    admin_conninfo = _connection_info(user=admin_user, password=admin_password)

    try:
        with psycopg.connect(admin_conninfo) as connection:
            connection.execute(
                sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(schema_name))
            )
            connection.execute(
                sql.SQL(
                    "CREATE TABLE {}.items (id integer PRIMARY KEY, name text NOT NULL)"
                ).format(sql.Identifier(schema_name))
            )
            connection.execute(
                sql.SQL("INSERT INTO {}.items (id, name) VALUES (1, 'before')")
                .format(sql.Identifier(schema_name))
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

            owner = connection.execute(
                """
                SELECT tableowner
                FROM pg_tables
                WHERE schemaname = %s AND tablename = 'items'
                """,
                (schema_name,),
            ).fetchone()
            assert owner == (migrator_role,)

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

        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            with psycopg.connect(runtime_conninfo) as connection:
                connection.execute(
                    sql.SQL("CREATE TABLE {}.runtime_created (id integer)").format(
                        sql.Identifier(schema_name)
                    )
                )

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
                sql.SQL("CREATE TABLE {}.migration_created (id integer)").format(
                    sql.Identifier(schema_name)
                )
            )

        with psycopg.connect(admin_conninfo) as connection:
            connection.execute(
                sql.SQL("DROP SCHEMA {} CASCADE").format(sql.Identifier(schema_name))
            )
            for role in (runtime_role, migrator_role):
                if connection.execute(
                    "SELECT 1 FROM pg_roles WHERE rolname = %s",
                    (role,),
                ).fetchone():
                    connection.execute(
                        sql.SQL("DROP OWNED BY {}").format(sql.Identifier(role))
                    )
                    connection.execute(
                        sql.SQL("DROP ROLE {}").format(sql.Identifier(role))
                    )
    except Exception:
        # Best-effort cleanup keeps random test roles/schemas out of the shared
        # PostgreSQL service even when an assertion exposes a privilege defect.
        with psycopg.connect(admin_conninfo) as connection:
            connection.execute(
                sql.SQL("DROP SCHEMA IF EXISTS {} CASCADE").format(
                    sql.Identifier(schema_name)
                )
            )
            for role in (runtime_role, migrator_role):
                if connection.execute(
                    "SELECT 1 FROM pg_roles WHERE rolname = %s",
                    (role,),
                ).fetchone():
                    connection.execute(
                        sql.SQL("DROP OWNED BY {}").format(sql.Identifier(role))
                    )
                    connection.execute(
                        sql.SQL("DROP ROLE {}").format(sql.Identifier(role))
                    )
        raise
