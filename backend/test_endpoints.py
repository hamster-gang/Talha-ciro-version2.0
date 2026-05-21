"""test_endpoints.py — Quick end-to-end verification for CIRO pipeline."""
import urllib.request
import json
import time

BASE = "http://localhost:8000"

def get(path):
    try:
        with urllib.request.urlopen(BASE + path, timeout=8) as r:
            return json.loads(r.read())
    except Exception as e:
        return {"error": str(e)}

def post(path):
    try:
        req = urllib.request.Request(BASE + path, data=b"{}", method="POST",
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=8) as r:
            return json.loads(r.read())
    except Exception as e:
        return {"error": str(e)}


print("\n" + "="*60)
print("CIRO END-TO-END VERIFICATION")
print("="*60)

# ── 1. Health check ──────────────────────────────────────────
print("\n[1] GET /health")
h = get("/health")
orch = h.get("orchestrator", {})
breaker = h.get("circuit_breaker", {})
print(f"  running     : {orch.get('running')}")
print(f"  cycle_count : {orch.get('cycle_count')}")
print(f"  pipeline    : {orch.get('pipeline_status')}")
print(f"  breaker     : {breaker.get('state')}")

# ── 2. Trigger mock ─────────────────────────────────────────
print("\n[2] POST /api/trigger-mock")
tm = post("/api/trigger-mock")
print(f"  status : {tm.get('status')}")
print(f"  message: {tm.get('message')}")
time.sleep(5)  # Give pipeline time to run

# ── 3. Check health again ────────────────────────────────────
print("\n[3] GET /health (after trigger)")
h2 = get("/health")
orch2 = h2.get("orchestrator", {})
print(f"  cycle_count : {orch2.get('cycle_count')}")
print(f"  pipeline    : {orch2.get('pipeline_status')}")

# ── 4. Incidents ─────────────────────────────────────────────
print("\n[4] GET /api/incidents")
inc = get("/api/incidents")
incidents = inc.get("incidents", [])
print(f"  total incidents: {len(incidents)}")
if incidents:
    i = incidents[0]
    print(f"  latest id      : {i.get('incident_id')}")
    print(f"  crisis_type    : {i.get('crisis_type')}")
    print(f"  severity       : {i.get('severity')}")
    print(f"  confidence     : {i.get('confidence')}")
    print(f"  status         : {i.get('status')}")
    has_steps = bool(i.get("activity_steps"))
    print(f"  activity_steps : {'YES (' + str(len(i.get('activity_steps',[]))) + ' steps)' if has_steps else 'NO'}")

# ── 5. Escalated incidents ────────────────────────────────────
print("\n[5] GET /api/escalated-incidents")
esc = get("/api/escalated-incidents")
total_esc = esc.get("total", 0)
print(f"  escalated total: {total_esc}")
if esc.get("escalated_incidents"):
    e = esc["escalated_incidents"][0]
    print(f"  id             : {e.get('incident_id')}")
    print(f"  type           : {e.get('incident_type')}")
    print(f"  severity       : {e.get('severity')}")
    print(f"  confidence     : {e.get('confidence_label')}")

# ── 6. Live activity ─────────────────────────────────────────
print("\n[6] GET /api/live-activity")
la = get("/api/live-activity")
steps = la.get("steps", [])
completed = sum(1 for s in steps if s.get("status") == "completed")
running   = sum(1 for s in steps if s.get("status") == "running")
pending   = sum(1 for s in steps if s.get("status") == "pending")
print(f"  pipeline_ran  : {la.get('pipeline_ran')}")
print(f"  session_id    : {la.get('session_id')}")
print(f"  incident_id   : {la.get('incident_id')}")
print(f"  steps         : {completed} completed / {running} running / {pending} pending")
for s in steps:
    icon = {"completed": "✅", "running": "🔄", "pending": "⏳"}.get(s["status"], "?")
    print(f"    {icon} {s['id']:2d}. {s['label'][:55]}")

# ── 7. Pipeline status ───────────────────────────────────────
print("\n[7] GET /api/pipeline-status")
ps = get("/api/pipeline-status")
print(f"  pipeline_stage  : {ps.get('pipeline_stage')}")
print(f"  agents_completed: {ps.get('agents_completed')}")
print(f"  pipeline_status : {ps.get('pipeline_status')}")

print("\n" + "="*60)
print("VERIFICATION COMPLETE")
print("="*60)
