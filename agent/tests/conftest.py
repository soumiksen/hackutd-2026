import functools
import http.server
import json
import threading
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

PORTAL_DIR = Path(__file__).parent / "fake_portal"
UID = "11111111-1111-1111-1111-111111111111"
H = {"X-User-Id": UID}
USER = {"name": "Maya Lee", "phone": "+15551234567", "email": "maya@example.com", "consent_register": True,
        "spending_cap_usd": 10, "notify_channel": "app"}
VEH = {"plate": "ABC1234", "state": "TX", "make": "Honda", "model": "Civic", "color": "Blue"}


@pytest.fixture(scope="session")
def portal_url():
    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_GET(self):
            path = self.path.split("?")[0].strip("/")
            page = PORTAL_DIR / f"{path}.html"
            if not page.exists():
                self.send_error(404); return
            body = page.read_bytes()
            self.send_response(200); self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{srv.server_address[1]}"
    srv.shutdown()


@pytest.fixture
def client(tmp_path, monkeypatch, portal_url):
    # point the fake portal paths at /mockpark and /guestpass (the contract's portal_path values)
    monkeypatch.setenv("DATABASE_URL", f"sqlite:///{tmp_path}/t.db")
    monkeypatch.setenv("PROOFS_DIR", str(tmp_path / "proofs"))
    monkeypatch.setenv("MOCK_PORTAL_URL", portal_url)
    monkeypatch.setenv("DATA_DIR", str(tmp_path / "no-data"))  # forces agent/fixtures
    monkeypatch.setenv("PHOTON_WEBHOOK_SECRET", "whsec_test")
    monkeypatch.setenv("MESSENGER_URL", "http://127.0.0.1:9")  # nothing listens: sends fail quietly
    monkeypatch.setenv("DEMO_PORTAL_PARAMS", "")
    from agent import db
    from agent.config import settings
    db.reset()
    from agent.main import app
    app.router.routes = [r for r in app.router.routes if getattr(r, "name", "") != "proofs"]
    from fastapi.staticfiles import StaticFiles
    settings.proofs_dir.mkdir(parents=True, exist_ok=True)
    app.mount("/proofs", StaticFiles(directory=str(settings.proofs_dir)), name="proofs")
    with TestClient(app) as c:
        yield c
    db.reset()


@pytest.fixture
def user_vehicle(client):
    assert client.post("/users", json=USER, headers=H).status_code == 200
    v = client.post("/vehicles", json=VEH, headers=H).json()
    return v["vehicle_id"]


def draft_body(vehicle_id, property_id="uta-001", **kw):
    return {"vehicle_id": vehicle_id, "property_id": property_id, "role": "visitor",
            "host": {"name": "Maya Lee", "unit": "214"}, "duration_hours": 12, **kw}


def wait_status(client, reg_id, want, timeout=40):
    import time
    end = time.time() + timeout
    while time.time() < end:
        r = client.get(f"/registrations/{reg_id}", headers=H).json()
        if r["status"] in want:
            return r
        time.sleep(0.4)
    raise AssertionError(f"status stuck at {r['status']}: {r}")
