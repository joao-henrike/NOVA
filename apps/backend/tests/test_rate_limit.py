import unittest
from datetime import UTC, datetime, timedelta
from unittest.mock import Mock

from fastapi import Request
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.config import settings
from app.db.base import Base
from app.models.auth import AuthRateLimitBucket
from app.repositories.rate_limit import AuthRateLimitRepository
from app.services.rate_limit import (
    RateLimitExceeded,
    check_rate_limit,
    get_request_client_ip,
)


class AuthRateLimitTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.engine = create_engine(
            "sqlite+pysqlite:///:memory:",
            connect_args={"check_same_thread": False},
            poolclass=StaticPool,
        )
        Base.metadata.create_all(cls.engine)
        cls.session_factory = sessionmaker(
            bind=cls.engine,
            autoflush=False,
            expire_on_commit=False,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.engine.dispose()

    def setUp(self) -> None:
        self.original_secret = settings.auth_jwt_secret_key
        self.original_environment = settings.app_env
        settings.auth_jwt_secret_key = "rate-limit-test-secret-" + ("x" * 40)

    def tearDown(self) -> None:
        settings.auth_jwt_secret_key = self.original_secret
        settings.app_env = self.original_environment
        with self.session_factory() as session:
            session.query(AuthRateLimitBucket).delete(synchronize_session=False)
            session.commit()

    def test_rate_limit_repository_rejects_unsupported_database_dialect(self) -> None:
        session = Mock()
        session.get_bind.return_value.dialect.name = "mysql"

        with self.assertRaisesRegex(RuntimeError, "Unsupported database dialect"):
            AuthRateLimitRepository().increment_bucket(
                session,
                bucket_key="test-bucket",
                window_start=datetime.now(UTC),
                now=datetime.now(UTC),
            )

        session.execute.assert_called_once()
        session.scalar.assert_not_called()
        session.commit.assert_not_called()

    def test_rate_limit_repository_rolls_back_when_upsert_returns_no_count(self) -> None:
        session = Mock()
        session.get_bind.return_value.dialect.name = "sqlite"
        session.scalar.return_value = None

        with self.assertRaisesRegex(RuntimeError, "Unable to update"):
            AuthRateLimitRepository().increment_bucket(
                session,
                bucket_key="test-bucket",
                window_start=datetime.now(UTC),
                now=datetime.now(UTC),
            )

        session.execute.assert_called_once()
        session.scalar.assert_called_once()
        session.rollback.assert_called_once()
        session.commit.assert_not_called()

    def test_fixed_window_blocks_after_limit_and_resets(self) -> None:
        first_window = datetime(2026, 10, 30, 12, 0, 0, tzinfo=UTC)

        with self.session_factory() as session:
            first = check_rate_limit(
                session,
                scope="refresh",
                client_ip="203.0.113.10",
                limit=2,
                window_seconds=60,
                now=first_window,
            )
            second = check_rate_limit(
                session,
                scope="refresh",
                client_ip="203.0.113.10",
                limit=2,
                window_seconds=60,
                now=first_window + timedelta(seconds=10),
            )
            self.assertEqual((first, second), (1, 2))

            with self.assertRaises(RateLimitExceeded) as blocked:
                check_rate_limit(
                    session,
                    scope="refresh",
                    client_ip="203.0.113.10",
                    limit=2,
                    window_seconds=60,
                    now=first_window + timedelta(seconds=20),
                )
            self.assertGreaterEqual(blocked.exception.retry_after, 1)

            after_reset = check_rate_limit(
                session,
                scope="refresh",
                client_ip="203.0.113.10",
                limit=2,
                window_seconds=60,
                now=first_window + timedelta(seconds=60),
            )

        self.assertEqual(after_reset, 1)


    def test_non_positive_rate_limit_or_window_is_rejected(self) -> None:
        with self.session_factory() as session:
            for limit, window_seconds in ((0, 60), (1, 0), (-1, 60)):
                with self.subTest(limit=limit, window_seconds=window_seconds):
                    with self.assertRaisesRegex(ValueError, "must be positive"):
                        check_rate_limit(
                            session,
                            scope="invalid",
                            client_ip="203.0.113.1",
                            limit=limit,
                            window_seconds=window_seconds,
                        )

    def test_limits_are_isolated_by_scope_and_client(self) -> None:
        now = datetime(2026, 10, 30, 12, 0, 0, tzinfo=UTC)

        with self.session_factory() as session:
            check_rate_limit(
                session,
                scope="login",
                client_ip="203.0.113.10",
                limit=1,
                window_seconds=300,
                now=now,
            )
            second_client = check_rate_limit(
                session,
                scope="login",
                client_ip="203.0.113.11",
                limit=1,
                window_seconds=300,
                now=now,
            )
            other_scope = check_rate_limit(
                session,
                scope="callback",
                client_ip="203.0.113.10",
                limit=1,
                window_seconds=300,
                now=now,
            )

        self.assertEqual(second_client, 1)
        self.assertEqual(other_scope, 1)

    def test_client_ip_uses_last_alb_forwarded_address_in_cloud(self) -> None:
        settings.app_env = "dev"
        request = Request(
            {
                "type": "http",
                "method": "GET",
                "path": "/",
                "headers": [
                    (
                        b"x-forwarded-for",
                        b"198.51.100.20, 203.0.113.15",
                    )
                ],
                "client": ("10.0.0.5", 44321),
                "server": ("10.0.0.6", 8000),
            }
        )

        self.assertEqual(get_request_client_ip(request), "203.0.113.15")

    def test_cloud_mode_rejects_missing_forwarded_address(self) -> None:
        settings.app_env = "dev"
        request = Request(
            {
                "type": "http",
                "method": "GET",
                "path": "/",
                "headers": [],
                "client": ("10.0.0.5", 44321),
                "server": ("10.0.0.6", 8000),
            }
        )

        with self.assertRaisesRegex(ValueError, "Missing ALB-forwarded"):
            get_request_client_ip(request)

    def test_cloud_mode_rejects_invalid_appended_address(self) -> None:
        settings.app_env = "dev"
        request = Request(
            {
                "type": "http",
                "method": "GET",
                "path": "/",
                "headers": [
                    (b"x-forwarded-for", b"198.51.100.20, not-an-ip")
                ],
                "client": ("10.0.0.5", 44321),
                "server": ("10.0.0.6", 8000),
            }
        )

        with self.assertRaisesRegex(ValueError, "Invalid ALB-forwarded"):
            get_request_client_ip(request)

    def test_local_mode_does_not_trust_forwarded_for(self) -> None:
        settings.app_env = "local"
        request = Request(
            {
                "type": "http",
                "method": "GET",
                "path": "/",
                "headers": [(b"x-forwarded-for", b"203.0.113.99")],
                "client": ("127.0.0.1", 1234),
                "server": ("127.0.0.1", 8000),
            }
        )

        self.assertEqual(get_request_client_ip(request), "127.0.0.1")

    def test_database_stores_hmac_bucket_keys_not_client_addresses(self) -> None:
        with self.session_factory() as session:
            check_rate_limit(
                session,
                scope="callback",
                client_ip="203.0.113.10",
                limit=5,
                window_seconds=60,
            )
            keys = [row.bucket_key for row in session.query(AuthRateLimitBucket).all()]

        self.assertEqual(len(keys), 1)
        self.assertEqual(len(keys[0]), 64)
        self.assertNotIn("203.0.113.10", keys[0])
