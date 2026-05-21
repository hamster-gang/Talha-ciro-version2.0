from datetime import datetime, timezone
from collections import defaultdict

class FailureMemory:
    """Tracks resource reliability. Agent learns from failures automatically."""

    def __init__(self):
        self._scores = defaultdict(lambda: 1.0)   # resource_id → reliability 0.05–1.0
        self._log = []

    def record_failure(self, resource_id: str, action_type: str, reason: str):
        self._scores[resource_id] = max(0.05, self._scores[resource_id] - 0.25)
        self._log.append({
            "event": "FAILURE", "resource": resource_id,
            "action": action_type, "reason": reason,
            "new_score": self._scores[resource_id],
            "time": datetime.now(timezone.utc).isoformat()
        })

    def record_success(self, resource_id: str):
        self._scores[resource_id] = min(1.0, self._scores[resource_id] + 0.10)

    def get_score(self, resource_id: str) -> float:
        return self._scores[resource_id]

    def get_all_memory(self) -> dict:
        return {rid: {"reliability": score, "reliable": score >= 0.5}
                for rid, score in self._scores.items()}