"""Deterministic form-filler for vendor `mockpark` (selectors come from data/vendors.json)."""
from ..services import proofs


async def fill_and_submit(page, selectors: dict, values: dict, registration_id: str):
    """Fill every canonical field present on the page, screenshot, then click submit."""
    for field, value in values.items():
        sel = selectors.get(field)
        if not sel or not value:
            continue
        loc = page.locator(sel).first
        if await loc.count() == 0:
            continue
        tag = await loc.evaluate("e => e.tagName.toLowerCase()")
        if tag == "select":
            await loc.select_option(str(value))
        else:
            await loc.fill(str(value))
    await proofs.screenshot(page, registration_id, "fill_form.png")
    return selectors["submit"]
