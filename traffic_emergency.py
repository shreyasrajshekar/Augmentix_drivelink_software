import numpy as np
import pandas as pd
import random

# --- CONFIGURATION ---
NUM_CARS = 15
ROAD_LENGTH = 400
SIREN_RANGE = 100 # Distance cars can "hear" the siren

# Initialize Standard Cars
agents = []
for i in range(NUM_CARS):
    agents.append({
        "id": i,
        "lane": np.random.choice([1, 2, 3]),
        "position": np.random.uniform(0, ROAD_LENGTH),
        "speed": np.random.uniform(12, 16),
        "is_emergency": False,
        "status": "NORMAL"
    })

# Initialize the Emergency Vehicle (The Fire Truck)
emergency_v = {
    "id": "FIRE_TRUCK",
    "lane": 2, # Usually stays in the middle or fast lane
    "position": 0,
    "speed": 25,
    "is_emergency": True,
    "status": "EMERGENCY"
}
agents.append(emergency_v)

print(f"{'STEP':<5} | {'EVENT':<20} | {'ACTION LOG'}")
print("-" * 70)

for step in range(100):
    # Sort agents by position to process traffic flow correctly
    agents.sort(key=lambda x: x["position"], reverse=True)
    
    ev_pos = emergency_v["position"]
    ev_lane = emergency_v["lane"]

    for a in agents:
        if a["is_emergency"]:
            continue
            
        # 1. SIREN DETECTION LOGIC
        dist_to_ev = a["position"] - ev_pos
        
        # If Fire Truck is behind and within Siren Range
        if 0 < dist_to_ev < SIREN_RANGE:
            if a["lane"] == ev_lane:
                # MUST CLEAR THE LANE
                old_lane = a["lane"]
                # Logic: Move to lane 1 if in 2, move to 3 if in 2, etc.
                a["lane"] = 1 if old_lane == 2 else (2 if old_lane == 1 else 2)
                a["status"] = "YIELDING"
                print(f"{step:<5} | EMERGENCY SIREN!     | Car {a['id']} moving L{old_lane} -> L{a['lane']} to clear path")
            else:
                # Stay in current lane but slow down
                a["speed"] = 10
                a["status"] = "CAUTION"
        else:
            # Resume normal behavior once EV has passed
            if a["status"] != "NORMAL" and dist_to_ev < -20:
                a["status"] = "NORMAL"
                a["speed"] = np.random.uniform(12, 16)
                print(f"{step:<5} | CLEARANCE            | Car {a['id']} resuming normal speed.")

    # 2. UPDATE POSITIONS
    for a in agents:
        a["position"] = (a["position"] + a["speed"] * 0.5) % ROAD_LENGTH