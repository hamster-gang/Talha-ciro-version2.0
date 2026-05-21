"""
main.py — CIRO FastAPI Backend Entry Point.

Stability improvements in this version:
- Global exception handler: unhandled errors return 500 JSON instead of crashing
- /api/citizen-report no longer auto-triggers demo signals on every submission
  (this was causing the infinite reprocessing loop)
- /health is now detailed (includes circuit breaker + quota + cooldown state)
- /api/quota-status: real-time API usage monitoring
- /api/processing-state: current cooldown + deduplication state
- /api/retry-crisis: admin endpoint to force-reset cooldown for a crisis type
"""

import asyncio
import os
from dotenv import load_dotenv

# Load environment variables from .env file before importing agents/orchestrator
load_dotenv()

from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from agents.orchestrator import get_orchestrator
from pydantic import BaseModel
from typing import Optional
from core.storage import save_citizen_report, get_all_citizen_reports, update_report_status
from core.incident_store import get_all_incidents, get_incident_by_id
from core.signal_collector import collect_signals, get_signal_snapshot


# ── Request models ──────────────────────────────────────────────────────────

class CitizenReport(BaseModel):
    description:   str
    location:      str
    incident_type: str
    reporter_name: Optional[str] = None
    lat:           float
    lng:           float

class StatusUpdate(BaseModel):
    status: str

class FeedbackUpdate(BaseModel):
    resolved: bool
    comments: Optional[str] = None

class RetryCrisisRequest(BaseModel):
    crisis_type: str
    location:    Optional[str] = "default"


# ── App lifespan ────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Start autonomous agent loop on server boot. Shut it down cleanly on exit."""
    orch = get_orchestrator()
    # Use the orchestrator's BASE_INTERVAL; interval_seconds arg is the minimum
    task = asyncio.create_task(orch.run_forever(interval_seconds=orch.BASE_INTERVAL))
    yield
    orch.running = False
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass


app = FastAPI(title="CIRO — Crisis Intelligence & Response Orchestrator", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── Global exception handler ────────────────────────────────────────────────

@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    """
    [MAIN] [STEP] Catch-all handler — prevents unhandled exceptions from
    crashing the server process. Returns structured JSON error instead.
    """
    print(f"[MAIN] [ERROR] Unhandled exception on {request.url}: {exc}")
    return JSONResponse(
        status_code=500,
        content={
            "error":     str(exc),
            "path":      str(request.url),
            "message":   "Internal server error. The backend remains operational.",
            "timestamp": __import__("datetime").datetime.utcnow().isoformat() + "Z",
        }
    )


# ── Core status endpoints ────────────────────────────────────────────────────

@app.get("/status")
async def status():
    """Mobile app polls this every few seconds for real-time updates."""
    orch = get_orchestrator()
    return {
        "running":       orch.running,
        "agents_active": orch.running,
        "cycle_count":   orch.cycle_count,
        "latest":        orch.latest_result,
        "memory":        orch.memory.get_all_memory(),
    }


@app.get("/trace")
async def trace():
    """Returns full agent decision trace — shown on Trace screen."""
    orch = get_orchestrator()
    return {"trace": orch.logger.get_recent(50)}


@app.get("/state")
async def system_state():
    """Before/after system state — shown on Comparison screen."""
    orch = get_orchestrator()
    return {"system_state": orch.executor.system_state}


@app.get("/health")
async def health():
    """
    [MAIN] [STEP] Detailed health check — includes circuit breaker, quota,
    cooldown state, and orchestrator status.
    """
    orch    = get_orchestrator()
    breaker = orch.breaker
    quota   = orch.quota
    cooldown = orch.cooldown_mgr

    return {
        "status":            "ok",
        "service":           "ciro",
        "orchestrator": {
            "running":            orch.running,
            "cycle_count":        orch.cycle_count,
            "consecutive_errors": orch._consecutive_errors,
            "pipeline_status":    orch.latest_result.get("status", "unknown"),
        },
        "circuit_breaker":   breaker.status(),
        "quota":             quota.status(),
        "processing_state":  cooldown.status(),
    }


# ── Monitoring / protection endpoints ───────────────────────────────────────

@app.get("/api/quota-status")
async def quota_status():
    """[MAIN] [STEP] Real-time Gemini API quota usage monitoring."""
    orch = get_orchestrator()
    return {
        "quota":           orch.quota.status(),
        "circuit_breaker": orch.breaker.status(),
        "advisory":        "near_quota" if orch.quota.is_near_quota() else "healthy",
    }


@app.get("/api/processing-state")
async def processing_state():
    """[MAIN] [STEP] Current cooldown and signal deduplication state."""
    orch = get_orchestrator()
    return {
        "processing_state": orch.cooldown_mgr.status(),
        "last_signal_hash": orch._last_signal_hash,
        "cycle_count":      orch.cycle_count,
    }


@app.post("/api/retry-crisis")
async def retry_crisis(body: RetryCrisisRequest):
    """
    [MAIN] [STEP] Admin endpoint — force-resets the cooldown for a crisis type
    so the next cycle re-runs the full pipeline.
    This is the ONLY way to reprocess a crisis that's within cooldown.
    """
    orch = get_orchestrator()
    orch.cooldown_mgr.force_reset_cooldown(body.crisis_type, body.location or "default")
    # Also clear the last signal hash so the change-detection gate passes
    orch._last_signal_hash = None
    return {
        "status":      "cooldown_reset",
        "crisis_type": body.crisis_type,
        "message":     f"Cooldown cleared for '{body.crisis_type}'. Next cycle will reprocess.",
    }


# ── Demo / trigger endpoints ─────────────────────────────────────────────────

@app.post("/trigger-demo")
async def trigger_demo():
    """
    [MAIN] [STEP] Loads the demo flood scenario.
    Also resets signal hash so the orchestrator sees the new signals as fresh.
    Call this before starting a demo recording.
    """
    import json
    from datetime import datetime, timezone, timedelta

    now = datetime.now(timezone.utc)

    demo_social = {"posts": [
        {"text": "G-10 mein pani bhar gaya hai! Gaariyan phans gayi!", "timestamp": (now - timedelta(minutes=5)).isoformat(), "location": "G-10"},
        {"text": "Flash flooding G-10 Islamabad. 40+ cars stranded.",   "timestamp": (now - timedelta(minutes=2)).isoformat(), "location": "G-10"},
        {"text": "جی ۱۰ میں سیلاب آ گیا ہے فوری مدد چاہیے",          "timestamp": now.isoformat(),                           "location": "G-10"},
    ]}
    with open("mock_data/social_posts.json", "w") as f:
        json.dump(demo_social, f)

    demo_weather = {
        "temperature_c": 32, "humidity": 85, "condition": "Severe Thunderstorm",
        "alert_level": "RED", "rainfall_mmhr": 120,
        "forecast": {"day": "Tuesday", "rain_type": "Heavy Rain", "probability": 95, "expected_duration_hours": 6}
    }
    with open("mock_data/weather_mock.json", "w") as f:
        json.dump(demo_weather, f)

    demo_traffic = {
        "congestion_segments": [
            {"location": "G-10 Markaz",          "congestion_percent": 95, "avg_speed_kmh": 5},
            {"location": "Kashmir Highway G-10",  "congestion_percent": 80, "avg_speed_kmh": 15},
        ]
    }
    with open("mock_data/traffic_mock.json", "w") as f:
        json.dump(demo_traffic, f)

    # Reset orchestrator state so new signals are treated as fresh
    orch = get_orchestrator()
    orch._last_signal_hash       = None       # Force change detection to pass
    orch.executor._already_failed = False     # Reset failure demo flag
    # Clear flood cooldown so demo can run immediately
    orch.cooldown_mgr.force_reset_cooldown("Urban Flooding")

    # Fire pipeline immediately
    asyncio.create_task(orch.run_pipeline_now())

    return {"status": "Demo scenario loaded. Pipeline triggered immediately."}


@app.post("/api/trigger-mock")
async def trigger_mock():
    """
    [MAIN] [STEP] Load mock signal data and immediately trigger the pipeline.
    Use this to demo the pipeline with social + weather + traffic data
    without needing a citizen report.
    """
    import json
    from datetime import datetime, timezone, timedelta

    now = datetime.now(timezone.utc)

    mock_social = {"posts": [
        {"text": "G-10 mein pani bhar gaya hai! Gaariyan phans gayi!", "timestamp": (now - timedelta(minutes=5)).isoformat(), "location": "G-10"},
        {"text": "Heavy flooding near Kashmir Highway, traffic blocked.", "timestamp": (now - timedelta(minutes=3)).isoformat(), "location": "G-10"},
        {"text": "فوری مدد چاہیے جی ۱۰ مارکز میں پانی بھر گیا",           "timestamp": now.isoformat(), "location": "G-10"},
    ]}
    with open("mock_data/social_posts.json", "w") as f:
        json.dump(mock_social, f)

    mock_weather = {
        "temperature_c": 31, "humidity": 90, "condition": "Severe Thunderstorm",
        "alert_level": "RED", "rainfall_mmhr": 110,
        "forecast": {"day": "Tuesday", "rain_type": "Heavy Rain", "probability": 90, "expected_duration_hours": 4}
    }
    with open("mock_data/weather_mock.json", "w") as f:
        json.dump(mock_weather, f)

    mock_traffic = {
        "congestion_segments": [
            {"location": "G-10 Markaz",         "congestion_percent": 92, "avg_speed_kmh": 8},
            {"location": "Kashmir Highway G-10", "congestion_percent": 78, "avg_speed_kmh": 18},
        ]
    }
    with open("mock_data/traffic_mock.json", "w") as f:
        json.dump(mock_traffic, f)

    # Clear state and trigger pipeline
    orch = get_orchestrator()
    orch.cooldown_mgr.force_clear_all()
    orch._last_signal_hash = None
    orch.executor._already_failed = False

    asyncio.create_task(orch.run_pipeline_now())

    return {
        "status":  "mock_data_loaded",
        "message": "Mock signals loaded and pipeline triggered immediately.",
    }


# ── Citizen report endpoints ─────────────────────────────────────────────────

@app.post("/api/citizen-report")
async def create_citizen_report(report: CitizenReport):
    """
    [MAIN] [STEP] Accept a citizen report and immediately trigger the pipeline.

    Flow:
      1. Save the report to storage
      2. Clear all deduplication hashes so the pipeline sees fresh signals
      3. Fire run_pipeline_now() as a background task for instant processing
    """
    report_id = save_citizen_report(report.model_dump())

    # Reset signal hash so orchestrator sees current signals as "new"
    orch = get_orchestrator()
    orch._last_signal_hash = None
    # Clear processed hashes so the same signals can be reprocessed
    orch.cooldown_mgr.clear_all_hashes()

    # Fire pipeline immediately in background — citizen gets instant feedback
    asyncio.create_task(orch.run_pipeline_now())

    return {
        "report_id": report_id,
        "status":    "pipeline_triggered",
        "message":   "Your report has been received. AI pipeline triggered immediately.",
    }


@app.get("/api/citizen-reports")
async def fetch_citizen_reports():
    return {"reports": get_all_citizen_reports()}


@app.post("/api/update-report-status/{report_id}")
async def update_status(report_id: str, update: StatusUpdate):
    success = update_report_status(report_id, update.status)
    return {"status": "updated" if success else "not found"}


@app.post("/api/citizen-feedback/{report_id}")
async def submit_feedback(report_id: str, feedback: FeedbackUpdate):
    """[MAIN] [STEP] Log citizen feedback after incident resolution."""
    if feedback.resolved:
        update_report_status(report_id, "closed")
    return {"status": "feedback_received", "resolved": feedback.resolved}


# ── Alerts endpoint ──────────────────────────────────────────────────────────

@app.get("/api/alerts")
async def get_alerts():
    orch   = get_orchestrator()
    alerts = []
    if orch.latest_result and "execution" in orch.latest_result:
        exec_res = orch.latest_result["execution"]
        for act in exec_res.get("actions_executed", []):
            if "alert" in act["action_type"].lower() or "dispatch" in act["action_type"].lower():
                alerts.append({
                    "message":   f"System deployed {act['action_type'].replace('_', ' ').upper()}",
                    "severity":  "high",
                    "time_ago":  "Just now",
                })
    if not alerts:
        alerts = []
    return {"alerts": alerts[:10]}


# ── Incident endpoints ───────────────────────────────────────────────────────

@app.get("/api/incidents")
async def fetch_incidents():
    """[MAIN] [STEP] Returns all persisted incidents, newest first."""
    return {"incidents": get_all_incidents()}


@app.get("/api/incidents/{incident_id}/trace")
async def fetch_incident_trace(incident_id: str):
    """[MAIN] [STEP] Returns the reasoning trace for a specific incident."""
    inc = get_incident_by_id(incident_id)
    if not inc:
        raise HTTPException(status_code=404, detail="Incident not found")
    return {"trace": inc.get("reasoning_trace", [])}


@app.get("/api/simulation/{incident_id}")
async def fetch_simulation(incident_id: str):
    """[MAIN] [STEP] Returns before/after simulation data for a specific incident."""
    inc = get_incident_by_id(incident_id)
    if not inc:
        raise HTTPException(status_code=404, detail="Incident not found")
    return inc.get("simulation", {})


# ── Signal / pipeline endpoints ──────────────────────────────────────────────

@app.get("/api/signals")
async def fetch_signals():
    """[MAIN] [STEP] Returns live snapshot of multi-source signals."""
    social, weather, traffic = await collect_signals()
    return get_signal_snapshot(social, weather, traffic)


@app.get("/api/pipeline-status")
async def fetch_pipeline_status():
    """[MAIN] [STEP] Returns current state of the 5-agent pipeline."""
    orch   = get_orchestrator()
    latest = orch.latest_result

    stages = []
    if latest.get("fusion"):          stages.append("SIGNAL_FUSION")
    if latest.get("classification"):  stages.append("CRISIS_CLASSIFIER")
    if latest.get("allocation"):      stages.append("RESOURCE_ALLOCATOR")
    if latest.get("execution"):       stages.append("ACTION_EXECUTOR")
    if latest.get("recovery"):        stages.append("RECOVERY_AGENT")

    return {
        "cycle":             orch.cycle_count,
        "pipeline_stage":    (
            "recovery"   if "RECOVERY_AGENT"    in stages else
            "execution"  if "ACTION_EXECUTOR"   in stages else
            "monitoring"
        ),
        "agents_completed":  stages,
        "timestamp":         latest.get("timestamp") if latest else None,
        "pipeline_status":   latest.get("status", "monitoring"),
    }


@app.get("/api/agent-activity")
async def get_agent_activity():
    """[MAIN] [STEP] Returns real-time agent execution logs for the pipeline screen."""
    orch   = get_orchestrator()
    latest = orch.latest_result
    return {
        "cycle":            orch.cycle_count,
        "agents_active":    orch.running,
        "logs":             orch.logger.get_recent(20),
        "pipeline_stage":   latest.get("status", "monitoring"),
        "last_crisis_type": latest.get("classification", {}).get("crisis_type") if latest else None,
        "last_severity":    latest.get("classification", {}).get("severity")    if latest else None,
    }


@app.get("/api/live-activity")
async def get_live_activity():
    """
    [MAIN] [STEP] Returns structured 10-step execution trace for Live Agent Activity panel.
    Powers the Authorities Command Center → View Pipeline → Live Agent Activity.

    Three-tier lookup (most reliable first):
      Tier 1 — Primary  : most recent incident has stored activity_steps (built at incident save time)
      Tier 2 — Init     : citizen report submitted < 90s ago but pipeline not yet complete
      Tier 3 — Idle     : no recent activity — return pending skeleton
    """
    from core.incident_store import get_all_incidents
    from core.storage import get_all_citizen_reports
    from datetime import datetime, timezone, timedelta

    orch    = get_orchestrator()
    now_utc = datetime.now(timezone.utc)

    def _parse_ts(ts_str: str):
        """Safely parse an ISO timestamp string to timezone-aware datetime."""
        if not ts_str:
            return None
        try:
            return datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        except Exception:
            return None

    # ── Tier 0: live orchestrator state ──────────────────────────────────────
    if orch.live_activity_steps:
        # Check if the pipeline is currently running
        is_running = any(s["status"] == "running" for s in orch.live_activity_steps)
        if is_running or (now_utc - _parse_ts(orch.live_activity_steps[-1]["timestamp"] or now_utc.isoformat())) < timedelta(seconds=15):
            latest = orch.latest_result
            crisis_type = latest.get("classification", {}).get("crisis_type", "Unknown") if latest else "Unknown"
            severity = latest.get("classification", {}).get("severity", 1) if latest else 1
            confidence = latest.get("classification", {}).get("confidence", 0.0) if latest else 0.0
            
            return {
                "session_id":         orch.live_session_id,
                "pipeline_ran":       True,
                "has_citizen_report": True, # Assume true if live
                "steps":              orch.live_activity_steps,
                "cycle":              orch.cycle_count,
                "incident_id":        None,
                "crisis_type":        crisis_type,
                "severity":           severity,
                "confidence":         confidence,
                "timestamp":          now_utc.isoformat() + "Z",
            }

    # ── Tier 2 check: citizen report submitted recently? ─────────────────────
    recent_citizen_report = False
    citizen_report_ts     = None
    try:
        reports = get_all_citizen_reports()   # newest first
        if reports:
            rep_ts = _parse_ts(reports[0].get("timestamp", ""))
            if rep_ts and (now_utc - rep_ts) < timedelta(seconds=90):
                recent_citizen_report = True
                citizen_report_ts     = rep_ts
    except Exception:
        pass

    # ── Tier 1: most recent stored incident with activity_steps ──────────────
    try:
        all_incidents = get_all_incidents()
    except Exception:
        all_incidents = []

    if all_incidents:
        latest_inc     = all_incidents[0]   # newest first
        activity_steps = latest_inc.get("activity_steps")

        # Fallback: build on the fly for legacy incidents (stored before this fix)
        if not activity_steps and latest_inc.get("classification"):
            try:
                from core.incident_store import _build_activity_steps
                activity_steps = _build_activity_steps(latest_inc)
            except Exception:
                pass

        if activity_steps:
            inc_ts = _parse_ts(latest_inc.get("timestamp", ""))

            # If a NEW citizen report arrived AFTER this incident was saved,
            # fall through to Tier 2 (initializing state) instead.
            is_newer_report = (
                recent_citizen_report
                and citizen_report_ts
                and inc_ts
                and citizen_report_ts > inc_ts
            )

            if not is_newer_report:
                return {
                    "session_id":         latest_inc.get("session_id", ""),
                    "pipeline_ran":       True,
                    "has_citizen_report": True,
                    "steps":              activity_steps,
                    "cycle":              latest_inc.get("cycle", 0),
                    "incident_id":        latest_inc.get("incident_id", ""),
                    "crisis_type":        latest_inc.get("crisis_type", "Unknown"),
                    "severity":           latest_inc.get("severity", 1),
                    "confidence":         latest_inc.get("confidence", 0.0),
                    "timestamp":          latest_inc.get("timestamp", ""),
                }

    # ── Tier 2: citizen report submitted, pipeline still initializing ─────────
    if recent_citizen_report:
        init_ts = now_utc.isoformat()
        init_steps = [
            {
                "id": 1, "label": "New Citizen Report Received",
                "agent": "ORCHESTRATOR", "icon": "person_pin",
                "status": "completed", "timestamp": init_ts,
                "summary": "Citizen report received, verified, and queued for AI analysis.",
            },
            {
                "id": 2, "label": "Signal Fusion Agent Consolidating Inputs",
                "agent": "SIGNAL_FUSION", "icon": "hub",
                "status": "running", "timestamp": init_ts,
                "summary": "Fusing cross-source signals: social media, weather, traffic, citizen report...",
            },
        ]
        pending_defs = [
            (3,  "Classification Agent Determining Incident Type",              "CRISIS_CLASSIFIER",  "analytics"),
            (4,  "Severity Assessment Agent Calculating Risk Level",            "CRISIS_CLASSIFIER",  "warning"),
            (5,  "Confidence Scoring Agent Generating Confidence Score",        "CRISIS_CLASSIFIER",  "score"),
            (6,  "Resource Intelligence Agent Identifying Nearby Resources",    "RESOURCE_ALLOCATOR", "local_shipping"),
            (7,  "Dispatch Planning Agent Creating Response Strategy",          "ACTION_EXECUTOR",    "bolt"),
            (8,  "Government Sync Agent Updating the National Command Center",  "INCIDENT_STORE",     "sync"),
            (9,  "Authorities Notified",                                        "ACTION_EXECUTOR",    "campaign"),
            (10, "Emergency Response Initiated",                               "RECOVERY_AGENT",     "verified_user"),
        ]
        for sid, lbl, ag, ic in pending_defs:
            init_steps.append({
                "id": sid, "label": lbl, "agent": ag, "icon": ic,
                "status": "pending", "timestamp": "", "summary": "Awaiting execution",
            })
        return {
            "session_id":         f"cycle_{orch.cycle_count + 1}",
            "pipeline_ran":       True,
            "has_citizen_report": True,
            "steps":              init_steps,
            "cycle":              orch.cycle_count + 1,
            "incident_id":        None,
            "timestamp":          init_ts,
        }

    # ── Tier 3: idle — no recent citizen report, no recent stored incident ────
    latest       = orch.latest_result
    pipeline_ran = bool(latest and latest.get("status") not in ("monitoring", "signals_unchanged", None))
    idle_defs = [
        (1,  "New Citizen Report Received",                                "ORCHESTRATOR",       "person_pin"),
        (2,  "Signal Fusion Agent Consolidating Inputs",                   "SIGNAL_FUSION",      "hub"),
        (3,  "Classification Agent Determining Incident Type",             "CRISIS_CLASSIFIER",  "analytics"),
        (4,  "Severity Assessment Agent Calculating Risk Level",           "CRISIS_CLASSIFIER",  "warning"),
        (5,  "Confidence Scoring Agent Generating Confidence Score",       "CRISIS_CLASSIFIER",  "score"),
        (6,  "Resource Intelligence Agent Identifying Nearby Resources",   "RESOURCE_ALLOCATOR", "local_shipping"),
        (7,  "Dispatch Planning Agent Creating Response Strategy",         "ACTION_EXECUTOR",    "bolt"),
        (8,  "Government Sync Agent Updating the National Command Center", "INCIDENT_STORE",     "sync"),
        (9,  "Authorities Notified",                                       "ACTION_EXECUTOR",    "campaign"),
        (10, "Emergency Response Initiated",                              "RECOVERY_AGENT",     "verified_user"),
    ]
    idle_steps = [
        {
            "id": sid, "label": lbl, "agent": ag, "icon": ic,
            "status": "pending", "timestamp": "",
            "summary": "Awaiting citizen report submission",
        }
        for sid, lbl, ag, ic in idle_defs
    ]
    return {
        "session_id":         None,
        "pipeline_ran":       pipeline_ran,
        "has_citizen_report": False,
        "steps":              idle_steps,
        "cycle":              orch.cycle_count,
        "incident_id":        None,
        "timestamp":          now_utc.isoformat() + "Z",
    }


@app.get("/api/escalated-incidents")
async def get_escalated_incidents():
    """
    [MAIN] [STEP] Returns only validated incidents that meet escalation criteria.
    Escalation threshold: severity >= 3 AND confidence >= 0.65.
    These are auto-promoted to the National Command Center dashboard.
    """
    SEVERITY_THRESHOLD   = 2
    CONFIDENCE_THRESHOLD = 0.50

    all_incidents = get_all_incidents()
    escalated = []

    for inc in all_incidents:
        sev  = inc.get("severity", 0) or 0
        conf = inc.get("confidence", 0.0) or 0.0
        if sev >= SEVERITY_THRESHOLD and conf >= CONFIDENCE_THRESHOLD:
            # Build a clean dashboard-ready payload
            exec_res   = inc.get("execution", {})
            allocation = inc.get("allocation", {})
            actions    = exec_res.get("actions_executed", [])

            dispatched_units  = {}
            alert_messages    = []
            estimated_eta_min = 8

            for act in actions:
                if act.get("action_type") == "emergency_dispatch":
                    unit  = act["parameters"].get("unit_type", "unit")
                    count = act["parameters"].get("count", 1)
                    dispatched_units[unit] = dispatched_units.get(unit, 0) + count
                elif act.get("action_type") == "send_public_alert":
                    alert_messages.append(act["parameters"].get("message", ""))

            escalated.append({
                "incident_id":        inc["incident_id"],
                "incident_type":      inc.get("crisis_type", "Unknown").replace("_", " ").title(),
                "location":           inc.get("location", "Unknown"),
                "severity":           sev,
                "severity_label":     ["", "Minor", "Moderate", "High", "Critical", "Catastrophic"][min(sev, 5)],
                "confidence":         round(conf * 100),
                "confidence_label":   f"{round(conf * 100)}%",
                "status":             inc.get("status", "active"),
                "assigned_agency":    "Rescue 1122",
                "dispatched_units":   dispatched_units,
                "alert_messages":     alert_messages[:2],
                "recommended_actions": allocation.get("reasoning_steps", [])[:3],
                "estimated_eta_min":  estimated_eta_min,
                "timestamp":          inc.get("timestamp", ""),
                "affected_population": inc.get("affected_population", 0),
            })

    return {"escalated_incidents": escalated, "total": len(escalated)}


# ── Location / resource endpoints ────────────────────────────────────────────

@app.get("/api/location-insights")
async def fetch_location_insights(query: str):
    import google.generativeai as genai
    import json

    genai.configure(api_key=os.getenv("GEMINI_API_KEY"))
    model = genai.GenerativeModel("gemini-2.0-flash")
    prompt = f"""You are CIRO's geographical intelligence agent.
Analyze the location: {query}.
Provide a JSON response with:
1. "location_name": standard name
2. "district": district/province
3. "past_crises": list of objects {{"type": "...", "year": "YYYY", "losses": "..."}}
4. "upcoming_risks": list of strings (e.g. "Monsoon flooding expected next month")
5. "prevention_plan": paragraph on how to handle next time based on past failures.
Output ONLY valid JSON."""

    try:
        # Check circuit breaker before calling
        orch = get_orchestrator()
        if not orch.breaker.can_proceed():
            raise RuntimeError("Circuit breaker OPEN")
        orch.quota.record_call()
        response = model.generate_content(
            prompt,
            generation_config=genai.GenerationConfig(response_mime_type="application/json")
        )
        orch.breaker.record_success()
        return json.loads(response.text)
    except Exception as e:
        return {
            "location_name":   query.title(),
            "district":        "Standard Output",
            "past_crises":     [{"type": "Urban Flooding", "year": "2022", "losses": "Infrastructure damage"}],
            "upcoming_risks":  ["Moderate risk of isolated storms", "Traffic congestion expected"],
            "prevention_plan": "Monitor official CIRO channels for updates. Secure loose items and prepare emergency kits."
        }


@app.get("/api/nearby-resources")
async def get_nearby_resources(
    lat: float = 33.6844, lng: float = 73.0479, radius_km: float = 10.0
):
    """[MAIN] [STEP] Returns nearest emergency facilities for a given location."""
    from core.nearby_resources import fetch_nearby_resources
    result = await fetch_nearby_resources(lat, lng, int(radius_km * 1000))
    return result