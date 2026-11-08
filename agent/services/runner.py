"""Playwright runner: opens the mock portal, fills, submits, captures proof, handles Check 2."""
import asyncio
import logging
import re
from datetime import datetime, timezone
from urllib.parse import parse_qsl, urlencode

from .. import db, errors, safety
from ..config import settings
from ..models import ConfirmationExtract
from ..vendors import mockpark
from . import data, drafts, fallback, llm, messaging, properties, proofs

log = logging.getLogger("parkour.runner")

CAPTCHA = '[data-testid="captcha"]'
ERROR = '[data-testid="error"]'
CONF = '[data-testid="confirmation-number"]'
EXPIRES = '[data-testid="expires-at"]'
OUTCOME = f"{CONF}, {CAPTCHA}, {ERROR}"
REQUIRED = ["plate", "state", "make", "model", "color", "guest_name", "phone", "duration_hours"]
MAX_ATTEMPTS = 3  # first try plus 2 retries
_sem = asyncio.Semaphore(2)
_running: set[asyncio.Task] = set()


class NeedsUser(Exception):
    def __init__(self, reason: str, message: str, field: str | None = None, portal_url: str | None = None):
        self.reason, self.message, self.field, self.portal_url = reason, message, field, portal_url


class PortalFailure(Exception):
    pass


def start(registration_id: str) -> asyncio.Task:
    t = asyncio.create_task(run(registration_id))
    _running.add(t)
    t.add_done_callback(_running.discard)
    return t


# ---------- values and URL ----------
def canonical_values(reg: dict, user: dict, veh: dict) -> dict[str, str]:
    host = reg.get("host") or {}
    v = {
        "plate": veh["plate"], "state": veh["state"], "make": veh["make"], "model": veh["model"],
        "color": veh["color"], "host_unit": host.get("unit") or "", "host_name": host.get("name") or "",
        "guest_name": user["name"], "phone": user["phone"], "email": user.get("email") or "",
        "duration_hours": str(reg["duration_hours"]),
    }
    v.update(reg.get("_answers") or {})
    return {k: str(x) for k, x in v.items() if x not in (None, "")}


def portal_url(prop: dict, values: dict, captcha_cleared: bool) -> str:
    params = {"property": prop["property_code"], **values}
    extra = dict(parse_qsl(settings.demo_portal_params))
    if captcha_cleared:
        extra.pop("captcha", None)  # the user completed the challenge themselves
    params.update(extra)
    return settings.mock_portal_url + prop["portal_path"] + "?" + urlencode(params)


def missing_field(reg: dict, prop: dict, values: dict) -> str | None:
    need = list(REQUIRED)
    if reg["role"] == "visitor" and prop["guest_rules"].get("requires_host_unit"):
        need.insert(5, "host_unit")
    return next((f for f in need if not values.get(f)), None)


# ---------- page helpers ----------
async def settle(page, timeout_ms: int = 10000) -> str:
    """Wait for a result element. Returns confirmation, captcha, error or none."""
    try:
        await page.wait_for_selector(OUTCOME, state="visible", timeout=timeout_ms)
    except Exception:
        return "none"
    for kind, sel in (("confirmation", CONF), ("captcha", CAPTCHA), ("error", ERROR)):
        if await page.locator(sel).first.is_visible():
            return kind
    return "none"


def normalize_iso(s: str) -> str:
    dt = datetime.fromisoformat(s.strip().replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


async def extract_proof(page) -> dict:
    num = exp = None
    try:
        text = (await page.locator(CONF).first.text_content(timeout=3000)) or ""
        m = re.search(r"PK-[A-Z0-9]{6}", text)
        num = m.group(0) if m else None
        exp = normalize_iso((await page.locator(EXPIRES).first.text_content(timeout=3000)) or "")
    except Exception:
        pass
    if not (num and exp):  # Nemotron backup on the page text
        body = (await page.inner_text("body"))[:3000]
        out = await llm.chat_json(
            "confirmation_extract",
            'Extract the parking confirmation. Return {"confirmation_number","expires_at"} (ISO 8601 UTC).',
            body, ConfirmationExtract)
        num, exp = out.confirmation_number, normalize_iso(out.expires_at)
    return {"confirmation_number": num, "expires_at": exp}


async def handle_outcome(page, kind: str, reg: dict, url: str) -> None:
    """Raise NeedsUser / PortalFailure for blockers. Returns on confirmation."""
    if kind == "confirmation":
        return
    if kind == "captcha":
        raise NeedsUser("captcha", "The portal needs a human check (CAPTCHA). Complete it, then tap Continue.",
                        portal_url=url)
    if kind == "error":
        text = ((await page.locator(ERROR).first.text_content()) or "").strip()
        if "guest night limit" in text.lower() and not reg.get("_override"):
            raise NeedsUser("rule_conflict",
                            "The portal says the guest night limit was reached. Register anyway?", field="override")
        raise PortalFailure(f"Portal error: {text[:120]}")
    raise PortalFailure("The portal did not show a confirmation.")


# ---------- one attempt ----------
async def attempt(reg: dict, user: dict, veh: dict, prop: dict, vendor: dict, values: dict, url: str) -> dict:
    from playwright.async_api import async_playwright
    rid = reg["registration_id"]
    state_file = settings.proofs_dir / ".portal_state.json"  # keeps the portal's per-plate counter between runs
    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=True)
        try:
            ctx = await browser.new_context(
                storage_state=str(state_file) if state_file.exists() else None, viewport={"width": 420, "height": 900})
            page = await ctx.new_page()
            try:
                drafts.set_step(rid, "open_portal", "running")
                await page.goto(url, wait_until="domcontentloaded", timeout=15000)
                drafts.set_step(rid, "open_portal", "done")
                if await page.locator(CAPTCHA).count():
                    await handle_outcome(page, "captcha", reg, url)

                drafts.set_step(rid, "fill_form", "running")
                if vendor["vendor_id"] == "mockpark":
                    submit = await mockpark.fill_and_submit(page, vendor["selectors"], values, rid)
                    drafts.set_step(rid, "fill_form", "done")
                    drafts.set_step(rid, "submit", "running")
                    await page.locator(submit).first.click()
                    kind = await settle(page)
                else:
                    kind = await _guestpass(page, values, rid)
                    drafts.set_step(rid, "fill_form", "done")
                    drafts.set_step(rid, "submit", "running")
                drafts.set_step(rid, "submit", "done" if kind == "confirmation" else "error")
                await handle_outcome(page, kind, reg, url)

                drafts.set_step(rid, "capture_proof", "running")
                await proofs.screenshot(page, rid, "confirmation.png")
                proof = await extract_proof(page)
                await ctx.storage_state(path=str(state_file))
                return proof
            except (NeedsUser, PortalFailure):
                await _failure_shot(page, rid)
                raise
            except errors.ApiError:
                await _failure_shot(page, rid)
                raise
            except Exception as e:
                await _failure_shot(page, rid)
                raise PortalFailure(f"{type(e).__name__}") from e
        finally:
            await browser.close()


async def _failure_shot(page, rid):
    try:
        await proofs.screenshot(page, rid, "last_state.png")
    except Exception:
        pass


async def _guestpass(page, values: dict, rid: str) -> str:
    log.warning("guestpass: no script, using Nemotron fallback (script needs repair)")
    for step in range(5):
        if await page.locator(CAPTCHA).count():
            return "captcha"
        snap = await fallback.snapshot(page)
        plan = await fallback.plan_step(snap, values)
        if not plan.fills and not plan.click:
            raise PortalFailure("Could not understand the form.")
        await fallback.apply_plan(page, plan, snap)
        await proofs.screenshot(page, rid, "fill_form.png" if step == 0 else f"fill_form_{step + 1}.png")
        if not plan.click:
            raise PortalFailure("No way forward on the form.")
        await page.locator(plan.click).first.click()
        kind = await settle(page, 4000)
        if kind != "none":
            return kind
        await page.wait_for_timeout(300)
    raise PortalFailure("The form did not finish.")


# ---------- orchestration ----------
def _set(reg_id, **changes):
    return drafts.update(reg_id, lambda r: r.update(changes))


async def run(registration_id: str):
    async with _sem:
        try:
            if drafts.load(registration_id).get("_flow") == "maverick":
                from . import maverick  # hard-coded Maverick Place flow
                return await maverick.run(registration_id)
            await _run(registration_id)
        except Exception as e:  # never leave a registration stuck in submitting
            log.exception("runner crashed")
            await _fail(registration_id, "portal_failed", f"Unexpected error: {type(e).__name__}")


async def _fail(rid: str, code: str, message: str):
    reg = _set(rid, status="failed", error={"code": code, "message": message}, needs_user=None)
    user = db.get("users", "user_id", reg["_user_id"])
    if user:
        messaging.notify("failed", user, reg)


async def _run(rid: str):
    reg = drafts.load(rid)
    user = db.get("users", "user_id", reg["_user_id"])
    veh = db.get("vehicles", "vehicle_id", reg["vehicle"]["vehicle_id"])
    prop = properties.get_raw(reg["property"]["property_id"])
    vendor = data.vendors()[prop["vendor_id"]]
    values = canonical_values(reg, user, veh)
    url = portal_url(prop, values, reg.get("_captcha_cleared", False))

    try:
        safety.check_url(url)
    except errors.ApiError as e:
        return await _fail(rid, "unknown_domain", e.message)

    if (field := missing_field(reg, prop, values)):
        return _needs_user(rid, user, NeedsUser(
            "missing_info", f"I need your {field.replace('_', ' ')} to continue.", field=field))

    last = "unknown"
    for n in range(MAX_ATTEMPTS):
        try:
            proof = await attempt(drafts.load(rid), user, veh, prop, vendor, values, url)
            done = _set(rid, status="confirmed", needs_user=None, error=None, proof={
                **proof, "screenshot_urls": [proofs.url_for(rid, "confirmation.png"),
                                             proofs.url_for(rid, "fill_form.png")]})
            drafts.set_step(rid, "capture_proof", "done")
            messaging.notify("confirmed", user, drafts.load(rid))
            return done
        except NeedsUser as nu:
            return _needs_user(rid, user, nu)
        except errors.ApiError as e:
            last = e.message
            if e.code == "llm_unavailable":
                break
        except PortalFailure as e:
            last = str(e)
        log.info("attempt %d failed: %s", n + 1, last[:120])
        await asyncio.sleep(0.5)
    await _fail(rid, "portal_failed", f"The portal did not accept the registration ({last}).")


def _needs_user(rid: str, user: dict, nu: NeedsUser):
    reg = _set(rid, status="needs_user", needs_user={
        "reason": nu.reason, "message": nu.message, "field": nu.field, "portal_url": nu.portal_url})
    messaging.notify("needs_user", user, reg)
    return reg
