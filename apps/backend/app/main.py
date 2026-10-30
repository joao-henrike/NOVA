from fastapi import FastAPI, Request

from app.api.routes.auth import router as auth_router
from app.api.routes.health import router as health_router
from app.api.routes.items import router as items_router

app = FastAPI(
    title="CloudStart Backend",
    version="0.2.0",
    description="CloudStart application API.",
)

app.include_router(auth_router)
app.include_router(health_router)
app.include_router(items_router)


@app.middleware("http")
async def secure_api_responses(request: Request, call_next):
    response = await call_next(request)
    if request.url.path.startswith("/api/"):
        response.headers.setdefault("Cache-Control", "no-store")
        response.headers.setdefault("Pragma", "no-cache")
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
    return response


@app.get("/", tags=["root"])
def root() -> dict[str, str]:
    return {"service": "cloudstart-backend", "status": "ok"}
