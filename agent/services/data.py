"""Read-only loader for data/ files, falling back to agent/fixtures when data/ is absent."""
import json
from functools import lru_cache
from pathlib import Path

from ..config import settings

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"


def load(name: str):
    for base in (settings.data_dir, FIXTURES):
        p = base / name
        if p.exists():
            return json.loads(p.read_text())
    raise FileNotFoundError(name)


def properties() -> list[dict]: return load("properties.json")
def vendors() -> dict[str, dict]: return {v["vendor_id"]: v for v in load("vendors.json")["vendors"]}
def allowed_domains() -> list[str]: return load("allowed_domains.json")["domains"]
def blocked_urls() -> list[str]: return load("blocked_examples.json")["urls"]
def events() -> list[dict]: return load("events.json")["events"]
def zones() -> list[dict]: return load("parking_zones.json")["zones"]
def sign_expected() -> list[dict]: return load("sign_expected.json")["signs"]
