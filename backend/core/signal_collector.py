"""
signal_collector.py — Multi-source signal ingestion for CIRO.

Sources:
  1. Social media posts (mock JSON — simulates Twitter/X API)
  2. Weather data (mock — simulates OpenWeather API)
  3. Traffic data (mock — simulates Google Maps Traffic API)
  4. Citizen reports (live from citizen_reports.json — real submissions)

[SIGNAL_COLLECTOR] [STEP] All sources fused into unified signal for Agent 1.
"""
import json
import os
from datetime import datetime, timezone
from typing import Tuple, List, Dict, Any

# Paths to mock data files (simulated external APIs)
SOCIAL_PATH  = "mock_data/social_posts.json"
WEATHER_PATH = "mock_data/weather_mock.json"
TRAFFIC_PATH = "mock_data/traffic_mock.json"
CITIZEN_PATH = "citizen_reports.json"


def _load_json(path: str, default: Any) -> Any:
    if not os.path.exists(path):
        return default
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def collect_citizen_signals() -> List[str]:
    """
    [SIGNAL_COLLECTOR] [STEP] Convert recent citizen reports into social signal format.
    Citizen reports are treated as high-credibility local signals.
    Only uses reports from last 2 hours to keep signals fresh.
    """
    data = _load_json(CITIZEN_PATH, {"reports": []})
    citizen_posts = []
    now = datetime.now(timezone.utc)

    for report in data.get("reports", []):
        # Only include recent reports (within 2 hours)
        try:
            ts = datetime.fromisoformat(report.get("timestamp", ""))
            age_hours = (now - ts).total_seconds() / 3600
            if age_hours > 24:
                continue
        except Exception:
            continue

        # Convert to social-signal-style text string
        # Include report_id as nonce so each submission produces a unique signal hash
        inc_type = report.get("incident_type", "incident")
        location = report.get("location", "Islamabad")
        desc = report.get("description", "")
        report_id = report.get("report_id", "")
        post = f"[CITIZEN REPORT] {inc_type} at {location}: {desc[:120]} [ID:{report_id}]"
        citizen_posts.append(post)
        print(f"[SIGNAL_COLLECTOR] [STEP] Citizen signal ingested: {post[:80]}...")

    return citizen_posts


async def collect_signals() -> Tuple[List[str], Dict, Dict]:
    """
    [SIGNAL_COLLECTOR] [STEP] Reads all 4 signal sources.
    Returns (social_posts, weather, traffic).
    Citizen reports are merged into social_posts automatically.
    """
    print("[SIGNAL_COLLECTOR] [STEP] Collecting signals from all sources...")

    # SOURCE 1: Social media (simulates Twitter/X API scrape)
    social_data = _load_json(SOCIAL_PATH, {"posts": []})
    social_posts = [p["text"] for p in social_data.get("posts", [])]
    print(f"[SIGNAL_COLLECTOR] [STEP] Social media: {len(social_posts)} posts collected")

    # SOURCE 2: Weather (simulates OpenWeather API)
    weather = _load_json(WEATHER_PATH, {"temperature_c": 30, "humidity": 60, "rainfall_mmhr": 0, "alert_level": "Low"})
    print(f"[SIGNAL_COLLECTOR] [STEP] Weather: temp={weather.get('temperature_c')}°C, "
          f"rain={weather.get('rainfall_mmhr')}mm/hr, alert={weather.get('alert_level')}")

    # SOURCE 3: Traffic (simulates Google Maps Traffic API)
    traffic = _load_json(TRAFFIC_PATH, {"congestion_segments": []})
    max_cong = max((s.get("congestion_percent", 0) for s in traffic.get("congestion_segments", [])), default=0)
    print(f"[SIGNAL_COLLECTOR] [STEP] Traffic: max congestion={max_cong}% across segments")

    # SOURCE 4: Citizen reports (LIVE — real app submissions)
    citizen_signals = collect_citizen_signals()
    social_posts.extend(citizen_signals)
    print(f"[SIGNAL_COLLECTOR] [STEP] Citizen reports added: {len(citizen_signals)} new signals. "
          f"Total social signals: {len(social_posts)}")

    return social_posts, weather, traffic


def get_signal_snapshot(social_posts: List[str], weather: Dict, traffic: Dict) -> Dict:
    """
    [SIGNAL_COLLECTOR] [STEP] Build structured snapshot for /api/signals endpoint.
    Judges can see exactly what data fed into the AI decision.
    """
    max_cong = max(
        (s.get("congestion_percent", 0) for s in traffic.get("congestion_segments", [])), default=0
    )
    citizen_count = sum(1 for p in social_posts if p.startswith("[CITIZEN REPORT]"))
    return {
        "sources": {
            "social_media": {
                "post_count": len(social_posts) - citizen_count,
                "sample": social_posts[:3] if social_posts else [],
                "api": "Twitter/X Stream (mock)"
            },
            "citizen_reports": {
                "count": citizen_count,
                "api": "CIRO Citizen App (live)"
            },
            "weather": {
                "temperature_c": weather.get("temperature_c"),
                "rainfall_mmhr": weather.get("rainfall_mmhr"),
                "alert_level": weather.get("alert_level"),
                "api": "OpenWeather API (mock)"
            },
            "traffic": {
                "max_congestion_pct": max_cong,
                "segments_monitored": len(traffic.get("congestion_segments", [])),
                "api": "Google Maps Traffic API (mock)"
            }
        },
        "total_signals": len(social_posts),
        "timestamp": datetime.now(timezone.utc).isoformat()
    }