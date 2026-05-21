import os
import json

files_to_delete = [
    "citizen_reports.json",
    "incidents.json"
]

print("Clearing backend database files...")
for filename in files_to_delete:
    if os.path.exists(filename):
        os.remove(filename)
        print(f"Deleted: {filename}")
    else:
        print(f"Not found: {filename}")

print("Resetting mock data to prevent synthetic loops...")
mock_files = {
    "mock_data/social_posts.json": {"posts": []},
    "mock_data/traffic_mock.json": {"congestion_segments": []},
    "mock_data/weather_mock.json": {"temperature_c": 30, "humidity": 60, "condition": "Clear", "alert_level": "LOW", "rainfall_mmhr": 0, "forecast": {"day": "Tuesday", "rain_type": "None", "probability": 0, "expected_duration_hours": 0}}
}

for path, content in mock_files.items():
    if os.path.exists(path):
        with open(path, "w") as f:
            json.dump(content, f)
        print(f"Reset: {path}")

print("Database cleared successfully.")
