from fastapi import FastAPI

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


@app.get("/", tags=["root"])
def root() -> dict[str, str]:
    return {"service": "cloudstart-backend", "status": "ok"}
