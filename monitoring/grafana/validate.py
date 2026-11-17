"""Validate NOVA Grafana templates without cloud access."""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parent
manifest = json.loads((ROOT / "manifest.json").read_text())
contract = json.loads((ROOT / "collector-contract.json").read_text())
assert len(manifest["dashboards"]) == 30
assert sum(d["requirements"] for d in manifest["dashboards"]) == 506
assert len(list((ROOT / "dashboards").rglob("*.json"))) == 30
uids = set()
for d in manifest["dashboards"]:
    data = json.loads((ROOT / d["path"]).read_text())
    assert data["uid"] == d["uid"] and data["uid"] not in uids
    uids.add(data["uid"])
    panels = data["panels"]
    assert len(panels) == d["panels"]
    assert len({p["id"] for p in panels}) == len(panels)
    for i, p in enumerate(panels):
        a = p["gridPos"]
        assert 0 <= a["x"] and a["x"] + a["w"] <= 24 and a["h"] > 0
        for q in panels[i+1:]:
            b = q["gridPos"]
            assert not (a["x"] < b["x"] + b["w"] and b["x"] < a["x"] + a["w"] and a["y"] < b["y"] + b["h"] and b["y"] < a["y"] + a["h"])
        if p["type"] != "text":
            assert p["datasource"]["uid"] in {"nova-cloudwatch", "nova-zabbix"}
            assert p["targets"]
    assert sum(p["title"].startswith("PENDENTE |") for p in panels) == d["zabbixPending"]
    assert sum(p.get("datasource", {}).get("uid") == "nova-cloudwatch" for p in panels) == d["cloudwatch"]
assert len(contract["items"]) == manifest["totals"]["zabbixPending"]
assert len({(i["host"], i["key"]) for i in contract["items"]}) == len(contract["items"])
assert sum(d["panels"] for d in manifest["dashboards"]) == manifest["totals"]["panels"]
print("PASS: 30 dashboards, 506 requirements; structure and collector contract.")
