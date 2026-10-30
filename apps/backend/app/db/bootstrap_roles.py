"""Provision separate runtime and migration roles in the application database.

This command must run as the RDS-managed master identity from a one-off ECS task.
It is intentionally not part of normal API startup.
"""

from __future__ import annotations

import os
import re

import psycopg
from psycopg import sql
from psycopg.conninfo import make_conninfo

_ROLE_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,62}$")


def _required_env(name: str) -> str:
    value = os.getenv(name)
    if value is None or not value.strip():
        raise RuntimeError(f"Required environment variable {name} is missing.")
    return value


def _validate_role(name: str, password: str, *, env_name: str) -> None:
    if not _ROLE_PATTERN.fullmatch(name):
        raise RuntimeError(f"{env_name} is not a valid PostgreSQL role identifier.")
    if len(password) < 32:
        raise RuntimeError(f"{env_name.replace('_USER', '_PASSWORD')} must be at least 32 characters.")


def _ensure_login_role(
    connection: psycopg.Connection,
    *,
    role_name: str,
    password: str,
) -> None:
    exists = connection.execute(
        "SELECT 1 FROM pg_roles WHERE rolname = %s",
        (role_name,),
    ).fetchone()

    action = "ALTER ROLE" if exists else "CREATE ROLE"
    statement = sql.SQL(
        "{} {} WITH LOGIN PASSWORD {} "
        "NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS"
    ).format(
        sql.SQL(action),
        sql.Identifier(role_name),
        sql.Literal(password),
    )
    connection.execute(statement)


def _transfer_schema_objects(
    connection: psycopg.Connection,
    *,
    schema_name: str,
    owner_role: str,
) -> None:
    tables = connection.execute(
        """
        SELECT tablename
        FROM pg_tables
        WHERE schemaname = %s
        """,
        (schema_name,),
    ).fetchall()
    for (table_name,) in tables:
        connection.execute(
            sql.SQL("ALTER TABLE {}.{} OWNER TO {}").format(
                sql.Identifier(schema_name),
                sql.Identifier(table_name),
                sql.Identifier(owner_role),
            )
        )

    sequences = connection.execute(
        """
        SELECT c.relname
        FROM pg_class AS c
        JOIN pg_namespace AS n ON n.oid = c.relnamespace
        WHERE n.nspname = %s AND c.relkind = 'S'
        """,
        (schema_name,),
    ).fetchall()
    for (sequence_name,) in sequences:
        connection.execute(
            sql.SQL("ALTER SEQUENCE {}.{} OWNER TO {}").format(
                sql.Identifier(schema_name),
                sql.Identifier(sequence_name),
                sql.Identifier(owner_role),
            )
        )

    views = connection.execute(
        """
        SELECT table_name
        FROM information_schema.views
        WHERE table_schema = %s
        """,
        (schema_name,),
    ).fetchall()
    for (view_name,) in views:
        connection.execute(
            sql.SQL("ALTER VIEW {}.{} OWNER TO {}").format(
                sql.Identifier(schema_name),
                sql.Identifier(view_name),
                sql.Identifier(owner_role),
            )
        )

    materialized_views = connection.execute(
        """
        SELECT c.relname
        FROM pg_class AS c
        JOIN pg_namespace AS n ON n.oid = c.relnamespace
        WHERE n.nspname = %s AND c.relkind = 'm'
        """,
        (schema_name,),
    ).fetchall()
    for (view_name,) in materialized_views:
        connection.execute(
            sql.SQL("ALTER MATERIALIZED VIEW {}.{} OWNER TO {}").format(
                sql.Identifier(schema_name),
                sql.Identifier(view_name),
                sql.Identifier(owner_role),
            )
        )


def provision_database_roles(
    connection: psycopg.Connection,
    *,
    database_name: str,
    runtime_role: str,
    runtime_password: str,
    migrator_role: str,
    migrator_password: str,
    schema_name: str = "public",
) -> None:
    """Create/update least-privilege logins and apply schema ownership/grants.

    The runtime login gets DML only. The migration login owns schema objects and
    can create/alter them. This function is idempotent and safe to re-run after
    each Alembic upgrade to grant runtime access to newly-created objects.
    """
    _validate_role(runtime_role, runtime_password, env_name="DB_RUNTIME_USER")
    _validate_role(migrator_role, migrator_password, env_name="DB_MIGRATOR_USER")
    if runtime_role == migrator_role:
        raise RuntimeError("Runtime and migration roles must be different.")
    if not _ROLE_PATTERN.fullmatch(schema_name):
        raise RuntimeError("DB_SCHEMA_NAME is not a valid PostgreSQL schema identifier.")
    database_row = connection.execute("SELECT current_database()").fetchone()
    if database_row is None:
        raise RuntimeError("Unable to determine the connected PostgreSQL database.")
    current_database = database_row[0]
    if current_database != database_name:
        raise RuntimeError("Connected database does not match DB_NAME.")

    _ensure_login_role(
        connection,
        role_name=runtime_role,
        password=runtime_password,
    )
    _ensure_login_role(
        connection,
        role_name=migrator_role,
        password=migrator_password,
    )

    connection.execute(
        sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(
            sql.Identifier(database_name),
            sql.Identifier(runtime_role),
        )
    )
    connection.execute(
        sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(
            sql.Identifier(database_name),
            sql.Identifier(migrator_role),
        )
    )

    # PostgreSQL 15+ revokes CREATE on public by default; keep that boundary
    # explicit, including databases upgraded from older defaults.
    connection.execute(
        sql.SQL("REVOKE CREATE ON SCHEMA {} FROM PUBLIC").format(
            sql.Identifier(schema_name)
        )
    )
    connection.execute(
        sql.SQL("GRANT USAGE ON SCHEMA {} TO {}").format(
            sql.Identifier(schema_name),
            sql.Identifier(runtime_role),
        )
    )
    connection.execute(
        sql.SQL("REVOKE CREATE ON SCHEMA {} FROM {}").format(
            sql.Identifier(schema_name),
            sql.Identifier(runtime_role),
        )
    )
    connection.execute(
        sql.SQL("GRANT USAGE, CREATE ON SCHEMA {} TO {}").format(
            sql.Identifier(schema_name),
            sql.Identifier(migrator_role),
        )
    )

    # Existing Alembic-managed objects were originally created by the master
    # login. Transfer app-schema ownership so later DDL runs as the migrator.
    _transfer_schema_objects(
        connection,
        schema_name=schema_name,
        owner_role=migrator_role,
    )

    connection.execute(
        sql.SQL(
            "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {} TO {}"
        ).format(
            sql.Identifier(schema_name),
            sql.Identifier(runtime_role),
        )
    )
    connection.execute(
        sql.SQL(
            "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA {} TO {}"
        ).format(
            sql.Identifier(schema_name),
            sql.Identifier(runtime_role),
        )
    )


def main() -> None:
    host = _required_env("DB_HOST")
    port = int(os.getenv("DB_PORT", "5432"))
    database_name = _required_env("DB_NAME")
    admin_user = _required_env("DB_ADMIN_USER")
    admin_password = _required_env("DB_ADMIN_PASSWORD")
    runtime_role = _required_env("DB_RUNTIME_USER")
    runtime_password = _required_env("DB_RUNTIME_PASSWORD")
    migrator_role = _required_env("DB_MIGRATOR_USER")
    migrator_password = _required_env("DB_MIGRATOR_PASSWORD")
    schema_name = os.getenv("DB_SCHEMA_NAME", "public")

    if admin_user in {runtime_role, migrator_role}:
        raise RuntimeError("The RDS master identity cannot be an application role.")

    conninfo = make_conninfo(
        host=host,
        port=port,
        dbname=database_name,
        user=admin_user,
        password=admin_password,
        connect_timeout=10,
        application_name="cloudstart-db-role-bootstrap",
        sslmode=os.getenv("DB_SSLMODE", "prefer"),
    )

    with psycopg.connect(conninfo) as connection:
        provision_database_roles(
            connection,
            database_name=database_name,
            runtime_role=runtime_role,
            runtime_password=runtime_password,
            migrator_role=migrator_role,
            migrator_password=migrator_password,
            schema_name=schema_name,
        )

    print(
        "Database roles provisioned: runtime has DML-only access; "
        "migrator owns application schema objects."
    )


if __name__ == "__main__":
    main()
