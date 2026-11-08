"""End-to-end check of a running stack (API + mock portal), acting like the Flutter app.

    python -m agent.scripts.e2e [--api http://localhost:8000] [--captcha]

Start first: mock portal (port 8001) and the API. For --captcha, start the API with DEMO_PORTAL_PARAMS=captcha=on.
Uses a throwaway user id, so it never touches real data.
"""
import argparse
import sys
import time
import uuid

import httpx

VEH = {"plate": "ABC1234", "state": "TX", "make": "Honda", "model": "Civic", "color": "Blue"}
USER = {"name": "Maya Lee", "phone": "+15550100123", "email": "maya.demo@example.com", "consent_register": True,
        "spending_cap_usd": 10, "notify_channel": "app"}


def step(msg): print(f"  - {msg}", flush=True)


def poll(c, rid, want, timeout=90):
    end, last = time.time() + timeout, None
    while time.time() < end:
        r = c.get(f"/registrations/{rid}").json()
        if r["status"] != last:
            step(f"status={r['status']} steps={[s['name']+':'+s['status'] for s in r['steps']]}")
            last = r["status"]
        if r["status"] in want:
            return r
        time.sleep(1)
    raise SystemExit(f"FAIL: timed out in {last}")


def run_flow(c, prop_id, label, host, hours, captcha=False, expect="confirmed"):
    print(f"[{label}] {prop_id}")
    reg = c.post("/registrations/draft", json={"vehicle_id": c.vid, "property_id": prop_id, "role": "visitor",
                                               "host": host, "duration_hours": hours})
    if reg.status_code != 200:
        raise SystemExit(f"FAIL draft: {reg.text}")
    reg = reg.json()
    step(f"draft: {reg['summary']}")
    assert reg["status"] == "awaiting_confirm"
    c.post(f"/registrations/{reg['registration_id']}/confirm", json={"channel": "app"}).raise_for_status()
    r = poll(c, reg["registration_id"], {"confirmed", "failed", "needs_user"})
    if captcha:
        assert r["status"] == "needs_user" and r["needs_user"]["reason"] == "captcha", r
        step(f"captcha handoff url ok: {'captcha=on' in r['needs_user']['portal_url']}")
        c.post(f"/registrations/{reg['registration_id']}/resume").raise_for_status()
        r = poll(c, reg["registration_id"], {"confirmed", "failed", "needs_user"})
    if r["status"] != expect:
        raise SystemExit(f"FAIL: {r['status']} {r.get('error') or r.get('needs_user')}")
    if r["status"] == "confirmed":
        img = c.get(r["proof"]["screenshot_urls"][0])
        assert img.status_code == 200 and img.headers["content-type"] == "image/png", "screenshot did not load"
        step(f"confirmed {r['proof']['confirmation_number']} until {r['proof']['expires_at']}, screenshot ok")
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", default="http://localhost:8000")
    ap.add_argument("--captcha", action="store_true")
    ap.add_argument("--skip-guestpass", action="store_true")
    a = ap.parse_args()
    c = httpx.Client(base_url=a.api, headers={"X-User-Id": str(uuid.uuid4())}, timeout=120)
    assert c.get("/health").json() == {"status": "ok"}
    c.post("/users", json=USER).raise_for_status()
    c.vid = c.post("/vehicles", json=VEH).json()["vehicle_id"]
    near = c.get("/properties", params={"lat": 32.995, "lng": -96.7485, "limit": 3}).json()["properties"]
    step(f"nearby: {[(p['property_id'], p['distance_m']) for p in near]}")
    host = {"name": "Jordan Park", "unit": "214"}
    if a.captcha:
        run_flow(c, "utd-001", "mockpark + captcha", host, 12, captcha=True)
    else:
        run_flow(c, "utd-001", "mockpark happy path", host, 12)
        if not a.skip_guestpass:
            run_flow(c, "utd-002", "guestpass via Nemotron", host, 6)
    print("OK")


if __name__ == "__main__":
    sys.exit(main())
