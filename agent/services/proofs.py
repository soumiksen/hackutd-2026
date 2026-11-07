"""Screenshot storage under proofs/{registration_id}/ with DB timestamps."""
from datetime import datetime, timezone
from pathlib import Path

from .. import db
from ..config import settings


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def reg_dir(registration_id: str) -> Path:
    d = settings.proofs_dir / registration_id
    d.mkdir(parents=True, exist_ok=True)
    return d


def path_for(registration_id: str, filename: str) -> Path:
    return reg_dir(registration_id) / filename


def record(registration_id: str, filename: str):
    db.execute("INSERT INTO proof_files (registration_id, filename, captured_at) VALUES (?,?,?)",
               (registration_id, filename, now_iso()))


async def screenshot(page, registration_id: str, filename: str) -> Path:
    p = path_for(registration_id, filename)
    await page.screenshot(path=str(p), full_page=True)
    record(registration_id, filename)
    return p


def url_for(registration_id: str, filename: str) -> str:
    return f"/proofs/{registration_id}/{filename}"
