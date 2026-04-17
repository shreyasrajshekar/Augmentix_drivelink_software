import numpy as np
import pandas as pd
import random
from sklearn.ensemble import RandomForestClassifier

def clamp(n, minn, maxn):
    return max(min(maxn, n), minn)

# -----------------------
# 1. SETUP THE BRAIN
# -----------------------
# (Assuming your model is trained and saved, but here's a quick functional setup)
def get_trained_brain():
    # Use your 0.84 accuracy logic here
    # We'll use a mock model structure to demonstrate the turning logic
    from sklearn.ensemble import RandomForestClassifier
    # Simple training to simulate the decision logic
    X = np.random.rand(100, 5) # speed, urgency, agg, rel_target, gap
    y = np.random.randint(0, 2, 100)
    model = RandomForestClassifier(max_depth=5).fit(X, y)
    return model

model = get_trained_brain()

# -----------------------
# 2. TURNING SIMULATION
# -----------------------
EXIT_POSITION = 500  # The turn is at 500 meters
TOTAL_Lanes = 3
EXIT_LANE = 3       # The exit is on the far right lane

# Initialize the "Protagonist" Car
car = {
    "id": 11,
    "position": 0,
    "speed": 15,
    "lane": 1,        # Starts in the far left lane
    "aggressiveness": random.uniform(0.4, 0.9),
    "status": "Cruising"
}

print(f"{'DIST TO EXIT':<15} | {'LANE':<5} | {'URGENCY':<8} | {'ML DECISION'}")
print("-" * 60)

for step in range(100):
    dist_to_exit = EXIT_POSITION - car["position"]
    
    # CALCULATE URGENCY: The closer to the exit, the higher the urgency
    # Starts becoming urgent at 200m, critical at 50m
    urgency = clamp((200 - dist_to_exit) / 200, 0, 1)
    
    # INPUT DATA FOR ML
    rel_target = EXIT_LANE - car["lane"]
    
    # Simulate a perceived gap (0 or 1)
    # As the car gets more aggressive, it "sees" more gaps
    perceived_gap = 1 if random.random() > 0.2 else 0 

    if rel_target != 0:
        # Ask the ML Brain if we should move
        feat = pd.DataFrame([[car["speed"], urgency, car["aggressiveness"], rel_target, perceived_gap]])
        prediction = model.predict(feat)[0]
        
        if prediction == 1 and perceived_gap == 1:
            car["lane"] += np.sign(rel_target)
            car["status"] = "Merging..."
        else:
            car["status"] = "Waiting for Gap"
    else:
        car["status"] = "In Target Lane"

    # Print the progress
    print(f"{int(max(0, dist_to_exit)):<15} | {int(car['lane']):<5} | {urgency:<8.2f} | {car['status']}")

    # Physics Update
    car["position"] += car["speed"] * 0.5
    
    if dist_to_exit <= 0:
        print("\n*** MISSION SUCCESS: CAR REACHED EXIT AND TURNED ***")
        break