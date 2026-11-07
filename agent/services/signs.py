"""Flow 2: sign photo to parking plan, and mock checkout."""
import json
import uuid
from datetime import datetime, timedelta

from fastapi import UploadFile

from .. import db, errors
from ..models import PlanOut, SignRead
from . import data, drafts, llm, proofs, vision

DEFAULT_STAY = timedelta(hours=2)
PAID = {"pay_by_app", "meter", "garage", "lot_attendant"}

SYSTEM = (
    "You turn a parking sign reading into a parking plan. Stacked time-based rules must be evaluated for BOTH "
    "the current local time and the planned leave time; apply the stricter outcome and add a warning if the "
    "leave time crosses a restriction. Return JSON keys: method (pay_by_app|meter|garage|lot_attendant|free|"
    "permit_only|customers_only|unknown), zone_code, price_per_hour_usd, time_limit_minutes, hours, "
    "tow_risk (low|medium|high), confidence (0 to 1), warnings (list of short strings). "
    "Only use facts from the input. Use null when unknown.")


def _event_warnings(now: datetime) -> list[str]:
    today = now.date().isoformat()
    return [f"Event day nearby: {e['parking_note']}" if e.get("parking_note")
            else "Event day nearby: expect higher lot prices"
            for e in data.events() if e.get("date") == today]


async def analyze(user_id: str, photo: UploadFile, lat: float | None, lng: float | None) -> dict:
    sign, unreadable = await vision.analyze_sign(photo)
    now = datetime.now(drafts.TZ)
    zone = next((z for z in data.zones() if z["zone_code"] == sign.zone_code), None)
    sources = [{"type": "sign_photo", "label": "Your photo"}]

    context = {"sign": sign.model_dump(), "zone": zone, "now_local": now.strftime("%a %H:%M"),
               "leave_local": (now + DEFAULT_STAY).strftime("%a %H:%M")}
    try:
        plan = await llm.chat_json("sign_plan", SYSTEM, json.dumps(context, sort_keys=True), PlanOut)
    except errors.ApiError:  # text step unavailable: fall back to the raw sign reading
        plan = PlanOut(method=_method(sign), zone_code=sign.zone_code, price_per_hour_usd=sign.price_per_hour_usd,
                       time_limit_minutes=sign.time_limit_minutes, hours=sign.hours,
                       confidence=min(sign.confidence, 0.6), warnings=list(sign.restrictions))

    if zone:  # the zone table is authoritative for price and limits
        sources.append({"type": "zones", "label": "Sample zone table"})
        plan.zone_code = zone["zone_code"]
        plan.price_per_hour_usd = zone["price_per_hour_usd"]
        plan.hours = plan.hours or zone["hours"]
        plan.time_limit_minutes = plan.time_limit_minutes or zone["time_limit_minutes"]
        if plan.method == "unknown":
            plan.method = "pay_by_app"
    ev = _event_warnings(now)
    if ev:
        sources.append({"type": "events", "label": "Sample event calendar"})
        plan.warnings += [w for w in ev if w not in plan.warnings]

    if plan.method in ("permit_only", "customers_only"):
        plan.tow_risk = "high"
    stay_h = min((plan.time_limit_minutes or 120) / 60, DEFAULT_STAY.total_seconds() / 3600)
    total = None
    if plan.method == "free":
        total = 0.0
    elif plan.method in PAID and plan.price_per_hour_usd is not None:
        total = round(plan.price_per_hour_usd * stay_h, 2)
    needs_photo = unreadable or plan.method == "unknown"
    confidence = round(min(plan.confidence, 0.3) if unreadable else plan.confidence, 2)

    out = {"plan_id": f"plan_{uuid.uuid4().hex[:10]}", **plan.model_dump(exclude={"confidence", "warnings"}),
           "total_usd": total, "confidence": confidence, "needs_sign_photo": needs_photo,
           "warnings": plan.warnings, "sources": sources}
    db.put("plans", "plan_id", out["plan_id"], out, user_id=user_id)
    return out


def _method(sign: SignRead) -> str:
    allowed = PlanOut.model_fields["method"].annotation.__args__
    return sign.method if sign.method in allowed else "unknown"


def checkout(user: dict, plan_id: str, amount_usd: float) -> dict:
    """Fake payment. No real payment code anywhere."""
    row = db.query("SELECT user_id, data FROM plans WHERE plan_id=?", (plan_id,))
    if not row or row[0]["user_id"] != user["user_id"]:
        raise errors.not_found(f"Plan {plan_id} not found.")
    plan = json.loads(row[0]["data"])
    if amount_usd > float(user.get("spending_cap_usd") or 0):
        raise errors.validation("That amount is over your spending cap.")
    if plan.get("total_usd") is not None and abs(plan["total_usd"] - amount_usd) > 0.01:
        raise errors.validation("Amount does not match the plan total.")
    receipt = {"receipt_id": f"rcpt_{uuid.uuid4().hex[:10]}", "amount_usd": amount_usd, "paid_at": proofs.now_iso()}
    db.put("receipts", "receipt_id", receipt["receipt_id"], {**receipt, "plan_id": plan_id}, plan_id=plan_id)
    return receipt
