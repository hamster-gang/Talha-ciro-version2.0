"""
processing_state.py — Report lifecycle and crisis cooldown manager for CIRO.

Ensures:
1. A detected crisis type doesn't trigger repeated pipeline runs within COOLDOWN_SECONDS
2. Signal hashes are tracked — same hash = already processed, skip pipeline
3. Admin retry explicitly bypasses cooldown for a specific crisis type

Log format: [PROCESSING_STATE] [STEP] message

Input:  crisis_type (str), signal_hash (str), incident_id (str)
Output: is_on_cooldown() → bool, is_duplicate_signal() → Optional[str]
"""

import time
from typing import Optional, Dict


class CrisisCooldownManager:
    """
    Prevents the same crisis type from triggering the full Gemini pipeline
    repeatedly within a cooldown window.

    A new pipeline run is allowed only when:
      - No crisis of this type/location was processed in the last COOLDOWN_SECONDS, OR
      - An admin explicitly calls force_reset_cooldown()

    Input:  crisis_type (str), location (str), signal_hash (str), incident_id (str)
    Output: is_on_cooldown() → bool
    """

    COOLDOWN_SECONDS = 0  # 0 minutes for demo — do not block reprocessing

    def __init__(self):
        # crisis_key → Unix timestamp of last successful processing
        self._cooldowns: Dict[str, float] = {}
        # signal_hash → incident_id already created for this exact signal set
        self._processed_hashes: Dict[str, str] = {}

    def _crisis_key(self, crisis_type: str, location: str = "default") -> str:
        return f"{crisis_type.lower().strip()}:{location.lower().strip()}"

    def is_on_cooldown(self, crisis_type: str, location: str = "default") -> bool:
        """
        [PROCESSING_STATE] [STEP] Check if this crisis type is within its cooldown window.
        Returns True → skip pipeline. Returns False → proceed.
        """
        key  = self._crisis_key(crisis_type, location)
        last = self._cooldowns.get(key)

        if last is None:
            return False  # Never processed — allow

        elapsed   = time.time() - last
        remaining = self.COOLDOWN_SECONDS - elapsed

        if remaining > 0:
            print(
                f"[PROCESSING_STATE] [STEP] [COOLDOWN] Active for '{crisis_type}' -- "
                f"{int(remaining)}s remaining. Pipeline skipped."
            )
            return True

        return False  # Cooldown expired — allow

    def record_processed(
        self,
        crisis_type:  str,
        location:     str = "default",
        signal_hash:  Optional[str] = None,
        incident_id:  Optional[str] = None,
    ):
        """
        [PROCESSING_STATE] [STEP] Record a successfully processed crisis.
        Starts the cooldown clock and stores the signal hash → incident_id mapping.
        """
        key = self._crisis_key(crisis_type, location)
        self._cooldowns[key] = time.time()

        if signal_hash and incident_id:
            self._processed_hashes[signal_hash] = incident_id

        print(
            f"[PROCESSING_STATE] [STEP] [OK] Recorded crisis '{crisis_type}' @ '{location}'. "
            f"Cooldown active for {self.COOLDOWN_SECONDS}s. "
            f"Incident: {incident_id}"
        )

    def is_duplicate_signal(self, signal_hash: str) -> Optional[str]:
        """
        [PROCESSING_STATE] [STEP] Returns existing incident_id if this exact
        signal hash was already processed, else None.

        Input:  signal_hash (str)
        Output: incident_id (str) or None
        """
        existing = self._processed_hashes.get(signal_hash)
        if existing:
            print(
                f"[PROCESSING_STATE] [STEP] [DUP] Duplicate signal detected "
                f"(hash={signal_hash[:8]}...) -> already processed as {existing}. Skipping."
            )
        return existing

    def force_reset_cooldown(self, crisis_type: str, location: str = "default"):
        """
        [PROCESSING_STATE] [STEP] Admin-triggered retry — removes cooldown
        for a specific crisis type so the next cycle re-runs the pipeline.
        """
        key = self._crisis_key(crisis_type, location)
        removed = self._cooldowns.pop(key, None)
        if removed:
            print(
                f"[PROCESSING_STATE] [STEP] [RESET] Cooldown cleared for '{crisis_type}' "
                f"@ '{location}' -- next cycle will reprocess."
            )
        else:
            print(
                f"[PROCESSING_STATE] [STEP] [INFO] No active cooldown found for "
                f"'{crisis_type}' @ '{location}'."
            )

    def clear_all_hashes(self):
        """
        [PROCESSING_STATE] [STEP] Clear all processed signal hashes.
        Called when a new citizen report or mock data is submitted so the
        pipeline can reprocess even if signals produce the same hash.
        """
        count = len(self._processed_hashes)
        self._processed_hashes.clear()
        print(f"[PROCESSING_STATE] [STEP] [CLEAR] Cleared {count} processed signal hashes.")

    def force_clear_all(self):
        """
        [PROCESSING_STATE] [STEP] Nuclear reset — clear ALL cooldowns AND hashes.
        Used when we need to guarantee the pipeline runs on the next trigger.
        """
        self._cooldowns.clear()
        self._processed_hashes.clear()
        print("[PROCESSING_STATE] [STEP] [RESET] All cooldowns and hashes cleared. Pipeline fully unlocked.")

    def status(self) -> dict:
        """Returns current cooldown state for monitoring endpoint."""
        now    = time.time()
        active = {}
        for key, ts in self._cooldowns.items():
            remaining = self.COOLDOWN_SECONDS - (now - ts)
            if remaining > 0:
                active[key] = {"remaining_seconds": int(remaining)}

        return {
            "active_cooldowns":       active,
            "processed_signal_count": len(self._processed_hashes),
            "cooldown_seconds":       self.COOLDOWN_SECONDS,
        }


# ── Singleton ─────────────────────────────────────────────────────────────────

_cooldown_manager: Optional[CrisisCooldownManager] = None


def get_cooldown_manager() -> CrisisCooldownManager:
    global _cooldown_manager
    if _cooldown_manager is None:
        _cooldown_manager = CrisisCooldownManager()
    return _cooldown_manager
