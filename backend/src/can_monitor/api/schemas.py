"""Versioned HTTP request schemas."""

from __future__ import annotations

import uuid
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from can_monitor.application.transmission import (
    MIN_CYCLIC_PERIOD_MS,
    TransmissionMessage,
    TransmissionMode,
)
from can_monitor.domain.crc import CRC_PRESETS, ByteOrder, CrcInsertion, CrcParameters
from can_monitor.domain.counter import CounterConfig
from can_monitor.domain.models import CanIdFilter, FilterConfig, FilterMode
from can_monitor.domain.validation import parse_hex_payload, validate_can_id


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
    mode: Literal["all", "whitelist", "blacklist"] = "all"
    ids: list[FilterIdRequest] = Field(default_factory=list, max_length=512)

    @model_validator(mode="after")
    def validate_semantics(self) -> "FilterRequest":
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


class TxEnabledRequest(StrictModel):
    enabled: bool


class CrcRequest(StrictModel):
    algorithm: str = Field(max_length=64)
    range_start: int = Field(ge=0, le=63)
    range_end: int = Field(ge=0, le=63)
    position: int = Field(ge=0, le=63)
    byte_order: Literal["big", "little"] = "big"
    width: Literal[8, 16, 32] | None = None
    polynomial: int | None = Field(default=None, ge=0)
    initial_value: int | None = Field(default=None, ge=0)
    xor_out: int | None = Field(default=None, ge=0)
    reflect_input: bool | None = None
    reflect_output: bool | None = None

    def to_domain(self) -> CrcInsertion:
        if self.algorithm == "CUSTOM":
            values = (
                self.width,
                self.polynomial,
                self.initial_value,
                self.xor_out,
                self.reflect_input,
                self.reflect_output,
            )
            if any(value is None for value in values):
                raise ValueError("Custom CRC requires all algorithm parameters")
            parameters = CrcParameters(
                "CUSTOM",
                self.width,  # type: ignore[arg-type]
                self.polynomial,  # type: ignore[arg-type]
                self.initial_value,  # type: ignore[arg-type]
                self.xor_out,  # type: ignore[arg-type]
                self.reflect_input,  # type: ignore[arg-type]
                self.reflect_output,  # type: ignore[arg-type]
            )
        else:
            try:
                parameters = CRC_PRESETS[self.algorithm]
            except KeyError as error:
                raise ValueError(f"Unknown CRC algorithm: {self.algorithm}") from error
        parameters.validate()
        return CrcInsertion(
            parameters,
            self.range_start,
            self.range_end,
            self.position,
            ByteOrder(self.byte_order),
        )


class CounterRequest(StrictModel):
    enabled: bool = True
    bit_offset: int = Field(ge=0)
    bit_length: int = Field(ge=1, le=8)
    initial_value: int = Field(default=0, ge=0)
    increment: int = Field(default=1, gt=0)

    def to_domain(self) -> CounterConfig | None:
        if not self.enabled:
            return None
        return CounterConfig(
            bit_offset=self.bit_offset,
            bit_length=self.bit_length,
            initial_value=self.initial_value,
            increment=self.increment,
        )


class TransmissionMessageRequest(StrictModel):
    message_id: str = Field(
        default_factory=lambda: str(uuid.uuid4()),
        min_length=1,
        max_length=64,
        pattern=r"^[A-Za-z0-9_-]+$",
    )
    enabled: bool = True
    can_id: int = Field(ge=0)
    is_extended_id: bool = False
    is_fd: bool = False
    data_hex: str = Field(default="", max_length=256)
    mode: Literal["single", "cyclic"] = "single"
    period_ms: float | None = Field(
        default=None, ge=MIN_CYCLIC_PERIOD_MS, le=60_000
    )
    crc: CrcRequest | None = None
    counter: CounterRequest | None = None

    @model_validator(mode="after")
    def validate_message(self) -> "TransmissionMessageRequest":
        validate_can_id(self.can_id, self.is_extended_id)
        payload = parse_hex_payload(self.data_hex, is_fd=self.is_fd)
        if self.mode == "cyclic" and self.period_ms is None:
            raise ValueError("Cyclic messages require a period_ms")
        if self.mode == "single" and self.period_ms is not None:
            raise ValueError("Single messages must not define period_ms")
        if self.crc is not None:
            from can_monitor.domain.crc import insert_crc

            insert_crc(payload, self.crc.to_domain())
        TransmissionMessage(
            message_id=self.message_id,
            enabled=self.enabled,
            can_id=self.can_id,
            is_extended_id=self.is_extended_id,
            is_fd=self.is_fd,
            payload=payload,
            mode=TransmissionMode(self.mode),
            period_ms=self.period_ms,
            crc=self.crc.to_domain() if self.crc else None,
            counter=self.counter.to_domain() if self.counter else None,
        )
        return self

    def to_domain(self) -> TransmissionMessage:
        return TransmissionMessage(
            message_id=self.message_id,
            enabled=self.enabled,
            can_id=self.can_id,
            is_extended_id=self.is_extended_id,
            is_fd=self.is_fd,
            payload=parse_hex_payload(self.data_hex, is_fd=self.is_fd),
            mode=TransmissionMode(self.mode),
            period_ms=self.period_ms,
            crc=self.crc.to_domain() if self.crc else None,
            counter=self.counter.to_domain() if self.counter else None,
        )


class TransmissionPlanRequest(StrictModel):
    messages: list[TransmissionMessageRequest] = Field(min_length=1, max_length=128)

    @model_validator(mode="after")
    def validate_unique_ids(self) -> "TransmissionPlanRequest":
        ids = [message.message_id for message in self.messages]
        if len(ids) != len(set(ids)):
            raise ValueError("Transmission message IDs must be unique")
        if not any(message.enabled for message in self.messages):
            raise ValueError("At least one transmission message must be enabled")
        return self
