import json
import time

import pytest

from agent import safety
from agent.errors import ApiError
from agent.services import data, llm, messaging, reminders

from .conftest import H, draft_body, wait_status


def test_allowlist_and_blocked_examples(client):
    safety.check_url("http://localhost:8001/mockpark/")
    safety.check_url("http://127.0.0.1:8001/x")
    for u in data.blocked_urls() + ["https://evil.com/", "http://localhost.evil.example/a", "not a url"]:
        with pytest.raises(ApiError) as e:
            safety.check_url(u)
        assert e.value.code == "unknown_domain"
    with pytest.raises(ApiError):
        safety.check_text_urls("pay here http://mockpark-portal.xyz/")


def test_extract_json_handles_reasoning_and_prose():
    assert llm.extract_json('<think>hmm {"a":0}</think>Sure: {"a": {"b": "}"}, "c": 1} trailing') == {"a": {"b": "}"}, "c": 1}
    with pytest.raises(ValueError):
        llm.extract_json("no json here")


def test_signature_verification(client):
    raw, ts = b'{"x":1}', str(int(time.time()))
    good = messaging.sign(raw, ts, "whsec_test")
    assert messaging.verify_signature(raw, ts, good)
    assert not messaging.verify_signature(raw, ts, "v0=" + "0" * 64)
    assert not messaging.verify_signature(raw, str(int(time.time()) - 1000), messaging.sign(raw, str(int(time.time()) - 1000), "whsec_test"))
    assert not messaging.verify_signature(raw, None, good)


def _post_webhook(client, text, sender="+15551234567", mid="m1", sig=None):
    body = json.dumps({"event": "messages", "space": {"id": "s", "platform": "iMessage"}, "message": {
        "id": mid, "direction": "inbound", "sender": {"id": sender, "platform": "iMessage"},
        "content": {"type": "text", "text": text}}}).encode()
    ts = str(int(time.time()))
    return client.post("/messaging/webhook", content=body, headers={
        "X-Spectrum-Timestamp": ts, "X-Spectrum-Signature": sig or messaging.sign(body, ts, "whsec_test"),
        "Content-Type": "application/json"})


def test_webhook_bad_signature_401(client, user_vehicle):
    assert _post_webhook(client, "YES", sig="v0=" + "0" * 64).status_code == 401
    assert client.post("/messaging/webhook", json={}).status_code == 401


def test_webhook_yes_confirms_and_other_sender_ignored(client, user_vehicle):
    rid = client.post("/registrations/draft", json=draft_body(user_vehicle), headers=H).json()["registration_id"]
    assert _post_webhook(client, "YES", sender="+15559999999", mid="m-other").json() == {"ok": True}
    time.sleep(0.5)
    assert client.get(f"/registrations/{rid}", headers=H).json()["status"] == "awaiting_confirm"
    assert _post_webhook(client, " yes ", mid="m-yes").json() == {"ok": True}
    assert wait_status(client, rid, {"submitting", "confirmed"})
    assert wait_status(client, rid, {"confirmed", "failed"})["status"] == "confirmed"


def test_webhook_no_cancels_and_intent_fallback(client, user_vehicle, monkeypatch):
    from agent.models import Intent

    async def fake(task, *a, **k):
        return Intent(intent="no")
    monkeypatch.setattr(llm, "chat_json", fake)
    rid = client.post("/registrations/draft", json=draft_body(user_vehicle), headers=H).json()["registration_id"]
    _post_webhook(client, "nah not this time", mid="m-free")
    deadline = time.time() + 5
    while time.time() < deadline and client.get(f"/registrations/{rid}", headers=H).json()["status"] != "cancelled":
        time.sleep(0.2)
    assert client.get(f"/registrations/{rid}", headers=H).json()["status"] == "cancelled"


def test_webhook_no_consent_does_not_run(client, user_vehicle):
    from .conftest import USER
    client.post("/users", json={**USER, "consent_register": False}, headers=H)
    rid = client.post("/registrations/draft", json=draft_body(user_vehicle), headers=H).json()["registration_id"]
    _post_webhook(client, "YES", mid="m-nc")
    time.sleep(0.8)
    assert client.get(f"/registrations/{rid}", headers=H).json()["status"] == "awaiting_confirm"


def test_expiry_and_reminder(client, user_vehicle):
    from datetime import datetime, timedelta, timezone
    rid = client.post("/registrations/draft", json=draft_body(user_vehicle, duration_hours=6), headers=H).json()["registration_id"]
    client.post(f"/registrations/{rid}/confirm", json={"channel": "app"}, headers=H)
    reg = wait_status(client, rid, {"confirmed"})
    exp = datetime.fromisoformat(reg["proof"]["expires_at"].replace("Z", "+00:00"))
    reminders.tick(exp - timedelta(minutes=10))
    assert client.get(f"/registrations/{rid}", headers=H).json()["status"] == "confirmed"
    reminders.tick(exp + timedelta(minutes=1))
    assert client.get(f"/registrations/{rid}", headers=H).json()["status"] == "expired"


def test_checkout_mock(client, user_vehicle):
    from agent import db
    db.put("plans", "plan_id", "plan_x", {"plan_id": "plan_x", "total_usd": 4.0}, user_id=H["X-User-Id"])
    ok = client.post("/checkout/mock", json={"plan_id": "plan_x", "amount_usd": 4.0}, headers=H)
    assert ok.status_code == 200 and set(ok.json()) == {"receipt_id", "amount_usd", "paid_at"}
    assert client.post("/checkout/mock", json={"plan_id": "plan_x", "amount_usd": 40}, headers=H).status_code == 422
    assert client.post("/checkout/mock", json={"plan_id": "nope", "amount_usd": 1}, headers=H).status_code == 404
