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

    if exists:
        # A CREATEROLE administrator may rotate credentials for a role it
        # administers, but cannot change the SUPERUSER attribute. Do not send
        # NOSUPERUSER during ALTER ROLE: it is a superuser-only operation.
        statement = sql.SQL("ALTER ROLE {} WITH LOGIN PASSWORD {}").format(
            sql.Identifier(role_name),
            sql.Literal(password),
        )
        connection.execute(statement)
    else:
        # Safe attributes are enforced at creation time, when they are
        # controlled by the role-creating administrator.
        statement = sql.SQL(
            "CREATE ROLE {} WITH LOGIN PASSWORD {} "
            "NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS"
        ).format(
            sql.Identifier(role_name),
            sql.Literal(password),
        )
        connection.execute(statement)

    attributes = connection.execute(
        """
        SELECT rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls
        FROM pg_roles
        WHERE rolname = %s
        """,
        (role_name,),
    ).fetchone()
    if attributes is None:
        raise RuntimeError(f"PostgreSQL role {role_name} was not found after provisioning.")
    if any(attributes):
        raise RuntimeError(
            f"PostgreSQL role {role_name} has elevated attributes; "
            "refusing to continue with a non-least-privilege application identity."
        )


def _revoke_role_memberships(
    connection: psycopg.Connection,
    *,
    role_name: str,
) -> None:
    """Remove inherited role memberships so grants cannot bypass direct ACLs."""
    memberships = connection.execute(
        """
        SELECT DISTINCT granted_role.rolname
        FROM pg_auth_members AS membership
        JOIN pg_roles AS granted_role ON granted_role.oid = membership.roleid
        JOIN pg_roles AS member_role ON member_role.oid = membership.member
        WHERE member_role.rolname = %s
        """,
        (role_name,),
    ).fetchall()

    for (granted_role,) in memberships:
        connection.execute(
            sql.SQL("REVOKE {} FROM {}").format(
                sql.Identifier(granted_role),
                sql.Identifier(role_name),
            )
        )

    remaining = connection.execute(
        """
        SELECT EXISTS (
            SELECT 1
            FROM pg_auth_members AS membership
            JOIN pg_roles AS member_role ON member_role.oid = membership.member
            WHERE member_role.rolname = %s
        )
        """,
        (role_name,),
    ).fetchone()
    if remaining is None or remaining[0]:
        raise RuntimeError(
            f"Unable to remove all inherited role memberships from {role_name}."
        )


def _set_current_user_role_option(
    connection: psycopg.Connection,
    *,
    role_name: str,
    can_set: bool,
) -> None:
    """Temporarily allow the bootstrap identity to assume the migrator role."""
    option = sql.SQL("TRUE" if can_set else "FALSE")
    connection.execute(
        sql.SQL(
            "GRANT {} TO CURRENT_USER WITH SET {}, INHERIT FALSE"
        ).format(sql.Identifier(role_name), option)
    )

    membership = connection.execute(
        """
        SELECT EXISTS (
            SELECT 1
            FROM pg_auth_members AS membership
            JOIN pg_roles AS granted_role ON granted_role.oid = membership.roleid
            JOIN pg_roles AS member_role ON member_role.oid = membership.member
            WHERE granted_role.rolname = %s
              AND member_role.rolname = current_user
              AND membership.set_option = %s
        )
        """,
        (role_name, can_set),
    ).fetchone()
    if membership is None or not membership[0]:
        expected = "enabled" if can_set else "disabled"
        raise RuntimeError(
            f"Unable to ensure SET ROLE is {expected} for the bootstrap identity and {role_name}."
        )


def _transfer_schema_objects(
    connection: psycopg.Connection,
    *,
    schema_name: str,
    owner_role: str,
) -> None:
    tables = connection.execute(
        """
        SELECT tablename, tableowner
        FROM pg_tables
        WHERE schemaname = %s
        """,
        (schema_name,),
    ).fetchall()
    for table_name, current_owner in tables:
        if current_owner == owner_role:
            continue
        connection.execute(
            sql.SQL("ALTER TABLE {}.{} OWNER TO {}").format(
                sql.Identifier(schema_name),
                sql.Identifier(table_name),
                sql.Identifier(owner_role),
            )
        )

    sequences = connection.execute(
        """
        SELECT c.relname, pg_get_userbyid(c.relowner)
        FROM pg_class AS c
        JOIN pg_namespace AS n ON n.oid = c.relnamespace
        WHERE n.nspname = %s AND c.relkind = 'S'
        """,
        (schema_name,),
    ).fetchall()
    for sequence_name, current_owner in sequences:
        if current_owner == owner_role:
            continue
        connection.execute(
            sql.SQL("ALTER SEQUENCE {}.{} OWNER TO {}").format(
                sql.Identifier(schema_name),
                sql.Identifier(sequence_name),
                sql.Identifier(owner_role),
            )
        )

    views = connection.execute(
        """
        SELECT c.relname, pg_get_userbyid(c.relowner)
        FROM pg_class AS c
        JOIN pg_namespace AS n ON n.oid = c.relnamespace
        WHERE n.nspname = %s AND c.relkind = 'v'
        """,
        (schema_name,),
    ).fetchall()
    for view_name, current_owner in views:
        if current_owner == owner_role:
            continue
        connection.execute(
            sql.SQL("ALTER VIEW {}.{} OWNER TO {}").format(
                sql.Identifier(schema_name),
                sql.Identifier(view_name),
                sql.Identifier(owner_role),
            )
        )

    materialized_views = connection.execute(
        """
        SELECT c.relname, pg_get_userbyid(c.relowner)
        FROM pg_class AS c
        JOIN pg_namespace AS n ON n.oid = c.relnamespace
        WHERE n.nspname = %s AND c.relkind = 'm'
        """,
        (schema_name,),
    ).fetchall()
    for view_name, current_owner in materialized_views:
        if current_owner == owner_role:
            continue
        connection.execute(
            sql.SQL("ALTER MATERIALIZED VIEW {}.{} OWNER TO {}").format(
                sql.Identifier(schema_name),
                sql.Identifier(view_name),
                sql.Identifier(owner_role),
            )
        )

    # SECURITY DEFINER routines must not remain owned by the bootstrap
    # identity. Transfer application functions/procedures to the restricted
    # migrator, but leave extension-owned routines under extension control.
    routines = connection.execute(
        """
        SELECT
            CASE p.prokind
                WHEN 'p' THEN 'PROCEDURE'
                WHEN 'a' THEN 'AGGREGATE'
                ELSE 'FUNCTION'
            END,
            format(
                '%I.%I(%s)',
                n.nspname,
                p.proname,
                pg_get_function_identity_arguments(p.oid)
            ),
            pg_get_userbyid(p.proowner)
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = %s
          AND p.prokind IN ('f', 'w', 'p', 'a')
          AND NOT EXISTS (
              SELECT 1
              FROM pg_depend AS dependency
              WHERE dependency.classid = 'pg_proc'::regclass
                AND dependency.objid = p.oid
                AND dependency.deptype = 'e'
          )
        """,
        (schema_name,),
    ).fetchall()
    for routine_kind, routine_signature, current_owner in routines:
        if current_owner == owner_role:
            continue
        connection.execute(
            sql.SQL("ALTER {} {} OWNER TO {}").format(
                sql.SQL(routine_kind),
                sql.SQL(routine_signature),
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

    # Role membership can confer privileges that direct schema/table ACLs do
    # not reveal. Reconcile both logins before granting their intended access.
    _revoke_role_memberships(connection, role_name=runtime_role)
    _revoke_role_memberships(connection, role_name=migrator_role)

    # PostgreSQL 16 grants CREATEROLE administrators ADMIN OPTION but not SET
    # OPTION on roles they create. Temporarily enable SET so this identity can
    # transfer object ownership and then administer ACLs as the new owner.
    _set_current_user_role_option(
        connection,
        role_name=migrator_role,
        can_set=True,
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

    # PUBLIC must not retain schema discovery or object-creation rights.
    # Application identities receive only the schema access granted below.
    connection.execute(
        sql.SQL("REVOKE ALL PRIVILEGES ON SCHEMA {} FROM PUBLIC").format(
            sql.Identifier(schema_name)
        )
    )
    # Reconcile existing direct schema ACLs instead of only removing CREATE.
    # This keeps repeated provisioning safe when a previous grant was broader.
    connection.execute(
        sql.SQL("REVOKE ALL PRIVILEGES ON SCHEMA {} FROM {}").format(
            sql.Identifier(schema_name),
            sql.Identifier(runtime_role),
        )
    )
    connection.execute(
        sql.SQL("GRANT USAGE ON SCHEMA {} TO {}").format(
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

    # The migrator now owns application objects. Perform ACL reconciliation
    # as that owner; the RDS master identity is not a PostgreSQL superuser.
    connection.execute(
        sql.SQL("SET ROLE {}").format(sql.Identifier(migrator_role))
    )

    # Remove stale PUBLIC and direct runtime grants before applying the exact
    # application ACL. PUBLIC function EXECUTE is especially sensitive for
    # SECURITY DEFINER routines, so it is revoked from existing and future code.
    connection.execute(
        sql.SQL("REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA {} FROM PUBLIC").format(
            sql.Identifier(schema_name)
        )
    )
    connection.execute(
        sql.SQL("REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA {} FROM PUBLIC").format(
            sql.Identifier(schema_name)
        )
    )
    connection.execute(
        sql.SQL("REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA {} FROM PUBLIC").format(
            sql.Identifier(schema_name)
        )
    )
    connection.execute(
        sql.SQL("REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA {} FROM {}").format(
            sql.Identifier(schema_name),
            sql.Identifier(runtime_role),
        )
    )
    connection.execute(
        sql.SQL("REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA {} FROM {}").format(
            sql.Identifier(schema_name),
            sql.Identifier(runtime_role),
        )
    )
    connection.execute(
        sql.SQL("REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA {} FROM {}").format(
            sql.Identifier(schema_name),
            sql.Identifier(runtime_role),
        )
    )
    connection.execute(
        "ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC"
    )
    connection.execute(
        sql.SQL(
            "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {} TO {}"
        ).format(
            sql.Identifier(schema_name),
            sql.Identifier(runtime_role),
        )
    )

    # Alembic metadata is deployment control-plane state, not application data.
    # Runtime must not be able to alter migration history or use it as a schema
    # discovery oracle; the migrator retains ownership and full schema access.
    alembic_version_exists = connection.execute(
        """
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = %s AND table_name = 'alembic_version'
        """,
        (schema_name,),
    ).fetchone()
    if alembic_version_exists is not None:
        connection.execute(
            sql.SQL("REVOKE ALL ON TABLE {}.alembic_version FROM {}").format(
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

    connection.execute("RESET ROLE")
    # Keep the administrator's ADMIN OPTION for future maintenance, but
    # remove the temporary ability to SET ROLE outside the bootstrap task.
    _set_current_user_role_option(
        connection,
        role_name=migrator_role,
        can_set=False,
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
