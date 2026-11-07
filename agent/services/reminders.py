"""Lifespan loop: mark passes expired, send expiry reminders 30 minutes ahead."""
import asyncio
import json
import logging
from datetime import datetime, timedelta, timezone

from .. import db
from . import drafts, messaging

log = logging.getLogger("parkour.reminders")
REMIND_BEFORE = timedelta(minutes=30)


def _parse(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def tick(now: datetime | None = None):
    now = now or datetime.now(timezone.utc)
    for row in db.query("SELECT data FROM registrations WHERE status='confirmed'"):
        reg = json.loads(row["data"])
        exp = _parse(reg["proof"]["expires_at"])
        user = db.get("users", "user_id", reg["_user_id"])
        if now >= exp:
            drafts.update(reg["registration_id"], lambda r: r.update(status="expired"))
        elif now >= exp - REMIND_BEFORE and not reg.get("_reminded"):
            drafts.update(reg["registration_id"], lambda r: r.update(_reminded=True))
            if user:
                messaging.notify("expiry_reminder", user, reg)


async def loop():
    while True:
        try:
            tick()
        except Exception as e:
            log.warning("reminder tick failed: %s", type(e).__name__)
        await asyncio.sleep(60)
