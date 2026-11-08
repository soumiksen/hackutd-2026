"""Hard-coded Maverick Place flow: take frontend data, drive the Parkva page, record proof."""
import asyncio
import logging
import uuid
from datetime import datetime, timedelta, timezone

from .. import db, errors, safety
from ..config import settings
from ..vendors import parkva
from . import drafts, messaging, proofs

log = logging.getLogger("parkour.maverick")

MAVERICK_URL = "https://app.parkva.com/p/maverick-place-Lu8K28/visit"
PROPERTY = {"property_id": "maverick-place", "name": "Maverick Place"}
# This flow alone may reach this host; the shared data/allowed_domains.json is owned by the data engineer.
EXTRA_ALLOWED = {"app.parkva.com"}
MAX_ATTEMPTS = 2


def split_name(full: str) -> tuple[str, str]:
    parts = full.strip().split()
    return (parts[0], " ".join(parts[1:]) or parts[0]) if parts else ("", "")


def create(user: dict, veh: dict, unit: str, resident_last_name: str, guest: dict | None, dry_run: bool) -> dict:
    """Make the registration record (status submitting) and start the run. Caller has checked consent."""
    first, last = split_name(user["name"])
    g = guest or {}
    reg = {
        "registration_id": f"reg_{uuid.uuid4().hex[:10]}", "_user_id": user["user_id"],
        "created_at": proofs.now_iso(), "_flow": "maverick", "_dry_run": dry_run, "_answers": {},
        "status": "submitting", "property": dict(PROPERTY), "alternatives": [],
        "vehicle": drafts.vehicle_public(veh), "role": "visitor",
        "host": {"name": resident_last_name.strip(), "unit": unit.strip()}, "duration_hours": 24,
        "summary": f"Register your {veh['model']} ({veh['state']} {veh['plate']}) at Maverick Place "
                   f"as a guest of unit {unit.strip()}, Day Pass?",
        "steps": [{"name": "match_property", "status": "done", "at": proofs.now_iso()}],
        "needs_user": None, "proof": None, "error": None,
        "_guest": {"first_name": g.get("first_name") or first, "last_name": g.get("last_name") or last,
                   "email": g.get("email") or user["email"]},
    }
    drafts.save(reg)
    from . import runner
    runner.start(reg["registration_id"])
    return reg


def values(reg: dict, veh: dict) -> dict:
    a, g = reg.get("_answers") or {}, reg["_guest"]
    return {"plate": veh["plate"], "unit": a.get("host_unit") or reg["host"]["unit"],
            "resident_last_name": a.get("host_name") or reg["host"]["name"],
            "first_name": g["first_name"], "last_name": g["last_name"], "email": g["email"]}


class NeedsUser(Exception):
    def __init__(self, reason, message, field=None, portal_url=None):
        self.reason, self.message, self.field, self.portal_url = reason, message, field, portal_url


class Failure(Exception):
    def __init__(self, msg, retry=True):
        super().__init__(msg)
        self.retry = retry


async def attempt(reg: dict, veh: dict, v: dict) -> dict | None:
    from playwright.async_api import async_playwright
    rid = reg["registration_id"]
    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=True)
        try:
            ctx = await browser.new_context(viewport={"width": 420, "height": 900})
            page = await ctx.new_page()
            try:
                drafts.set_step(rid, "open_portal", "running")
                await page.goto(MAVERICK_URL, wait_until="networkidle", timeout=30000)
                await page.locator(parkva.PLATE).wait_for(state="visible", timeout=15000)
                drafts.set_step(rid, "open_portal", "done")
                if await page.locator(parkva.CHALLENGE_SEL).count():
                    raise NeedsUser("captcha", "Maverick Place wants a human check. Register on the page, or tap Continue to retry.",
                                    portal_url=MAVERICK_URL)

                drafts.set_step(rid, "fill_form", "running")
                try:
                    expires = await parkva.fill(page, v, rid)
                except parkva.UnitNotFound:
                    raise NeedsUser("missing_info", f"Unit {v['unit']} was not found at Maverick Place. What is the unit number?",
                                    field="host_unit")
                drafts.set_step(rid, "fill_form", "done")
                if reg.get("_dry_run"):
                    return None  # stop before submit

                drafts.set_step(rid, "submit", "running")
                await page.locator(parkva.SUBMIT).first.click()
                kind, text = await parkva.outcome(page)
                if kind == "challenge":
                    raise NeedsUser("captcha", "Maverick Place wants a human check. Register on the page, or tap Continue to retry.",
                                    portal_url=MAVERICK_URL)
                if kind == "error":
                    drafts.set_step(rid, "submit", "error")
                    text = " ".join(text.split("\n")[0].split())[:160]  # first line only; the rest is link text
                    low = text.lower()
                    if any(w in low for w in ("can't park", "cannot park", "reserved", "not allowed")):
                        # a real rule (for example the plate belongs to a resident): retrying cannot help
                        raise Failure(f"Maverick Place refused it: {text}", retry=False)
                    if any(w in low for w in ("last name", "does not match", "doesn't match", "verify", "not found")):
                        raise NeedsUser("missing_info", f"Maverick Place could not verify the resident: {text}",
                                        field="host_name")
                    raise Failure(f"Portal error: {text}", retry=False)
                if kind == "none":
                    raise Failure("The page did not show a result.", retry=False)
                drafts.set_step(rid, "submit", "done")
                drafts.set_step(rid, "capture_proof", "running")
                await proofs.screenshot(page, rid, "confirmation.png")
                if kind == "already":  # the site already holds this registration: report its expiry
                    expires = parkva.parse_until(text) or expires
                return {"confirmation_number": parkva.extract_confirmation(text),
                        "expires_at": expires or (datetime.now(timezone.utc) + timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%SZ")}
            except (NeedsUser, Failure):
                try:
                    await proofs.screenshot(page, rid, "last_state.png")
                except Exception:
                    pass
                raise
            except Exception as e:
                try:
                    await proofs.screenshot(page, rid, "last_state.png")
                except Exception:
                    pass
                raise Failure(type(e).__name__) from e
        finally:
            await browser.close()


def _set(rid, **ch):
    return drafts.update(rid, lambda r: r.update(ch))


async def run(rid: str):
    reg = drafts.load(rid)
    user = db.get("users", "user_id", reg["_user_id"])
    veh = db.get("vehicles", "vehicle_id", reg["vehicle"]["vehicle_id"])
    try:
        safety.check_url(MAVERICK_URL, extra_hosts=EXTRA_ALLOWED)
    except errors.ApiError as e:
        return _fail(rid, user, "unknown_domain", e.message)
    last = "unknown"
    for n in range(MAX_ATTEMPTS):
        reg = drafts.load(rid)
        try:
            proof = await attempt(reg, veh, values(reg, veh))
        except NeedsUser as nu:
            r = _set(rid, status="needs_user", needs_user={"reason": nu.reason, "message": nu.message,
                                                           "field": nu.field, "portal_url": nu.portal_url})
            messaging.notify("needs_user", user, r)
            return
        except Failure as e:
            last = str(e)
            log.info("maverick attempt %d failed: %s", n + 1, last[:100])
            if not e.retry:
                break
            await asyncio.sleep(1)
            continue
        if proof is None:  # dry run: form filled, nothing submitted
            _set(rid, status="cancelled", needs_user=None,
                 summary="Dry run: the Maverick Place form was filled in but NOT submitted.",
                 proof={"confirmation_number": None, "expires_at": None,
                        "screenshot_urls": [proofs.url_for(rid, "fill_form.png")]})
            return
        _set(rid, status="confirmed", needs_user=None, error=None,
             proof={**proof, "screenshot_urls": [proofs.url_for(rid, "confirmation.png"),
                                                 proofs.url_for(rid, "fill_form.png")]})
        drafts.set_step(rid, "capture_proof", "done")
        messaging.notify("confirmed", user, drafts.load(rid))
        return
    _fail(rid, user, "portal_failed", last if last.startswith("Maverick Place refused") else
          f"Maverick Place did not accept the registration ({last}).")


def _fail(rid, user, code, message):
    r = _set(rid, status="failed", error={"code": code, "message": message}, needs_user=None)
    if user:
        messaging.notify("failed", user, r)
