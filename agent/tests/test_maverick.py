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
    assert client.post("/maverick-place/register", json={"vehicle_id": mav, "confirm": True}, headers=H).status_code == 422
    client.post("/users", json=USER, headers=H)  # consent back on
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
