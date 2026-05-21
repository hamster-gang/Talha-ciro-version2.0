import asyncio
import os
import json
from datetime import datetime
from typing import List, Dict, Any
from pydantic import BaseModel
import google.generativeai as genai
import urllib.request
import urllib.parse
from core.rate_limiter import get_gemini_breaker, get_quota_monitor
from core.agent_logger import safe_print


class IncidentInfo(BaseModel):
    incident_id: str
    crisis_type: str
    severity: int
    affected_population: int
    location: str


class AllocationResult(BaseModel):
    allocation_plan: Dict[str, Dict[str, int]]
    trade_off_reasoning: str
    unmet_needs: List[str]
    reasoning_steps: List[str]


# Default mock resources — change these to match your resources_mock.json
DEFAULT_RESOURCES = {
    "rescue_unit": 3,
    "ambulance": 2,
    "fire_truck": 1,
    "police_unit": 4
}


class ResourceAllocatorAgent:
    """
    Agent 3 — Resource Allocator.
    Takes classification from CrisisClassifierAgent.
    Uses Gemini to allocate scarce resources across incidents.
    Finds nearest actual resources (hospitals, police) using Google Places API.
    Shows trade-offs and flags unmet needs.
    """

    def __init__(self, api_key: str, logger=None, available_resources: Dict = None):
        self.logger = logger
        self.available_resources = available_resources or DEFAULT_RESOURCES
        self.places_key = os.getenv("GOOGLE_PLACES_KEY", "")
        genai.configure(api_key=api_key)
        self.model = genai.GenerativeModel(
            model_name="gemini-2.0-flash",
            system_instruction="""You are an expert emergency resource dispatcher for Pakistani cities.
Allocate scarce emergency resources across active incidents.
Prioritize by: severity × affected_population.
When dispatching resources like police, ambulance, or rescue units, explicitly identify the nearest relevant station or hospital to the incident's location.
Show step-by-step reasoning. Explain every trade-off explicitly and mention the dispatch origin.
Flag which incidents are underserved in unmet_needs.
Output strictly in the JSON schema provided."""
        )

    def _log(self, msg: str, session_id: str = None):
        safe_print(f"[RESOURCE_ALLOCATOR] {msg}")
        if self.logger:
            self.logger.log("RESOURCE_ALLOCATOR", msg, session_id)

    def _find_nearest_resource(self, location: str, resource_keyword: str) -> str:
        if not self.places_key:
            return f"Mock {resource_keyword} near {location}"
        
        query = urllib.parse.quote(f"{resource_keyword} near {location}")
        url = f"https://maps.googleapis.com/maps/api/place/textsearch/json?query={query}&key={self.places_key}"
        try:
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req) as response:
                data = json.loads(response.read().decode())
                if data.get("results") and len(data["results"]) > 0:
                    best = data["results"][0]
                    return f"{best.get('name', 'Unknown')} at {best.get('formatted_address', '')}"
        except Exception as e:
            print(f"Places API error: {e}")
        return f"Nearest available {resource_keyword} (API fallback)"

    async def allocate(
        self,
        classification: Dict[str, Any],
        incident_id: str,
        session_id: str = None
    ) -> Dict[str, Any]:

        # Build incident list from classification
        incidents = [{
            "incident_id": incident_id,
            "crisis_type": classification.get("crisis_type", "flood"),
            "severity": classification.get("severity", 3),
            "affected_population": classification.get("affected_population", 10000),
            "location": "G-10, Islamabad"
        }]

        self._log(
            f"Allocating resources for {len(incidents)} incident(s). "
            f"Available: {self.available_resources}",
            session_id
        )

        nearest_hospital = self._find_nearest_resource(incidents[0]["location"], "hospital")
        nearest_police = self._find_nearest_resource(incidents[0]["location"], "police station")
        nearest_fire = self._find_nearest_resource(incidents[0]["location"], "fire station")

        input_data = {
            "incidents": incidents,
            "available_resources": self.available_resources,
            "nearest_infrastructure": {
                "hospital": nearest_hospital,
                "police_station": nearest_police,
                "fire_station": nearest_fire
            }
        }

        prompt = (
            "Determine the optimal resource allocation.\n"
            "Justify every assignment. Flag any unmet needs.\n\n"
            f"Input:\n{json.dumps(input_data, indent=2)}"
        )

        try:
            breaker = get_gemini_breaker()
            quota   = get_quota_monitor()

            if not breaker.can_proceed():
                self._log("Circuit breaker OPEN — skipping Gemini, using priority fallback.", session_id)
                raise RuntimeError("Circuit breaker OPEN")

            self._log("Calling Gemini for optimal allocation plan...", session_id)
            quota.record_call()
            # Run blocking SDK call in thread pool so event loop stays alive
            response = await asyncio.to_thread(
                self.model.generate_content,
                prompt,
                generation_config=genai.GenerationConfig(
                    response_mime_type="application/json",
                    response_schema=AllocationResult,
                    temperature=0.3
                )
            )
            data = json.loads(response.text)
            result = AllocationResult(**data)
            breaker.record_success()

            for step in result.reasoning_steps:
                self._log(f"Reasoning: {step}", session_id)

            self._log(f"Trade-off: {result.trade_off_reasoning}", session_id)
            if result.unmet_needs:
                self._log(f"⚠️ Unmet needs: {result.unmet_needs}", session_id)

        except Exception as e:
            get_gemini_breaker().record_failure()
            self._log(f"Gemini error: {e}. Using priority-based fallback.", session_id)
            result = AllocationResult(
                allocation_plan={incident_id: {"rescue_unit": 2, "ambulance": 1}},
                trade_off_reasoning="Fallback: severity-based allocation. 2 rescue + 1 ambulance to highest priority.",
                unmet_needs=["fire_truck not allocated (insufficient units)"],
                reasoning_steps=[
                    "AI reasoning temporarily unavailable. Using backup analysis engine.",
                    "API error", 
                    "Fallback priority allocation applied"
                ]
            )

        return {
            "allocation_plan": result.allocation_plan,
            "trade_off_reasoning": result.trade_off_reasoning,
            "unmet_needs": result.unmet_needs,
            "reasoning_steps": result.reasoning_steps,
            "agent_name": "RESOURCE_ALLOCATOR",
            "timestamp": datetime.utcnow().isoformat() + "Z"
        }