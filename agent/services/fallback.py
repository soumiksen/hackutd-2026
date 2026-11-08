"""Nemotron fallback: fill an unfamiliar form by field meaning (vendor `guestpass`)."""
import hashlib
import json
import logging

from pydantic import ValidationError

from ..models import FormPlan
from . import llm

log = logging.getLogger("parkour.fallback")

SNAPSHOT_JS = """() => {
  const vis = e => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
  const sel = e => e.id ? '#' + CSS.escape(e.id) : (e.name ? e.tagName.toLowerCase() + '[name="' + e.name + '"]' : null);
  const labelOf = e => {
    if (e.id) { const l = document.querySelector('label[for="' + CSS.escape(e.id) + '"]'); if (l) return l.innerText.trim(); }
    const p = e.closest('label'); return p ? p.innerText.trim() : (e.getAttribute('aria-label') || '');
  };
  const fields = [...document.querySelectorAll('input, select, textarea')]
    .filter(e => vis(e) && !e.readOnly && !e.disabled && !['hidden','submit','button'].includes(e.type) && sel(e))
    .map(e => ({selector: sel(e), tag: e.tagName.toLowerCase(), type: e.type || '', name: e.name || '', id: e.id || '',
      label: labelOf(e), placeholder: e.placeholder || '', filled: !!(e.value && e.tagName !== 'SELECT'),
      options: e.tagName === 'SELECT' ? [...e.options].map(o => ({value: o.value, text: o.text})) : undefined}));
  const buttons = [...document.querySelectorAll('button, input[type=submit], input[type=button]')]
    .filter(vis).map(b => {
      const text = (b.innerText || b.value || '').trim().replace(/"/g, '');
      return {selector: b.id ? '#' + CSS.escape(b.id) : (b.tagName === 'BUTTON' && text ? 'button:text-is("' + text + '")' : null), text};
    }).filter(b => b.selector && b.text);
  return {fields, buttons};
}"""

SYSTEM = (
    "You fill web forms for a parking guest registration. You get the form's fields and buttons and the "
    "user's canonical values. Match fields by meaning (labels, names, placeholders), not exact wording. "
    'Return {"fills":[{"selector","value"}],"click":"selector"}. Use only selectors from the list. '
    "Values must come from the canonical values (or a select option value). Skip fields you cannot match. "
    "click is the button that moves forward or submits.")


async def snapshot(page) -> dict:
    return await page.evaluate(SNAPSHOT_JS)


def validate_plan(plan: FormPlan, snap: dict, values: dict) -> FormPlan:
    """Drop anything the model invented: unknown selectors and values the user never supplied."""
    fields = {f["selector"]: f for f in snap["fields"]}
    buttons = {b["selector"] for b in snap["buttons"]}
    allowed_vals = {str(v) for v in values.values() if v}
    fills = []
    for f in plan.fills:
        spec = fields.get(f.selector)
        if not spec:
            log.warning("fallback: dropped unknown selector")
            continue
        if spec.get("filled"):  # already prefilled from the URL: leave it alone
            continue
        opts = {o["value"] for o in spec.get("options") or []} | {o["text"] for o in spec.get("options") or []}
        if f.value not in allowed_vals and f.value not in opts:
            log.warning("fallback: dropped value not supplied by user")
            continue
        fills.append(f)
    click = plan.click if plan.click in buttons else None
    return FormPlan(fills=fills, click=click)


async def plan_step(snap: dict, values: dict) -> FormPlan:
    user = json.dumps({"canonical_values": {k: v for k, v in values.items() if v}, "form": snap}, sort_keys=True)
    try:
        plan = await llm.chat_json("form_fallback", SYSTEM, user, FormPlan)
    except ValidationError:
        raise
    return validate_plan(plan, snap, values)


async def apply_plan(page, plan: FormPlan, snap: dict):
    tags = {f["selector"]: f["tag"] for f in snap["fields"]}
    for f in plan.fills:
        loc = page.locator(f.selector).first
        if tags.get(f.selector) == "select":
            try:
                await loc.select_option(value=f.value)
            except Exception:
                await loc.select_option(label=f.value)
        else:
            await loc.fill(f.value)


def snap_digest(snap: dict) -> str:
    return hashlib.sha256(json.dumps(snap, sort_keys=True).encode()).hexdigest()[:12]
