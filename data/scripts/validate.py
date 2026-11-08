"""Checks every data file against API_CONTRACT.md. Run before every commit:
    python data/scripts/validate.py
Exits 1 on any error. Standard library only.
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
DATA = ROOT / "data"
CANONICAL = {"plate", "state", "make", "model", "color", "host_unit", "host_name",
             "guest_name", "phone", "email", "duration_hours"}
PROPERTY_FIELDS = ["property_id", "name", "campus", "lat", "lng", "radius_m", "vendor_id",
                   "property_code", "portal_path", "guest_rules", "tow_enforced", "notes",
                   "confidence", "last_verified"]
RULE_KEYS = {"max_nights_per_month", "max_duration_hours", "requires_host_unit", "guest_hours"}
DFW = {"lat": (32.4, 33.3), "lng": (-97.6, -96.4)}
PHONE_RE = re.compile(r"\+1\d{10}|\(\d{3}\)\s?\d{3}-\d{4}|\b\d{3}-\d{3}-\d{4}\b")

errors, warnings = [], []
def err(msg): errors.append(msg)
def warn(msg): warnings.append(msg)

def load(name):
    p = DATA / name
    if not p.exists():
        err(f"missing file data/{name}")
        return None
    try:
        return json.loads(p.read_text())
    except json.JSONDecodeError as e:
        err(f"data/{name} is not valid JSON: {e}")
        return None

vendors = load("vendors.json")
vendor_ids = set()
if vendors is not None:
    for v in vendors.get("vendors", []):
        vid = v.get("vendor_id")
        vendor_ids.add(vid)
        bad = set(v.get("fields", [])) - CANONICAL
        if bad: err(f"vendor {vid}: non-canonical fields {sorted(bad)}")
        sel = v.get("selectors")
        if sel is not None:
            missing = set(v.get("fields", [])) - set(sel)
            if missing: err(f"vendor {vid}: selectors missing {sorted(missing)}")
            if "submit" not in sel: err(f"vendor {vid}: selectors missing 'submit'")
    if vendor_ids - {"mockpark", "guestpass"}:
        err(f"vendors.json has vendor ids outside the contract enum: {sorted(vendor_ids - {'mockpark', 'guestpass'})}")

props = load("properties.json")
pids, codes = set(), set()
if props is not None:
    if not isinstance(props, list): err("properties.json must be a top-level array")
    else:
        per_campus = {"UTA": 0, "UTD": 0}
        for i, p in enumerate(props):
            pid = p.get("property_id", f"#{i}")
            for f in PROPERTY_FIELDS:
                if f not in p: err(f"{pid}: missing field {f}")
            extra = set(p) - set(PROPERTY_FIELDS)
            if extra: err(f"{pid}: fields not in the contract {sorted(extra)}")
            if pid in pids: err(f"duplicate property_id {pid}")
            pids.add(pid)
            if not re.fullmatch(r"(uta|utd)-\d{3}", str(pid)): err(f"{pid}: id must look like uta-001 / utd-001")
            if p.get("campus") not in per_campus: err(f"{pid}: campus must be UTA or UTD")
            else:
                per_campus[p["campus"]] += 1
                if not str(pid).startswith(p["campus"].lower()): err(f"{pid}: id prefix does not match campus")
            lat, lng = p.get("lat"), p.get("lng")
            if not (isinstance(lat, (int, float)) and DFW["lat"][0] <= lat <= DFW["lat"][1]): err(f"{pid}: lat outside DFW")
            if not (isinstance(lng, (int, float)) and DFW["lng"][0] <= lng <= DFW["lng"][1]): err(f"{pid}: lng outside DFW")
            r = p.get("radius_m")
            if not (isinstance(r, (int, float)) and 50 <= r <= 300): err(f"{pid}: radius_m must be 50-300")
            vid = p.get("vendor_id")
            if vid is not None and vid not in vendor_ids: err(f"{pid}: vendor_id {vid} not in vendors.json")
            if (p.get("portal_path") is None) != (vid is None): err(f"{pid}: portal_path must be null exactly when vendor_id is null")
            if vid is not None:
                if p.get("portal_path") != f"/{vid}/": err(f"{pid}: portal_path should be /{vid}/")
                code = p.get("property_code")
                if not code: err(f"{pid}: property_code required when vendor_id is set")
                elif code in codes: err(f"{pid}: duplicate property_code {code}")
                else: codes.add(code)
            gr = p.get("guest_rules") or {}
            if set(gr) != RULE_KEYS: err(f"{pid}: guest_rules keys must be {sorted(RULE_KEYS)}")
            c = p.get("confidence")
            if not (isinstance(c, (int, float)) and 0 <= c <= 1): err(f"{pid}: confidence must be 0-1")
            lv = p.get("last_verified")
            if lv is not None and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(lv)): err(f"{pid}: last_verified must be YYYY-MM-DD or null")
        for campus, n in per_campus.items():
            if n < 15: warn(f"{campus} has {n} properties; the data plan targets 15+")

allowed = load("allowed_domains.json")
if allowed is not None:
    if "localhost" not in allowed.get("domains", []) or "127.0.0.1" not in allowed.get("domains", []):
        err("allowed_domains.json must include localhost and 127.0.0.1")

blocked = load("blocked_examples.json")
if blocked is not None and allowed is not None:
    from urllib.parse import urlparse
    for u in blocked.get("urls", []):
        host = urlparse(u).hostname or ""
        if host in allowed.get("domains", []): err(f"blocked example {u} is on the allowlist")

demo = load("demo.json")
if demo is not None:
    vehicles = {}
    for u in demo.get("users", []):
        if "phone" in u: err(f"demo user {u.get('user_id')}: use phone_env_var, never phone")
        for v in u.get("vehicles", []): vehicles[v["vehicle_id"]] = u["user_id"]
        for h in u.get("hosts", []) + u.get("visit_history", []):
            if h["property_id"] not in pids: err(f"demo user {u.get('user_id')}: unknown property {h['property_id']}")
    for s in demo.get("scenarios", []):
        if s.get("property_id") not in pids: err(f"scenario {s.get('id')}: unknown property {s.get('property_id')}")
        if s.get("alternative_property_id") and s["alternative_property_id"] not in pids:
            err(f"scenario {s.get('id')}: unknown alternative property")
        if vehicles.get(s.get("vehicle_id")) != s.get("user_id"):
            err(f"scenario {s.get('id')}: vehicle {s.get('vehicle_id')} does not belong to {s.get('user_id')}")
        code = (s.get("url_params") or {}).get("property")
        if code and code not in codes: err(f"scenario {s.get('id')}: unknown property code {code}")

signs = load("sign_expected.json") if (DATA / "sign_expected.json").exists() else None
if signs is not None:
    for s in signs.get("signs", []):
        if not (DATA / "sample_signs" / s["file"]).exists(): err(f"sign {s['file']} listed but missing in sample_signs/")
    listed = {s["file"] for s in signs.get("signs", [])}
    for f in (DATA / "sample_signs").glob("*.jpg"):
        if f.name not in listed: err(f"sample_signs/{f.name} is not listed in sign_expected.json")
else:
    warn("sign_expected.json not created yet (P1)")

rules_file = ROOT / "mock-portal" / "rules.json"
if rules_file.exists() and props:
    rules = json.loads(rules_file.read_text()).get("properties", {})
    if set(rules) != codes: err("mock-portal/rules.json is stale: run python data/scripts/build_rules.py")
else:
    err("mock-portal/rules.json missing: run python data/scripts/build_rules.py")

for f in list(DATA.rglob("*.json")) + list(DATA.rglob("*.csv")):
    if PHONE_RE.search(f.read_text()): err(f"{f.relative_to(ROOT)} contains something that looks like a real phone number")

for w in warnings: print(f"WARN  {w}")
for e in errors: print(f"ERROR {e}")
print(f"{len(pids)} properties, {len(vendor_ids)} vendors, {len(errors)} errors, {len(warnings)} warnings")
sys.exit(1 if errors else 0)
