"""Photo understanding: vehicle photos (endpoint 4) and parking signs (endpoint 18)."""
import base64
import io

from fastapi import UploadFile

from .. import errors
from ..config import settings
from ..models import PlanOut, SignRead, VehicleVision
from . import data, llm

MAX_BYTES = 8 * 1024 * 1024


async def to_data_url(photo: UploadFile) -> str:
    raw = await photo.read()
    if not raw:
        raise errors.validation("Photo is empty.")
    if len(raw) > MAX_BYTES:
        raise errors.validation("Photo is larger than 8 MB.")
    mime = photo.content_type if (photo.content_type or "").startswith("image/") else "image/jpeg"
    return f"data:{mime};base64,{base64.b64encode(raw).decode()}"


def _require_vision():
    if not settings.vision_model:
        raise errors.llm_unavailable("VISION_MODEL is not set. Enter the vehicle manually.")


async def read_vehicle(photo: UploadFile) -> dict:
    _require_vision()
    url = await to_data_url(photo)
    out = await llm.chat_json(
        "vehicle_vision",
        "You read vehicle photos. Return JSON with keys plate, state (2-letter US code), make, model, "
        "color, confidence (0 to 1). Use an empty string for anything you cannot see.",
        "Read the license plate and identify the vehicle.", VehicleVision,
        model=settings.vision_model, images=[url])
    d = out.model_dump()
    d["plate"] = "".join(ch for ch in d["plate"].upper() if ch.isalnum())
    d["state"] = d["state"].upper()[:2]
    return d


async def analyze_sign(photo: UploadFile) -> tuple[PlanOut, bool]:
    """Returns (plan fields, needs_sign_photo)."""
    _require_vision()
    url = await to_data_url(photo)
    sign = await llm.chat_json(
        "sign_vision",
        "You read parking signs. Return JSON with keys sign_text, zone_code (string or null), method "
        "(pay_by_app|meter|garage|lot_attendant|free|permit_only|customers_only|unknown), "
        "price_per_hour_usd (number or null), time_limit_minutes (integer or null), hours (string or null), "
        "restrictions (list of strings, include every stacked time-based rule), readable (boolean), confidence (0 to 1). "
        "If the photo is blurry or not a sign set readable false.",
        "Read this parking sign.", SignRead, model=settings.vision_model, images=[url])
    return sign, (not sign.readable or sign.confidence < 0.4)
