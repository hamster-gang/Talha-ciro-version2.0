---

# CIRO — Crisis Intelligence & Response Orchestrator

> Built for Google AI Seekho Hackathon 2026 — Challenge 3

CIRO is an autonomous agentic AI system that detects urban crises in real time, reasons through multi-source signals, allocates emergency resources, and simulates coordinated response actions. The system is designed to run continuously with safety controls (deduplication, cooldowns, circuit breaker, and quota monitoring) and expose a clean API for mobile and web clients.

---

## Overview

CIRO connects three layers:

1. **Signals layer** (social, weather, traffic, citizen reports)
2. **Agentic pipeline** (fusion → classification → allocation → execution → recovery)
3. **Experience layer** (Flutter mobile dashboards for citizens and authorities)

The backend runs an autonomous loop and only triggers a full pipeline run when signals change and cooldown rules allow. Each pipeline run generates structured artifacts (actions, simulation diff, activity timeline) that the frontend renders.

---

## Architecture (High-Level)

**Backend (FastAPI)**
- Orchestrator manages the full agent pipeline and loop.
- Incident store persists completed runs and produces live activity traces.
- Status endpoints power dashboards and metrics.

**Mobile (Flutter)**
- Citizen Safety Center for reporting and tracking incidents.
- Authorities Command Center for live incidents, trace, and simulation.
- Pipeline and trace panels for agent activity visibility.

---

## Agents Developed

1. **Signal Fusion Agent**
	- Inputs: social posts, weather, traffic
	- Output: unified signal + anomaly detection
	- Includes heuristic fallback when AI calls are unavailable

2. **Crisis Classifier Agent**
	- Classifies crisis type, severity, affected radius/population
	- Detects conflicts between signals
	- Produces a decision: proceed vs monitor

3. **Resource Allocator Agent**
	- Assigns resource units by incident type and severity
	- Produces a structured allocation plan

4. **Action Executor Agent**
	- Converts allocation plan into concrete actions
	- Executes actions (dispatch, alert, reroute, notify)
	- Records outcomes for simulation and audit

5. **Recovery Agent**
	- Verifies incident outcome after a delay
	- Updates incident state and produces lessons learned

---

## Mock vs Real APIs

**Mock/Simulated**
- Social, weather, and traffic signals are loaded from mocked sources in the backend.
- Demo triggers populate signals for repeatable testing.

**Real/External**
- **Gemini** for LLM reasoning and agent outputs.
- **Google Maps Static API** for map preview on the authorities dashboard (optional, controlled by API key).

---

## API Surface (Backend)

Core endpoints exposed by the backend:

- `GET /status` — real-time orchestrator status and latest pipeline result
- `GET /trace` — recent agent trace logs
- `GET /health` — health with circuit breaker/quota/cooldown state
- `POST /api/citizen-report` — submit a citizen incident report
- `GET /api/citizen-reports` — list citizen reports
- `POST /api/citizen-feedback/{report_id}` — feedback on a report
- `GET /api/incidents` — persisted incidents
- `GET /api/incidents/{incident_id}/trace` — reasoning trace for an incident
- `GET /api/simulation/{incident_id}` — before/after simulation view
- `GET /api/pipeline-status` — pipeline stage for the workflow screen
- `GET /api/live-activity` — 10-step structured activity trace
- `GET /api/escalated-incidents` — escalated incidents summary
- `POST /trigger-demo` — demo signal injection

---

## Integrations

- **Flutter ↔ FastAPI**: REST integration, polling for live updates
- **Gemini**: used in Signal Fusion, Crisis Classification, Resource Allocation, and Action Execution
- **Android GPS**: optional geolocation for citizen reporting (runtime permission)

---

## Build & Deployment Notes

- **Mobile APK** can be built via GitHub Actions workflow:
  - Action: `Build Android APK`
  - Artifact: `app-release.apk`

- **Environment variables**
  - `GEMINI_API_KEY` (backend)
  - `GOOGLE_API_KEY` (optional; fallback name for Gemini)
  - `API_BASE_URL` (mobile, injected into `.env` at build time)

---

## Tech Stack

- **Backend**: FastAPI (Python)
- **Mobile**: Flutter
- **AI Models**: Gemini 2.0 Flash (primary)
- **Architecture**: Modular agent pipeline with safety controls
