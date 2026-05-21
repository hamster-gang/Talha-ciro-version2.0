import asyncio
import os
import json
from datetime import datetime
from typing import List, Dict, Any, Optional
from pydantic import BaseModel
import google.generativeai as genai
from agents.crisis_classifier import CrisisClassification
from core.rate_limiter import get_gemini_breaker, get_quota_monitor
from core.agent_logger import safe_print


class RetractionMessage(BaseModel):
    stakeholder_type: str
    message: str


class RecoveryResult(BaseModel):
    decision: str                                    # confirm | reclassify | retract
    updated_classification: Optional[CrisisClassification] = None
    retraction_messages: List[RetractionMessage]
    reasoning_steps: List[str]


class RecoveryAgent:
    """
    Agent 5 — Recovery and Verification.
    Triggered when field report arrives (simulated ~60s after initial response).
    Compares field report vs original classification.
    Makes autonomous decision: CONFIRM, RECLASSIFY, or RETRACT.
    If RETRACT: generates retraction messages for each stakeholder.
    Updates SYSTEM_STATE to reflect corrected reality.
    
    THIS IS YOUR SECRET WEAPON — no other team has this agent.
    """

    def __init__(self, api_key: str, logger=None):
        self.logger = logger
        genai.configure(api_key=api_key)
        self.model = genai.GenerativeModel(
            model_name="gemini-2.0-flash",
            system_instruction="""You are a Recovery and Verification Agent for emergency response.
You receive the original crisis classification, a field report from teams on the ground,
and a list of alerts already sent to the public.

Your task:
1. Compare field report vs original classification carefully.
2. Make a decision: 
   - 'confirm' if field report matches original
   - 'reclassify' if nature or severity has changed
   - 'retract' if it was a false alarm or completely different incident
3. Provide updated_classification reflecting current reality.
4. If retracting: generate retraction_messages for: public, media, utility_company, hospital.
5. List reasoning_steps explaining your logic step by step.

Output strictly in the JSON schema provided."""
        )

    def _log(self, msg: str, session_id: str = None, level: str = "INFO"):
        safe_print(f"[RECOVERY_AGENT] [{level}] {msg}")
        if self.logger:
            self.logger.log("RECOVERY_AGENT", msg, session_id, level)

    async def verify(
        self,
        incident_id: str,
        original_classification: CrisisClassification,
        field_report: str,
        alerts_sent: List[Dict],
        system_state: Dict = None,     # ActionExecutor's system_state
        session_id: str = None
    ) -> Dict[str, Any]:

        self._log(
            f"Verifying incident {incident_id}. "
            f"Original: {original_classification.crisis_type} severity={original_classification.severity}",
            session_id
        )
        self._log(f"Field report: '{field_report[:100]}...'", session_id)

        input_data = {
            "original_classification": original_classification.model_dump(),
            "field_report": field_report,
            "alerts_sent": alerts_sent
        }

        prompt = (
            "Analyze the verification data and provide the recovery decision.\n\n"
            f"Data:\n{json.dumps(input_data, indent=2)}"
        )

        try:
            breaker = get_gemini_breaker()
            if not breaker.can_proceed():
                self._log("Circuit breaker OPEN — using deterministic fallback.", session_id)
                raise RuntimeError("Circuit breaker OPEN")

            self._log("Calling Gemini for verification decision...", session_id)
            get_quota_monitor().record_call()
            # Run blocking SDK call in thread pool so event loop stays alive
            response = await asyncio.to_thread(
                self.model.generate_content,
                prompt,
                generation_config=genai.GenerationConfig(
                    response_mime_type="application/json",
                    response_schema=RecoveryResult,
                    temperature=0.2
                )
            )
            data = json.loads(response.text)
            result = RecoveryResult(**data)
            breaker.record_success()

            for step in result.reasoning_steps:
                self._log(f"Reasoning: {step}", session_id)

        except Exception as e:
            get_gemini_breaker().record_failure()
            self._log(f"Gemini error: {e}. Using deterministic fallback (broken water main).", session_id)
            # Your original excellent fallback — kept exactly as-is
            updated = original_classification.model_copy()
            updated.crisis_type = "infrastructure_failure"
            updated.severity = 2
            updated.conflict_detected = True
            updated.conflict_description = "Field report contradicted initial flood classification."
            result = RecoveryResult(
                decision="retract",
                updated_classification=updated,
                retraction_messages=[
                    RetractionMessage(
                        stakeholder_type="utility_company",
                        message="Earlier flood alert retracted. Confirmed broken water main. Please dispatch repair crews immediately."
                    ),
                    RetractionMessage(
                        stakeholder_type="public",
                        message="CORRECTION: Earlier flood alert is retracted. Incident is a localized water main burst. Area is safe."
                    ),
                    RetractionMessage(
                        stakeholder_type="media",
                        message="Official correction: G-10 incident reclassified as infrastructure_failure (broken water main), not flooding."
                    )
                ],
                reasoning_steps=["API error", "Applying fallback: field report indicates broken water main, not flood"]
            )

        decision = result.decision
        self._log(f"FINAL DECISION: {decision.upper()}", session_id,
                 "RECOVERY" if decision != "confirm" else "INFO")

        # Update SYSTEM_STATE if retracting
        if decision == "retract" and system_state is not None:
            for msg in result.retraction_messages:
                system_state["retracted_alerts"].append({
                    "stakeholder": msg.stakeholder_type,
                    "message": msg.message,
                    "time": datetime.utcnow().isoformat()
                })
            self._log(
                f"SYSTEM STATE UPDATED: {len(result.retraction_messages)} retraction messages logged.",
                session_id, "RECOVERY"
            )

        return {
            "result": result.model_dump(),
            "decision": decision,
            "incident_id": incident_id,
            "confidence": 0.95,
            "agent_name": "RECOVERY_AGENT",
            "timestamp": datetime.utcnow().isoformat() + "Z"
        }