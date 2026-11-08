"""Lifespan loop: mark passes expired, send expiry reminders 30 minutes ahead."""
import asyncio
import json
import logging
from datetime import datetime, timedelta, timezone

from .. import db, store
from . import drafts, messaging

log = logging.getLogger("parkour.reminders")
REMIND_BEFORE = timedelta(minutes=30)


def _parse(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def tick(now: datetime | None = None):
    now = now or datetime.now(timezone.utc)
    for reg in store.get_store().registrations_with_status("confirmed"):
        exp = _parse(reg["proof"]["expires_at"])
        user = store.get_store().get_user(reg["_user_id"])
        if now >= exp:
            store.get_store().reg_expire(reg["registration_id"])
        elif now >= exp - REMIND_BEFORE and not reg.get("_reminded"):
            store.get_store().reg_mark_reminded(reg["registration_id"])
            if user:
                messaging.notify("expiry_reminder", user, reg)


RESIDENT_TIMEOUT = timedelta(minutes=30)


def resident_timeouts(now: datetime | None = None):
    """A registration waiting on a resident who never replies fails after 30 minutes."""
    now = now or datetime.now(timezone.utc)
    for reg in store.get_store().registrations_with_status("needs_user"):
        if (reg.get("needs_user") or {}).get("reason") != "resident_info":
            continue
        asked = (reg.get("_answers") or {}).get("resident_requested_at")
        if asked and now - _parse(asked) > RESIDENT_TIMEOUT:
            store.get_store().reg_failed(reg["registration_id"], "resident_no_reply",
                                         "The resident didn't reply in time. Try again.")
            user = store.get_store().get_user(reg["_user_id"])
            if user:
                messaging.notify("failed", user, drafts.load(reg["registration_id"]))


async def loop():
    while True:
        try:
            tick()
            resident_timeouts()
        except Exception as e:
            log.warning("reminder tick failed: %s", type(e).__name__)
        await asyncio.sleep(60)
