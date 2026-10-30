"""scope items to authenticated users

Revision ID: 0003_scope_items_to_users
Revises: 0002_add_authentication
"""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = "0003_scope_items_to_users"
down_revision = "0002_add_authentication"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Keep legacy rows intact. They remain inaccessible through the user-scoped API
    # until an administrator explicitly assigns a legitimate owner.
    op.add_column(
        "items",
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=True),
    )
    op.create_foreign_key(
        "fk_items_user_id_users",
        "items",
        "users",
        ["user_id"],
        ["id"],
        ondelete="CASCADE",
    )
    op.create_index("ix_items_user_id", "items", ["user_id"])


def downgrade() -> None:
    op.drop_index("ix_items_user_id", table_name="items")
    op.drop_constraint("fk_items_user_id_users", "items", type_="foreignkey")
    op.drop_column("items", "user_id")
