"""Builds mock-portal/rules.json from data/properties.json.

The mock portal is static, so it reads property names and guest rules from this
generated file, keyed by property_code. Run after every change to properties.json:
    python data/scripts/build_rules.py
"""
import json, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
props = json.loads((ROOT / "data" / "properties.json").read_text())
rules = {}
for p in props:
    if not p["vendor_id"]:
        continue
    rules[p["property_code"]] = {
        "property_id": p["property_id"],
        "name": p["name"],
        "vendor_id": p["vendor_id"],
        **p["guest_rules"],
    }
out = ROOT / "mock-portal" / "rules.json"
out.write_text(json.dumps({"generated_from": "data/properties.json", "properties": rules}, indent=2) + "\n")
print(f"wrote {len(rules)} property codes to {out}")
