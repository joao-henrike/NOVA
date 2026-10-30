from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.models.item import ItemStatus


class ItemCreate(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    description: str | None = Field(default=None, max_length=2000)
    status: ItemStatus = ItemStatus.ACTIVE


class ItemUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=120)
    description: str | None = Field(default=None, max_length=2000)
    status: ItemStatus | None = None

    @field_validator("name", "status", mode="before")
    @classmethod
    def reject_null_for_required_database_fields(cls, value):
        if value is None:
            raise ValueError("This field cannot be null.")
        return value


class ItemRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    description: str | None
    status: ItemStatus
    created_at: datetime
    updated_at: datetime
