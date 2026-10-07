from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.api.dependencies import CurrentUser
from app.db.session import get_db
from app.models.item import Item, ItemStatus
from app.schemas.item import ItemCreate, ItemRead, ItemUpdate
from app.services.items import ItemNotFoundError, ItemService


router = APIRouter(prefix="/api/items", tags=["items"])
service = ItemService()


@router.get("", response_model=list[ItemRead])
def list_items(
    current_user: CurrentUser,
    offset: int = Query(default=0, ge=0),
    limit: int = Query(default=50, ge=1, le=100),
    item_status: ItemStatus | None = Query(default=None, alias="status"),
    db: Session = Depends(get_db),
) -> list[Item]:
    return service.list(
        db,
        offset=offset,
        limit=limit,
        status=item_status,
    )


@router.post("", response_model=ItemRead, status_code=status.HTTP_201_CREATED)
def create_item(
    data: ItemCreate,
    current_user: CurrentUser,
    db: Session = Depends(get_db),
) -> Item:
    return service.create(db, data)


@router.get("/{item_id}", response_model=ItemRead)
def get_item(
    item_id: UUID,
    current_user: CurrentUser,
    db: Session = Depends(get_db),
) -> Item:
    try:
        return service.get(db, item_id)
    except ItemNotFoundError as exc:
        raise HTTPException(status_code=404, detail="Item not found") from exc


@router.patch("/{item_id}", response_model=ItemRead)
def update_item(
    item_id: UUID,
    data: ItemUpdate,
    current_user: CurrentUser,
    db: Session = Depends(get_db),
) -> Item:
    if not data.model_dump(exclude_unset=True):
        raise HTTPException(status_code=400, detail="No fields to update")

    try:
        return service.update(db, item_id, data)
    except ItemNotFoundError as exc:
        raise HTTPException(status_code=404, detail="Item not found") from exc


@router.delete("/{item_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_item(
    item_id: UUID,
    current_user: CurrentUser,
    db: Session = Depends(get_db),
) -> None:
    try:
        service.delete(db, item_id)
    except ItemNotFoundError as exc:
        raise HTTPException(status_code=404, detail="Item not found") from exc
