import asyncio
import os
import json
import uuid
from datetime import datetime
from typing import List, Dict, Any, Optional
from pydantic import BaseModel
import google.generativeai as genai
from core.rate_limiter import get_gemini_breaker, get_quota_monitor
from core.agent_logger import safe_print


# ── Pydantic models (unchanged from your original) ─────────────────
class ActionDefinition(BaseModel):
    incident_id: str
    action_type: str
    parameters: Dict[str, Any]
    reasoning: str


class ActionPlanOutput(BaseModel):
    actions: List[ActionDefinition]
    reasoning_steps: List[str]


class ActionExecutionResult(BaseModel):
    incident_id: str
    action_type: str
    parameters: Dict[str, Any]
    status: str
    confirmation_id: Optional[str] = None
    timestamp: str
    retry_suggestion: Optional[str] = None
    reasoning: str


def generate_ticket(prefix: str) -> str:
    return f"{prefix}-{str(uuid.uuid4())[:6].upper()}"


class ActionExecutorAgent:
    """
    Agent 4 — Action Executor.
    Takes allocation_plan from ResourceAllocatorAgent.
    Calls Gemini to plan exact actions.
    Executes 4 action types with DETERMINISTIC failure + recovery for demo.
    Integrates with FailureMemory to learn from failures.
    Maintains SYSTEM_STATE for before/after comparison.
    """

    # ── DEMO CONTROL: set to True to trigger failure in rescue dispatch ──
    DEMO_FAILURE_ACTIVE = False
    DEMO_FAILURE_UNIT = "rescue_unit"

    def __init__(self, api_key: str, logger=None, memory=None):
        self.logger = logger
        self.memory = memory          # FailureMemory instance
        self.system_state = {         # Instance variable, not global
            "active_incidents": [],
            "dispatched_resources": {},
            "sent_alerts": [],
            "retracted_alerts": []
        }
        self._already_failed = False  # Ensures failure triggers once per demo
        genai.configure(api_key=api_key)
        self.model = genai.GenerativeModel(
            model_name="gemini-2.0-flash",
            system_instruction="""You are an Action Executor Planner for emergency response.
Given an allocation plan, generate the exact concrete actions needed.
Supported action_types: traffic_reroute, emergency_dispatch, send_public_alert, notify_stakeholder
For each resource in allocation plan: create emergency_dispatch action.
Also generate: relevant public alert, traffic reroute if flood, stakeholder notifications.
Output strictly in JSON schema."""
        )

    def _log(self, msg: str, session_id: str = None, level: str = "INFO"):
        safe_print(f"[ACTION_EXECUTOR] [{level}] {msg}")
        if self.logger:
            self.logger.log("ACTION_EXECUTOR", msg, session_id, level)

    async def execute(
        self,
        allocation_plan: Dict[str, Dict[str, int]],
        session_id: str = None
    ) -> Dict[str, Any]:

        self._log(f"Received allocation for {len(allocation_plan)} incidents.", session_id)

        # Track active incidents
        for inc_id in allocation_plan:
            if inc_id not in self.system_state["active_incidents"]:
                self.system_state["active_incidents"].append(inc_id)

        # Gemini plans concrete actions from allocation
        try:
            breaker = get_gemini_breaker()
            quota   = get_quota_monitor()

            if not breaker.can_proceed():
                self._log("Circuit breaker OPEN — skipping Gemini, using fallback action generation.", session_id)
                raise RuntimeError("Circuit breaker OPEN")

            self._log("Calling Gemini to plan concrete actions...", session_id)
            quota.record_call()
            prompt = (
                f"Allocation Plan:\n{json.dumps(allocation_plan, indent=2)}\n\n"
                "Generate exact actions for emergency response."
            )
            # Run blocking SDK call in thread pool so event loop stays alive
            response = await asyncio.to_thread(
                self.model.generate_content,
                prompt,
                generation_config=genai.GenerationConfig(
                    response_mime_type="application/json",
                    response_schema=ActionPlanOutput,
                    temperature=0.2
                )
            )
            plan_data = json.loads(response.text)
            action_plan = ActionPlanOutput(**plan_data)
            breaker.record_success()

            for step in action_plan.reasoning_steps:
                self._log(f"Reasoning: {step}", session_id)

        except Exception as e:
            get_gemini_breaker().record_failure()
            self._log(f"Gemini error: {e}. Using fallback action generation.", session_id)
            fallback_actions = []
            for inc_id, resources in allocation_plan.items():
                for res_type, count in resources.items():
                    fallback_actions.append(ActionDefinition(
                        incident_id=inc_id,
                        action_type="emergency_dispatch",
                        parameters={"unit_type": res_type, "count": count, "destination": inc_id},
                        reasoning="Fallback dispatch"
                    ))
                fallback_actions.append(ActionDefinition(
                    incident_id=inc_id,
                    action_type="send_public_alert",
                    parameters={"zone": inc_id, "message": "Emergency response dispatched to your area."},
                    reasoning="Fallback alert"
                ))
                fallback_actions.append(ActionDefinition(
                    incident_id=inc_id,
                    action_type="traffic_reroute",
                    parameters={"zone": "G-10", "alternate_route": "Via G-9 Service Road"},
                    reasoning="Fallback reroute"
                ))
            action_plan = ActionPlanOutput(
                actions=fallback_actions, 
                reasoning_steps=[
                    "AI reasoning temporarily unavailable. Using backup analysis engine.",
                    "API fallback"
                ]
            )

        # Execute each action
        results = []
        success_count = 0

        self._log("Executing action plan...", session_id)

        for action in action_plan.actions:
            self._log(f"Executing: {action.action_type} -> {action.incident_id}", session_id)
            sim_result = self._execute_action(action, session_id)

            if sim_result["status"] == "success":
                success_count += 1
                self._log(f"✅ SUCCESS: {action.action_type} | ID: {sim_result.get('confirmation_id')}", session_id)
                # LEARNING: record success in memory
                if self.memory and action.action_type == "emergency_dispatch":
                    unit = action.parameters.get("unit_type", "unknown")
                    self.memory.record_success(unit)

            elif sim_result["status"] == "failed":
                self._log(
                    f"❌ FAILURE: {action.action_type} | Reason: {sim_result.get('retry_suggestion')}",
                    session_id, "WARN"
                )
                # LEARNING: record failure in memory
                if self.memory and action.action_type == "emergency_dispatch":
                    unit = action.parameters.get("unit_type", "unknown")
                    self.memory.record_failure(unit, action.action_type, "dispatch_failed")
                    self._log(
                        f"LEARNING: {unit} reliability -> {self.memory.get_score(unit):.2f}",
                        session_id, "LEARNING"
                    )
                    # RECOVERY: try backup
                    recovery = self._attempt_recovery(action, session_id)
                    if recovery:
                        sim_result = recovery
                        success_count += 1

            result_obj = ActionExecutionResult(
                incident_id=action.incident_id,
                action_type=action.action_type,
                parameters=action.parameters,
                status=sim_result["status"],
                confirmation_id=sim_result.get("confirmation_id"),
                timestamp=sim_result["timestamp"],
                retry_suggestion=sim_result.get("retry_suggestion"),
                reasoning=action.reasoning
            )
            results.append(result_obj.model_dump())

        return {
            "result": {
                "actions_executed": results,
                "total_actions": len(results),
                "success_count": success_count,
                "system_state_snapshot": self.system_state
            },
            "confidence": 0.9,
            "agent_name": "ACTION_EXECUTOR",
            "timestamp": datetime.utcnow().isoformat() + "Z"
        }

    def _execute_action(self, action: ActionDefinition, session_id: str) -> Dict:
        """Execute a single action. Deterministic failure for rescue_unit demo."""

        if action.action_type == "emergency_dispatch":
            unit_type = action.parameters.get("unit_type", "")

            # ── DETERMINISTIC FAILURE (replaces random.random()) ─────────
            # Fails ONCE per demo session for rescue_unit → then recovers
            if (self.DEMO_FAILURE_ACTIVE
                    and unit_type == self.DEMO_FAILURE_UNIT
                    and not self._already_failed):
                self._already_failed = True   # Only fails once
                return {
                    "status": "failed",
                    "confirmation_id": None,
                    "timestamp": datetime.utcnow().isoformat() + "Z",
                    "retry_suggestion": f"Primary {unit_type} unavailable. Deployed to I-8 incident."
                }

            # Success path
            count = action.parameters.get("count", 1)
            dest = action.parameters.get("destination", action.incident_id)
            current = self.system_state["dispatched_resources"].get(unit_type, 0)
            self.system_state["dispatched_resources"][unit_type] = current + count
            return {
                "status": "success",
                "confirmation_id": generate_ticket("DSP"),
                "timestamp": datetime.utcnow().isoformat() + "Z"
            }

        elif action.action_type == "traffic_reroute":
            return {
                "status": "success",
                "confirmation_id": generate_ticket("TRF"),
                "timestamp": datetime.utcnow().isoformat() + "Z"
            }

        elif action.action_type == "send_public_alert":
            alert = {
                "zone": action.parameters.get("zone", action.incident_id),
                "message": action.parameters.get("message", "Emergency alert"),
                "time": datetime.utcnow().isoformat()
            }
            self.system_state["sent_alerts"].append(alert)
            return {
                "status": "success",
                "confirmation_id": generate_ticket("ALT"),
                "timestamp": datetime.utcnow().isoformat() + "Z"
            }

        elif action.action_type == "notify_stakeholder":
            return {
                "status": "success",
                "confirmation_id": generate_ticket("STK"),
                "timestamp": datetime.utcnow().isoformat() + "Z"
            }

        return {
            "status": "failed",
            "confirmation_id": None,
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "retry_suggestion": f"Unknown action type: {action.action_type}"
        }

    def _attempt_recovery(self, failed_action: ActionDefinition, session_id: str) -> Optional[Dict]:
        """Recovery: try backup unit after primary failure."""
        backup_unit = "ambulance"  # Backup for rescue_unit
        self._log(
            f"🔄 RECOVERY: Primary {failed_action.parameters.get('unit_type')} failed. "
            f"Attempting backup: {backup_unit}",
            session_id, "RECOVERY"
        )
        # Simulate backup dispatch success
        self.system_state["dispatched_resources"][backup_unit] = (
            self.system_state["dispatched_resources"].get(backup_unit, 0) + 1
        )
        if self.memory:
            self.memory.record_success(backup_unit)
        self._log(f"✅ RECOVERY SUCCESS: {backup_unit} dispatched as backup.", session_id, "RECOVERY")
        return {
            "status": "recovered",
            "confirmation_id": generate_ticket("RCV"),
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "retry_suggestion": None
        }