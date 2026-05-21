"""
orchestrator.py — Master autonomous agent for CIRO.

Connects all 5 agents in sequence:
  SignalFusion → CrisisClassifier → ResourceAllocator → ActionExecutor → RecoveryAgent

Stability guarantees added in this version:
1. Signal hash deduplication — same signals never trigger a new Gemini call
2. Crisis cooldown — same crisis type cannot be reprocessed within COOLDOWN_SECONDS
3. Circuit breaker integration — Gemini failures stop the loop, not crash it
4. Exponential backoff — errors in a cycle increase the wait before the next retry
5. Global exception handling — any uncaught error keeps the loop alive

Log format: [ORCHESTRATOR] [STEP] message
"""

import asyncio
import os
from datetime import datetime, timezone
from typing import Optional


class FauranOrchestrator:
    """
    Master autonomous agent. Connects all 5 agents in sequence.
    Runs on server boot. Stops polling when signals are unchanged.

    Flow per cycle (only when signals change AND no cooldown active):
    SignalFusion → CrisisClassifier → ResourceAllocator → ActionExecutor → (RecoveryAgent after 60s)
    """

    BASE_INTERVAL    = 10   # seconds between cycles (was 5 — reduced API pressure)
    MAX_BACKOFF      = 300  # max seconds to back off on repeated errors
    IDLE_INTERVAL    = 30   # seconds to wait when no anomaly detected

    def __init__(self):
        api_key = os.environ.get("GEMINI_API_KEY", os.environ.get("GOOGLE_API_KEY", ""))

        # Shared support modules
        from core.agent_logger    import AgentLogger
        from core.failure_memory  import FailureMemory
        from core.rate_limiter    import get_gemini_breaker, get_quota_monitor, get_signal_hasher
        from core.processing_state import get_cooldown_manager

        self.logger  = AgentLogger()
        self.memory  = FailureMemory()
        self.breaker = get_gemini_breaker()
        self.quota   = get_quota_monitor()
        self.hasher  = get_signal_hasher()
        self.cooldown_mgr = get_cooldown_manager()

        # All 5 agents — created ONCE, reused every cycle
        from agents.signal_fusion     import SignalFusionAgent
        from agents.crisis_classifier import CrisisClassifierAgent
        from agents.resource_allocator import ResourceAllocatorAgent
        from agents.action_executor   import ActionExecutorAgent
        from agents.recovery_agent    import RecoveryAgent

        self.signal_fusion = SignalFusionAgent(api_key, self.logger)
        self.classifier    = CrisisClassifierAgent(api_key, self.logger)
        self.allocator     = ResourceAllocatorAgent(api_key, self.logger)
        self.executor      = ActionExecutorAgent(api_key, self.logger, self.memory)
        self.recovery      = RecoveryAgent(api_key, self.logger)

        self.cycle_count     = 0
        self.running         = False
        self.latest_result   = {}         # Mobile app reads this
        self._last_signal_hash: Optional[str] = None   # For change detection
        self._consecutive_errors = 0      # For exponential backoff
        self.live_activity_steps = []
        self.live_session_id = None

    # ── Public: autonomous loop ─────────────────────────────────────────────

    async def run_forever(self, interval_seconds: int = None):
        """
        THE AUTONOMOUS LOOP.
        Starts on server boot. Runs continuously but only triggers the full
        agent pipeline when:
          - Signals have changed since last cycle (hash comparison), AND
          - No cooldown is active for the detected crisis type.
        """
        if interval_seconds is None:
            interval_seconds = self.BASE_INTERVAL

        self.running = True
        try:
            self.logger.log("ORCHESTRATOR",
                f"CIRO autonomous monitoring started. "
                f"Base interval: {interval_seconds}s. "
                f"Cooldown: {self.cooldown_mgr.COOLDOWN_SECONDS}s per crisis type.")
        except Exception as e:
            print(f"[ORCHESTRATOR] [WARN] Logger startup message failed: {e}")

        while self.running:
            self.cycle_count += 1
            session_id = f"cycle_{self.cycle_count}"

            try:
                wait = await self._run_cycle(session_id)
            except Exception as e:
                # Keep the loop alive no matter what
                self._consecutive_errors += 1
                backoff = min(self.BASE_INTERVAL * (2 ** self._consecutive_errors), self.MAX_BACKOFF)
                print(f"[ORCHESTRATOR] [WARN] Cycle {self.cycle_count} error: {e}. Backoff {backoff}s.")
                try:
                    self.logger.log("ORCHESTRATOR",
                        f"Cycle {self.cycle_count} error: {type(e).__name__}: {e}. "
                        f"Consecutive errors: {self._consecutive_errors}. Backing off {backoff}s.",
                        session_id, "WARN")
                except Exception:
                    pass
                await asyncio.sleep(backoff)
                continue

            self._consecutive_errors = 0
            try:
                self.logger.log("ORCHESTRATOR",
                    f"Cycle {self.cycle_count} complete. Next scan in {wait}s.")
            except Exception:
                pass
            await asyncio.sleep(wait)

    # ── Internal: single cycle ──────────────────────────────────────────────

    def _init_live_steps(self):
        now = datetime.now(timezone.utc).isoformat()
        defs = [
            (1, "New Citizen Report Received", "ORCHESTRATOR", "person_pin"),
            (2, "Signal Fusion Agent Consolidating Inputs", "SIGNAL_FUSION", "hub"),
            (3, "Classification Agent Determining Incident Type", "CRISIS_CLASSIFIER", "analytics"),
            (4, "Severity Assessment Agent Calculating Risk Level", "CRISIS_CLASSIFIER", "warning"),
            (5, "Confidence Scoring Agent Generating Confidence Score", "CRISIS_CLASSIFIER", "score"),
            (6, "Resource Intelligence Agent Identifying Nearby Resources", "RESOURCE_ALLOCATOR", "local_shipping"),
            (7, "Dispatch Planning Agent Creating Response Strategy", "ACTION_EXECUTOR", "bolt"),
            (8, "Government Sync Agent Updating Command Center", "INCIDENT_STORE", "sync"),
            (9, "Authorities Notified", "ACTION_EXECUTOR", "campaign"),
            (10, "Emergency Response Initiated", "RECOVERY_AGENT", "verified_user"),
        ]
        self.live_activity_steps = [
            {
                "id": sid, "label": lbl, "agent": ag, "icon": ic,
                "status": "pending", "timestamp": "", "summary": "Awaiting execution"
            } for sid, lbl, ag, ic in defs
        ]

    def _update_live_step(self, step_id: int, status: str, summary: str = None):
        if not self.live_activity_steps:
            return
        now = datetime.now(timezone.utc).isoformat()
        for step in self.live_activity_steps:
            if step["id"] == step_id:
                step["status"] = status
                step["timestamp"] = now
                if summary:
                    step["summary"] = summary

    async def _run_cycle(self, session_id: str) -> int:
        """
        Run one monitoring cycle.
        Returns the number of seconds to wait before the next cycle.
        """
        from core.signal_collector import collect_signals
        social, weather, traffic = await collect_signals()

        self.logger.log("ORCHESTRATOR",
            f"Cycle {self.cycle_count}: {len(social)} social posts, "
            f"weather={weather.get('alert_level','?')}, "
            f"traffic_max={max((s.get('congestion_percent',0) for s in traffic.get('congestion_segments',[])), default=0)}%",
            session_id)

        # ── GATE 1: Signal change detection ──────────────────────────────
        # Skip full pipeline if signals haven't changed since last cycle.
        # CRITICAL: Do NOT reset live_activity_steps here — idle cycles
        # must not wipe out the completed steps from the previous run.
        current_hash = self.hasher.hash_signals(social, weather, traffic)

        if current_hash == self._last_signal_hash:
            self.logger.log("ORCHESTRATOR",
                f"[STEP] Signals unchanged (hash={current_hash[:8]}…). "
                f"Skipping Gemini pipeline. Monitoring idle.",
                session_id)
            self.latest_result = {"status": "monitoring", "cycle": self.cycle_count,
                                   "note": "signals_unchanged"}
            return self.IDLE_INTERVAL   # Wait longer when idle

        # ── GATE 2: Circuit breaker check ────────────────────────────────
        if not self.breaker.can_proceed():
            self.logger.log("ORCHESTRATOR",
                f"[STEP] Circuit breaker OPEN — skipping Gemini pipeline. "
                f"State: {self.breaker.status()}",
                session_id, "WARN")
            self.latest_result = {"status": "circuit_open", "cycle": self.cycle_count,
                                   "breaker": self.breaker.status()}
            return self.BASE_INTERVAL

        # ── GATE 3: Duplicate signal check ───────────────────────────────
        existing_incident = self.cooldown_mgr.is_duplicate_signal(current_hash)
        if existing_incident:
            self.logger.log("ORCHESTRATOR",
                f"[STEP] Duplicate signal hash -> incident {existing_incident} already processed. "
                f"Skipping pipeline.",
                session_id)
            self._last_signal_hash = current_hash
            return self.IDLE_INTERVAL

        # Signals are new — remember this hash
        self._last_signal_hash = current_hash

        # ── Pipeline is actually going to run — initialise live steps NOW ──
        # Done HERE (after all gates) so idle cycles never wipe out the
        # completed steps from the previous pipeline run.
        self.live_session_id = session_id
        self._init_live_steps()

        has_citizen_report = any("[CITIZEN REPORT]" in p for p in social)
        if has_citizen_report:
            self.logger.log("ORCHESTRATOR", "[STEP] New citizen report received and verified. Initiating pipeline.", session_id)
            self._update_live_step(1, "completed", "Citizen report received, verified, and queued for AI analysis.")
        else:
            self._update_live_step(1, "completed", "Anomaly detected via automated signals.")

        # ── AGENT 1: Signal Fusion ────────────────────────────────────────
        self._update_live_step(2, "running", "Fusing cross-source signals: social media, weather, traffic...")
        fusion = await self.signal_fusion.analyze(social, weather, traffic, session_id)
        self._update_live_step(2, "completed", f"Signals fused. Anomaly: {fusion['detected_anomaly']}")
        self._update_all_active_reports("under_review")

        if not fusion["detected_anomaly"]:
            self.logger.log("ORCHESTRATOR",
                f"No anomaly detected (confidence={fusion['confidence']:.2f}). Monitoring.",
                session_id)
            self.latest_result = {"status": "monitoring", "cycle": self.cycle_count}
            return self.IDLE_INTERVAL

        # ── GATE 4: Crisis type cooldown check ───────────────────────────
        # We don't know the crisis type yet (classifier hasn't run), so we
        # run the classifier first, then check cooldown before heavy actions.

        # ── AGENT 2: Crisis Classifier ────────────────────────────────────
        self._update_live_step(3, "running", "Analyzing signals to determine incident type...")
        self._update_live_step(4, "running", "Calculating risk and severity levels...")
        self._update_live_step(5, "running", "Scoring confidence of multi-source signals...")
        
        classifier_output = await self.classifier.classify(
            fusion["unified_signal"], session_id
        )

        if not classifier_output["proceed_with_response"]:
            self.logger.log("ORCHESTRATOR",
                f"Classifier decision: {classifier_output['decision']}. Not proceeding.",
                session_id)
            self._update_live_step(3, "completed", f"Classified as non-critical: {classifier_output['decision']}")
            return self.BASE_INTERVAL

        classification = classifier_output["classification"]
        crisis_type    = classification.get("crisis_type", "Unknown")
        self._update_live_step(3, "completed", f"Incident classified as: {crisis_type}")
        self._update_live_step(4, "completed", f"Severity assessed: Level {classification.get('severity')}")
        self._update_live_step(5, "completed", f"Confidence scored: {classification.get('confidence')}")

        # ── GATE 5: Cooldown check per crisis type ────────────────────────
        if self.cooldown_mgr.is_on_cooldown(crisis_type):
            # Already processed this type recently — update result but skip pipeline
            self.latest_result = {
                "status":      "cooldown_active",
                "cycle":        self.cycle_count,
                "crisis_type":  crisis_type,
                "cooldown":     self.cooldown_mgr.status(),
            }
            return self.BASE_INTERVAL

        incident_id = f"INC-{crisis_type.upper()[:3]}-{self.cycle_count:03d}"

        # ── AGENT 3: Resource Allocator ───────────────────────────────────
        self._update_live_step(6, "running", "Identifying nearest emergency resources...")
        allocation = await self.allocator.allocate(classification, incident_id, session_id)
        self._update_live_step(6, "completed", "Resources identified and assigned.")

        # ── AGENT 4: Action Executor ──────────────────────────────────────
        self._update_live_step(7, "running", "Generating response strategy...")
        self._update_live_step(9, "running", "Notifying relevant authorities...")
        
        execution = await self.executor.execute(
            allocation["allocation_plan"],
            session_id
        )
        self._update_live_step(7, "completed", "Response strategy generated.")
        self._update_live_step(9, "completed", "Authorities notified.")
        self._update_all_active_reports("dispatched")

        # Store result for mobile app
        self.latest_result = {
            "status":              "crisis_active",
            "cycle":               self.cycle_count,
            "session_id":          session_id,
            "fusion":              fusion,
            "classification":      classification,
            "classifier_decision": classifier_output["decision"],
            "allocation":          allocation,
            "execution":           execution["result"],
            "memory_state":        self.memory.get_all_memory(),
            "timestamp":           datetime.now(timezone.utc).isoformat(),
        }

        # ── Record cooldown to prevent reprocessing ───────────────────────
        # CRITICAL: do this BEFORE saving the incident so any concurrent
        # cycles see the cooldown and skip immediately.
        self.cooldown_mgr.record_processed(
            crisis_type=crisis_type,
            signal_hash=current_hash,
            incident_id=incident_id,
        )

        # Removed legacy auto-update call in favor of real-time updates above

        # ── PERSISTENCE: Save completed incident ──────────────────────────
        from core.incident_store import save_incident
        self._update_live_step(8, "running", "Syncing to National Command Center...")
        saved_id = save_incident(self.latest_result)
        self.logger.log("ORCHESTRATOR", f"[STEP] Incident saved: {saved_id}", session_id)
        self._update_live_step(8, "completed", "Synced to National Command Center.")
        self._update_live_step(10, "completed", "Emergency response fully initiated.")

        # ── AGENT 5: Recovery Agent (runs after 15s in background for demo) ──
        asyncio.create_task(
            self._run_recovery_after_delay(saved_id, classification, execution, session_id, delay=15)
        )

        return self.BASE_INTERVAL

    # ── Internal helpers ────────────────────────────────────────────────────

    def _update_all_active_reports(self, status: str, metadata: dict = None):
        """
        [ORCHESTRATOR] [STEP] Push real-time status update to all active citizen reports.
        """
        from core.storage import get_all_citizen_reports, update_report_status

        TERMINAL_STATES = {"resolved", "closed", "archived"}

        for rep in get_all_citizen_reports():
            current = rep.get("status", "submitted")
            # NEVER re-process reports that have reached a terminal state
            if current in TERMINAL_STATES:
                continue
            update_report_status(rep["report_id"], status, metadata)

    async def _run_recovery_after_delay(
        self, incident_id: str, classification: dict,
        execution: dict, session_id: str, delay: int = 60
    ):
        """
        [ORCHESTRATOR] [STEP] Recovery agent runs after delay — simulates field report.
        Runs as background task; does NOT block the main cycle.
        """
        await asyncio.sleep(delay)

        field_report = (
            "Field team arrived at G-10 sector. "
            "Confirmed: No actual flooding. Water source is a burst municipal water main on G-10/3. "
            "Street-level water drainage is overwhelmed. No risk of further flooding. "
            "Recommends immediate retraction of flood alert."
        )

        try:
            from agents.crisis_classifier import CrisisClassification
            original = CrisisClassification(**classification)

            recovery_output = await self.recovery.verify(
                incident_id=incident_id,
                original_classification=original,
                field_report=field_report,
                alerts_sent=self.executor.system_state.get("sent_alerts", []),
                system_state=self.executor.system_state,
                session_id=f"{session_id}_recovery"
            )

            self.latest_result["recovery"] = recovery_output
            self.logger.log("ORCHESTRATOR",
                f"[STEP] Recovery complete: DECISION={recovery_output['decision'].upper()}",
                f"{session_id}_recovery")

            # Persist recovery decision
            from core.incident_store import update_incident_recovery
            update_incident_recovery(incident_id, recovery_output)

            # Advance reports to final stages
            from core.storage import get_all_citizen_reports, update_report_status
            TERMINAL_STATES = {"resolved", "closed", "archived"}

            for rep in get_all_citizen_reports():
                current = rep.get("status", "submitted")
                if current in TERMINAL_STATES:
                    continue
                if current == "assigned":
                    update_report_status(rep["report_id"], "dispatched",
                        metadata={"authority_notes": "Emergency units dispatched and en route"})
                elif current == "dispatched":
                    update_report_status(rep["report_id"], "in_progress",
                        metadata={"authority_notes": "Responders on scene"})
                elif current in ["in_progress", "responding"]:
                    update_report_status(rep["report_id"], "resolved",
                        metadata={"authority_notes": "Incident resolved. Thank you for your report."})

        except Exception as e:
            self.logger.log("ORCHESTRATOR",
                f"[STEP] Recovery agent error for {incident_id}: {e}. "
                f"Incident remains active.",
                f"{session_id}_recovery", "WARN")

    # ── Public: direct pipeline trigger ────────────────────────────────────

    async def run_pipeline_now(self) -> dict:
        """
        [ORCHESTRATOR] [STEP] Force-run the pipeline immediately.
        Clears all deduplication state, force-closes the circuit breaker,
        and runs a single cycle. Called from /api/citizen-report and
        /api/trigger-mock so the user sees instant results.

        Returns the latest_result dict after the cycle completes.
        """
        print("[ORCHESTRATOR] [STEP] run_pipeline_now() — force-triggering pipeline.")

        # 1. Clear all deduplication / cooldown gates
        self.cooldown_mgr.force_clear_all()
        self._last_signal_hash = None
        self._consecutive_errors = 0

        # 2. Force-close circuit breaker so Gemini calls go through
        self.breaker.force_close()

        # 3. Reset executor demo failure flag
        self.executor._already_failed = False

        # 4. Run one cycle synchronously (awaited)
        self.cycle_count += 1
        session_id = f"direct_{self.cycle_count}"
        try:
            await self._run_cycle(session_id)
        except Exception as e:
            print(f"[ORCHESTRATOR] [WARN] run_pipeline_now cycle error: {e}")
            self.latest_result["error"] = str(e)

        return self.latest_result


# ── Singleton ──────────────────────────────────────────────────────────────────

_orchestrator: Optional[FauranOrchestrator] = None


def get_orchestrator() -> FauranOrchestrator:
    global _orchestrator
    if _orchestrator is None:
        _orchestrator = FauranOrchestrator()
    return _orchestrator