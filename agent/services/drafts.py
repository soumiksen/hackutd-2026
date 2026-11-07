"""Registration store, draft rules, summary template, and state transitions."""
import copy
import uuid
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from .. import db, errors
from ..models import DraftIn, PatchIn
from . import messaging, properties, proofs

TZ = ZoneInfo("America/Chicago")
COUNTED = ("submitting", "needs_user", "confirmed", "expired", "finished")


# ---------- storage ----------
def public(reg: dict) -> dict:
    return {k: v for k, v in reg.items() if not k.startswith("_")}


def save(reg: dict):
    db.put("registrations", "registration_id", reg["registration_id"], reg,
           user_id=reg["_user_id"], status=reg["status"], created_at=reg["created_at"])


def load(registration_id: str, user_id: str | None = None) -> dict:
    reg = db.get("registrations", "registration_id", registration_id)
    if not reg or (user_id and reg["_user_id"] != user_id):
        raise errors.not_found(f"Registration {registration_id} not found.")
    return reg


def update(registration_id: str, fn) -> dict:
    """Atomic read-modify-write."""
    with db.tx():
        reg = load(registration_id)
        fn(reg)
        save(reg)
        return reg


def set_step(registration_id: str, name: str, status: str):
    def f(reg):
        for s in reg["steps"]:
            if s["name"] == name:
                s["status"], s["at"] = status, proofs.now_iso()
                return
        reg["steps"].append({"name": name, "status": status, "at": proofs.now_iso()})
    return update(registration_id, f)


def list_for_user(user_id: str, statuses: tuple | None = None) -> list[dict]:
    rows = db.query("SELECT data FROM registrations WHERE user_id=? ORDER BY created_at DESC, rowid DESC", (user_id,))
    import json
    regs = [json.loads(r["data"]) for r in rows]
    return [r for r in regs if not statuses or r["status"] in statuses]


def user_by_phone(phone: str) -> dict | None:
    import json
    for r in db.query("SELECT data FROM users"):
        u = json.loads(r["data"])
        if u.get("phone") == phone:
            return u
    return None


def newest_for_message(user_id: str) -> dict | None:
    for r in list_for_user(user_id):
        if r["status"] in ("awaiting_confirm", "needs_user"):
            return r
    return None


def latest_pass(user_id: str) -> dict | None:
    regs = list_for_user(user_id, ("confirmed", "expired", "finished"))
    return regs[0] if regs else None


# ---------- rules and summary ----------
def _vehicle(user_id: str, vehicle_id: str) -> dict:
    v = db.get("vehicles", "vehicle_id", vehicle_id)
    if not v or v["_user_id"] != user_id:
        raise errors.not_found(f"Vehicle {vehicle_id} not found.")
    return v


def vehicle_public(v: dict) -> dict:
    return {k: v[k] for k in ("vehicle_id", "plate", "state", "make", "model", "color")}


def guest_nights_used(user_id: str, property_id: str, exclude: str | None = None) -> int:
    month = datetime.now(timezone.utc).strftime("%Y-%m")
    return sum(1 for r in list_for_user(user_id)
               if r["property"]["property_id"] == property_id and r["role"] == "visitor"
               and r["status"] in COUNTED and r["created_at"].startswith(month)
               and r["registration_id"] != exclude)


def check_rules(user_id: str, prop: dict, role: str, duration: int, exclude: str | None = None):
    rules = prop["guest_rules"]
    if not prop.get("vendor_id") or not prop.get("portal_path"):
        raise errors.validation(f"{prop['name']} has no guest registration portal. {prop.get('notes') or ''}".strip())
    if duration > rules["max_duration_hours"]:
        raise errors.validation(
            f"{prop['name']} allows at most {rules['max_duration_hours']} hours per guest registration.")
    if role == "visitor" and guest_nights_used(user_id, prop["property_id"], exclude) >= rules["max_nights_per_month"]:
        raise errors.validation(
            f"guest night limit reached: {prop['name']} allows {rules['max_nights_per_month']} guest nights per month.")


def build_summary(veh: dict, prop: dict, role: str, host: dict | None, duration: int) -> str:
    until = (datetime.now(timezone.utc) + timedelta(hours=duration)).astimezone(TZ)
    t = until.strftime("%-I:%M %p")
    day = "" if until.date() == datetime.now(TZ).date() else until.strftime(" on %a")
    car = f"{veh['model']} ({veh['state']} {veh['plate']})"
    if role == "resident":
        who = "as a resident"
    else:
        h = host or {}
        who = f"as {h['name']}'s guest" if h.get("name") else "as a guest"
        if h.get("unit"):
            who += f", unit {h['unit']}"
    return f"Register your {car} at {prop['name']} {who}, until {t}{day}?"


# ---------- operations ----------
def _fill(reg: dict, user: dict, veh: dict, prop: dict, role: str, host: dict | None, duration: int):
    check_rules(user["user_id"], prop, role, duration, reg["registration_id"])
    reg.update({
        "status": "awaiting_confirm",
        "property": {"property_id": prop["property_id"], "name": prop["name"]},
        "alternatives": properties.alternatives(prop),
        "vehicle": vehicle_public(veh),
        "role": role,
        "host": None if role == "resident" else (host or {"name": None, "unit": None}),
        "duration_hours": duration,
        "needs_user": None, "proof": None, "error": None,
        "summary": build_summary(veh, prop, role, None if role == "resident" else host, duration),
        "steps": [{"name": "match_property", "status": "done", "at": proofs.now_iso()}],
    })


def draft(user: dict, body: DraftIn) -> dict:
    veh = _vehicle(user["user_id"], body.vehicle_id)
    prop = properties.get_raw(body.property_id)
    reg = {"registration_id": f"reg_{uuid.uuid4().hex[:10]}", "_user_id": user["user_id"],
           "created_at": proofs.now_iso(), "_answers": {}, "_override": False, "_captcha_cleared": False}
    _fill(reg, user, veh, prop, body.role, body.host.model_dump() if body.host else None, body.duration_hours)
    save(reg)
    messaging.notify("check1_prompt", user, reg)
    return reg


def patch(user: dict, registration_id: str, body: PatchIn) -> dict:
    reg = load(registration_id, user["user_id"])
    if reg["status"] != "awaiting_confirm":
        raise errors.wrong_state("Only a registration awaiting confirmation can be edited.")
    changes = body.model_dump(exclude_unset=True)
    veh = _vehicle(user["user_id"], changes.get("vehicle_id") or reg["vehicle"]["vehicle_id"])
    prop = properties.get_raw(changes.get("property_id") or reg["property"]["property_id"])
    role = changes.get("role") or reg["role"]
    host = changes["host"] if "host" in changes else reg["host"]
    _fill(reg, user, veh, prop, role, host, changes.get("duration_hours") or reg["duration_hours"])
    save(reg)
    messaging.notify("check1_prompt", user, reg)
    return reg


def cancel(user: dict, registration_id: str) -> dict:
    reg = load(registration_id, user["user_id"])
    if reg["status"] not in ("awaiting_confirm", "needs_user", "drafted"):
        raise errors.wrong_state(f"Cannot cancel a registration that is {reg['status']}.")
    reg["status"], reg["needs_user"] = "cancelled", None
    save(reg)
    return reg


def confirm(user: dict, registration_id: str, channel: str) -> dict:
    """The only path that starts the runner (consent gate)."""
    from . import runner
    reg = load(registration_id, user["user_id"])
    if not user.get("consent_register"):
        raise errors.consent_required()
    if reg["status"] != "awaiting_confirm":
        raise errors.wrong_state(f"Registration is {reg['status']}, not awaiting_confirm.")
    reg["status"] = "submitting"
    reg["_confirmed_via"] = channel
    reg["_confirmed_at"] = proofs.now_iso()
    save(reg)
    runner.start(reg["registration_id"])
    return reg


def answer(user: dict, registration_id: str, field: str, value: str) -> dict:
    from . import runner
    reg = load(registration_id, user["user_id"])
    nu = reg.get("needs_user")
    if reg["status"] != "needs_user" or not nu:
        raise errors.wrong_state("This registration is not waiting for an answer.")
    if nu["reason"] == "rule_conflict":
        if field != "override":
            raise errors.validation("Answer the rule conflict with field 'override'.")
        if value.strip().lower() == "true":
            reg["_override"] = True
        else:
            reg["status"], reg["needs_user"] = "cancelled", None
            save(reg)
            return reg
    elif nu["reason"] == "missing_info":
        if field != nu.get("field"):
            raise errors.validation(f"Expected an answer for '{nu.get('field')}'.")
        if not value.strip():
            raise errors.validation("Answer cannot be empty.")
        reg["_answers"][field] = value.strip()
        if field in ("host_unit", "host_name") and reg.get("host") is not None:
            reg["host"]["unit" if field == "host_unit" else "name"] = value.strip()
    else:
        raise errors.wrong_state("This registration needs resume, not an answer.")
    reg["status"], reg["needs_user"] = "submitting", None
    save(reg)
    runner.start(reg["registration_id"])
    return reg


def resume(user: dict, registration_id: str) -> dict:
    from . import runner
    reg = load(registration_id, user["user_id"])
    if reg["status"] != "needs_user" or (reg.get("needs_user") or {}).get("reason") != "captcha":
        raise errors.wrong_state("This registration is not waiting on a CAPTCHA.")
    reg["_captcha_cleared"] = True
    reg["status"], reg["needs_user"] = "submitting", None
    save(reg)
    runner.start(reg["registration_id"])
    return reg


def renew(user: dict, registration_id: str, duration_hours: int) -> dict:
    prev = load(registration_id, user["user_id"])
    if prev["status"] not in ("confirmed", "expired", "finished"):
        raise errors.wrong_state("Only an active or past pass can be renewed.")
    return draft(user, DraftIn(vehicle_id=prev["vehicle"]["vehicle_id"], property_id=prev["property"]["property_id"],
                               role=prev["role"], host=prev["host"], duration_hours=duration_hours))
