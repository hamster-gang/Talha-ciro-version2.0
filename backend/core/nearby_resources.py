"""
nearby_resources.py — Nearest Emergency Resources for CIRO.

Given incident lat/lng, queries Google Places API for nearby:
  - Hospitals
  - Fire stations
  - Police stations
  - Rescue / Emergency services

Returns top 3 of each type, sorted by distance.
Adds mock real-time availability counts per facility.

[NEARBY_RESOURCES] [STEP] Each call queries live Google Places data.
"""
import os
import math
import httpx
from typing import List, Dict, Any

PLACES_API_URL = "https://maps.googleapis.com/maps/api/place/nearbysearch/json"


def _haversine_km(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """Calculate distance in km between two GPS coordinates."""
    R = 6371
    d_lat = math.radians(lat2 - lat1)
    d_lng = math.radians(lng2 - lng1)
    a = math.sin(d_lat / 2) ** 2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(d_lng / 2) ** 2
    return R * 2 * math.asin(math.sqrt(a))


def _eta_minutes(distance_km: float) -> int:
    """Estimate arrival time assuming 40 km/h average speed for emergency response."""
    return max(1, round((distance_km / 40) * 60))


def _mock_availability(place_type: str, place_id: str) -> Dict[str, Any]:
    """
    Generate realistic mock availability numbers per facility type.
    Uses place_id hash to keep numbers consistent between calls.
    """
    seed = abs(hash(place_id)) % 100
    if place_type == "hospital":
        return {
            "ambulances_available": 2 + (seed % 4),
            "doctors_on_duty": 5 + (seed % 8),
            "medical_teams": 1 + (seed % 3),
            "emergency_beds": 10 + (seed % 15),
            "readiness": "HIGH" if seed > 50 else "MEDIUM"
        }
    elif place_type == "fire_station":
        return {
            "fire_engines": 1 + (seed % 3),
            "firefighters_on_duty": 8 + (seed % 10),
            "rescue_vehicles": 1 + (seed % 2),
            "water_tankers": 1 + (seed % 2),
            "readiness": "HIGH" if seed > 40 else "MEDIUM"
        }
    elif place_type == "police":
        return {
            "patrol_cars": 2 + (seed % 5),
            "officers_on_duty": 6 + (seed % 10),
            "riot_control_units": seed % 2,
            "readiness": "HIGH" if seed > 30 else "MEDIUM"
        }
    else:  # rescue_1122 / emergency
        return {
            "rescue_vehicles": 1 + (seed % 3),
            "rescue_personnel": 5 + (seed % 8),
            "ambulances_available": 1 + (seed % 3),
            "rescue_boats": seed % 3,  # For flood incidents
            "readiness": "HIGH" if seed > 45 else "MEDIUM"
        }


async def fetch_nearby_resources(
    lat: float,
    lng: float,
    radius_m: int = 10000
) -> Dict[str, Any]:
    """
    [NEARBY_RESOURCES] [STEP] Query Google Places for emergency facilities near incident.
    
    Input: lat, lng of incident, search radius in meters (default 10km)
    Output: dict with hospitals, fire_stations, police, rescue — each sorted by distance
    """
    api_key = os.getenv("GOOGLE_PLACES_KEY") or os.getenv("GOOGLE_MAPS_KEY", "")
    print(f"[NEARBY_RESOURCES] [STEP] Searching within {radius_m}m of ({lat:.4f}, {lng:.4f})")

    resource_types = [
        ("hospital", "hospitals"),
        ("fire_station", "fire_stations"),
        ("police", "police_stations"),
    ]

    all_resources = {}

    async with httpx.AsyncClient(timeout=8.0) as client:
        for place_type, label in resource_types:
            print(f"[NEARBY_RESOURCES] [STEP] Querying Google Places: type={place_type}")
            try:
                resp = await client.get(PLACES_API_URL, params={
                    "location": f"{lat},{lng}",
                    "radius": radius_m,
                    "type": place_type,
                    "key": api_key
                })
                data = resp.json()
                results = data.get("results", [])[:5]

                facilities = []
                for place in results:
                    place_lat = place["geometry"]["location"]["lat"]
                    place_lng = place["geometry"]["location"]["lng"]
                    dist_km = _haversine_km(lat, lng, place_lat, place_lng)
                    eta = _eta_minutes(dist_km)

                    facility = {
                        "name": place.get("name", "Unknown"),
                        "place_id": place.get("place_id", ""),
                        "address": place.get("vicinity", ""),
                        "lat": place_lat,
                        "lng": place_lng,
                        "distance_km": round(dist_km, 2),
                        "eta_minutes": eta,
                        "rating": place.get("rating"),
                        "type": place_type,
                        "availability": _mock_availability(place_type, place.get("place_id", "")),
                        "recommended": dist_km < 3.0  # Mark closest as recommended
                    }
                    facilities.append(facility)

                # Sort by distance
                facilities.sort(key=lambda x: x["distance_km"])
                # Mark the closest as recommended
                if facilities:
                    facilities[0]["recommended"] = True
                all_resources[label] = facilities[:3]
                print(f"[NEARBY_RESOURCES] [STEP] Found {len(facilities)} {label}, showing nearest 3")

            except Exception as e:
                print(f"[NEARBY_RESOURCES] [WARN] Failed to fetch {place_type}: {e}")
                all_resources[label] = _fallback_resources(place_type, lat, lng)

    # Add Pakistan Rescue 1122 as a known emergency service (supplementary)
    all_resources["rescue_1122"] = _rescue_1122_data(lat, lng)

    all_resources["summary"] = {
        "incident_lat": lat,
        "incident_lng": lng,
        "search_radius_km": radius_m / 1000,
        "total_facilities_found": sum(len(v) for k, v in all_resources.items() if k != "summary"),
        "nearest_hospital_eta_min": all_resources["hospitals"][0]["eta_minutes"] if all_resources.get("hospitals") else None,
        "nearest_fire_eta_min": all_resources["fire_stations"][0]["eta_minutes"] if all_resources.get("fire_stations") else None,
    }

    return all_resources


def _rescue_1122_data(lat: float, lng: float) -> List[Dict]:
    """Hardcoded Rescue 1122 stations for Islamabad (well-known, public info)."""
    stations = [
        {"name": "Rescue 1122 — G-9 Islamabad", "lat": 33.697, "lng": 73.063, "address": "G-9 Markaz, Islamabad"},
        {"name": "Rescue 1122 — I-8 Islamabad", "lat": 33.679, "lng": 73.096, "address": "I-8, Islamabad"},
    ]
    result = []
    for s in stations:
        dist = _haversine_km(lat, lng, s["lat"], s["lng"])
        result.append({
            **s,
            "distance_km": round(dist, 2),
            "eta_minutes": _eta_minutes(dist),
            "type": "rescue_1122",
            "availability": _mock_availability("rescue_1122", s["name"]),
            "recommended": dist < 5.0
        })
    result.sort(key=lambda x: x["distance_km"])
    return result[:2]


def _fallback_resources(place_type: str, lat: float, lng: float) -> List[Dict]:
    """Fallback if Google Places API fails — return a generic placeholder."""
    return [{
        "name": f"Nearest {place_type.replace('_', ' ').title()}",
        "place_id": "fallback",
        "address": "Location unavailable",
        "lat": lat,
        "lng": lng,
        "distance_km": 0.0,
        "eta_minutes": 5,
        "type": place_type,
        "availability": _mock_availability(place_type, "fallback"),
        "recommended": True
    }]
