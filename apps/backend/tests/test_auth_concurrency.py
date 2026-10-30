from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from threading import Barrier
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, delete, select
from sqlalchemy.orm import sessionmaker

from app.core.config import settings
from app.core.security import hash_refresh_token
from app.models.auth import AuthRateLimitBucket, RefreshToken
from app.models.user import User
from app.services.auth import AuthenticationError, AuthService
from app.services.rate_limit import RateLimitExceeded, _bucket_key, check_rate_limit


@pytest.fixture
def postgres_session_factory():
    try:
        database_url = settings.sqlalchemy_database_url
    except RuntimeError:
        pytest.skip("A PostgreSQL DATABASE_URL is required for this concurrency test.")

    engine = create_engine(database_url, pool_size=5, max_overflow=2)
    if engine.dialect.name != "postgresql":
        engine.dispose()
        pytest.skip("This test requires PostgreSQL row-level locking.")

    factory = sessionmaker(
        bind=engine,
        autoflush=False,
        expire_on_commit=False,
    )
    try:
        yield factory
    finally:
        engine.dispose()


def test_concurrent_refresh_attempts_revoke_the_token_family(
    postgres_session_factory,
) -> None:
    original_secret = settings.auth_jwt_secret_key
    settings.auth_jwt_secret_key = "concurrency-test-secret-" + ("x" * 40)

    user_id = None
    family_id = None
    service = AuthService()
    barrier = Barrier(2)

    try:
        with postgres_session_factory() as session:
            user = User(
                email=f"refresh-race-{uuid4()}@example.invalid",
                name="Refresh Concurrency Test",
                email_verified=False,
            )
            session.add(user)
            session.commit()
            session.refresh(user)
            user_id = user.id

            _, original_refresh_token, _ = service.issue_session(
                session,
                user=user,
            )
            original_hash = hash_refresh_token(original_refresh_token)
            original_record = session.scalar(
                select(RefreshToken).where(
                    RefreshToken.token_hash == original_hash,
                )
            )
            assert original_record is not None
            family_id = original_record.family_id

        def attempt_rotation():
            with postgres_session_factory() as session:
                barrier.wait(timeout=10)
                try:
                    return (
                        "success",
                        service.rotate_refresh_token(
                            session,
                            refresh_token=original_refresh_token,
                        ),
                    )
                except AuthenticationError:
                    return ("rejected", None)

        with ThreadPoolExecutor(max_workers=2) as executor:
            futures = [
                executor.submit(attempt_rotation),
                executor.submit(attempt_rotation),
            ]
            results = [future.result(timeout=20) for future in futures]

        outcomes = [outcome for outcome, _ in results]
        assert outcomes.count("success") == 1
        assert outcomes.count("rejected") == 1

        winner = next(result for outcome, result in results if outcome == "success")
        replacement_refresh_token = winner[2]

        with postgres_session_factory() as session:
            family_tokens = list(
                session.scalars(
                    select(RefreshToken).where(
                        RefreshToken.family_id == family_id,
                    )
                )
            )

            assert len(family_tokens) == 2
            assert all(token.revoked_at is not None for token in family_tokens)
            assert {
                token.token_hash for token in family_tokens
            } == {
                original_hash,
                hash_refresh_token(replacement_refresh_token),
            }

    finally:
        if user_id is not None:
            with postgres_session_factory() as session:
                session.execute(
                    delete(RefreshToken).where(RefreshToken.user_id == user_id)
                )
                session.execute(delete(User).where(User.id == user_id))
                session.commit()
        settings.auth_jwt_secret_key = original_secret



def test_refresh_family_cleanup_uses_postgresql_and_preserves_replay_history(
    postgres_session_factory,
) -> None:
    original_secret = settings.auth_jwt_secret_key
    settings.auth_jwt_secret_key = "refresh-retention-test-secret-" + ("x" * 40)
    user_id = None
    active_family_id = None
    service = AuthService()
    expired_ancestor_token = "postgres-expired-ancestor-refresh-token"
    expired_family_id = uuid4()

    try:
        with postgres_session_factory() as session:
            user = User(
                email=f"refresh-retention-{uuid4()}@example.invalid",
                name="Refresh Retention Test",
                email_verified=False,
            )
            session.add(user)
            session.commit()
            session.refresh(user)
            user_id = user.id

            _, current_token, _ = service.issue_session(session, user=user)
            current_record = session.scalar(
                select(RefreshToken).where(
                    RefreshToken.token_hash == hash_refresh_token(current_token)
                )
            )
            assert current_record is not None
            active_family_id = current_record.family_id

            now = datetime.now(UTC)
            session.add_all(
                [
                    RefreshToken(
                        user_id=user.id,
                        family_id=active_family_id,
                        token_hash=hash_refresh_token(expired_ancestor_token),
                        expires_at=now - timedelta(seconds=1),
                        revoked_at=now - timedelta(seconds=2),
                    ),
                    RefreshToken(
                        user_id=user.id,
                        family_id=expired_family_id,
                        token_hash=hash_refresh_token("postgres-expired-family-a"),
                        expires_at=now - timedelta(days=1),
                        revoked_at=now - timedelta(days=2),
                    ),
                    RefreshToken(
                        user_id=user.id,
                        family_id=expired_family_id,
                        token_hash=hash_refresh_token("postgres-expired-family-b"),
                        expires_at=now - timedelta(days=1),
                        revoked_at=now - timedelta(days=2),
                    ),
                ]
            )
            session.commit()

            # Issuing a new session runs the cleanup against PostgreSQL.
            service.issue_session(session, user=user)

            assert session.scalar(
                select(RefreshToken.id)
                .where(RefreshToken.family_id == expired_family_id)
                .limit(1)
            ) is None
            assert session.scalar(
                select(RefreshToken.id)
                .where(
                    RefreshToken.family_id == active_family_id,
                    RefreshToken.token_hash == hash_refresh_token(expired_ancestor_token),
                )
                .limit(1)
            ) is not None

            # The expired ancestor is still recognized as a replay signal
            # because its family has a token that remains within its lifetime.
            with pytest.raises(AuthenticationError):
                service.rotate_refresh_token(
                    session,
                    refresh_token=expired_ancestor_token,
                )

            family_tokens = list(
                session.scalars(
                    select(RefreshToken).where(
                        RefreshToken.family_id == active_family_id
                    )
                )
            )
            assert family_tokens
            assert all(token.revoked_at is not None for token in family_tokens)

    finally:
        if user_id is not None:
            with postgres_session_factory() as session:
                session.execute(
                    delete(RefreshToken).where(RefreshToken.user_id == user_id)
                )
                session.execute(delete(User).where(User.id == user_id))
                session.commit()
        settings.auth_jwt_secret_key = original_secret


def test_concurrent_rate_limit_requests_cannot_exceed_shared_quota(
    postgres_session_factory,
) -> None:
    original_secret = settings.auth_jwt_secret_key
    settings.auth_jwt_secret_key = "rate-limit-concurrency-secret-" + ("x" * 40)

    client_ip = f"198.51.100.{(uuid4().int % 240) + 10}"
    scope = f"rate-limit-concurrency-{uuid4()}"
    request_count = 12
    allowed_limit = 4
    barrier = Barrier(request_count)
    bucket_key = _bucket_key(scope=scope, client_ip=client_ip)
    window_time = datetime.now(UTC)

    try:
        def attempt_request() -> str:
            with postgres_session_factory() as session:
                barrier.wait(timeout=10)
                try:
                    check_rate_limit(
                        session,
                        scope=scope,
                        client_ip=client_ip,
                        limit=allowed_limit,
                        window_seconds=300,
                        now=window_time,
                    )
                    return "accepted"
                except RateLimitExceeded:
                    return "blocked"

        with ThreadPoolExecutor(max_workers=request_count) as executor:
            futures = [
                executor.submit(attempt_request)
                for _ in range(request_count)
            ]
            outcomes = [future.result(timeout=30) for future in futures]

        assert outcomes.count("accepted") == allowed_limit
        assert outcomes.count("blocked") == request_count - allowed_limit

        with postgres_session_factory() as session:
            bucket = session.get(AuthRateLimitBucket, bucket_key)
            assert bucket is not None
            assert bucket.request_count == request_count

    finally:
        with postgres_session_factory() as session:
            session.query(AuthRateLimitBucket).filter(
                AuthRateLimitBucket.bucket_key == bucket_key
            ).delete(synchronize_session=False)
            session.commit()
        settings.auth_jwt_secret_key = original_secret
