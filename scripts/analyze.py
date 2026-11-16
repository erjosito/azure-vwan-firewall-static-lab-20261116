import json
import ipaddress
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).parent.parent
DESIGNS = ["published-vnet", "published-branch", "separate-untrusted"]
if (ROOT / "raw-output" / "published-vnet-confirmation-untrusted-a-receipts.json").exists():
    DESIGNS.append("published-vnet-confirmation")
ENDPOINTS = {"trusted-a": "10.10.0.4", "trusted-b": "10.20.0.4", "untrusted-a": "10.30.0.4"}


def load(name):
    return json.loads((ROOT / "raw-output" / f"{name}.json").read_text(encoding="utf-8-sig"))


def guest_records(name):
    data = load(name)
    messages = [item["message"] for item in data["value"]]
    return [json.loads(line) for message in messages for line in message.splitlines() if line.startswith("{")]


def route_rows(data):
    if isinstance(data, list):
        return data
    return data.get("value", data.get("effectiveRoutes", []))


def log_rows(data):
    if isinstance(data, list):
        return data
    if "tables" in data:
        return [dict(zip([column["name"] for column in table["columns"]], row))
                for table in data["tables"] for row in table["rows"]]
    return []


def expected_route(design, source, target):
    if not source.startswith("untrusted") and not target.startswith("untrusted"):
        return "bypassed"
    if design == "published-branch" and source.startswith("untrusted"):
        return "bypassed"
    return "required"


logs = log_rows(load("firewall-network-events"))
before = json.loads((ROOT / "predictions-before-azure.json").read_text())
after = json.loads((ROOT / "predictions-after-fix.json").read_text())
summary = {"source": before["source"], "fixedSource": after["source"], "scope": before["scope"],
           "scenarios": [], "firewallLogRows": len(logs)}
for design in DESIGNS:
    probes, receipts, routes = [], [], {}
    for endpoint in ENDPOINTS:
        records = guest_records(f"{design}-{endpoint}-run")
        controls = [record for record in records if record["kind"] == "local-controls"]
        assert len(controls) == 1 and controls[0]["allFourPortsReady"], (design, endpoint, "local controls")
        endpoint_probes = [record for record in records if record["kind"] == "probe"]
        assert len(endpoint_probes) == 8, (design, endpoint, "truncated probe output")
        probes.extend(endpoint_probes)
        receipts.extend(guest_records(f"{design}-{endpoint}-receipts"))
    for table in ["defaultRouteTable", "trusted", "untrusted"]:
        routes[table] = route_rows(load(f"{design}-table-{table}-effective"))
    connections = load(f"{design}-connections")
    evidence = []
    for probe in probes:
        table = "trusted" if not probe["source"].startswith("untrusted") else (
            "untrusted" if design == "separate-untrusted" else "defaultRouteTable")
        connection = next(item for item in connections if item["name"] == f'conn-{probe["source"]}')
        assert connection["routingConfiguration"]["associatedRouteTable"]["id"].endswith("/" + table)
        candidates = [(ipaddress.ip_network(prefix).prefixlen, row)
                      for row in routes[table] for prefix in row["addressPrefixes"]
                      if ipaddress.ip_address(ENDPOINTS[probe["target"]]) in ipaddress.ip_network(prefix)]
        assert candidates, (design, probe["source"], probe["target"], "missing active-table route")
        selected = max(candidates, key=lambda item: item[0])[1]
        observed_route = "required" if selected["nextHopType"] == "Azure Firewall" else "bypassed"
        assert observed_route == expected_route(design, probe["source"], probe["target"])
        receipt = [record for record in receipts if record.get("nonce") == probe["nonce"]
                   and record["endpoint"] == probe["target"]]
        start = datetime.fromisoformat(probe["utc"])
        matching_logs = [row for row in logs if row["SourceIp"] == ENDPOINTS[probe["source"]]
                         and row["DestinationIp"] == ENDPOINTS[probe["target"]]
                         and int(row["SourcePort"]) == probe["sourcePort"]
                         and int(row["DestinationPort"]) == probe["destinationPort"]
                         and row["Protocol"].lower() == probe["protocol"]
                         and start - timedelta(seconds=1)
                         <= datetime.fromisoformat(str(row["TimeGenerated"]).replace("Z", "+00:00"))
                         <= start + timedelta(seconds=5)]
        evidence.append({**probe, "forwardExpected": expected_route(design, probe["source"], probe["target"]),
                         "activeLookupTable": table, "azureSelectedNextHopType": selected["nextHopType"],
                         "forwardGuestReceived": bool(receipt),
                         "observedGuestPeers": [record["remote"] for record in receipt],
                         "sourceTuplePreserved": any(record["remote"] == [ENDPOINTS[probe["source"]], probe["sourcePort"]]
                                                     for record in receipt),
                         "forwardFirewallEvents": matching_logs})
    model_design = "published-vnet" if design == "published-vnet-confirmation" else design
    baseline = [prediction for prediction in before["predictions"] if prediction["design"] == model_design]
    fixed = [prediction for prediction in after["predictions"] if prediction["design"] == model_design]
    assert len(baseline) == len(fixed) == 6
    assert all(item["outcome"] == "satisfied" for prediction in fixed for item in prediction["parity"])
    summary["scenarios"].append({
        "design": design, "probeCount": len(probes), "receiptCount": len(receipts),
        "hubEffectiveRoutes": routes, "probes": evidence,
        "originalModelAssessments": [
            {"source": item["source"], "target": item["destination"], "parity": item["parity"]}
            for item in baseline
        ],
        "fixedModelAssessments": [
            {"source": item["source"], "target": item["destination"], "parity": item["parity"]}
            for item in fixed
        ],
    })
(ROOT / "comparison.json").write_text(json.dumps(summary, indent=2))
for scenario in summary["scenarios"]:
    print(scenario["design"], "probes", scenario["probeCount"], "receipts", scenario["receiptCount"])
    for source in ENDPOINTS:
        for target in ENDPOINTS:
            if source == target:
                continue
            probes = [probe for probe in scenario["probes"] if probe["source"] == source and probe["target"] == target]
            print(source, "->", target, probes[0]["forwardExpected"],
                  "echo", [probe["echo"] for probe in probes],
                  "guest", [probe["forwardGuestReceived"] for probe in probes],
                  "FW", [[row["Action"] for row in probe["forwardFirewallEvents"]] for probe in probes])
print("Firewall events:", len(logs))
