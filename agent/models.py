"""Pydantic schemas mirroring API_CONTRACT.md objects."""
from typing import Literal, Optional

from pydantic import BaseModel, Field

Role = Literal["resident", "visitor"]
NotifyChannel = Literal["app", "message", "both"]
CANONICAL_FIELDS = ["plate", "state", "make", "model", "color", "host_unit", "host_name",
                    "guest_name", "phone", "email", "duration_hours"]
STEP_NAMES = ["match_property", "open_portal", "fill_form", "submit", "capture_proof"]


class UserIn(BaseModel):
    name: str = Field(min_length=1)
    phone: str = Field(pattern=r"^\+[1-9]\d{6,14}$")  # E.164
    email: str = Field(min_length=3)
    consent_register: bool = False
    spending_cap_usd: float = 0
    notify_channel: NotifyChannel = "app"


class VehicleIn(BaseModel):
    plate: str = Field(min_length=1, max_length=12)
    state: str = Field(min_length=2, max_length=2)
    make: str
    model: str
    color: str
    year: Optional[int] = None


class Host(BaseModel):
    name: Optional[str] = None
    unit: Optional[str] = None


class DraftIn(BaseModel):
    vehicle_id: str
    property_id: str
    role: Role
    host: Optional[Host] = None
    duration_hours: int = Field(gt=0)


class PatchIn(BaseModel):
    vehicle_id: Optional[str] = None
    property_id: Optional[str] = None
    role: Optional[Role] = None
    host: Optional[Host] = None
    duration_hours: Optional[int] = Field(default=None, gt=0)


class ConfirmIn(BaseModel):
    channel: Literal["app", "message"] = "app"


class AnswerIn(BaseModel):
    field: str
    value: str


class RenewIn(BaseModel):
    duration_hours: int = Field(gt=0)


class CheckoutIn(BaseModel):
    plan_id: str
    amount_usd: float = Field(ge=0)


# ---- LLM output schemas (validated before use) ----
class Fill(BaseModel):
    selector: str
    value: str


class FormPlan(BaseModel):
    fills: list[Fill]
    click: Optional[str] = None


class Intent(BaseModel):
    intent: Literal["yes", "no", "edit", "other"]


class ConfirmationExtract(BaseModel):
    confirmation_number: str
    expires_at: str


class VehicleVision(BaseModel):
    plate: str = ""
    state: str = ""
    make: str = ""
    model: str = ""
    color: str = ""
    confidence: float = 0.0


class SignRead(BaseModel):
    """What the vision model reads off a sign photo."""
    sign_text: str = ""
    zone_code: Optional[str] = None
    method: str = "unknown"
    price_per_hour_usd: Optional[float] = None
    time_limit_minutes: Optional[int] = None
    hours: Optional[str] = None
    restrictions: list[str] = []
    readable: bool = True
    confidence: float = 0.0


class PlanOut(BaseModel):
    method: Literal["pay_by_app", "meter", "garage", "lot_attendant", "free",
                    "permit_only", "customers_only", "unknown"] = "unknown"
    zone_code: Optional[str] = None
    price_per_hour_usd: Optional[float] = None
    total_usd: Optional[float] = None
    time_limit_minutes: Optional[int] = None
    hours: Optional[str] = None
    tow_risk: Literal["low", "medium", "high"] = "medium"
    confidence: float = 0.0
    warnings: list[str] = []
