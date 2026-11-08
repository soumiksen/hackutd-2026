"""Registration operations. The rules and the state machine live in the SpacetimeDB module (reducers in
spacetimedb/src/index.ts); this layer calls them, reads the result back, and sends the Check 1 message."""
import uuid

from .. import errors, store
from ..models import DraftIn, PatchIn
from . import messaging


def public(reg: dict) -> dict:
    return {k: v for k, v in reg.items() if not k.startswith("_")}


def vehicle_public(v: dict) -> dict:
    return {k: v[k] for k in ("vehicle_id", "plate", "state", "make", "model", "color")}


def load(registration_id: str, user_id: str | None = None) -> dict:
    reg = store.get_store().get_registration(registration_id, user_id)
    if not reg:
        raise errors.not_found(f"Registration {registration_id} not found.")
    return reg


def list_for_user(user_id: str, statuses: tuple | None = None) -> list[dict]:
    return store.get_store().list_registrations(user_id, statuses)


def user_by_phone(phone: str) -> dict | None:
    return store.get_store().user_by_phone(phone)


def newest_for_message(user_id: str) -> dict | None:
    return next((r for r in list_for_user(user_id) if r["status"] in ("awaiting_confirm", "needs_user")), None)


def pending_resident(phone: str) -> dict | None:
    """The newest registration waiting for this phone number (a resident we texted), or None."""
    waiting = [r for r in store.get_store().registrations_with_status("needs_user")
               if (r.get("needs_user") or {}).get("reason") == "resident_info"
               and (r.get("_answers") or {}).get("resident_phone") == phone]
    return max(waiting, key=lambda r: r["_answers"].get("resident_requested_at", ""), default=None)


def latest_pass(user_id: str) -> dict | None:
    regs = list_for_user(user_id, ("confirmed", "expired", "finished"))
    return regs[0] if regs else None


def set_step(registration_id: str, name: str, status: str):
    store.get_store().reg_step(registration_id, name, status)


def _new_id() -> str:
    return f"reg_{uuid.uuid4().hex[:10]}"


def draft(user: dict, body: DraftIn) -> dict:
    rid = _new_id()
    store.get_store().draft(rid, user["user_id"], body.vehicle_id, body.property_id, body.role,
                            body.host.model_dump() if body.host else None, body.duration_hours)
    reg = load(rid)
    messaging.notify("check1_prompt", user, reg)
    return reg


def patch(user: dict, registration_id: str, body: PatchIn) -> dict:
    store.get_store().patch(user["user_id"], registration_id, body.model_dump(exclude_unset=True))
    reg = load(registration_id)
    messaging.notify("check1_prompt", user, reg)
    return reg


def cancel(user: dict, registration_id: str) -> dict:
    store.get_store().cancel(user["user_id"], registration_id)
    return load(registration_id)


def confirm(user: dict, registration_id: str, channel: str) -> dict:
    """The only way a registration reaches the worker; the module checks consent and state."""
    store.get_store().confirm(user["user_id"], registration_id, channel)
    from . import worker
    worker.wake()
    return load(registration_id)


def answer(user: dict, registration_id: str, field: str, value: str) -> dict:
    store.get_store().answer(user["user_id"], registration_id, field, value)
    reg = load(registration_id)
    if field == "resident_phone" and (reg.get("needs_user") or {}).get("reason") == "resident_info":
        messaging.ask_resident(user, reg)  # text the resident; the worker waits for their reply
    from . import worker
    worker.wake()
    return reg


def resume(user: dict, registration_id: str) -> dict:
    store.get_store().resume(user["user_id"], registration_id)
    from . import worker
    worker.wake()
    return load(registration_id)


def renew(user: dict, registration_id: str, duration_hours: int) -> dict:
    rid = _new_id()
    store.get_store().renew(user["user_id"], registration_id, rid, duration_hours)
    reg = load(rid)
    messaging.notify("check1_prompt", user, reg)
    return reg
