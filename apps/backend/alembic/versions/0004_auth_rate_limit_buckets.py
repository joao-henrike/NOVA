"""add shared authentication rate-limit buckets

Revision ID: 0004_auth_rate_limit_buckets
Revises: 0003_scope_items_to_users
"""

from alembic import op
import sqlalchemy as sa


revision = "0004_auth_rate_limit_buckets"
down_revision = "0003_scope_items_to_users"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "auth_rate_limit_buckets",
        sa.Column("bucket_key", sa.String(length=64), nullable=False),
        sa.Column("window_start", sa.DateTime(timezone=True), nullable=False),
        sa.Column("request_count", sa.Integer(), nullable=False),
        sa.PrimaryKeyConstraint("bucket_key", name="pk_auth_rate_limit_buckets"),
    )
    op.create_index(
        "ix_auth_rate_limit_buckets_window_start",
        "auth_rate_limit_buckets",
        ["window_start"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_auth_rate_limit_buckets_window_start",
        table_name="auth_rate_limit_buckets",
    )
    op.drop_table("auth_rate_limit_buckets")
