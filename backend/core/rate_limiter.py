"""
rate_limiter.py — API protection layer for CIRO.

Implements:
- CircuitBreaker: stops calling Gemini after N consecutive failures
- QuotaMonitor: tracks calls per minute/hour to detect exhaustion
- SignalHasher: generates a stable hash of signal data to detect changes

Log format: [RATE_LIMITER] [STEP] message

Input:  signal data dicts (social, weather, traffic)
Output: allow/block decisions + hash strings for deduplication
"""

import hashlib
import json
import time
from datetime import datetime, timezone
from enum import Enum
from typing import Optional, Dict


# ── Circuit Breaker ─────────────────────────────────────────────────────────

class CircuitState(Enum):
    CLOSED    = "closed"     # Normal — requests flow through
    OPEN      = "open"       # Tripped — all requests blocked
    HALF_OPEN = "half_open"  # Testing — one probe request allowed


class CircuitBreaker:
    """
    Protects the Gemini API from exhaustion via consecutive failure tracking.

    States:
        CLOSED    → requests pass through normally
        OPEN      → requests blocked for RECOVERY_WINDOW seconds
        HALF_OPEN → one probe allowed; success → CLOSED, failure → OPEN again

    Input:  record_success() / record_failure() calls from agent code
    Output: can_proceed() → bool, status() → dict
    """

    FAILURE_THRESHOLD = 3    # consecutive failures before opening circuit
    RECOVERY_WINDOW   = 120  # seconds to wait before half-open probe

    def __init__(self, name: str):
        self.name              = name
        self.state             = CircuitState.CLOSED
        self.failure_count     = 0
        self.last_failure_time: Optional[float] = None
        self.total_calls       = 0
        self.total_failures    = 0

    def record_success(self):
        """[RATE_LIMITER] [STEP] API call succeeded — reset failure counter."""
        self.failure_count = 0
        self.state         = CircuitState.CLOSED
        self.total_calls  += 1
        print(f"[RATE_LIMITER] [STEP] [OK] Circuit CLOSED for {self.name} -- API healthy.")

    def record_failure(self):
        """[RATE_LIMITER] [STEP] API call failed — increment failure counter.
        CRITICAL FIX: Do NOT increment if circuit is already OPEN — this was
        causing cascading failures that kept the circuit open indefinitely."""
        if self.state == CircuitState.OPEN:
            # Circuit already open — don't reset the recovery timer
            print(f"[RATE_LIMITER] [STEP] [SKIP] Circuit already OPEN for {self.name} — not recording additional failure.")
            return

        self.failure_count    += 1
        self.total_failures   += 1
        self.last_failure_time = time.time()
        self.total_calls      += 1

        if self.failure_count >= self.FAILURE_THRESHOLD:
            self.state = CircuitState.OPEN
            print(
                f"[RATE_LIMITER] [STEP] [OPEN] Circuit OPEN for {self.name} -- "
                f"{self.failure_count} consecutive failures. "
                f"Blocking API calls for {self.RECOVERY_WINDOW}s."
            )
        else:
            print(
                f"[RATE_LIMITER] [STEP] [WARN] Failure #{self.failure_count} "
                f"for {self.name} ({self.FAILURE_THRESHOLD - self.failure_count} until circuit opens)."
            )

    def can_proceed(self) -> bool:
        """[RATE_LIMITER] [STEP] Check whether an API call is allowed."""
        if self.state == CircuitState.CLOSED:
            return True

        if self.state == CircuitState.OPEN:
            elapsed = time.time() - (self.last_failure_time or 0)
            if elapsed >= self.RECOVERY_WINDOW:
                self.state = CircuitState.HALF_OPEN
                print(
                    f"[RATE_LIMITER] [STEP] [HALF-OPEN] Circuit HALF_OPEN for {self.name} -- "
                    f"testing recovery with one probe request."
                )
                return True
            remaining = int(self.RECOVERY_WINDOW - elapsed)
            print(
                f"[RATE_LIMITER] [STEP] [BLOCKED] Circuit OPEN -- {self.name} blocked. "
                f"{remaining}s until recovery probe."
            )
            return False

        # HALF_OPEN: allow one probe through
        return True

    def force_close(self):
        """[RATE_LIMITER] [STEP] Force-close the circuit breaker.
        Used when we need to guarantee the pipeline runs (e.g. citizen report trigger)."""
        self.state = CircuitState.CLOSED
        self.failure_count = 0
        print(f"[RATE_LIMITER] [STEP] [FORCE] Circuit FORCE-CLOSED for {self.name}. All API calls allowed.")

    def status(self) -> dict:
        now = time.time()
        recovery_in = 0
        if self.state == CircuitState.OPEN and self.last_failure_time:
            recovery_in = max(0, int(self.RECOVERY_WINDOW - (now - self.last_failure_time)))
        return {
            "name":              self.name,
            "state":             self.state.value,
            "failure_count":     self.failure_count,
            "total_calls":       self.total_calls,
            "total_failures":    self.total_failures,
            "recovery_in_secs":  recovery_in,
        }


# ── Quota Monitor ────────────────────────────────────────────────────────────

class QuotaMonitor:
    """
    Tracks Gemini API call frequency to detect quota exhaustion risk.

    Input:  record_call() after each API invocation
    Output: is_near_quota() → bool, status() → dict
    """

    MINUTE_LIMIT = 60    # warn at 80% of this
    HOUR_LIMIT   = 1000

    def __init__(self):
        self._calls: list = []  # list of Unix timestamps

    def record_call(self):
        """[RATE_LIMITER] [STEP] Record one API call timestamp."""
        now = time.time()
        self._calls.append(now)
        # Prune records older than 1 hour
        cutoff = now - 3600
        self._calls = [t for t in self._calls if t > cutoff]

    def calls_last_minute(self) -> int:
        cutoff = time.time() - 60
        return sum(1 for t in self._calls if t > cutoff)

    def calls_last_hour(self) -> int:
        return len(self._calls)

    def is_near_quota(self) -> bool:
        """Returns True if approaching minute-rate limit (>80%)."""
        return self.calls_last_minute() > self.MINUTE_LIMIT * 0.8

    def status(self) -> dict:
        return {
            "calls_last_minute": self.calls_last_minute(),
            "calls_last_hour":   self.calls_last_hour(),
            "minute_limit":      self.MINUTE_LIMIT,
            "hour_limit":        self.HOUR_LIMIT,
            "near_quota":        self.is_near_quota(),
        }


# ── Signal Hasher ─────────────────────────────────────────────────────────────

class SignalHasher:
    """
    Generates a stable MD5 hash of the current signal snapshot.
    Used to skip the Gemini pipeline if signals haven't changed since last cycle.

    Input:  social (list of str), weather (dict), traffic (dict)
    Output: hex hash string
    """

    def hash_signals(self, social: list, weather: dict, traffic: dict) -> str:
        """[RATE_LIMITER] [STEP] Compute stable hash of current signals."""
        payload = {
            # Use count + sorted first-5 texts for stability
            "social_count":        len(social),
            "social_sample":       sorted(social[:5]),
            "weather_condition":   weather.get("condition", ""),
            "weather_alert":       weather.get("alert_level", ""),
            "rainfall":            weather.get("rainfall_mmhr", 0),
            "traffic_max":         max(
                (s.get("congestion_percent", 0) for s in traffic.get("congestion_segments", [])),
                default=0
            ),
        }
        raw = json.dumps(payload, sort_keys=True)
        return hashlib.md5(raw.encode()).hexdigest()


# ── Singletons ────────────────────────────────────────────────────────────────

_gemini_breaker: Optional[CircuitBreaker] = None
_quota_monitor:  Optional[QuotaMonitor]   = None
_signal_hasher:  Optional[SignalHasher]   = None


def get_gemini_breaker() -> CircuitBreaker:
    global _gemini_breaker
    if _gemini_breaker is None:
        _gemini_breaker = CircuitBreaker("gemini-2.0-flash")
    return _gemini_breaker


def get_quota_monitor() -> QuotaMonitor:
    global _quota_monitor
    if _quota_monitor is None:
        _quota_monitor = QuotaMonitor()
    return _quota_monitor


def get_signal_hasher() -> SignalHasher:
    global _signal_hasher
    if _signal_hasher is None:
        _signal_hasher = SignalHasher()
    return _signal_hasher
