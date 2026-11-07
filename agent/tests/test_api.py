import json

from .conftest import H, USER, VEH, draft_body, wait_status

SECTION5 = [
    ("GET", "/health", None, 200, {"status"}),
    ("GET", "/users/me", None, 200, {"user_id", "name", "phone", "email", "consent_register", "spending_cap_usd", "notify_channel"}),
    ("GET", "/vehicles", None, 200, {"vehicles"}),
    ("GET", "/properties?lat=32.73&lng=-97.11&limit=2", None, 200, {"properties"}),
    ("GET", "/properties/uta-001", None, 200, {"property_id", "name", "campus", "lat", "lng", "radius_m", "vendor_id", "guest_rules", "tow_enforced", "notes"}),
    ("GET", "/passes", None, 200, {"passes"}),
]


def test_contract_shapes(client, user_vehicle):
    for method, path, body, code, keys in SECTION5:
        r = client.request(method, path, json=body, headers=H)
        assert r.status_code == code, path
        assert keys <= set(r.json()), path


def test_user_header_required_and_errors(client):
    r = client.get("/users/me")
    assert r.status_code == 422 and r.json()["error"]["code"] == "validation_error"
    r = client.get("/users/me", headers=H)
    assert r.status_code == 404 and r.json()["error"]["code"] == "not_found"


def test_properties_sorted_and_private_fields_hidden(client, user_vehicle):
    ps = client.get("/properties?lat=32.7315&lng=-97.1115&limit=3", headers=H).json()["properties"]
    d = [p["distance_m"] for p in ps]
    assert d == sorted(d) and len(ps) == 3
    assert not {"property_code", "portal_path", "confidence", "last_verified"} & set(ps[0])
    assert "distance_m" not in client.get("/properties/uta-001", headers=H).json()


def test_draft_summary_alternatives_and_rules(client, user_vehicle):
    r = client.post("/registrations/draft", json=draft_body(user_vehicle), headers=H)
    assert r.status_code == 200
    reg = r.json()
    assert reg["status"] == "awaiting_confirm" and "Civic (TX ABC1234)" in reg["summary"]
    assert "unit 214" in reg["summary"] and len(reg["alternatives"]) == 2
    assert reg["steps"][0] == {"name": "match_property", "status": "done", "at": reg["steps"][0]["at"]}
    assert not any(k.startswith("_") for k in reg)
    # too long
    r = client.post("/registrations/draft", json=draft_body(user_vehicle, duration_hours=48), headers=H)
    assert r.status_code == 422 and r.json()["error"]["code"] == "validation_error"
    # permit-only property
    r = client.post("/registrations/draft", json=draft_body(user_vehicle, property_id="utd-001"), headers=H)
    assert r.status_code == 422
    # unknown property / vehicle
    assert client.post("/registrations/draft", json=draft_body(user_vehicle, property_id="nope"), headers=H).status_code == 404
    assert client.post("/registrations/draft", json=draft_body("veh_nope"), headers=H).status_code == 404


def test_guest_night_limit_on_draft(client, user_vehicle):
    ids = []
    for _ in range(2):  # uta-002 allows 2 nights
        r = client.post("/registrations/draft", json=draft_body(user_vehicle, "uta-002", duration_hours=6), headers=H).json()
        ids.append(r["registration_id"])
        client.post(f"/registrations/{r['registration_id']}/confirm", json={"channel": "app"}, headers=H)
        wait_status(client, r["registration_id"], {"confirmed"})
    r = client.post("/registrations/draft", json=draft_body(user_vehicle, "uta-002", duration_hours=6), headers=H)
    assert r.status_code == 422 and "guest night limit" in r.json()["error"]["message"]


def test_patch_and_cancel_and_wrong_state(client, user_vehicle):
    reg = client.post("/registrations/draft", json=draft_body(user_vehicle), headers=H).json()
    rid = reg["registration_id"]
    p = client.patch(f"/registrations/{rid}", json={"duration_hours": 6}, headers=H).json()
    assert p["duration_hours"] == 6 and p["status"] == "awaiting_confirm"
    c = client.post(f"/registrations/{rid}/cancel", headers=H).json()
    assert c["status"] == "cancelled"
    r = client.post(f"/registrations/{rid}/confirm", json={"channel": "app"}, headers=H)
    assert r.status_code == 409 and r.json()["error"]["code"] == "wrong_state"
    assert client.get(f"/registrations/{rid}", headers={"X-User-Id": "someone-else"}).status_code == 404


def test_confirm_requires_consent(client, user_vehicle):
    client.post("/users", json={**USER, "consent_register": False}, headers=H)
    rid = client.post("/registrations/draft", json=draft_body(user_vehicle), headers=H).json()["registration_id"]
    r = client.post(f"/registrations/{rid}/confirm", json={"channel": "app"}, headers=H)
    assert r.status_code == 403 and r.json()["error"]["code"] == "consent_required"
    assert client.get(f"/registrations/{rid}", headers=H).json()["status"] == "awaiting_confirm"


def test_confirm_runs_mockpark_to_confirmed(client, user_vehicle):
    rid = client.post("/registrations/draft", json=draft_body(user_vehicle), headers=H).json()["registration_id"]
    r = client.post(f"/registrations/{rid}/confirm", json={"channel": "app"}, headers=H)
    assert r.status_code == 200 and r.json()["status"] == "submitting"
    reg = wait_status(client, rid, {"confirmed", "failed"})
    assert reg["status"] == "confirmed", reg
    assert reg["proof"]["confirmation_number"] == "PK-AB12CD" and reg["proof"]["expires_at"].endswith("Z")
    img = client.get(reg["proof"]["screenshot_urls"][0])
    assert img.status_code == 200 and img.headers["content-type"] == "image/png"
    assert {s["name"]: s["status"] for s in reg["steps"]} == {n: "done" for n in
           ["match_property", "open_portal", "fill_form", "submit", "capture_proof"]}
    assert [p["registration_id"] for p in client.get("/passes", headers=H).json()["passes"]] == [rid]


def test_captcha_then_resume(client, user_vehicle, monkeypatch):
    monkeypatch.setenv("DEMO_PORTAL_PARAMS", "captcha=on")
    rid = client.post("/registrations/draft", json=draft_body(user_vehicle), headers=H).json()["registration_id"]
    client.post(f"/registrations/{rid}/confirm", json={"channel": "app"}, headers=H)
    reg = wait_status(client, rid, {"needs_user", "failed"})
    assert reg["needs_user"]["reason"] == "captcha" and "captcha=on" in reg["needs_user"]["portal_url"]
    assert client.post(f"/registrations/{rid}/answer", json={"field": "x", "value": "y"}, headers=H).status_code == 409
    client.post(f"/registrations/{rid}/resume", headers=H)
    assert wait_status(client, rid, {"confirmed", "failed", "needs_user"})["status"] == "confirmed"


def test_missing_info_then_answer(client, user_vehicle):
    body = draft_body(user_vehicle, host={"name": "Maya Lee", "unit": None})
    rid = client.post("/registrations/draft", json=body, headers=H).json()["registration_id"]
    client.post(f"/registrations/{rid}/confirm", json={"channel": "app"}, headers=H)
    reg = wait_status(client, rid, {"needs_user", "failed"})
    assert reg["needs_user"]["reason"] == "missing_info" and reg["needs_user"]["field"] == "host_unit"
    assert client.post(f"/registrations/{rid}/answer", json={"field": "plate", "value": "x"}, headers=H).status_code == 422
    client.post(f"/registrations/{rid}/answer", json={"field": "host_unit", "value": "214"}, headers=H)
    assert wait_status(client, rid, {"confirmed", "failed", "needs_user"})["status"] == "confirmed"


def test_portal_failure_retries_then_failed(client, user_vehicle, monkeypatch):
    monkeypatch.setenv("DEMO_PORTAL_PARAMS", "fail=1")
    rid = client.post("/registrations/draft", json=draft_body(user_vehicle), headers=H).json()["registration_id"]
    client.post(f"/registrations/{rid}/confirm", json={"channel": "app"}, headers=H)
    reg = wait_status(client, rid, {"failed", "confirmed"}, timeout=60)
    assert reg["status"] == "failed" and reg["error"]["code"] == "portal_failed"


def test_unknown_domain_blocked(client, user_vehicle, monkeypatch):
    monkeypatch.setenv("MOCK_PORTAL_URL", "http://mockpark-portal.xyz")
    rid = client.post("/registrations/draft", json=draft_body(user_vehicle), headers=H).json()["registration_id"]
    client.post(f"/registrations/{rid}/confirm", json={"channel": "app"}, headers=H)
    reg = wait_status(client, rid, {"failed"})
    assert reg["error"]["code"] == "unknown_domain"


def test_guestpass_via_nemotron_fallback(client, user_vehicle, monkeypatch):
    from agent.models import FormPlan
    from agent.services import llm

    async def fake(task, system, user, schema, **kw):
        assert task == "form_fallback"
        d = json.loads(user)
        v, fields = d["canonical_values"], {f["label"]: f["selector"] for f in d["form"]["fields"]}
        fills = []
        for label, sel in fields.items():
            key = {"Vehicle tag": "plate", "Visitor name": "guest_name", "Hours": "duration_hours",
                   "Contact number": "phone", "Unit visiting": "host_unit"}.get(label)
            if key:
                fills.append({"selector": sel, "value": v[key]})
        fills.append({"selector": "#ignored", "value": "x"})  # invented selector must be dropped
        btn = d["form"]["buttons"][0]["selector"]
        return FormPlan(fills=fills, click=btn)
    monkeypatch.setattr(llm, "chat_json", fake)
    rid = client.post("/registrations/draft", json=draft_body(user_vehicle, "uta-003"), headers=H).json()["registration_id"]
    client.post(f"/registrations/{rid}/confirm", json={"channel": "app"}, headers=H)
    reg = wait_status(client, rid, {"confirmed", "failed"})
    assert reg["status"] == "confirmed" and reg["proof"]["confirmation_number"] == "PK-GP9Z8Y"


def test_renew_creates_new_draft(client, user_vehicle):
    rid = client.post("/registrations/draft", json=draft_body(user_vehicle, duration_hours=6), headers=H).json()["registration_id"]
    client.post(f"/registrations/{rid}/confirm", json={"channel": "app"}, headers=H)
    wait_status(client, rid, {"confirmed"})
    new = client.post(f"/registrations/{rid}/renew", json={"duration_hours": 6}, headers=H).json()
    assert new["status"] == "awaiting_confirm" and new["registration_id"] != rid
