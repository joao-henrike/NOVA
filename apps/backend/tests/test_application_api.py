import unittest
from datetime import UTC, datetime, timedelta
from unittest.mock import patch
from uuid import uuid4

import jwt
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.config import settings
from app.core.security import (
    create_access_token,
    create_pkce_challenge,
    create_pkce_verifier,
    hash_refresh_token,
)
from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.auth import (
    AuthIdentity,
    AuthProvider,
    AuthRateLimitBucket,
    OAuthState,
    RefreshToken,
)
from app.models.item import Item
from app.models.user import User
from app.services.auth import AuthService
from app.services.providers import (
    ProviderAuthenticationError,
    apple_authorization_url,
    claims_to_identity,
    generate_apple_client_secret,
    google_authorization_url,
)


class ApplicationApiTest(unittest.TestCase):
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

        def override_get_db():
            with cls.session_factory() as session:
                yield session

        app.dependency_overrides[get_db] = override_get_db
        cls.client = TestClient(app)

        with cls.session_factory() as session:
            user = User(
                email="test@example.com",
                name="Test User",
                email_verified=True,
            )
            session.add(user)
            session.commit()
            session.refresh(user)
            cls.user_id = user.id

    @classmethod
    def tearDownClass(cls) -> None:
        app.dependency_overrides.clear()
        cls.engine.dispose()

    def setUp(self) -> None:
        self.original_secret = settings.auth_jwt_secret_key
        settings.auth_jwt_secret_key = "x" * 64

    def tearDown(self) -> None:
        settings.auth_jwt_secret_key = self.original_secret
        with self.session_factory() as session:
            session.query(RefreshToken).delete(synchronize_session=False)
            session.query(AuthRateLimitBucket).delete(synchronize_session=False)
            session.query(OAuthState).delete(synchronize_session=False)
            session.query(Item).delete(synchronize_session=False)
            session.query(AuthIdentity).delete(synchronize_session=False)
            session.query(User).filter(User.id != self.user_id).delete(
                synchronize_session=False,
            )
            session.commit()

    def _issue_session(self, user_id=None) -> tuple[str, str]:
        with self.session_factory() as session:
            user = session.get(User, user_id or self.user_id)
            if user is None:
                raise AssertionError("Test user does not exist.")
            access_token, refresh_token, _ = AuthService().issue_session(
                session,
                user=user,
            )
            return access_token, refresh_token

    def _auth_headers(self, user_id=None) -> dict[str, str]:
        access_token, _ = self._issue_session(user_id)
        return {"Authorization": f"Bearer {access_token}"}

    def _issue_refresh_token(self) -> str:
        _, refresh_token = self._issue_session()
        return refresh_token

    def test_items_requires_authentication(self) -> None:
        response = self.client.get("/api/items")
        self.assertEqual(response.status_code, 401)

    def test_inactive_user_cannot_use_existing_access_token(self) -> None:
        with self.session_factory() as session:
            inactive_user = User(
                email=f"inactive-{uuid4()}@example.com",
                name="Inactive User",
                email_verified=True,
            )
            session.add(inactive_user)
            session.commit()
            session.refresh(inactive_user)
            inactive_user_id = inactive_user.id

        access_token, refresh_token = self._issue_session(inactive_user_id)
        with self.session_factory() as session:
            inactive_user = session.get(User, inactive_user_id)
            self.assertIsNotNone(inactive_user)
            inactive_user.is_active = False
            session.commit()

        protected_response = self.client.get(
            "/api/auth/me",
            headers={"Authorization": f"Bearer {access_token}"},
        )
        self.assertEqual(protected_response.status_code, 401)

        refresh_response = self.client.post(
            "/api/auth/refresh",
            json={"refresh_token": refresh_token},
        )
        self.assertEqual(refresh_response.status_code, 401)

        with self.session_factory() as session:
            record = session.query(RefreshToken).filter(
                RefreshToken.token_hash == hash_refresh_token(refresh_token)
            ).one()
            self.assertIsNotNone(record.revoked_at)

    def test_item_validation_boundaries(self) -> None:
        headers = self._auth_headers()
        created = self.client.post(
            "/api/items",
            json={
                "name": "Validation boundary item",
                "description": "This description can be cleared.",
            },
            headers=headers,
        )
        self.assertEqual(created.status_code, 201)
        item_id = created.json()["id"]

        invalid_queries = (
            "/api/items?offset=-1",
            "/api/items?limit=0",
            "/api/items?limit=101",
            "/api/items?status=unknown",
        )
        for path in invalid_queries:
            with self.subTest(path=path):
                response = self.client.get(path, headers=headers)
                self.assertEqual(response.status_code, 422)

        empty_patch = self.client.patch(
            f"/api/items/{item_id}",
            json={},
            headers=headers,
        )
        self.assertEqual(empty_patch.status_code, 400)

        cleared_description = self.client.patch(
            f"/api/items/{item_id}",
            json={"description": None},
            headers=headers,
        )
        self.assertEqual(cleared_description.status_code, 200)
        self.assertIsNone(cleared_description.json()["description"])

        invalid_id = self.client.get(
            "/api/items/not-a-uuid",
            headers=headers,
        )
        self.assertEqual(invalid_id.status_code, 422)


    def test_auth_rate_limit_rejects_invalid_client_metadata(self) -> None:
        with patch(
            "app.api.routes.auth.get_request_client_ip",
            side_effect=ValueError("invalid forwarded address"),
        ):
            response = self.client.post(
                "/api/auth/refresh",
                json={"refresh_token": "not-used"},
            )

        self.assertEqual(response.status_code, 400)
        self.assertEqual(
            response.json()["detail"],
            "Invalid client address metadata.",
        )

    def test_google_callback_rejects_missing_parameters_and_mismatched_state(self) -> None:
        self.client.cookies.clear()
        invalid_requests = (
            {},
            {"error": "access_denied", "state": "state"},
            {"code": "authorization-code"},
            {"state": "state"},
        )
        for params in invalid_requests:
            with self.subTest(params=params):
                response = self.client.get(
                    "/api/auth/google/callback",
                    params=params,
                )
                self.assertEqual(response.status_code, 400)

        mismatch = self.client.get(
            "/api/auth/google/callback",
            params={"code": "authorization-code", "state": "expected-state"},
            cookies={"nova_oauth_state_google": "different-state"},
        )
        self.assertEqual(mismatch.status_code, 400)

    def test_google_callback_rejects_state_without_pkce_verifier(self) -> None:
        state = f"missing-verifier-{uuid4()}"
        with self.session_factory() as session:
            session.add(
                OAuthState(
                    provider=AuthProvider.GOOGLE,
                    state=state,
                    nonce="test-nonce",
                    code_verifier=None,
                    redirect_uri="https://example.com/callback",
                    expires_at=datetime.now(UTC) + timedelta(minutes=5),
                )
            )
            session.commit()

        response = self.client.get(
            "/api/auth/google/callback",
            params={"code": "authorization-code", "state": state},
            cookies={"nova_oauth_state_google": state},
        )
        self.assertEqual(response.status_code, 400)

    def test_google_callback_normalizes_provider_authentication_errors(self) -> None:
        state = "provider-error-state"
        record = OAuthState(
            provider=AuthProvider.GOOGLE,
            state=state,
            nonce="test-nonce",
            code_verifier="test-verifier",
            redirect_uri="https://example.com/callback",
            expires_at=datetime.now(UTC) + timedelta(minutes=5),
        )
        with (
            patch(
                "app.api.routes.auth.service.consume_oauth_state",
                return_value=record,
            ),
            patch(
                "app.api.routes.auth.exchange_google_code",
                side_effect=ProviderAuthenticationError("provider unavailable"),
            ),
        ):
            response = self.client.get(
                "/api/auth/google/callback",
                params={"code": "authorization-code", "state": state},
                cookies={"nova_oauth_state_google": state},
            )

        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.json()["detail"], "Google authentication failed.")

    def test_cookie_refresh_requires_https_origin_outside_local(self) -> None:
        original_environment = settings.app_env
        _, refresh_token = self._issue_session()
        self.client.cookies.clear()
        self.client.cookies.set("nova_refresh_token", refresh_token)
        settings.app_env = "dev"
        try:
            response = self.client.post(
                "/api/auth/refresh",
                json={},
                headers={
                    "Origin": "http://testserver",
                    "X-Forwarded-For": "203.0.113.20",
                },
            )
        finally:
            settings.app_env = original_environment
            self.client.cookies.clear()

        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.json()["detail"], "HTTPS origin required.")

    def test_refresh_without_any_token_returns_unauthorized(self) -> None:
        self.client.cookies.clear()
        response = self.client.post("/api/auth/refresh", json={})
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.json()["detail"], "Refresh token required.")

    def test_items_crud(self) -> None:
        headers = self._auth_headers()

        created = self.client.post(
            "/api/items",
            json={
                "name": "CloudStart API",
                "description": "Authentication integration test",
            },
            headers=headers,
        )
        self.assertEqual(created.status_code, 201)
        self.assertEqual(created.headers["cache-control"], "no-store")
        self.assertEqual(created.headers["pragma"], "no-cache")
        self.assertEqual(created.headers["x-content-type-options"], "nosniff")
        self.assertEqual(created.headers["referrer-policy"], "no-referrer")
        item = created.json()
        item_id = item["id"]
        self.assertEqual(item["status"], "active")

        fetched = self.client.get(f"/api/items/{item_id}", headers=headers)
        self.assertEqual(fetched.status_code, 200)
        self.assertEqual(fetched.json()["name"], "CloudStart API")

        updated = self.client.patch(
            f"/api/items/{item_id}",
            json={"name": "CloudStart API v2", "status": "inactive"},
            headers=headers,
        )
        self.assertEqual(updated.status_code, 200)
        self.assertEqual(updated.json()["status"], "inactive")

        for invalid_payload in ({"name": None}, {"status": None}):
            invalid_update = self.client.patch(
                f"/api/items/{item_id}",
                json=invalid_payload,
                headers=headers,
            )
            self.assertEqual(invalid_update.status_code, 422)

        unchanged = self.client.get(f"/api/items/{item_id}", headers=headers)
        self.assertEqual(unchanged.status_code, 200)
        self.assertEqual(unchanged.json()["name"], "CloudStart API v2")
        self.assertEqual(unchanged.json()["status"], "inactive")

        listed = self.client.get(
            "/api/items?status=inactive",
            headers=headers,
        )
        self.assertEqual(listed.status_code, 200)
        self.assertTrue(any(x["id"] == item_id for x in listed.json()))

        deleted = self.client.delete(
            f"/api/items/{item_id}",
            headers=headers,
        )
        self.assertEqual(deleted.status_code, 204)

        missing = self.client.get(f"/api/items/{item_id}", headers=headers)
        self.assertEqual(missing.status_code, 404)

    def test_items_are_isolated_between_users(self) -> None:
        with self.session_factory() as session:
            other_user = User(
                email=f"other-{uuid4()}@example.com",
                name="Other User",
                email_verified=True,
            )
            session.add(other_user)
            session.commit()
            session.refresh(other_user)
            other_user_id = other_user.id

        owner_headers = self._auth_headers()
        other_headers = self._auth_headers(other_user_id)

        created = self.client.post(
            "/api/items",
            json={"name": "Private owner item"},
            headers=owner_headers,
        )
        self.assertEqual(created.status_code, 201)
        item_id = created.json()["id"]

        other_list = self.client.get("/api/items", headers=other_headers)
        self.assertEqual(other_list.status_code, 200)
        self.assertEqual(other_list.json(), [])

        self.assertEqual(
            self.client.get(f"/api/items/{item_id}", headers=other_headers).status_code,
            404,
        )
        self.assertEqual(
            self.client.patch(
                f"/api/items/{item_id}",
                json={"name": "Unauthorized change"},
                headers=other_headers,
            ).status_code,
            404,
        )
        self.assertEqual(
            self.client.delete(
                f"/api/items/{item_id}",
                headers=other_headers,
            ).status_code,
            404,
        )

        owner_read = self.client.get(f"/api/items/{item_id}", headers=owner_headers)
        self.assertEqual(owner_read.status_code, 200)
        self.assertEqual(owner_read.json()["name"], "Private owner item")

    def test_item_input_cannot_assign_or_change_owner(self) -> None:
        with self.session_factory() as session:
            other_user = User(
                email=f"mass-assignment-{uuid4()}@example.com",
                name="Other User",
                email_verified=True,
            )
            session.add(other_user)
            session.commit()
            session.refresh(other_user)
            other_user_id = other_user.id

        owner_headers = self._auth_headers()
        forged_create = self.client.post(
            "/api/items",
            json={"name": "Forged owner", "user_id": str(other_user_id)},
            headers=owner_headers,
        )
        self.assertEqual(forged_create.status_code, 422)

        created = self.client.post(
            "/api/items",
            json={"name": "Owner-controlled item"},
            headers=owner_headers,
        )
        self.assertEqual(created.status_code, 201)
        item_id = created.json()["id"]

        forged_update = self.client.patch(
            f"/api/items/{item_id}",
            json={"user_id": str(other_user_id)},
            headers=owner_headers,
        )
        self.assertEqual(forged_update.status_code, 422)

        owner_read = self.client.get(
            f"/api/items/{item_id}",
            headers=owner_headers,
        )
        other_read = self.client.get(
            f"/api/items/{item_id}",
            headers=self._auth_headers(other_user_id),
        )
        self.assertEqual(owner_read.status_code, 200)
        self.assertEqual(other_read.status_code, 404)

    def test_refresh_rotates_token_and_reuse_revokes_family(self) -> None:
        original_token = self._issue_refresh_token()

        rotated = self.client.post(
            "/api/auth/refresh",
            json={"refresh_token": original_token},
        )
        self.assertEqual(rotated.status_code, 200)
        self.assertEqual(rotated.headers["cache-control"], "no-store")
        self.assertEqual(rotated.headers["pragma"], "no-cache")
        replacement_token = rotated.cookies.get("nova_refresh_token")
        self.assertIsNotNone(replacement_token)
        self.assertNotEqual(replacement_token, original_token)

        reused = self.client.post(
            "/api/auth/refresh",
            json={"refresh_token": original_token},
        )
        self.assertEqual(reused.status_code, 401)

        # Reuse detection revokes the whole family, including its latest token.
        revoked_replacement = self.client.post(
            "/api/auth/refresh",
            json={"refresh_token": replacement_token},
        )
        self.assertEqual(revoked_replacement.status_code, 401)

    def test_cookie_refresh_rejects_cross_origin_and_rotates_same_origin(self) -> None:
        _, refresh_token = self._issue_session()
        self.client.cookies.clear()
        self.client.cookies.set(
            "nova_refresh_token",
            refresh_token,
            path="/api/auth",
        )

        rejected = self.client.post(
            "/api/auth/refresh",
            json={},
            headers={"Origin": "http://attacker.test"},
        )
        self.assertEqual(rejected.status_code, 403)

        with self.session_factory() as session:
            record = (
                session.query(RefreshToken)
                .filter_by(token_hash=hash_refresh_token(refresh_token))
                .one()
            )
            self.assertIsNone(record.revoked_at)

        rotated = self.client.post(
            "/api/auth/refresh",
            json={},
            headers={"Origin": "https://testserver"},
        )
        self.assertEqual(rotated.status_code, 200)
        self.assertEqual(rotated.headers["cache-control"], "no-store")
        replacement_token = rotated.cookies.get("nova_refresh_token")
        self.assertTrue(replacement_token)
        self.assertNotEqual(replacement_token, refresh_token)
        self.client.cookies.clear()

        with self.session_factory() as session:
            old_record = (
                session.query(RefreshToken)
                .filter_by(token_hash=hash_refresh_token(refresh_token))
                .one()
            )
            replacement_record = (
                session.query(RefreshToken)
                .filter_by(token_hash=hash_refresh_token(replacement_token))
                .one()
            )
            self.assertIsNotNone(old_record.revoked_at)
            self.assertIsNone(replacement_record.revoked_at)

    def test_logout_revokes_refresh_and_access_tokens(self) -> None:
        access_token, refresh_token = self._issue_session()
        headers = {"Authorization": f"Bearer {access_token}"}

        before_logout = self.client.get("/api/auth/me", headers=headers)
        self.assertEqual(before_logout.status_code, 200)

        logged_out = self.client.post(
            "/api/auth/logout",
            json={"refresh_token": refresh_token},
        )
        self.assertEqual(logged_out.status_code, 204)

        refreshed = self.client.post(
            "/api/auth/refresh",
            json={"refresh_token": refresh_token},
        )
        self.assertEqual(refreshed.status_code, 401)

        access_after_logout = self.client.get("/api/auth/me", headers=headers)
        self.assertEqual(access_after_logout.status_code, 401)

    def test_cookie_logout_rejects_cross_origin_and_preserves_session(self) -> None:
        _, refresh_token = self._issue_session()
        self.client.cookies.clear()
        self.client.cookies.set(
            "nova_refresh_token",
            refresh_token,
            path="/api/auth",
        )

        rejected = self.client.post(
            "/api/auth/logout",
            headers={"Origin": "http://attacker.test"},
        )
        self.assertEqual(rejected.status_code, 403)

        with self.session_factory() as session:
            record = (
                session.query(RefreshToken)
                .filter_by(token_hash=hash_refresh_token(refresh_token))
                .one()
            )
            self.assertIsNone(record.revoked_at)

        accepted = self.client.post(
            "/api/auth/logout",
            headers={"Origin": "https://testserver"},
        )
        self.assertEqual(accepted.status_code, 204)
        self.client.cookies.clear()

        with self.session_factory() as session:
            record = (
                session.query(RefreshToken)
                .filter_by(token_hash=hash_refresh_token(refresh_token))
                .one()
            )
            self.assertIsNotNone(record.revoked_at)

    def test_body_token_logout_does_not_require_browser_origin(self) -> None:
        _, refresh_token = self._issue_session()

        response = self.client.post(
            "/api/auth/logout",
            json={"refresh_token": refresh_token},
        )

        self.assertEqual(response.status_code, 204)

    def test_new_oauth_login_removes_expired_states(self) -> None:
        expired_state = f"expired-{uuid4()}"
        current_state = f"current-{uuid4()}"

        with self.session_factory() as session:
            session.add(
                OAuthState(
                    provider=AuthProvider.GOOGLE,
                    state=expired_state,
                    nonce="expired-nonce",
                    code_verifier="expired-verifier",
                    redirect_uri="https://cloudstart.example.com/callback",
                    expires_at=datetime.now(UTC) - timedelta(seconds=1),
                )
            )
            session.commit()

            AuthService().create_oauth_state(
                session,
                provider=AuthProvider.GOOGLE,
                state=current_state,
                nonce="current-nonce",
                code_verifier="current-verifier",
                redirect_uri="https://cloudstart.example.com/callback",
            )

            self.assertIsNone(
                session.query(OAuthState)
                .filter(OAuthState.state == expired_state)
                .one_or_none()
            )
            self.assertIsNotNone(
                session.query(OAuthState)
                .filter(OAuthState.state == current_state)
                .one_or_none()
            )

    def test_oauth_state_can_only_be_consumed_once(self) -> None:
        state = f"one-time-{uuid4()}"

        with self.session_factory() as session:
            service = AuthService()
            service.create_oauth_state(
                session,
                provider=AuthProvider.GOOGLE,
                state=state,
                nonce="one-time-nonce",
                code_verifier="one-time-verifier",
                redirect_uri="https://cloudstart.example.com/callback",
            )

            first_use = service.consume_oauth_state(
                session,
                provider=AuthProvider.GOOGLE,
                state=state,
            )
            replay = service.consume_oauth_state(
                session,
                provider=AuthProvider.GOOGLE,
                state=state,
            )

        self.assertIsNotNone(first_use)
        self.assertEqual(first_use.state, state)
        self.assertIsNone(replay)

    def test_expired_oauth_state_is_rejected_and_deleted(self) -> None:
        state = f"expired-callback-{uuid4()}"

        with self.session_factory() as session:
            session.add(
                OAuthState(
                    provider=AuthProvider.GOOGLE,
                    state=state,
                    nonce="expired-nonce",
                    code_verifier="expired-verifier",
                    redirect_uri="https://cloudstart.example.com/callback",
                    expires_at=datetime.now(UTC) - timedelta(seconds=1),
                )
            )
            session.commit()

            consumed = AuthService().consume_oauth_state(
                session,
                provider=AuthProvider.GOOGLE,
                state=state,
            )
            remaining = (
                session.query(OAuthState)
                .filter(OAuthState.state == state)
                .one_or_none()
            )

        self.assertIsNone(consumed)
        self.assertIsNone(remaining)

    def test_auth_endpoint_rate_limit_returns_429_and_retry_after(self) -> None:
        from app.api.routes.auth import AUTH_RATE_LIMITS

        with patch.dict(AUTH_RATE_LIMITS, {"refresh": (1, 300)}):
            first = self.client.post(
                "/api/auth/refresh",
                json={"refresh_token": "not-a-valid-refresh-token"},
            )
            blocked = self.client.post(
                "/api/auth/refresh",
                json={"refresh_token": "not-a-valid-refresh-token"},
            )

        self.assertEqual(first.status_code, 401)
        self.assertEqual(blocked.status_code, 429)
        self.assertGreaterEqual(int(blocked.headers["retry-after"]), 1)
        self.assertEqual(blocked.headers["cache-control"], "no-store")
        self.assertEqual(
            blocked.json()["detail"],
            "Too many authentication requests. Please try again later.",
        )

    def test_auth_rate_limits_are_separated_by_endpoint(self) -> None:
        from app.api.routes.auth import AUTH_RATE_LIMITS

        with patch.dict(
            AUTH_RATE_LIMITS,
            {"refresh": (1, 300), "logout": (1, 300)},
        ):
            self.client.post(
                "/api/auth/refresh",
                json={"refresh_token": "not-a-valid-refresh-token"},
            )
            blocked_refresh = self.client.post(
                "/api/auth/refresh",
                json={"refresh_token": "not-a-valid-refresh-token"},
            )
            logout_response = self.client.post(
                "/api/auth/logout",
                json={"refresh_token": "invalid-rate-limit-test-token"},
            )

        self.assertEqual(blocked_refresh.status_code, 429)
        self.assertEqual(logout_response.status_code, 204)

    def test_missing_user_is_rejected(self) -> None:
        token, _ = create_access_token(uuid4(), uuid4())
        response = self.client.get(
            "/api/items",
            headers={"Authorization": f"Bearer {token}"},
        )
        self.assertEqual(response.status_code, 401)

    def test_google_oauth_callback_creates_session(self) -> None:
        original = {
            "google_client_id": settings.google_client_id,
            "google_client_secret": settings.google_client_secret,
            "google_redirect_uri": settings.google_redirect_uri,
            "auth_cookie_secure": settings.auth_cookie_secure,
        }
        settings.google_client_id = "google-client-id"
        settings.google_client_secret = "google-client-secret"
        settings.google_redirect_uri = (
            "https://cloudstart.example.com/api/auth/google/callback"
        )
        settings.auth_cookie_secure = False

        try:
            start = self.client.get(
                "/api/auth/google/login",
                follow_redirects=False,
            )
            self.assertEqual(start.status_code, 302)
            state = start.headers["location"].split("state=", 1)[1].split("&", 1)[0]

            with (
                patch(
                    "app.api.routes.auth.exchange_google_code",
                    return_value={"id_token": "provider-id-token"},
                ),
                patch(
                    "app.api.routes.auth.verify_google_id_token",
                    return_value={
                        "sub": "google-subject",
                        "email": "google@example.com",
                        "email_verified": True,
                        "name": "Google User",
                    },
                ),
            ):
                callback = self.client.get(
                    f"/api/auth/google/callback?code=oauth-code&state={state}",
                    follow_redirects=False,
                )

            self.assertEqual(callback.status_code, 200)
            payload = callback.json()
            self.assertIn("access_token", payload)
            self.assertEqual(payload["token_type"], "bearer")
            self.assertEqual(
                self.client.get(
                    "/api/auth/me",
                    headers={"Authorization": f"Bearer {payload['access_token']}"},
                ).status_code,
                200,
            )
            self.assertIn("nova_refresh_token=", callback.headers.get("set-cookie", ""))
        finally:
            for name, value in original.items():
                setattr(settings, name, value)

    def test_apple_oauth_callback_creates_session(self) -> None:
        original = {
            "apple_client_id": settings.apple_client_id,
            "apple_team_id": settings.apple_team_id,
            "apple_key_id": settings.apple_key_id,
            "apple_private_key": settings.apple_private_key,
            "apple_redirect_uri": settings.apple_redirect_uri,
            "auth_cookie_secure": settings.auth_cookie_secure,
        }
        settings.apple_client_id = "com.example.cloudstart.web"
        settings.apple_team_id = "TEAM123456"
        settings.apple_key_id = "KEY1234567"
        settings.apple_private_key = "mocked-private-key"
        settings.apple_redirect_uri = (
            "https://cloudstart.example.com/api/auth/apple/callback"
        )
        settings.auth_cookie_secure = False

        try:
            start = self.client.get(
                "/api/auth/apple/login",
                follow_redirects=False,
            )
            self.assertEqual(start.status_code, 302)
            state = start.headers["location"].split("state=", 1)[1].split("&", 1)[0]

            with (
                patch(
                    "app.api.routes.auth.exchange_apple_code",
                    return_value={"id_token": "provider-id-token"},
                ),
                patch(
                    "app.api.routes.auth.verify_apple_id_token",
                    return_value={
                        "sub": "apple-subject",
                    },
                ),
            ):
                callback = self.client.post(
                    "/api/auth/apple/callback",
                    data={
                        "code": "oauth-code",
                        "state": state,
                        "user": (
                            '{"email":"victim@example.com",'
                            '"name":{"firstName":"Apple","lastName":"User"}}'
                        ),
                    },
                )

            self.assertEqual(callback.status_code, 200)
            payload = callback.json()
            self.assertIn("access_token", payload)
            me = self.client.get(
                "/api/auth/me",
                headers={"Authorization": f"Bearer {payload['access_token']}"},
            )
            self.assertEqual(me.status_code, 200)
            self.assertIsNone(me.json()["email"])
            self.assertEqual(me.json()["name"], "Apple User")
            self.assertEqual(me.headers["cache-control"], "no-store")
        finally:
            for name, value in original.items():
                setattr(settings, name, value)


class OAuthProtocolTest(unittest.TestCase):
    def setUp(self) -> None:
        self.original = {
            "google_client_id": settings.google_client_id,
            "google_client_secret": settings.google_client_secret,
            "google_redirect_uri": settings.google_redirect_uri,
            "apple_client_id": settings.apple_client_id,
            "apple_team_id": settings.apple_team_id,
            "apple_key_id": settings.apple_key_id,
            "apple_private_key": settings.apple_private_key,
            "apple_redirect_uri": settings.apple_redirect_uri,
            "auth_cookie_secure": settings.auth_cookie_secure,
        }

        settings.google_client_id = "google-client-id"
        settings.google_client_secret = "google-client-secret"
        settings.google_redirect_uri = "https://cloudstart.example.com/api/auth/google/callback"

        settings.apple_client_id = "com.example.cloudstart.web"
        settings.apple_team_id = "TEAM123456"
        settings.apple_key_id = "KEY1234567"
        settings.apple_private_key = "test-private-key"
        settings.apple_redirect_uri = "https://cloudstart.example.com/api/auth/apple/callback"
        settings.auth_cookie_secure = True

    def tearDown(self) -> None:
        for name, value in self.original.items():
            setattr(settings, name, value)

    def test_pkce_s256(self) -> None:
        verifier = create_pkce_verifier()
        challenge = create_pkce_challenge(verifier)

        self.assertGreaterEqual(len(verifier), 43)
        self.assertEqual(len(challenge), 43)

    def test_google_authorization_request(self) -> None:
        url = google_authorization_url(
            "state-value",
            "nonce-value",
            "challenge-value",
        )
        self.assertIn("response_type=code", url)
        self.assertIn("state=state-value", url)
        self.assertIn("nonce=nonce-value", url)
        self.assertIn("code_challenge=challenge-value", url)
        self.assertIn("code_challenge_method=S256", url)

    def test_apple_authorization_request(self) -> None:
        url = apple_authorization_url(
            "state-value",
            "nonce-value",
        )
        self.assertIn("response_type=code", url)
        self.assertIn("response_mode=form_post", url)
        self.assertIn("scope=name+email", url)
        self.assertIn("state=state-value", url)
        self.assertIn("nonce=nonce-value", url)

    def test_identity_uses_provider_subject(self) -> None:
        subject, email, verified, name = claims_to_identity(
            {
                "sub": "apple-subject-123",
                "email": "USER@EXAMPLE.COM",
                "email_verified": "true",
                "name": "User",
            }
        )
        self.assertEqual(subject, "apple-subject-123")
        self.assertEqual(email, "user@example.com")
        self.assertTrue(verified)
        self.assertEqual(name, "User")

    def test_apple_client_secret_claims(self) -> None:
        try:
            from cryptography.hazmat.primitives import serialization
            from cryptography.hazmat.primitives.asymmetric import ec

            private_key = ec.generate_private_key(ec.SECP256R1())
            settings.apple_private_key = private_key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            ).decode()

            token = generate_apple_client_secret()
            header = jwt.get_unverified_header(token)
            claims = jwt.decode(
                token,
                private_key.public_key(),
                algorithms=["ES256"],
                audience="https://appleid.apple.com",
            )

            self.assertEqual(header["alg"], "ES256")
            self.assertEqual(header["kid"], "KEY1234567")
            self.assertEqual(claims["iss"], "TEAM123456")
            self.assertEqual(claims["sub"], "com.example.cloudstart.web")
            self.assertGreater(
                claims["exp"],
                int(datetime.now(UTC).timestamp()),
            )
        except ModuleNotFoundError as exc:
            self.fail(f"cryptography dependency missing: {exc}")


if __name__ == "__main__":
    unittest.main()
