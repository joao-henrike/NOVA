import os

import psycopg
from fastapi import FastAPI
from fastapi.responses import JSONResponse

app = FastAPI(title="CloudStart Backend", version="0.1.0")


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/api/health")
def api_health() -> dict[str, str]:
    return {"status": "ok", "service": "backend"}


@app.get("/api/info")
def info() -> dict[str, str]:
    return {
        "service": "backend",
        "environment": os.getenv("APP_ENV", "unknown"),
    }


@app.get("/api/health/db")
def database_health() -> JSONResponse:
    required = ["DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD"]
    if any(not os.getenv(key) for key in required):
        return JSONResponse(status_code=503, content={"status": "degraded"})

    try:
        with psycopg.connect(
            host=os.environ["DB_HOST"],
            port=int(os.environ["DB_PORT"]),
            dbname=os.environ["DB_NAME"],
            user=os.environ["DB_USER"],
            password=os.environ["DB_PASSWORD"],
            connect_timeout=3,
        ):
            return JSONResponse(content={"status": "ok", "database": "reachable"})
    except psycopg.Error:
        return JSONResponse(status_code=503, content={"status": "degraded"})
