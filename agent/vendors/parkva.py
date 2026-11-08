"""Hard-coded form driver for Maverick Place guest parking (a Parkva-hosted page).

Selectors were read from the live page. The page is one form: plate (no state), a unit search box with a
suggestion dropdown, the resident's last name, a fixed "Day Pass" duration, then first/last name and email.
"""
import re
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

from ..services import proofs

TZ = ZoneInfo("America/Chicago")
PLATE = "#plate"
UNIT = 'input[placeholder="Search your unit number"]'
RESIDENT_LAST = 'input[placeholder="Resident\'s last name"]'
FIRST, LAST, EMAIL = "#firstName", "#lastName", "#email"
SUBMIT = 'button[type="submit"]'
DURATION_CARD = 'button:has-text("Until")'
ERROR_SEL = '[role="alert"], [data-sonner-toast], .text-destructive, .text-red-600, .text-red-500'
CHALLENGE_SEL = ('iframe[src*="recaptcha" i]:visible, iframe[src*="hcaptcha" i]:visible, '
                 'iframe[src*="turnstile" i]:visible, iframe[src*="challenge" i]:visible, '
                 '[data-testid="captcha"]')


class UnitNotFound(Exception):
    pass


def norm_unit(u: str) -> str:
    """'Unit 227-A', '227a' and '227 A' all become '227A' so they compare equal."""
    return re.sub(r"[^A-Z0-9]", "", re.sub(r"^unit\s+", "", u.strip(), flags=re.I).upper())


async def pick_unit(page, unit: str):
    """Type the unit and click the matching suggestion (the page requires choosing from the list)."""
    want = norm_unit(unit)
    box = page.locator(UNIT).first
    await box.click()
    await box.fill("")
    await box.type(re.match(r"\d*", want).group(0) or want, delay=60)  # search by the digits, then match exactly
    await page.wait_for_timeout(1200)
    options = page.get_by_text(re.compile(r"^\s*Unit\s+", re.I))
    for i in range(min(await options.count(), 25)):
        o = options.nth(i)
        if norm_unit((await o.inner_text()).strip()) == want:
            await o.click()
            return
    raise UnitNotFound(unit)


def parse_until(text: str) -> str | None:
    """'Until Sun, Nov 8, 8:35 PM' -> ISO UTC (Central time, year inferred)."""
    m = re.search(r"Until\s+(?:\w{3},\s+)?(\w{3,9}\s+\d{1,2}),\s+(\d{1,2}:\d{2}\s*[AP]M)", text or "", re.I)
    if not m:
        return None
    now = datetime.now(TZ)
    for fmt in ("%b %d %Y %I:%M %p", "%B %d %Y %I:%M %p"):
        try:
            dt = datetime.strptime(f"{m.group(1)} {now.year} {m.group(2).upper().replace('  ', ' ')}", fmt).replace(tzinfo=TZ)
        except ValueError:
            continue
        if dt < now - _days(180):
            dt = dt.replace(year=now.year + 1)
        return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return None


def _days(n):
    from datetime import timedelta
    return timedelta(days=n)


async def fill(page, v: dict, rid: str) -> str | None:
    """Fill the whole form. Returns the expiry ISO string shown on the Day Pass card, if readable."""
    await page.locator(PLATE).fill(v["plate"])
    await pick_unit(page, v["unit"])
    await page.locator(RESIDENT_LAST).fill(v["resident_last_name"])
    await page.locator(FIRST).fill(v["first_name"])
    await page.locator(LAST).fill(v["last_name"])
    await page.locator(EMAIL).fill(v["email"])
    expires = None
    try:
        expires = parse_until(await page.locator(DURATION_CARD).first.inner_text(timeout=3000))
    except Exception:
        pass
    await proofs.screenshot(page, rid, "fill_form.png")
    return expires


SUCCESS_WORDS = ("confirmed", "registered successfully", "you're all set", "you are registered", "success")


def classify_message(text: str) -> str:
    """The site reports results in the same alert/toast element: tell success from error by its words."""
    low = text.lower()
    if "already registered" in low or "don't need another pass" in low:
        return "already"
    if any(w in low for w in SUCCESS_WORDS) and not any(w in low for w in ("not ", "can't", "cannot", "failed")):
        return "success"
    return "error"


async def outcome(page, timeout_ms: int = 20000) -> tuple[str, str]:
    """After submit: ('success'|'already'|'error'|'challenge'|'none', text)."""
    deadline = timeout_ms // 500
    for _ in range(deadline):
        await page.wait_for_timeout(500)
        if await page.locator(CHALLENGE_SEL).count():
            return "challenge", ""
        errs = page.locator(ERROR_SEL)
        for i in range(await errs.count()):
            t = (await errs.nth(i).inner_text()).strip()
            if t:
                return classify_message(" ".join(t.split("\n")[0].split())), t
        if not await page.locator(PLATE).is_visible():  # form is gone: the page moved to a result view
            return "success", (await page.inner_text("body"))[:2000]
    return "none", (await page.inner_text("body"))[:500]


def extract_confirmation(text: str) -> str | None:
    m = re.search(r"(?:confirmation|reference|pass|code)\s*(?:#|number|no\.?|:)?\s*[:\-]?\s*([A-Z0-9][A-Z0-9\-]{4,})", text or "", re.I)
    return m.group(1).upper() if m and any(ch.isdigit() for ch in m.group(1)) else None
