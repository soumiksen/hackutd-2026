"""Hard-coded Maverick Place flow: take frontend data, drive the Parkva page, record proof."""
import asyncio
import logging
import uuid
from datetime import datetime, timedelta, timezone

from .. import errors, safety, store
from ..config import settings
from ..vendors import parkva
from . import browser as browser_mod
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


def create(user: dict, veh: dict, unit: str | None, resident_last_name: str | None, guest: dict | None,
           dry_run: bool) -> dict:
    """Start a Maverick Place registration. The module checks consent, fills a missing unit or resident name
    from the last visit, and queues it for the worker."""
    first, last = split_name(user["name"])
    g = guest or {}
    guest_full = {"first_name": g.get("first_name") or first, "last_name": g.get("last_name") or last,
                  "email": g.get("email") or user["email"]}
    rid = f"reg_{uuid.uuid4().hex[:10]}"
    store.get_store().start_maverick(rid, user["user_id"], veh["vehicle_id"], unit, resident_last_name, guest_full, dry_run)
    from . import worker
    worker.wake()
    return drafts.load(rid)


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
        browser = await browser_mod.launch(pw)
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


async def run(rid: str):
    reg = drafts.load(rid)
    user = store.get_store().get_user(reg["_user_id"])
    veh = store.get_store().get_vehicle(reg["vehicle"]["vehicle_id"])
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
            store.get_store().reg_needs_user(rid, {"reason": nu.reason, "message": nu.message,
                                                   "field": nu.field, "portal_url": nu.portal_url})
            messaging.notify("needs_user", user, drafts.load(rid))
            return
        except Failure as e:
            last = str(e)
            log.info("maverick attempt %d failed: %s", n + 1, last[:100])
            if not e.retry:
                break
            await asyncio.sleep(1)
            continue
        if proof is None:  # dry run: form filled, nothing submitted
            store.get_store().reg_dry_run_done(
                rid, "Dry run: the Maverick Place form was filled in but NOT submitted.",
                {"confirmation_number": None, "expires_at": None,
                 "screenshot_urls": [proofs.url_for(rid, "fill_form.png")]})
            return
        drafts.set_step(rid, "capture_proof", "done")
        store.get_store().reg_confirmed(rid, {**proof, "screenshot_urls": [proofs.url_for(rid, "confirmation.png"),
                                                                           proofs.url_for(rid, "fill_form.png")]})
        messaging.notify("confirmed", user, drafts.load(rid))
        return
    _fail(rid, user, "portal_failed", last if last.startswith("Maverick Place refused") else
          f"Maverick Place did not accept the registration ({last}).")


def _fail(rid, user, code, message):
    store.get_store().reg_failed(rid, code, message)
    if user:
        messaging.notify("failed", user, drafts.load(rid))
