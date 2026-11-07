"""Outbound events to the Photon messenger sidecar and inbound webhook handling."""
import asyncio
import hashlib
import hmac
import logging
import time

import httpx

from .. import db, errors
from ..config import settings
from ..models import Intent
from . import llm, proofs

log = logging.getLogger("parkour.messaging")
REPLAY_WINDOW_S = 300
_tasks: set[asyncio.Task] = set()


def spawn(coro) -> asyncio.Task:
    t = asyncio.create_task(coro)
    _tasks.add(t)
    t.add_done_callback(_tasks.discard)
    return t


# ---------- outbound ----------
async def send(event: str, to_phone: str, text: str, attachment_path: str | None = None) -> bool:
    ok = False
    try:
        async with httpx.AsyncClient(timeout=15) as c:
            r = await c.post(f"{settings.messenger_url}/send",
                             headers={"X-Internal-Key": settings.internal_api_key},
                             json={"to_phone": to_phone, "text": text, "event": event,
                                   "attachment_path": attachment_path})
            ok = r.status_code < 300
    except Exception as e:
        log.warning("send event=%s failed: %s", event, type(e).__name__)
    db.execute("INSERT INTO message_log (at, event, ok) VALUES (?,?,?)", (proofs.now_iso(), event, int(ok)))
    return ok


def wants_message(user: dict) -> bool:
    return user.get("notify_channel") in ("message", "both")


def event_text(event: str, reg: dict) -> tuple[str, str | None]:
    """Short message text and optional attachment path for an event."""
    if event == "check1_prompt":
        return f"{reg['summary']}\nReply YES to register, NO to skip.", None
    if event == "needs_user":
        nu = reg.get("needs_user") or {}
        text = nu.get("message") or "Parkour needs your input."
        if nu.get("reason") == "captcha" and nu.get("portal_url"):
            text += f"\n{nu['portal_url']}"
        elif nu.get("reason") == "rule_conflict":
            text += "\nReply YES to register anyway, NO to cancel."
        return text, None
    if event == "confirmed":
        pr = reg.get("proof") or {}
        shot = next((u for u in pr.get("screenshot_urls", []) if "confirmation" in u), None)
        path = None
        if shot:
            path = str(settings.proofs_dir / shot.removeprefix("/proofs/"))
        return (f"Registered. Confirmation {pr.get('confirmation_number')}, valid until {pr.get('expires_at')}.", path)
    if event == "failed":
        return "Registration failed. Open Parkour to see what happened.", None
    if event == "expiry_reminder":
        return "Your guest pass expires in 30 minutes. Reply RENEW to extend.", None
    return "Parkour update.", None


def notify(event: str, user: dict, reg: dict, *, force: bool = False):
    """Fire-and-forget outbound event if the user wants messages."""
    if not (force or wants_message(user)):
        return
    text, attach = event_text(event, reg)
    try:
        spawn(send(event, user["phone"], text, attach))
    except RuntimeError:  # no running loop (sync tests)
        pass


# ---------- inbound ----------
def verify_signature(raw: bytes, timestamp: str | None, signature: str | None, now: float | None = None) -> bool:
    """HMAC-SHA256 over `v0:{timestamp}:{rawBody}` keyed by PHOTON_WEBHOOK_SECRET (Photon Spectrum docs)."""
    secret = settings.photon_webhook_secret
    if not (secret and timestamp and signature):
        return False
    try:
        if abs((now or time.time()) - int(timestamp)) > REPLAY_WINDOW_S:
            return False
    except ValueError:
        return False
    expected = "v0=" + hmac.new(secret.encode(), b"v0:" + timestamp.encode() + b":" + raw, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature.strip())


def sign(raw: bytes, timestamp: str, secret: str) -> str:
    """Test helper mirroring Photon's signing."""
    return "v0=" + hmac.new(secret.encode(), b"v0:" + timestamp.encode() + b":" + raw, hashlib.sha256).hexdigest()


async def classify(text: str) -> str:
    try:
        out = await llm.chat_json(
            "message_intent",
            "Classify a user's reply to a parking registration prompt. intent is one of: "
            "yes (wants to register), no (decline), edit (wants to change details), other.",
            f'Reply: "{text[:300]}"', Intent)
        return out.intent
    except errors.ApiError:
        return "other"


async def reply(phone: str, text: str):
    await send("needs_user", phone, text)  # helper replies reuse the needs_user event name


async def handle_inbound(payload: dict):
    """Process one verified Photon `messages` delivery. Runs as a background task."""
    from . import drafts  # local import: drafts imports this module
    try:
        msg = payload.get("message") or {}
        mid = msg.get("id")
        if msg.get("direction") != "inbound" or (msg.get("content") or {}).get("type") != "text":
            return
        if mid:
            if db.query("SELECT 1 FROM webhook_seen WHERE message_id=?", (mid,)):
                return
            db.execute("INSERT INTO webhook_seen (message_id) VALUES (?)", (mid,))
        phone = (msg.get("sender") or {}).get("id")
        text = (msg["content"].get("text") or "").strip()
        user = drafts.user_by_phone(phone) if phone else None
        if not user:
            return  # unknown sender: ignore
        reg = drafts.newest_for_message(user["user_id"])
        word = text.upper()
        if word == "RENEW":
            intent = "renew"
        elif word in ("YES", "NO"):
            intent = word.lower()
        else:
            intent = await classify(text)
        if intent == "renew":
            prev = drafts.latest_pass(user["user_id"])
            if prev:
                new = drafts.renew(user, prev["registration_id"], prev["duration_hours"])
                notify("check1_prompt", user, new, force=True)
            else:
                await reply(phone, "No pass to renew.")
            return
        if not reg:
            await reply(phone, "Nothing waiting for you right now.")
            return
        if intent == "yes":
            if reg["status"] == "awaiting_confirm":
                drafts.confirm(user, reg["registration_id"], "message")
            elif reg["status"] == "needs_user" and (reg.get("needs_user") or {}).get("reason") == "rule_conflict":
                drafts.answer(user, reg["registration_id"], "override", "true")
            else:
                await reply(phone, "Reply YES or NO.")
        elif intent == "no":
            if reg["status"] == "needs_user" and (reg.get("needs_user") or {}).get("reason") == "rule_conflict":
                drafts.answer(user, reg["registration_id"], "override", "false")
            else:
                drafts.cancel(user, reg["registration_id"])
        elif intent == "edit":
            await reply(phone, f"Open Parkour to edit: {settings.public_base_url}")
        elif reg["status"] == "needs_user" and (reg.get("needs_user") or {}).get("reason") == "missing_info":
            drafts.answer(user, reg["registration_id"], reg["needs_user"]["field"], text)
        else:
            await reply(phone, "Reply YES or NO.")
    except errors.ApiError as e:
        log.info("inbound rejected: %s", e.code)
    except Exception as e:
        log.warning("inbound failed: %s", type(e).__name__)
