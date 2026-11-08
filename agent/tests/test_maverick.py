import pytest

from agent.services import maverick
from agent.vendors import parkva

from .conftest import H, USER, wait_status


@pytest.fixture
def mav(client, user_vehicle, portal_url, monkeypatch):
    monkeypatch.setattr(maverick, "MAVERICK_URL", f"{portal_url}/parkva")
    return user_vehicle


def body(vid, **kw):
    return {"vehicle_id": vid, "unit": "101-A", "resident_last_name": "Park", "confirm": True, **kw}


def test_register_confirmed(client, mav):
    r = client.post("/maverick-place/register", json=body(mav), headers=H)
    assert r.status_code == 200 and r.json()["property"]["name"] == "Maverick Place"
    reg = wait_status(client, r.json()["registration_id"], {"confirmed", "failed", "needs_user"})
    assert reg["status"] == "confirmed", reg
    assert reg["proof"]["confirmation_number"] == "MV48213" and reg["proof"]["expires_at"].endswith("Z")
    assert client.get(reg["proof"]["screenshot_urls"][0]).status_code == 200
    assert not any(k.startswith("_") for k in reg)
    assert client.get("/passes", headers=H).json()["passes"][0]["registration_id"] == reg["registration_id"]


def test_dry_run_does_not_submit(client, mav):
    r = client.post("/maverick-place/register", json=body(mav, dry_run=True), headers=H).json()
    reg = wait_status(client, r["registration_id"], {"cancelled", "failed", "confirmed", "needs_user"})
    assert reg["status"] == "cancelled" and "NOT submitted" in reg["summary"]
    assert client.get(reg["proof"]["screenshot_urls"][0]).status_code == 200


def test_gates(client, mav):
    assert client.post("/maverick-place/register", json=body(mav, confirm=False), headers=H).status_code == 422
    client.post("/users", json={**USER, "consent_register": False}, headers=H)
    r = client.post("/maverick-place/register", json=body(mav), headers=H)
    assert r.status_code == 403 and r.json()["error"]["code"] == "consent_required"
    client.post("/users", json=USER, headers=H)  # consent back on
    r = client.post("/maverick-place/register", json={"vehicle_id": mav, "confirm": True}, headers=H)
    # nothing saved yet: no error, it asks for the resident's phone instead
    assert r.status_code == 200 and r.json()["needs_user"]["field"] == "resident_phone"
    assert client.post("/maverick-place/register", json=body("veh_nope"), headers=H).status_code == 404


def test_unknown_unit_asks_then_answer_finishes(client, mav):
    r = client.post("/maverick-place/register", json=body(mav, unit="999"), headers=H).json()
    reg = wait_status(client, r["registration_id"], {"needs_user", "failed", "confirmed"})
    assert reg["needs_user"]["reason"] == "missing_info" and reg["needs_user"]["field"] == "host_unit"
    client.post(f"/registrations/{r['registration_id']}/answer", json={"field": "host_unit", "value": "Unit 101-B"}, headers=H)
    assert wait_status(client, r["registration_id"], {"confirmed", "failed", "needs_user"})["status"] == "confirmed"


def test_wrong_resident_name_asks_for_it(client, mav):
    r = client.post("/maverick-place/register", json=body(mav, resident_last_name="Nope"), headers=H).json()
    reg = wait_status(client, r["registration_id"], {"needs_user", "failed", "confirmed"})
    assert reg["needs_user"]["field"] == "host_name"
    client.post(f"/registrations/{r['registration_id']}/answer", json={"field": "host_name", "value": "Park"}, headers=H)
    assert wait_status(client, r["registration_id"], {"confirmed", "failed", "needs_user"})["status"] == "confirmed"


def test_helpers():
    assert parkva.norm_unit("Unit 101-a") == "101A" == parkva.norm_unit("101 A") == parkva.norm_unit("101A")
    assert parkva.parse_until("Day Pass\n\nUntil Sun, Nov 8, 8:35 PM\n\nFree").endswith("Z")
    assert parkva.parse_until("nothing") is None
    assert parkva.extract_confirmation("Confirmation number: MV48213") == "MV48213"
    assert parkva.extract_confirmation("You are registered") is None
    assert maverick.split_name("Maya Lee") == ("Maya", "Lee") and maverick.split_name("Cher") == ("Cher", "Cher")


def test_extra_domain_scoped_to_this_flow():
    from agent import safety
    from agent.errors import ApiError
    with pytest.raises(ApiError):
        safety.check_url(maverick.MAVERICK_URL)  # not globally allowed
    safety.check_url(maverick.MAVERICK_URL, extra_hosts=maverick.EXTRA_ALLOWED)


def test_resident_plate_is_refused_once_with_clear_message(client, user_vehicle, mav):
    vid = client.post("/vehicles", json={"plate": "RES1", "state": "TX", "make": "A", "model": "B", "color": "C"}, headers=H).json()["vehicle_id"]
    r = client.post("/maverick-place/register", json=body(vid), headers=H).json()
    reg = wait_status(client, r["registration_id"], {"failed", "needs_user", "confirmed"})
    assert reg["status"] == "failed" and reg["error"]["code"] == "portal_failed"
    assert reg["error"]["message"].startswith("Maverick Place refused it:") and "reserved for visitors" in reg["error"]["message"]


@pytest.mark.parametrize("plate", ["DUP1", "TOAST1"])
def test_toast_success_and_already_registered_count_as_confirmed(client, user_vehicle, mav, plate):
    vid = client.post("/vehicles", json={"plate": plate, "state": "TX", "make": "A", "model": "B", "color": "C"}, headers=H).json()["vehicle_id"]
    r = client.post("/maverick-place/register", json=body(vid), headers=H).json()
    reg = wait_status(client, r["registration_id"], {"failed", "needs_user", "confirmed"})
    assert reg["status"] == "confirmed", reg
    assert reg["proof"]["expires_at"].endswith("Z")


def test_classify_message():
    assert parkva.classify_message("Guest pass confirmed") == "success"
    assert parkva.classify_message("This plate is already registered here until Nov 8, 8:56 PM CST.") == "already"
    assert parkva.classify_message("This vehicle can't park in this zone") == "error"
    assert parkva.classify_message("Registration failed, not confirmed") == "error"


# ---------- first visit: ask the resident by text ----------
import json as _json
import time as _time


@pytest.fixture
def sent(monkeypatch):
    """Capture texts the backend would send through Photon."""
    from agent.services import messaging
    out = []

    async def fake_send(event, to_phone, text, attachment_path=None):
        out.append({"event": event, "to": to_phone, "text": text})
        return True
    monkeypatch.setattr(messaging, "send", fake_send)

    async def no_llm(text):  # tests never call the real model
        return None
    monkeypatch.setattr(messaging, "parse_resident_reply_llm", no_llm)
    return out


def inbound(client, text, sender="+15557770001", mid=None):
    from agent.config import settings
    return client.post("/messaging/inbound", json={"message_id": mid or f"m-{_time.time_ns()}", "from_phone": sender, "text": text},
                       headers={"X-Internal-Key": settings.internal_api_key})


@pytest.fixture
def first_visit(client, user_vehicle, portal_url, monkeypatch, sent):
    from agent.services import maverick
    monkeypatch.setenv("INTERNAL_API_KEY", "internal-test-key")
    monkeypatch.setattr(maverick, "MAVERICK_URL", f"{portal_url}/parkva")
    r = client.post("/maverick-place/register", json={"vehicle_id": user_vehicle, "confirm": True}, headers=H)
    assert r.status_code == 200, r.text
    return r.json()


def test_maverick_is_in_the_property_list(client, user_vehicle):
    ps = client.get("/properties?lat=32.7243&lng=-97.1200&limit=3", headers=H).json()["properties"]
    mp = next(p for p in ps if p["property_id"] == "maverick-place")
    assert mp["vendor_id"] == "parkva" and mp["distance_m"] < mp["radius_m"] and "property_code" not in mp


def test_no_saved_info_asks_for_the_residents_phone(client, first_visit):
    assert first_visit["status"] == "needs_user"
    assert first_visit["needs_user"]["reason"] == "missing_info" and first_visit["needs_user"]["field"] == "resident_phone"
    assert first_visit["property"]["property_id"] == "maverick-place"


def test_full_first_visit_flow_through_the_resident(client, user_vehicle, first_visit, sent):
    rid = first_visit["registration_id"]
    # the visitor enters the resident's number
    r = client.post(f"/registrations/{rid}/answer", json={"field": "resident_phone", "value": "+1 (555) 777-0001"}, headers=H)
    assert r.status_code == 200 and r.json()["needs_user"]["reason"] == "resident_info"
    assert "0001" in r.json()["needs_user"]["message"]
    deadline = _time.time() + 5
    while not sent and _time.time() < deadline:
        _time.sleep(0.1)
    assert len(sent) == 1 and sent[0]["event"] == "resident_request" and sent[0]["to"] == "+15557770001"
    assert "Maya" in sent[0]["text"] and "Maverick Place" in sent[0]["text"] and "unit number and last name" in sent[0]["text"]
    assert USER["email"] not in sent[0]["text"] and USER["phone"] not in sent[0]["text"]  # nothing private goes to the resident
    # a stranger's text does nothing
    assert inbound(client, "227A Adhikary", sender="+15558889999").json() == {"ok": True}
    _time.sleep(0.6)
    assert client.get(f"/registrations/{rid}", headers=H).json()["needs_user"]["reason"] == "resident_info"
    # an unclear reply gets help, not a registration
    inbound(client, "who is this?")
    deadline = _time.time() + 5
    while not any("couldn't read" in m["text"] for m in sent) and _time.time() < deadline:
        _time.sleep(0.1)
    assert any("couldn't read" in m["text"] for m in sent)
    assert client.get(f"/registrations/{rid}", headers=H).json()["status"] == "needs_user"
    # the resident answers
    inbound(client, "Hi, it's 101-A, Park")
    reg = wait_status(client, rid, {"confirmed", "failed", "cancelled"})
    assert reg["status"] == "confirmed", reg
    assert reg["host"] == {"name": "Park", "unit": "101A"}  # the page matches 101A and 101-A as the same unit
    # saved: the next visit asks nobody
    places = client.get("/places?property_id=maverick-place", headers=H).json()["places"]
    assert [(p["unit"], p["host_name"]) for p in places] == [("101A", "Park")]
    again = client.post("/maverick-place/register", json={"vehicle_id": user_vehicle, "confirm": True}, headers=H).json()
    assert again["status"] == "submitting" and again["needs_user"] is None
    assert wait_status(client, again["registration_id"], {"confirmed", "failed", "needs_user"})["status"] == "confirmed"


def test_resident_declines(client, first_visit, sent):
    rid = first_visit["registration_id"]
    client.post(f"/registrations/{rid}/answer", json={"field": "resident_phone", "value": "+15557770001"}, headers=H)
    inbound(client, "No, I'm not expecting anyone")
    reg = wait_status(client, rid, {"failed", "confirmed"})
    assert reg["status"] == "failed" and reg["error"]["code"] == "resident_declined"


def test_resident_phone_rules(client, first_visit, sent):
    rid = first_visit["registration_id"]
    bad = client.post(f"/registrations/{rid}/answer", json={"field": "resident_phone", "value": "555-1234"}, headers=H)
    assert bad.status_code == 422
    own = client.post(f"/registrations/{rid}/answer", json={"field": "resident_phone", "value": USER["phone"]}, headers=H)
    assert own.status_code == 422 and "own number" in own.json()["error"]["message"]
    assert client.post(f"/registrations/{rid}/answer", json={"field": "plate", "value": "x"}, headers=H).status_code == 422
    assert client.get(f"/registrations/{rid}", headers=H).json()["needs_user"]["field"] == "resident_phone"
    assert sent == []  # nothing was sent to anyone


def test_at_most_three_resident_texts_per_hour(client, user_vehicle, portal_url, monkeypatch, sent):
    from agent.services import maverick
    monkeypatch.setattr(maverick, "MAVERICK_URL", f"{portal_url}/parkva")
    codes = []
    for i in range(4):
        r = client.post("/maverick-place/register", json={"vehicle_id": user_vehicle, "confirm": True}, headers=H).json()
        a = client.post(f"/registrations/{r['registration_id']}/answer", json={"field": "resident_phone", "value": f"+1555777000{i}"}, headers=H)
        codes.append(a.status_code)
    assert codes == [200, 200, 200, 429]


def test_resident_who_never_replies_times_out(client, first_visit, sent):
    from datetime import datetime, timedelta, timezone
    from agent.services import reminders
    rid = first_visit["registration_id"]
    client.post(f"/registrations/{rid}/answer", json={"field": "resident_phone", "value": "+15557770001"}, headers=H)
    reminders.resident_timeouts(datetime.now(timezone.utc) + timedelta(minutes=10))
    assert client.get(f"/registrations/{rid}", headers=H).json()["status"] == "needs_user"
    reminders.resident_timeouts(datetime.now(timezone.utc) + timedelta(minutes=31))
    reg = client.get(f"/registrations/{rid}", headers=H).json()
    assert reg["status"] == "failed" and reg["error"]["code"] == "resident_no_reply"


def test_internal_inbound_needs_the_key(client, monkeypatch):
    monkeypatch.setenv("INTERNAL_API_KEY", "internal-test-key")
    body = {"message_id": "x1", "from_phone": "+15557770001", "text": "hi"}
    assert client.post("/messaging/inbound", json=body).status_code == 401
    assert client.post("/messaging/inbound", json=body, headers={"X-Internal-Key": "wrong"}).status_code == 401
    assert client.post("/messaging/inbound", json={**body, "from_phone": "nope"}, headers={"X-Internal-Key": "internal-test-key"}).status_code == 422
    assert client.post("/messaging/inbound", json=body, headers={"X-Internal-Key": "internal-test-key"}).json() == {"ok": True}
    monkeypatch.setenv("INTERNAL_API_KEY", "")
    assert client.post("/messaging/inbound", json=body, headers={"X-Internal-Key": ""}).status_code == 401  # no key set: closed


def test_parse_resident_reply():
    from agent.services.messaging import parse_resident_reply as p
    assert p("227A Adhikary") == ("227A", "Adhikary")
    assert p("Unit 227-A, last name Adhikary") == ("227A", "Adhikary")
    assert p("adhikary 227 a") == ("227A", "Adhikary")
    assert p("apt #12 O'Brien") == ("12", "O'Brien")
    assert p("Smith Jones 227A") is None and p("hello") is None and p("227A") is None


def test_failed_text_puts_the_question_back(client, first_visit, monkeypatch):
    """If Photon cannot text the resident, the visitor is asked again instead of waiting for nobody."""
    from agent.services import messaging

    async def failing_send(event, to_phone, text, attachment_path=None):
        return False
    monkeypatch.setattr(messaging, "send", failing_send)
    rid = first_visit["registration_id"]
    r = client.post(f"/registrations/{rid}/answer", json={"field": "resident_phone", "value": "+15557770001"}, headers=H)
    assert r.status_code == 200
    deadline = _time.time() + 5
    reg = r.json()
    while reg["needs_user"]["reason"] != "missing_info" and _time.time() < deadline:
        _time.sleep(0.2)
        reg = client.get(f"/registrations/{rid}", headers=H).json()
    assert reg["status"] == "needs_user" and reg["needs_user"]["field"] == "resident_phone"
    assert "couldn't text that number" in reg["needs_user"]["message"]
