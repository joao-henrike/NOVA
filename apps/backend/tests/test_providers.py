import unittest
from datetime import UTC, datetime, timedelta
from unittest.mock import Mock, patch

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from google.auth.exceptions import TransportError

from app.api.routes.auth import _extract_apple_profile_name, _validate_redirect_uri
from app.core.config import settings
from app.services.providers import (
    ProviderAuthenticationError,
    exchange_google_code,
    verify_apple_id_token,
    verify_google_id_token,
)


class ProviderSettingsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.original = {
            "app_env": settings.app_env,
            "google_client_id": settings.google_client_id,
            "google_client_secret": settings.google_client_secret,
            "google_redirect_uri": settings.google_redirect_uri,
            "apple_client_id": settings.apple_client_id,
            "apple_team_id": settings.apple_team_id,
            "apple_key_id": settings.apple_key_id,
            "apple_private_key": settings.apple_private_key,
            "apple_redirect_uri": settings.apple_redirect_uri,
        }
        settings.google_client_id = "google-client-id"
        settings.google_client_secret = "google-client-secret"
        settings.google_redirect_uri = (
            "https://cloudstart.example.com/api/auth/google/callback"
        )
        settings.apple_client_id = "com.example.cloudstart.web"
        settings.apple_team_id = "TEAM123456"
        settings.apple_key_id = "KEY1234567"
        settings.apple_private_key = "test-private-key"
        settings.apple_redirect_uri = (
            "https://cloudstart.example.com/api/auth/apple/callback"
        )

    def tearDown(self) -> None:
        for name, value in self.original.items():
            setattr(settings, name, value)

    @patch("app.services.providers.id_token.verify_oauth2_token")
    def test_google_id_token_accepts_expected_issuer_nonce_and_subject(
        self,
        verify,
    ) -> None:
        claims = {
            "iss": "https://accounts.google.com",
            "aud": "google-client-id",
            "nonce": "expected-nonce",
            "sub": "google-subject",
        }
        verify.return_value = claims

        result = verify_google_id_token("signed-token", "expected-nonce")

        self.assertEqual(result, claims)
        verify.assert_called_once()
        self.assertEqual(verify.call_args.args[2], "google-client-id")
        self.assertEqual(verify.call_args.args[1].keywords["timeout"], 10)

    @patch("app.services.providers.id_token.verify_oauth2_token")
    def test_google_id_token_rejects_wrong_nonce(self, verify) -> None:
        verify.return_value = {
            "iss": "https://accounts.google.com",
            "aud": "google-client-id",
            "nonce": "different-nonce",
            "sub": "google-subject",
        }

        with self.assertRaisesRegex(ProviderAuthenticationError, "nonce"):
            verify_google_id_token("signed-token", "expected-nonce")

    @patch("app.services.providers.id_token.verify_oauth2_token")
    def test_google_id_token_rejects_wrong_issuer(self, verify) -> None:
        verify.return_value = {
            "iss": "https://attacker.example",
            "aud": "google-client-id",
            "nonce": "expected-nonce",
            "sub": "google-subject",
        }

        with self.assertRaisesRegex(ProviderAuthenticationError, "issuer"):
            verify_google_id_token("signed-token", "expected-nonce")

    @patch("app.services.providers.id_token.verify_oauth2_token")
    def test_google_id_token_rejects_missing_subject(self, verify) -> None:
        verify.return_value = {
            "iss": "https://accounts.google.com",
            "aud": "google-client-id",
            "nonce": "expected-nonce",
        }

        with self.assertRaisesRegex(ProviderAuthenticationError, "subject"):
            verify_google_id_token("signed-token", "expected-nonce")

    @patch("app.services.providers.id_token.verify_oauth2_token")
    def test_google_transport_errors_are_normalized(self, verify) -> None:
        verify.side_effect = TransportError("provider is unreachable")

        with self.assertRaisesRegex(
            ProviderAuthenticationError,
            "validation failed",
        ):
            verify_google_id_token("signed-token", "expected-nonce")

    @patch("app.services.providers._post_form")
    def test_google_code_exchange_sends_pkce_verifier(self, post_form) -> None:
        post_form.return_value = {"id_token": "provider-id-token"}

        result = exchange_google_code(
            "authorization-code",
            "pkce-verifier",
            settings.google_redirect_uri,
        )

        self.assertEqual(result["id_token"], "provider-id-token")
        data = post_form.call_args.args[1]
        self.assertEqual(data["code"], "authorization-code")
        self.assertEqual(data["code_verifier"], "pkce-verifier")
        self.assertEqual(data["grant_type"], "authorization_code")
        self.assertEqual(data["redirect_uri"], settings.google_redirect_uri)

    def _apple_token(self, *, nonce="expected-nonce", audience=None, issuer=None):
        private_key = rsa.generate_private_key(
            public_exponent=65537,
            key_size=2048,
        )
        now = datetime.now(UTC)
        claims = {
            "iss": issuer or settings.apple_issuer,
            "aud": audience or settings.apple_client_id,
            "iat": now,
            "exp": now + timedelta(minutes=5),
            "sub": "apple-subject",
            "nonce": nonce,
        }
        token = jwt.encode(claims, private_key, algorithm="RS256", headers={"kid": "test-key"})
        return token, private_key.public_key()

    def _mock_apple_jwks(self, public_key):
        client = Mock()
        client.get_signing_key_from_jwt.return_value = public_key
        return patch(
            "app.services.providers.get_apple_jwk_client",
            return_value=client,
        )

    def test_apple_id_token_verifies_signature_issuer_audience_and_nonce(self) -> None:
        token, public_key = self._apple_token()

        with self._mock_apple_jwks(public_key):
            claims = verify_apple_id_token(token, "expected-nonce")

        self.assertEqual(claims["sub"], "apple-subject")
        self.assertEqual(claims["aud"], settings.apple_client_id)

    def test_apple_id_token_rejects_wrong_nonce(self) -> None:
        token, public_key = self._apple_token(nonce="different-nonce")

        with (
            self._mock_apple_jwks(public_key),
            self.assertRaisesRegex(ProviderAuthenticationError, "nonce"),
        ):
            verify_apple_id_token(token, "expected-nonce")

    def test_apple_id_token_rejects_wrong_audience(self) -> None:
        token, public_key = self._apple_token(audience="another-client-id")

        with (
            self._mock_apple_jwks(public_key),
            self.assertRaises(ProviderAuthenticationError),
        ):
            verify_apple_id_token(token, "expected-nonce")

    def test_apple_id_token_rejects_wrong_issuer(self) -> None:
        token, public_key = self._apple_token(issuer="https://attacker.example")

        with (
            self._mock_apple_jwks(public_key),
            self.assertRaises(ProviderAuthenticationError),
        ):
            verify_apple_id_token(token, "expected-nonce")

    def test_apple_browser_profile_uses_name_but_never_email(self) -> None:
        supplied_profile = (
            '{"email":"victim@example.com",'
            '"name":{"firstName":"  Jane ","lastName":" Doe  "}}'
        )

        self.assertEqual(_extract_apple_profile_name(supplied_profile), "Jane Doe")

    def test_apple_browser_profile_rejects_invalid_or_non_object_data(self) -> None:
        self.assertIsNone(_extract_apple_profile_name(None))
        self.assertIsNone(_extract_apple_profile_name("not-json"))
        self.assertIsNone(_extract_apple_profile_name('["not", "an", "object"]'))
        self.assertIsNone(_extract_apple_profile_name('{"name":"not-an-object"}'))

    def test_apple_browser_profile_limits_display_name_length(self) -> None:
        long_name = "A" * 250
        supplied_profile = (
            '{"name":{"firstName":"' + long_name + '","lastName":""}}'
        )

        self.assertEqual(len(_extract_apple_profile_name(supplied_profile) or ""), 200)

    def test_redirect_uri_requires_https_outside_localhost_development(self) -> None:
        settings.app_env = "dev"

        with self.assertRaisesRegex(RuntimeError, "localhost in local development"):
            _validate_redirect_uri("http://cloudstart.example.com/callback")

        _validate_redirect_uri("https://cloudstart.example.com/callback")

    def test_localhost_http_redirect_is_allowed_only_in_local_environment(self) -> None:
        settings.app_env = "local"
        _validate_redirect_uri("http://localhost:8000/api/auth/google/callback")

        with self.assertRaises(RuntimeError):
            _validate_redirect_uri("http://192.0.2.10/callback")

    def test_redirect_uri_rejects_embedded_user_information(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "user information"):
            _validate_redirect_uri("https://user:password@example.com/callback")


if __name__ == "__main__":
    unittest.main()
