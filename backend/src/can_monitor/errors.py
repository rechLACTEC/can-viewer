"""Application exceptions with stable HTTP problem metadata."""

from __future__ import annotations


class CanMonitorError(Exception):
    status_code = 500
    code = "internal_error"
    title = "Internal server error"

    def __init__(self, detail: str) -> None:
        super().__init__(detail)
        self.detail = detail


class InvalidRequestError(CanMonitorError):
    status_code = 400
    code = "invalid_request"
    title = "Invalid request"


class NotFoundError(CanMonitorError):
    status_code = 404
    code = "not_found"
    title = "Resource not found"


class ConflictError(CanMonitorError):
    status_code = 409
    code = "conflict"
    title = "Resource conflict"


class TransmissionDisabledError(CanMonitorError):
    status_code = 403
    code = "transmission_disabled"
    title = "CAN transmission disabled"


class TransmissionAuthorizationError(CanMonitorError):
    status_code = 403
    code = "transmission_authorization_failed"
    title = "CAN transmission authorization failed"


class RateLimitError(CanMonitorError):
    status_code = 429
    code = "rate_limit_exceeded"
    title = "CAN transmission rate limit exceeded"


class CanAdapterError(CanMonitorError):
    status_code = 503
    code = "can_adapter_error"
    title = "CAN interface unavailable"


class RecordingStorageError(CanMonitorError):
    status_code = 507
    code = "recording_storage_error"
    title = "CAN recording storage unavailable"
