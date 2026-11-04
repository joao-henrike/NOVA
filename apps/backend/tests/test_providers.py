import unittest
from datetime import UTC, datetime, timedelta
from unittest.mock import Mock, patch

import httpx
import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from google.auth.exceptions import TransportError
from jwt.exceptions import PyJWKClientError

from app.api.routes.auth import _extract_apple_profile_name, _validate_redirect_uri
from app.core.config import settings
from app.services.providers import (
    ProviderAuthenticationError,
    _post_form,
    claims_to_identity,
    exchange_apple_code,
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


    @patch("app.services.providers.httpx.post")
    def test_token_exchange_normalizes_transport_errors(self, post) -> None:
        post.side_effect = httpx.ConnectError("provider unavailable")

        with self.assertRaisesRegex(ProviderAuthenticationError, "request failed"):
            _post_form("https://provider.example/token", {"code": "test"})

    @patch("app.services.providers.httpx.post")
    def test_token_exchange_normalizes_invalid_json(self, post) -> None:
        response = Mock()
        response.json.side_effect = ValueError("invalid JSON")
        post.return_value = response

        with self.assertRaisesRegex(ProviderAuthenticationError, "request failed"):
            _post_form("https://provider.example/token", {"code": "test"})

    @patch("app.services.providers.httpx.post")
    def test_token_exchange_rejects_non_object_and_provider_errors(self, post) -> None:
        response = Mock()
        response.json.return_value = ["not", "an", "object"]
        post.return_value = response
        with self.assertRaisesRegex(ProviderAuthenticationError, "invalid data"):
            _post_form("https://provider.example/token", {"code": "test"})

        response.json.return_value = {"error": "access_denied"}
        with self.assertRaisesRegex(ProviderAuthenticationError, "rejected"):
            _post_form("https://provider.example/token", {"code": "test"})

    @patch("app.services.providers._post_form", return_value={})
    def test_google_code_exchange_rejects_missing_id_token(self, post_form) -> None:
        with self.assertRaisesRegex(ProviderAuthenticationError, "ID token"):
            exchange_google_code(
                "authorization-code",
                "pkce-verifier",
                settings.google_redirect_uri,
            )

    @patch("app.services.providers._post_form", return_value={})
    @patch("app.services.providers.generate_apple_client_secret", return_value="client-secret")
    def test_apple_code_exchange_rejects_missing_id_token(
        self,
        client_secret,
        post_form,
    ) -> None:
        with self.assertRaisesRegex(ProviderAuthenticationError, "ID token"):
            exchange_apple_code(
                "authorization-code",
                settings.apple_redirect_uri,
            )
        client_secret.assert_called_once()
        post_form.assert_called_once()

    @patch("app.services.providers._post_form")
    @patch("app.services.providers.generate_apple_client_secret", return_value="client-secret")
    def test_apple_code_exchange_sends_expected_parameters(
        self,
        client_secret,
        post_form,
    ) -> None:
        post_form.return_value = {"id_token": "apple-id-token"}
        result = exchange_apple_code("authorization-code", settings.apple_redirect_uri)

        self.assertEqual(result["id_token"], "apple-id-token")
        data = post_form.call_args.args[1]
        self.assertEqual(data["client_id"], settings.apple_client_id)
        self.assertEqual(data["client_secret"], "client-secret")
        self.assertEqual(data["code"], "authorization-code")
        self.assertEqual(data["redirect_uri"], settings.apple_redirect_uri)
        self.assertEqual(data["grant_type"], "authorization_code")
        client_secret.assert_called_once()

    @patch("app.services.providers.id_token.verify_oauth2_token")
    def test_google_id_token_normalizes_invalid_token_value(self, verify) -> None:
        verify.side_effect = ValueError("invalid provider token")
        with self.assertRaisesRegex(ProviderAuthenticationError, "validation failed"):
            verify_google_id_token("invalid-token", "expected-nonce")

    def test_apple_jwks_lookup_errors_are_normalized(self) -> None:
        client = Mock()
        client.get_signing_key_from_jwt.side_effect = PyJWKClientError("JWKS unavailable")
        with (
            patch("app.services.providers.get_apple_jwk_client", return_value=client),
            self.assertRaisesRegex(ProviderAuthenticationError, "validation failed"),
        ):
            verify_apple_id_token("signed-token", "expected-nonce")

    def test_provider_identity_rejects_invalid_subject_and_oversized_fields(self) -> None:
        invalid_subjects = (None, "", "  ", 123)
        for subject in invalid_subjects:
            with (
                self.subTest(subject=subject),
                self.assertRaisesRegex(ProviderAuthenticationError, "subject"),
            ):
                claims_to_identity({"sub": subject})

        with self.assertRaisesRegex(ProviderAuthenticationError, "subject is too long"):
            claims_to_identity({"sub": "S" * 256})

        with self.assertRaisesRegex(ProviderAuthenticationError, "email address is too long"):
            claims_to_identity(
                {
                    "sub": "valid-subject",
                    "email": ("a" * 310) + "@example.com",
                    "email_verified": True,
                }
            )

    def test_redirect_uri_rejects_missing_scheme_fragment_and_malformed_host(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "absolute HTTP"):
            _validate_redirect_uri("/api/auth/callback")
        with self.assertRaisesRegex(RuntimeError, "fragment"):
            _validate_redirect_uri("https://example.com/callback#fragment")
        with self.assertRaisesRegex(RuntimeError, "invalid"):
            _validate_redirect_uri("http://[::1")

    def test_apple_redirect_requires_https_and_registered_domain(self) -> None:
        settings.app_env = "local"
        with self.assertRaisesRegex(RuntimeError, "requires HTTPS"):
            _validate_redirect_uri("http://localhost:8000/callback", apple=True)
        with self.assertRaisesRegex(RuntimeError, "registered domain"):
            _validate_redirect_uri("https://localhost/callback", apple=True)

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
