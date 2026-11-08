"""All persistent state lives in SpacetimeDB (module in spacetimedb/): accounts, sessions, vehicles,
saved places, history and the registration state machine.

The API and the worker are clients of that database. Business rules (drafting, rule checks, the consent
gate, state transitions, saved places, history) run inside the module as reducers; this file only calls
them and turns the results into plain dicts. Only caches and logs stay in the local SQLite file (agent/db.py).
"""
import json
import re
from datetime import datetime, timezone

from . import errors
from .config import settings
from .stdb import Stdb, StdbError, ident, quote


class EmailTaken(Exception):
    pass


class HasAccount(Exception):
    pass


class StoreUnavailable(Exception):
    pass


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


USER_KEYS = ("user_id", "name", "phone", "email", "consent_register", "spending_cap_usd", "notify_channel")
VEH_KEYS = ("vehicle_id", "user_id", "plate", "state", "make", "model", "color", "year")
PLACE_KEYS = ("place_id", "property_id", "property_name", "unit", "host_name", "vehicle_id", "plate",
              "duration_hours", "label", "uses", "first_used_at", "last_used_at")
HIST_KEYS = ("registration_id", "property_id", "property_name", "plate", "unit", "status",
             "confirmation_number", "expires_at", "created_at", "updated_at")

# "code: message" thrown by a reducer -> contract error
RULE_ERRORS = {"validation_error": 422, "not_found": 404, "wrong_state": 409, "consent_required": 403, "rate_limited": 429}
_RULE_RE = re.compile(r"^\s*(" + "|".join(RULE_ERRORS) + r"): (.*)$", re.S)


def _veh_out(v: dict) -> dict:
    out = {k: v.get(k) for k in VEH_KEYS}
    if not out["year"]:
        out.pop("year")  # 0 means unknown; the contract omits it
    return out


def _json(s: str, default=None):
    return json.loads(s) if s else default


def reg_from_row(r: dict) -> dict:
    """Registration row -> the contract's Registration object plus private `_` fields for the API and worker."""
    return {
        "registration_id": r["registration_id"], "status": r["status"], "summary": r["summary"],
        "property": {"property_id": r["property_id"], "name": r["property_name"]},
        "alternatives": _json(r["alternatives_json"], []),
        "vehicle": {"vehicle_id": r["vehicle_id"], "plate": r["plate"], "state": r["state"], "make": r["make"],
                    "model": r["model"], "color": r["color"]},
        "role": r["role"],
        "host": None if r["role"] == "resident" else {"name": r["host_name"] or None, "unit": r["host_unit"] or None},
        "duration_hours": r["duration_hours"], "steps": _json(r["steps_json"], []),
        "needs_user": _json(r["needs_user_json"]), "proof": _json(r["proof_json"]), "error": _json(r["error_json"]),
        "created_at": r["created_at"],
        "_user_id": r["user_id"], "_flow": r["flow"], "_answers": _json(r["answers_json"], {}),
        "_guest": _json(r["guest_json"], {}), "_override": r["override"], "_captcha_cleared": r["captcha_cleared"],
        "_dry_run": r["dry_run"], "_reminded": r["reminded"], "_run_state": r["run_state"],
    }


class Store:
    kind = "spacetimedb"

    def __init__(self, client: Stdb):
        self.c = client

    # ---------- plumbing ----------
    def _call(self, reducer, args):
        try:
            self.c.call(reducer, args)
        except StdbError as e:
            msg = e.body
            if "email_taken" in msg:
                raise EmailTaken()
            if "user_has_account" in msg:
                raise HasAccount()
            if (m := _RULE_RE.match(msg)):
                raise errors.ApiError(RULE_ERRORS[m.group(1)], m.group(1), m.group(2).strip())
            if e.status >= 500 or e.status in (401, 403):
                raise StoreUnavailable(str(e))
            raise
        except StoreUnavailable:
            raise
        except errors.ApiError:
            raise
        except Exception as e:  # network
            raise StoreUnavailable(type(e).__name__) from e

    def _sql(self, q):
        try:
            return self.c.sql(q)
        except StdbError as e:
            raise StoreUnavailable(str(e)) from e
        except Exception as e:
            raise StoreUnavailable(type(e).__name__) from e

    # ---------- users ----------
    def get_user(self, user_id):
        rows = self._sql(f"SELECT * FROM profile WHERE user_id = {ident(user_id)}")
        return {k: rows[0][k] for k in USER_KEYS} if rows else None

    def put_user(self, u):
        self._call("upsert_profile", [u["user_id"], u["name"], u["phone"], u["email"], bool(u["consent_register"]),
                                      float(u["spending_cap_usd"]), u["notify_channel"], now_iso()])

    def user_by_phone(self, phone):
        rows = self._sql(f"SELECT * FROM profile WHERE phone = {quote(phone)}")
        return {k: rows[0][k] for k in USER_KEYS} if rows else None

    def delete_user(self, user_id):
        self._call("delete_user", [user_id])

    # ---------- credentials and sessions ----------
    def create_credential(self, user_id, email, password_hash):
        self._call("create_credential", [user_id, email, password_hash, now_iso()])

    def get_credential(self, user_id=None, email=None):
        rows = self._sql("SELECT * FROM credential WHERE " +
                         (f"user_id = {ident(user_id)}" if user_id else f"email = {quote(email)}"))
        return rows[0] if rows else None

    def set_password(self, user_id, password_hash):
        self._call("set_password", [user_id, password_hash])

    def create_session(self, token_hash, user_id, expires_at):
        self._call("create_session", [token_hash, user_id, now_iso(), expires_at])

    def get_session(self, token_hash):
        rows = self._sql(f"SELECT * FROM session WHERE token_hash = {ident(token_hash)}")
        return {"user_id": rows[0]["user_id"], "expires_at": rows[0]["expires_at"]} if rows else None

    def delete_session(self, token_hash):
        self._call("delete_session", [token_hash])

    def delete_other_sessions(self, user_id, keep_hash):
        self._call("delete_user_sessions", [user_id, keep_hash])

    def purge_expired_sessions(self):
        self._call("purge_expired_sessions", [now_iso()])

    # ---------- vehicles ----------
    def put_vehicle(self, user_id, v):
        self._call("upsert_vehicle", [v["vehicle_id"], user_id, v["plate"], v["state"], v["make"], v["model"],
                                      v["color"], int(v.get("year") or 0), now_iso()])

    def get_vehicle(self, vehicle_id):
        rows = self._sql(f"SELECT * FROM vehicle WHERE vehicle_id = {ident(vehicle_id)}")
        return _veh_out(rows[0]) if rows else None

    def list_vehicles(self, user_id):
        rows = sorted(self._sql(f"SELECT * FROM vehicle WHERE user_id = {ident(user_id)}"), key=lambda r: r["created_at"])
        return [_veh_out(r) for r in rows]

    def delete_vehicle(self, user_id, vehicle_id):
        self._call("delete_vehicle", [user_id, vehicle_id])

    # ---------- saved places and history (written by the module when a registration changes) ----------
    def list_places(self, user_id, property_id=None):
        q = f"SELECT * FROM saved_place WHERE user_id = {ident(user_id)}"
        if property_id:
            q += f" AND property_id = {ident(property_id)}"
        return sorted(({k: r[k] for k in PLACE_KEYS} for r in self._sql(q)), key=lambda p: p["last_used_at"], reverse=True)

    def label_place(self, user_id, place_id, label) -> bool:
        try:
            self.c.call("label_place", [user_id, place_id, label])
            return True
        except StdbError as e:
            if "not_found" in e.body:
                return False
            raise StoreUnavailable(str(e)) from e

    def forget_place(self, user_id, place_id):
        self._call("forget_place", [user_id, place_id])

    def list_history(self, user_id, limit=50):
        rows = sorted(self._sql(f"SELECT * FROM parking_history WHERE user_id = {ident(user_id)}"),
                      key=lambda r: r["created_at"], reverse=True)
        return [{k: r[k] for k in HIST_KEYS} for r in rows[:limit]]

    # ---------- properties (rule fields; the module checks them when drafting) ----------
    def load_properties(self, properties: list[dict]):
        self._call("load_properties", [json.dumps(properties)])

    # ---------- registrations ----------
    def get_registration(self, registration_id, user_id=None):
        rows = self._sql(f"SELECT * FROM registration WHERE registration_id = {ident(registration_id)}")
        if not rows or (user_id and rows[0]["user_id"] != user_id):
            return None
        return reg_from_row(rows[0])

    def list_registrations(self, user_id, statuses=None):
        rows = sorted(self._sql(f"SELECT * FROM registration WHERE user_id = {ident(user_id)}"),
                      key=lambda r: r["created_at_ms"], reverse=True)
        regs = [reg_from_row(r) for r in rows]
        return [r for r in regs if not statuses or r["status"] in statuses]

    def registrations_with_status(self, status):
        return [reg_from_row(r) for r in self._sql(f"SELECT * FROM registration WHERE status = {quote(status)}")]

    def draft(self, registration_id, user_id, vehicle_id, property_id, role, host, duration_hours):
        h = host or {}
        self._call("draft_registration", [registration_id, user_id, vehicle_id, property_id, role,
                                          h.get("name") or "", h.get("unit") or "", int(duration_hours)])

    def patch(self, user_id, registration_id, changes: dict):
        host_set = "host" in changes
        h = changes.get("host") or {}
        self._call("patch_registration", [user_id, registration_id, changes.get("vehicle_id") or "",
                                          changes.get("property_id") or "", changes.get("role") or "", host_set,
                                          h.get("name") or "", h.get("unit") or "", int(changes.get("duration_hours") or 0)])

    def cancel(self, user_id, registration_id):
        self._call("cancel_registration", [user_id, registration_id])

    def confirm(self, user_id, registration_id, channel):
        self._call("confirm_registration", [user_id, registration_id, channel])

    def answer(self, user_id, registration_id, field, value):
        self._call("answer_registration", [user_id, registration_id, field, value])

    def resume(self, user_id, registration_id):
        self._call("resume_registration", [user_id, registration_id])

    def renew(self, user_id, registration_id, new_registration_id, duration_hours):
        self._call("renew_registration", [user_id, registration_id, new_registration_id, int(duration_hours)])

    def start_maverick(self, registration_id, user_id, vehicle_id, unit, resident_last_name, guest, dry_run):
        self._call("start_maverick", [registration_id, user_id, vehicle_id, unit or "", resident_last_name or "",
                                      json.dumps(guest or {}), bool(dry_run)])

    # ---------- the resident's reply (Maverick Place) ----------
    def resident_reply(self, registration_id, unit, last_name):
        self._call("resident_reply", [registration_id, unit, last_name])

    def resident_decline(self, registration_id, code, message):
        self._call("resident_decline", [registration_id, code, message])

    # ---------- worker ----------
    def claim(self, registration_id) -> bool:
        try:
            self.c.call("claim_registration", [registration_id])
            return True
        except StdbError as e:
            if "not_claimable" in e.body:
                return False
            raise StoreUnavailable(str(e)) from e

    def release_stuck(self):
        self._call("release_stuck", [])

    def reg_step(self, registration_id, name, status):
        self._call("reg_step", [registration_id, name, status])

    def reg_needs_user(self, registration_id, needs_user: dict):
        self._call("reg_needs_user", [registration_id, json.dumps(needs_user)])

    def reg_confirmed(self, registration_id, proof: dict):
        self._call("reg_confirmed", [registration_id, json.dumps(proof)])

    def reg_failed(self, registration_id, code, message):
        self._call("reg_failed", [registration_id, code, message])

    def reg_dry_run_done(self, registration_id, summary, proof: dict):
        self._call("reg_dry_run_done", [registration_id, summary, json.dumps(proof)])

    def reg_expire(self, registration_id):
        self._call("reg_expire", [registration_id])

    def reg_mark_reminded(self, registration_id):
        self._call("reg_mark_reminded", [registration_id])

    # ---------- test support (module refuses unless enable_dev_mode was called) ----------
    def dev_wipe(self):
        # Never on a real database: only databases named *-test, and the module re-checks its own dev-mode flag.
        if not self.c.database.endswith("-test"):
            raise RuntimeError(f"refusing to wipe database {self.c.database!r}: its name does not end in -test")
        self._call("enable_dev_mode", [])
        self._call("dev_wipe", [])


_store = None
_store_key = None


def get_store() -> Store:
    """Re-evaluated when the settings change (tests point it at a throwaway database)."""
    global _store, _store_key
    key = (settings.spacetimedb_uri, settings.spacetimedb_database, settings.spacetimedb_token)
    if _store is None or key != _store_key:
        if not settings.spacetimedb_uri:
            raise StoreUnavailable("SPACETIMEDB_URI is not set")
        _store_key = key
        _store = Store(Stdb(settings.spacetimedb_uri, settings.spacetimedb_database, settings.spacetimedb_token))
    return _store


def set_store(s):
    global _store, _store_key
    _store = s
    _store_key = (settings.spacetimedb_uri, settings.spacetimedb_database, settings.spacetimedb_token)
