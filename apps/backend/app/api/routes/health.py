from fastapi import APIRouter
from fastapi.responses import JSONResponse
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from app.core.config import settings
from app.db.session import get_engine


router = APIRouter(tags=["health"])


@router.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@router.get("/api/health")
def api_health() -> dict[str, str]:
    return {"status": "ok", "service": "backend"}


@router.get("/api/info")
def info() -> dict[str, str]:
    return {
        "service": "backend",
        "environment": settings.app_env,
        "version": "0.2.0",
    }


@router.get("/api/health/db")
def database_health() -> JSONResponse:
    try:
        with get_engine().connect() as connection:
            connection.execute(text("SELECT 1"))
    except (RuntimeError, SQLAlchemyError):
        return JSONResponse(status_code=503, content={"status": "degraded"})

    return JSONResponse(content={"status": "ok", "database": "reachable"})
