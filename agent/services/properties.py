"""Seeded properties: load, distance, alternatives."""
import math

from .. import db, errors
from . import data

PRIVATE = {"property_code", "portal_path", "confidence", "last_verified"}


def load_into_db():
    for p in data.properties():
        db.put("properties", "property_id", p["property_id"], p)


def haversine_m(lat1, lng1, lat2, lng2) -> float:
    r = 6371000
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def all_raw() -> list[dict]:
    return [db.get("properties", "property_id", r["property_id"]) for r in
            db.query("SELECT property_id FROM properties ORDER BY property_id")]


def get_raw(property_id: str) -> dict:
    p = db.get("properties", "property_id", property_id)
    if not p:
        raise errors.not_found(f"Property {property_id} not found.")
    return p


def public(p: dict, distance_m: float | None = None) -> dict:
    out = {k: v for k, v in p.items() if k not in PRIVATE}
    if distance_m is not None:
        out["distance_m"] = round(distance_m, 1)
    return out


def nearby(lat: float, lng: float, limit: int = 10) -> list[dict]:
    scored = sorted(((haversine_m(lat, lng, p["lat"], p["lng"]), p) for p in all_raw()), key=lambda t: t[0])
    return [public(p, d) for d, p in scored[:limit]]


def match(lat: float, lng: float) -> dict | None:
    """Nearest property whose radius contains the point."""
    best = min(((haversine_m(lat, lng, p["lat"], p["lng"]), p) for p in all_raw()), key=lambda t: t[0], default=None)
    return best[1] if best and best[0] <= best[1]["radius_m"] else None


def alternatives(p: dict, n: int = 2) -> list[dict]:
    others = sorted(((haversine_m(p["lat"], p["lng"], o["lat"], o["lng"]), o)
                     for o in all_raw() if o["property_id"] != p["property_id"]), key=lambda t: t[0])
    return [{"property_id": o["property_id"], "name": o["name"]} for _, o in others[:n]]
