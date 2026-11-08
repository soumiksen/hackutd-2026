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


class MaverickGuest(BaseModel):
    first_name: Optional[str] = None
    last_name: Optional[str] = None
    email: Optional[str] = None


class MaverickIn(BaseModel):
    """Hard-coded Maverick Place guest registration (contract endpoint 22)."""
    vehicle_id: str
    unit: Optional[str] = Field(default=None, min_length=1, max_length=20)                 # e.g. "101-A"; saved place if omitted
    resident_last_name: Optional[str] = Field(default=None, min_length=1, max_length=60)   # the resident being visited
    guest: Optional[MaverickGuest] = None                          # defaults to the user's name and email
    confirm: bool = False                                          # the app sends true only after the user taps Register
    dry_run: bool = False                                          # fill the form, take a screenshot, do not submit


class SignUpIn(BaseModel):
    email: str
    password: str
    name: str = Field(min_length=1, max_length=100)
    phone: str = Field(pattern=r"^\+[1-9]\d{6,14}$")
    consent_register: bool = False
    spending_cap_usd: float = Field(default=10, ge=0, le=1000)
    notify_channel: NotifyChannel = "app"


class SignInIn(BaseModel):
    email: str
    password: str


class PasswordIn(BaseModel):
    current_password: str
    new_password: str


class UserPatch(BaseModel):
    name: Optional[str] = Field(default=None, min_length=1, max_length=100)
    phone: Optional[str] = Field(default=None, pattern=r"^\+[1-9]\d{6,14}$")
    consent_register: Optional[bool] = None
    spending_cap_usd: Optional[float] = Field(default=None, ge=0, le=1000)
    notify_channel: Optional[NotifyChannel] = None


class PlaceLabelIn(BaseModel):
    label: str = Field(max_length=60)


class ResidentDetails(BaseModel):
    """What a resident's free-text reply contains. Empty strings when it is not there."""
    unit: str = ""
    last_name: str = ""
