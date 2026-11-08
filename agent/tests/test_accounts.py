import pytest

from agent import auth, store as store_mod
from agent.stdb import ident, quote

from .conftest import H, USER, VEH, draft_body, wait_status

SIGNUP = {"email": "Maya@Example.com", "password": "correct horse", "name": "Maya Lee", "phone": "+15551234567",
          "consent_register": True, "spending_cap_usd": 10, "notify_channel": "app"}


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


def signup(client, **kw):
    r = client.post("/auth/signup", json={**SIGNUP, **kw})
    assert r.status_code == 200, r.text
    return r.json()


# ---------- sign up / sign in ----------
def test_signup_signin_signout(client):
    s = signup(client)
    assert s["user"]["email"] == "maya@example.com" and s["user"]["has_account"] is True and "password" not in str(s)
    tok = s["token"]
    me = client.get("/users/me", headers=bearer(tok)).json()
    assert me["user_id"] == s["user"]["user_id"] and me["name"] == "Maya Lee"
    # sign in on a "second device" with different letter case
    s2 = client.post("/auth/signin", json={"email": " MAYA@example.com ", "password": "correct horse"}).json()
    assert s2["token"] != tok and s2["user"]["user_id"] == s["user"]["user_id"]
    # sign out only that session
    assert client.post("/auth/signout", headers=bearer(s2["token"])).json() == {"ok": True}
    assert client.get("/users/me", headers=bearer(s2["token"])).status_code == 401
    assert client.get("/users/me", headers=bearer(tok)).status_code == 200


def test_signup_validation_and_duplicates(client):
    assert client.post("/auth/signup", json={**SIGNUP, "password": "short"}).status_code == 422
    assert client.post("/auth/signup", json={**SIGNUP, "email": "not-an-email"}).status_code == 422
    assert client.post("/auth/signup", json={**SIGNUP, "phone": "5551234"}).status_code == 422
    signup(client)
    r = client.post("/auth/signup", json={**SIGNUP, "email": "MAYA@example.com"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "conflict"


def test_wrong_password_and_unknown_email_look_the_same_and_throttle(client):
    signup(client)
    a = client.post("/auth/signin", json={"email": "maya@example.com", "password": "nope nope nope"})
    b = client.post("/auth/signin", json={"email": "ghost@example.com", "password": "nope nope nope"})
    assert a.status_code == b.status_code == 401 and a.json() == b.json()
    for _ in range(4):
        client.post("/auth/signin", json={"email": "maya@example.com", "password": "bad bad bad"})
    r = client.post("/auth/signin", json={"email": "maya@example.com", "password": "correct horse"})
    assert r.status_code == 429 and r.json()["error"]["code"] == "rate_limited"


def test_password_is_hashed_not_stored(client):
    signup(client)
    cred = store_mod.get_store().get_credential(email="maya@example.com")
    assert cred["password_hash"].startswith("scrypt$") and "correct horse" not in cred["password_hash"]
    assert auth.verify_password("correct horse", cred["password_hash"]) and not auth.verify_password("x", cred["password_hash"])


def test_expired_session_rejected(client):
    s = signup(client)
    store_mod.get_store().create_session(auth.token_hash("old-token"), s["user"]["user_id"], "2020-01-01T00:00:00Z")
    r = client.get("/users/me", headers=bearer("old-token"))
    assert r.status_code == 401 and r.json()["error"]["code"] == "unauthorized"


def test_account_id_in_header_is_not_enough(client):
    s = signup(client)
    uid = s["user"]["user_id"]
    r = client.get("/users/me", headers={"X-User-Id": uid})
    assert r.status_code == 401
    assert client.get("/users/me", headers=bearer(s["token"])).status_code == 200


def test_anonymous_devices_still_work_unless_auth_required(client, monkeypatch):
    assert client.post("/users", json=USER, headers=H).status_code == 200
    assert client.get("/users/me", headers=H).json()["has_account"] is False
    monkeypatch.setenv("REQUIRE_AUTH", "true")
    r = client.get("/users/me", headers=H)
    assert r.status_code == 401 and r.json()["error"]["code"] == "unauthorized"
    s = signup(client)
    assert client.get("/users/me", headers=bearer(s["token"])).status_code == 200


def test_signup_claims_anonymous_profile_and_keeps_cars(client, user_vehicle):
    s = client.post("/auth/signup", json=SIGNUP, headers=H).json()
    assert s["user"]["user_id"] == H["X-User-Id"]
    cars = client.get("/vehicles", headers=bearer(s["token"])).json()["vehicles"]
    assert [c["vehicle_id"] for c in cars] == [user_vehicle] and "user_id" not in cars[0]


def test_change_password_signs_out_other_devices(client):
    a = signup(client)
    b = client.post("/auth/signin", json={"email": "maya@example.com", "password": "correct horse"}).json()
    r = client.post("/auth/password", json={"current_password": "wrong wrong", "new_password": "a brand new one"}, headers=bearer(a["token"]))
    assert r.status_code == 401
    r = client.post("/auth/password", json={"current_password": "correct horse", "new_password": "a brand new one"}, headers=bearer(a["token"]))
    assert r.status_code == 200
    assert client.get("/users/me", headers=bearer(a["token"])).status_code == 200
    assert client.get("/users/me", headers=bearer(b["token"])).status_code == 401
    assert client.post("/auth/signin", json={"email": "maya@example.com", "password": "correct horse"}).status_code == 401
    assert client.post("/auth/signin", json={"email": "maya@example.com", "password": "a brand new one"}).status_code == 200


def test_patch_profile_and_delete_account(client):
    s = signup(client)
    h = bearer(s["token"])
    p = client.patch("/users/me", json={"name": "Maya L", "consent_register": False}, headers=h).json()
    assert p["name"] == "Maya L" and p["consent_register"] is False and p["email"] == "maya@example.com"
    veh = client.post("/vehicles", json=VEH, headers=h).json()["vehicle_id"]
    assert client.delete("/users/me", headers=h).json() == {"ok": True}
    assert client.get("/users/me", headers=h).status_code == 401  # session is gone
    assert store_mod.get_store().get_vehicle(veh) is None
    assert client.post("/auth/signin", json={"email": "maya@example.com", "password": "correct horse"}).status_code == 401


def test_data_is_per_user(client):
    a = signup(client)
    b = signup(client, email="other@example.com", phone="+15557654321")
    va = client.post("/vehicles", json=VEH, headers=bearer(a["token"])).json()["vehicle_id"]
    assert client.get("/vehicles", headers=bearer(b["token"])).json()["vehicles"] == []
    r = client.post("/registrations/draft", json=draft_body(va), headers=bearer(b["token"]))
    assert r.status_code == 404  # b cannot use a's car


# ---------- saved places and history ----------
def confirm_at(client, headers, vid, property_id="uta-001", host=None, hours=6):
    body = draft_body(vid, property_id, duration_hours=hours, **({"host": host} if host else {}))
    rid = client.post("/registrations/draft", json=body, headers=headers).json()["registration_id"]
    client.post(f"/registrations/{rid}/confirm", json={"channel": "app"}, headers=headers)
    reg = wait_status(client, rid, {"confirmed", "failed", "needs_user"})
    assert reg["status"] == "confirmed", reg
    return rid


def test_confirmed_registration_is_remembered_and_counted(client, user_vehicle):
    confirm_at(client, H, user_vehicle)
    places = client.get("/places", headers=H).json()["places"]
    assert len(places) == 1
    p = places[0]
    assert (p["property_id"], p["unit"], p["host_name"], p["uses"], p["duration_hours"]) == ("uta-001", "214", "Maya Lee", 1, 6)
    assert p["plate"] == "ABC1234" and p["vehicle_id"] == user_vehicle and p["label"] == ""
    confirm_at(client, H, user_vehicle)
    p = client.get("/places", headers=H).json()["places"][0]
    assert p["uses"] == 2
    assert len(client.get("/places?property_id=uta-002", headers=H).json()["places"]) == 0


def test_draft_prefills_unit_from_past_visit(client, user_vehicle):
    confirm_at(client, H, user_vehicle, host={"name": "Jordan Park", "unit": "B12"})
    body = draft_body(user_vehicle)
    body.pop("host")
    reg = client.post("/registrations/draft", json=body, headers=H).json()
    assert reg["host"] == {"name": "Jordan Park", "unit": "B12"} and "unit B12" in reg["summary"]
    # explicit values win
    reg = client.post("/registrations/draft", json=draft_body(user_vehicle, host={"name": "X", "unit": "9"}), headers=H).json()
    assert reg["host"]["unit"] == "9"
    # a different property has nothing saved
    body["property_id"] = "uta-002"
    assert client.post("/registrations/draft", json=body, headers=H).json()["host"] == {"name": None, "unit": None}


def test_place_label_and_forget(client, user_vehicle):
    confirm_at(client, H, user_vehicle)
    pid = client.get("/places", headers=H).json()["places"][0]["place_id"]
    assert client.patch(f"/places/{pid}", json={"label": "Alex's place"}, headers=H).json()["label"] == "Alex's place"
    assert client.patch("/places/pl_missing", json={"label": "x"}, headers=H).status_code == 404
    assert client.delete(f"/places/{pid}", headers=H).json() == {"ok": True}
    assert client.get("/places", headers=H).json()["places"] == []


def test_history_lists_every_attempt_newest_first(client, user_vehicle):
    first = confirm_at(client, H, user_vehicle, hours=6)
    d = client.post("/registrations/draft", json=draft_body(user_vehicle, duration_hours=6), headers=H).json()
    client.post(f"/registrations/{d['registration_id']}/cancel", headers=H)
    hist = client.get("/history", headers=H).json()["history"]
    assert [h["status"] for h in hist][:2] == ["cancelled", "confirmed"]
    assert hist[1]["registration_id"] == first and hist[1]["property_name"] and hist[1]["expires_at"].endswith("Z")
    assert len(client.get("/history?limit=1", headers=H).json()["history"]) == 1


def test_places_and_history_are_private(client, user_vehicle):
    confirm_at(client, H, user_vehicle)
    s = signup(client)
    assert client.get("/places", headers=bearer(s["token"])).json()["places"] == []
    assert client.get("/history", headers=bearer(s["token"])).json()["history"] == []


def test_maverick_second_time_needs_no_unit(client, user_vehicle, portal_url, monkeypatch):
    from agent.services import maverick
    monkeypatch.setattr(maverick, "MAVERICK_URL", f"{portal_url}/parkva")
    b = {"vehicle_id": user_vehicle, "unit": "101-A", "resident_last_name": "Park", "confirm": True}
    rid = client.post("/maverick-place/register", json=b, headers=H).json()["registration_id"]
    assert wait_status(client, rid, {"confirmed", "failed", "needs_user"})["status"] == "confirmed"
    place = client.get("/places?property_id=maverick-place", headers=H).json()["places"][0]
    assert (place["unit"], place["host_name"]) == ("101-A", "Park")
    r = client.post("/maverick-place/register", json={"vehicle_id": user_vehicle, "confirm": True}, headers=H)
    assert r.status_code == 200 and r.json()["host"] == {"name": "Park", "unit": "101-A"}
    assert wait_status(client, r.json()["registration_id"], {"confirmed", "failed", "needs_user"})["status"] == "confirmed"
    assert client.get("/places?property_id=maverick-place", headers=H).json()["places"][0]["uses"] == 2


def test_dry_runs_leave_no_history(client, user_vehicle, portal_url, monkeypatch):
    from agent.services import maverick
    monkeypatch.setattr(maverick, "MAVERICK_URL", f"{portal_url}/parkva")
    b = {"vehicle_id": user_vehicle, "unit": "101-A", "resident_last_name": "Park", "confirm": True, "dry_run": True}
    rid = client.post("/maverick-place/register", json=b, headers=H).json()["registration_id"]
    wait_status(client, rid, {"cancelled", "failed"})
    assert client.get("/history", headers=H).json()["history"] == []


def test_storage_outage_gives_503_not_a_crash(client):
    class Down(store_mod.Store):
        def get_credential(self, *a, **k):
            raise store_mod.StoreUnavailable("down")
    store_mod.set_store(Down(store_mod.get_store().c))
    r = client.get("/users/me", headers=H)
    assert r.status_code == 503 and r.json()["error"]["code"] == "storage_unavailable"


def test_sql_values_are_escaped():
    assert quote("o'brien") == "'o''brien'"
    with pytest.raises(ValueError):
        quote("a\nb")
    with pytest.raises(ValueError):
        ident("x' OR '1'='1")
    assert ident("veh_ab-12") == "'veh_ab-12'"
