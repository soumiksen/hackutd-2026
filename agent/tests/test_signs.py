from agent.models import PlanOut, SignRead
from agent.services import llm

from .conftest import H, USER


def fake_llm(readable=True):
    async def fake(task, system, user, schema, **kw):
        if task == "sign_vision":
            return SignRead(zone_code="4521", method="pay_by_app", readable=readable, confidence=0.9 if readable else 0.1)
        return PlanOut(method="pay_by_app", confidence=0.85, tow_risk="low")
    return fake


def test_sign_analyze_and_checkout(client, monkeypatch):
    monkeypatch.setenv("VISION_MODEL", "test/vision")
    monkeypatch.setattr(llm, "chat_json", fake_llm())
    client.post("/users", json=USER, headers=H)
    r = client.post("/signs/analyze", files={"photo": ("s.jpg", b"\xff\xd8fake", "image/jpeg")}, headers=H)
    assert r.status_code == 200
    plan = r.json()
    assert plan["zone_code"] == "4521" and plan["price_per_hour_usd"] == 2.0 and plan["total_usd"] == 4.0
    assert plan["needs_sign_photo"] is False and plan["sources"][0]["type"] == "sign_photo"
    paid = client.post("/checkout/mock", json={"plan_id": plan["plan_id"], "amount_usd": plan["total_usd"]}, headers=H)
    assert paid.status_code == 200 and paid.json()["receipt_id"].startswith("rcpt_")


def test_unreadable_sign_asks_for_new_photo(client, monkeypatch):
    monkeypatch.setenv("VISION_MODEL", "test/vision")
    monkeypatch.setattr(llm, "chat_json", fake_llm(readable=False))
    r = client.post("/signs/analyze", files={"photo": ("s.jpg", b"x", "image/jpeg")}, headers=H).json()
    assert r["needs_sign_photo"] is True and r["confidence"] <= 0.3


def test_vision_unavailable_without_model(client, monkeypatch):
    monkeypatch.setenv("VISION_MODEL", "")
    r = client.post("/vehicles/vision", files={"photo": ("c.jpg", b"x", "image/jpeg")}, headers=H)
    assert r.status_code == 503 and r.json()["error"]["code"] == "llm_unavailable"


def test_vehicle_vision_normalizes(client, monkeypatch):
    from agent.models import VehicleVision
    monkeypatch.setenv("VISION_MODEL", "test/vision")

    async def fake(*a, **k):
        return VehicleVision(plate="abc 1234", state="tx", make="Honda", model="Civic", color="Blue", confidence=0.9)
    monkeypatch.setattr(llm, "chat_json", fake)
    r = client.post("/vehicles/vision", files={"photo": ("c.jpg", b"x", "image/jpeg")}, headers=H).json()
    assert r == {"plate": "ABC1234", "state": "TX", "make": "Honda", "model": "Civic", "color": "Blue", "confidence": 0.9}
