from datetime import datetime, timedelta
from typing import Any, cast

from sqlalchemy import Table, case, delete
from sqlalchemy.dialects.postgresql import insert as postgresql_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.orm import Session

from app.models.auth import AuthRateLimitBucket


class AuthRateLimitRepository:
    def increment_bucket(
        self,
        session: Session,
        *,
        bucket_key: str,
        window_start: datetime,
        now: datetime,
    ) -> int:
        table = cast(Table, AuthRateLimitBucket.__table__)

        # Authentication traffic is low-volume; prune stale counters here
        # instead of introducing a scheduled task or a separate cache.
        session.execute(
            delete(AuthRateLimitBucket).where(
                AuthRateLimitBucket.window_start < now - timedelta(days=1)
            )
        )

        values = {
            "bucket_key": bucket_key,
            "window_start": window_start,
            "request_count": 1,
        }
        dialect = session.get_bind().dialect.name
        statement: Any
        if dialect == "postgresql":
            statement = postgresql_insert(table).values(**values)
        elif dialect == "sqlite":
            statement = sqlite_insert(table).values(**values)
        else:
            raise RuntimeError(
                f"Unsupported database dialect for auth rate limiting: {dialect}"
            )

        excluded = statement.excluded
        reset_window = table.c.window_start < excluded.window_start
        statement = statement.on_conflict_do_update(
            index_elements=[table.c.bucket_key],
            set_={
                "window_start": case(
                    (reset_window, excluded.window_start),
                    else_=table.c.window_start,
                ),
                "request_count": case(
                    (reset_window, 1),
                    else_=table.c.request_count + 1,
                ),
            },
        ).returning(table.c.request_count)

        count = session.scalar(statement)
        if count is None:
            session.rollback()
            raise RuntimeError("Unable to update authentication rate limit bucket.")

        session.commit()
        return int(count)
