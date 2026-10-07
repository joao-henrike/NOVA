from functools import lru_cache
from urllib.parse import quote_plus

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    app_name: str = "CloudStart Backend"
    app_env: str = "local"

    database_url: str | None = None
    db_host: str | None = None
    db_port: int = 5432
    db_name: str | None = None
    db_user: str | None = None
    db_password: str | None = None
    db_connect_timeout: int = 3

    google_client_id: str | None = None
    google_client_secret: str | None = None
    google_redirect_uri: str | None = None

    apple_client_id: str | None = None
    apple_team_id: str | None = None
    apple_key_id: str | None = None
    apple_private_key: str | None = None
    apple_private_key_path: str | None = None
    apple_redirect_uri: str | None = None
    apple_client_secret_ttl_seconds: int = 15_552_000

    auth_jwt_secret_key: str | None = None
    auth_token_issuer: str = "cloudstart-backend"
    auth_token_audience: str = "cloudstart-api"
    auth_access_token_ttl_minutes: int = 15
    auth_refresh_token_ttl_days: int = 30
    auth_state_ttl_seconds: int = 600
    auth_cookie_secure: bool = True

    google_authorization_url: str = "https://accounts.google.com/o/oauth2/v2/auth"
    google_token_url: str = "https://oauth2.googleapis.com/token"
    google_issuer: str = "https://accounts.google.com"

    apple_authorization_url: str = "https://appleid.apple.com/auth/authorize"
    apple_token_url: str = "https://appleid.apple.com/auth/token"
    apple_jwks_url: str = "https://appleid.apple.com/auth/keys"
    apple_issuer: str = "https://appleid.apple.com"

    @property
    def sqlalchemy_database_url(self) -> str:
        if self.database_url:
            return self.database_url

        if not all((self.db_host, self.db_name, self.db_user, self.db_password)):
            raise RuntimeError(
                "Database configuration is incomplete. Set DATABASE_URL or "
                "DB_HOST, DB_NAME, DB_USER and DB_PASSWORD."
            )

        user = quote_plus(self.db_user or "")
        password = quote_plus(self.db_password or "")
        return (
            f"postgresql+psycopg://{user}:{password}@"
            f"{self.db_host}:{self.db_port}/{self.db_name}"
        )

    def require_google_config(self) -> None:
        if not all(
            (self.google_client_id, self.google_client_secret, self.google_redirect_uri)
        ):
            raise RuntimeError("Google authentication is not configured.")

    def require_apple_config(self) -> None:
        if not all(
            (
                self.apple_client_id,
                self.apple_team_id,
                self.apple_key_id,
                self.apple_redirect_uri,
            )
        ):
            raise RuntimeError("Apple authentication is not configured.")

    def require_auth_signing_key(self) -> str:
        if not self.auth_jwt_secret_key or len(self.auth_jwt_secret_key) < 32:
            raise RuntimeError(
                "AUTH_JWT_SECRET_KEY must contain at least 32 characters."
            )
        return self.auth_jwt_secret_key

    def get_apple_private_key(self) -> str:
        if self.apple_private_key:
            return self.apple_private_key.replace("\\n", "\n")

        if self.apple_private_key_path:
            with open(self.apple_private_key_path, encoding="utf-8") as key_file:
                return key_file.read()

        raise RuntimeError("Apple private key is not configured.")


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
