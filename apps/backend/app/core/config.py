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
        return f"postgresql+psycopg://{user}:{password}@{self.db_host}:{self.db_port}/{self.db_name}"


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
