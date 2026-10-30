from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, delete, select
from sqlalchemy.orm import sessionmaker

from app.core.config import settings
from app.core.security import hash_refresh_token
from app.models.auth import RefreshToken
from app.models.user import User
from app.services.auth import AuthenticationError, AuthService


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
