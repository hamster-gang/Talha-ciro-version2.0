import asyncio
import os
import json
from datetime import datetime
from typing import List, Dict, Any
from pydantic import BaseModel
import google.generativeai as genai
from core.rate_limiter import get_gemini_breaker, get_quota_monitor
from core.agent_logger import safe_print


class AnomalyOutput(BaseModel):
    detected_anomaly: bool
    anomaly_description: str
    confidence: float
    reasoning_steps: List[str]


def score_post(post: str) -> Dict[str, float]:
    """Score a single social post for credibility, urgency, location match."""
    post_lower = post.lower()
    urgency = 0.9 if any(w in post_lower for w in [
        "bhar gaya", "flooding", "emergency", "heavy", "phans gayi",
        "flood", "siel", "paani", "pani"
    ]) else 0.5
    location_match = 0.9 if any(w in post_lower for w in [
        "g-10", "g-9", "g-11", "g10", "g9", "g11", "islamabad"
    ]) else 0.5
    return {
        "text": post,
        "credibility": 0.8,
        "urgency": urgency,
        "location_match": location_match
    }


class SignalFusionAgent:
    """
    Agent 1 — Signal Fusion.
    Reads social, weather, traffic. Scores posts. Calls Gemini for anomaly detection.
    Produces unified_signal passed to CrisisClassifierAgent.
    """

    def __init__(self, api_key: str, logger=None):
        self.logger = logger
        genai.configure(api_key=api_key)          # ← called ONCE here, not every call
        self.model = genai.GenerativeModel(
            model_name="gemini-2.0-flash",
            system_instruction="""You are a crisis signal analyst for Pakistani cities (Islamabad focus).
Analyze social media posts (in Urdu, Roman Urdu, and English), weather data, and traffic congestion.
Determine if there is an active crisis or anomaly.
Set confidence based on how many independent sources confirm the same event.
Output strictly in the requested JSON schema."""
        )

    def _log(self, msg: str, session_id: str = None):
        safe_print(f"[SIGNAL_FUSION] {msg}")
        if self.logger:
            self.logger.log("SIGNAL_FUSION", msg, session_id)

    async def analyze(
        self,
        social_posts: List[str],
        weather: Dict[str, Any],
        traffic: Dict[str, Any],
        session_id: str = None
    ) -> Dict[str, Any]:

        self._log("Scoring social posts for credibility, urgency, location match.", session_id)
        scored_posts = [score_post(p) for p in social_posts]

        self._log(f"Fusing {len(social_posts)} social posts + weather + traffic.", session_id)
        unified_signal = {
            "social_analysis": scored_posts,
            "weather_data": weather,
            "traffic_data": traffic
        }

        prompt = (
            "Analyze these crisis signals for Islamabad emergency response.\n"
            "Multiple independent signal types (social + weather + traffic) converging on same "
            "location should increase confidence significantly.\n\n"
            f"Signals:\n{json.dumps(unified_signal, indent=2)}"
        )

        try:
            breaker = get_gemini_breaker()
            quota   = get_quota_monitor()

            # Check circuit breaker — if OPEN, skip API call entirely
            if not breaker.can_proceed():
                self._log("Circuit breaker OPEN — skipping Gemini call, using heuristic only.", session_id)
                raise RuntimeError(f"Circuit breaker OPEN for {breaker.name}")

            # Warn if near quota
            if quota.is_near_quota():
                self._log(f"[WARN] Near API quota ({quota.calls_last_minute()} calls/min). Proceeding with caution.", session_id)

            self._log("Calling Gemini for anomaly detection...", session_id)
            quota.record_call()
            # Run blocking SDK call in thread pool so event loop stays alive
            response = await asyncio.to_thread(
                self.model.generate_content,
                prompt,
                generation_config=genai.GenerationConfig(
                    response_mime_type="application/json",
                    response_schema=AnomalyOutput,
                    temperature=0.2
                )
            )
            result = json.loads(response.text)
            self._log(
                f"Gemini result: anomaly={result['detected_anomaly']}, "
                f"confidence={result['confidence']:.3f}",
                session_id
            )
            for step in result.get("reasoning_steps", []):
                self._log(f"Reasoning: {step}", session_id)

        except Exception as e:
            # Record the failure in the circuit breaker
            breaker = get_gemini_breaker()
            breaker.record_failure()
            self._log(f"Gemini error: {e}. Circuit breaker failure count: {breaker.failure_count}. Running heuristic fallback.", session_id)

            # CRITICAL FIX: DO NOT blindly return detected_anomaly=True.
            # This was the root cause of infinite API loops on quota exhaustion.
            # Instead, use scored posts to decide if signals are genuinely alarming.
            high_urgency_posts = [p for p in scored_posts if p["urgency"] >= 0.8]
            high_location_posts = [p for p in scored_posts if p["location_match"] >= 0.8]
            weather_severe = weather.get("alert_level", "") in ["RED", "ORANGE"]
            traffic_severe = any(
                s.get("congestion_percent", 0) >= 80
                for s in traffic.get("congestion_segments", [])
            )

            # Require at least 2 independent severe signals before triggering pipeline
            severe_signal_count = (
                (1 if len(high_urgency_posts) >= 2 else 0) +
                (1 if len(high_location_posts) >= 1 else 0) +
                (1 if weather_severe else 0) +
                (1 if traffic_severe else 0)
            )
            anomaly_detected = severe_signal_count >= 2
            confidence = min(0.4 + (severe_signal_count * 0.15), 0.85) if anomaly_detected else 0.2

            self._log(
                f"Heuristic fallback: {severe_signal_count} severe signals, "
                f"anomaly={anomaly_detected}, confidence={confidence:.2f}",
                session_id
            )
            result = {
                "detected_anomaly": anomaly_detected,
                "anomaly_description": (
                    f"Heuristic fallback ({severe_signal_count} severe signals: "
                    f"urgency_posts={len(high_urgency_posts)}, weather_severe={weather_severe}, "
                    f"traffic_severe={traffic_severe})"
                ) if anomaly_detected else "Heuristic fallback: insufficient signals for crisis detection",
                "confidence": confidence,
                "reasoning_steps": [
                    "AI reasoning temporarily unavailable. Using backup analysis engine.",
                    f"API error: {type(e).__name__}",
                    f"High-urgency posts: {len(high_urgency_posts)}/{len(scored_posts)}",
                    f"Weather alert level: {weather.get('alert_level', 'NONE')}",
                    f"Traffic severe: {traffic_severe}",
                    f"Severe signal count: {severe_signal_count}/4 (need >=2 to trigger)",
                ]
            }
        else:
            # Record success in circuit breaker
            get_gemini_breaker().record_success()

        # TASK 32: Force pipeline execution if a verified citizen report is present
        has_citizen_report = any("[CITIZEN REPORT]" in p.get("text", "") for p in scored_posts)
        if has_citizen_report:
            self._log("Citizen Report detected. Forcing pipeline anomaly execution.", session_id)
            result["detected_anomaly"] = True
            result["confidence"] = max(float(result.get("confidence", 0)), 0.95)
            if "Citizen report overrides monitoring state" not in result.get("reasoning_steps", []):
                result.setdefault("reasoning_steps", []).append("Citizen report overrides monitoring state")

        # Hackathon Demo: Force pipeline execution if any new data is provided
        if len(social_posts) > 0 or weather or traffic:
            if not result["detected_anomaly"]:
                self._log("Demo Override: Forcing anomaly detection for new signals.", session_id)
                result["detected_anomaly"] = True
                result["confidence"] = max(float(result.get("confidence", 0)), 0.75)
                if "Demo override triggered pipeline execution" not in result.get("reasoning_steps", []):
                    result.setdefault("reasoning_steps", []).append("Demo override triggered pipeline execution")
                
        return {
            "detected_anomaly": result["detected_anomaly"],
            "anomaly_description": result["anomaly_description"],
            "confidence": float(result["confidence"]),
            "reasoning_steps": result.get("reasoning_steps", []),
            "unified_signal": unified_signal,
            "agent_name": "SIGNAL_FUSION",
            "timestamp": datetime.utcnow().isoformat() + "Z"
        }