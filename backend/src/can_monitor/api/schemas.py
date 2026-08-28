"""Versioned HTTP request schemas."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from can_monitor.domain.models import CanIdFilter, FilterConfig, FilterMode
from can_monitor.domain.validation import validate_can_id


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class FilterIdRequest(StrictModel):
    can_id: int = Field(ge=0)
    is_extended_id: bool = False

    @model_validator(mode="after")
    def validate_identifier(self) -> "FilterIdRequest":
        try:
            validate_can_id(self.can_id, self.is_extended_id)
        except Exception as error:
            raise ValueError(str(error)) from error
        return self


class FilterRequest(StrictModel):
    mode: Literal["all", "filtered"] = "all"
    ids: list[FilterIdRequest] = Field(default_factory=list, max_length=512)

    @model_validator(mode="after")
    def validate_semantics(self) -> "FilterRequest":
        if self.mode == "filtered" and not self.ids:
            raise ValueError("Filtered mode requires at least one CAN ID")
        if self.mode == "all" and self.ids:
            raise ValueError("ALL mode must not include CAN IDs")
        unique = {(item.can_id, item.is_extended_id) for item in self.ids}
        if len(unique) != len(self.ids):
            raise ValueError("Duplicate CAN ID filters are not allowed")
        return self

    def to_domain(self) -> FilterConfig:
        return FilterConfig(
            mode=FilterMode(self.mode),
            ids=tuple(
                CanIdFilter(item.can_id, item.is_extended_id) for item in self.ids
            ),
        )


class SessionCreateRequest(StrictModel):
    interface: str = Field(min_length=1, max_length=32, pattern=r"^[A-Za-z0-9_.:-]+$")
    filter: FilterRequest = Field(default_factory=FilterRequest)
    fd: bool = False


class SendFrameRequest(StrictModel):
    can_id: int = Field(ge=0)
    is_extended_id: bool = False
    is_fd: bool = False
    data_hex: str = Field(default="", max_length=256)

    @model_validator(mode="after")
    def validate_identifier(self) -> "SendFrameRequest":
        try:
            validate_can_id(self.can_id, self.is_extended_id)
        except Exception as error:
            raise ValueError(str(error)) from error
        return self
