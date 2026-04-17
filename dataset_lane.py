import numpy as np
import pandas as pd
import random
from sklearn.ensemble import RandomForestClassifier
from sklearn.model_selection import train_test_split
from sklearn.metrics import accuracy_score

# -----------------------
# PARAMETERS - THE 0.84 CALIBRATION
# -----------------------
NUM_CARS = 200 
STEPS = 1000
ROAD_LENGTH = 150 

np.random.seed(42)
random.seed(42)

cars = []
for i in range(NUM_CARS):
    curr = np.random.choice([1, 2, 3])
    cars.append({
        "id": i,
        "lane": curr,
        "position": np.random.uniform(0, ROAD_LENGTH),
        "speed": np.random.uniform(10, 20),
        "target_lane": np.random.choice([l for l in [1, 2, 3] if l != curr]),
        "distance_to_turn": np.random.uniform(10, 150),
        "aggressiveness": np.random.uniform(0.7, 1.0),
    })

raw_dataset = []

# -----------------------
# SIMULATION
# -----------------------
for step in range(STEPS):
    for car in cars:
        current_lane = car["lane"]
        urgency = max(0, (150 - car["distance_to_turn"]) / 150)
        
        # Determine REAL physical possibility
        real_gap = not any(o["lane"] == car["target_lane"] and abs(o["position"] - car["position"]) < 4 for o in cars if o["id"] != car["id"])
        
        # THE ANCHOR: 16% Noise = 0.84 Accuracy limit
        # If the driver misjudges the gap 16% of the time, the ML model will fail 16% of the time.
        perceived_gap = 1 if (real_gap if random.random() > 0.16 else not real_gap) else 0

        decision = current_lane
        # DETERMINISTIC RULE (No randomness here)
        if current_lane != car["target_lane"] and real_gap:
            if urgency > 0.4 or car["aggressiveness"] > 0.9:
                decision = car["target_lane"]

        raw_dataset.append({
            "speed": car["speed"],
            "urgency": urgency,
            "aggressiveness": car["aggressiveness"],
            "rel_target": car["target_lane"] - current_lane,
            "perceived_gap": perceived_gap,
            "action": 1 if decision != current_lane else 0 # TARGET VARIABLE
        })
        
        car["lane"] = decision
        car["position"] = (car["position"] + car["speed"] * 0.1) % ROAD_LENGTH
        car["distance_to_turn"] -= car["speed"] * 0.1
        
        if car["distance_to_turn"] <= 0 or decision == car["target_lane"]:
            car["distance_to_turn"] = 150
            car["target_lane"] = np.random.choice([l for l in [1, 2, 3] if l != car["lane"]])

df = pd.DataFrame(raw_dataset)

# -----------------------
# BALANCING (THE CRITICAL STEP)
# -----------------------
changes = df[df['action'] == 1]
stays = df[df['action'] == 0]

# Sample equally from both classes to hit 50/50 balance
sample_size = min(len(changes), 10000)
balanced_df = pd.concat([changes.sample(sample_size), stays.sample(sample_size)])

X = balanced_df.drop('action', axis=1)
y = balanced_df['action']

X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, stratify=y)

# Depth 7 is necessary to capture the Urgency/Aggression boundary
model = RandomForestClassifier(max_depth=7, n_estimators=100, random_state=42)
model.fit(X_train, y_train)

# -----------------------
# OUTPUT
# -----------------------
y_pred = model.predict(X_test)
print(f"\nLane change events in dataset: {len(changes)}")
print(f"Accuracy (on balanced 50/50 set): {accuracy_score(y_test, y_pred):.2f}")

print("\n--- ML-BASED DECISION TEST ---")
for i in range(5):
    car = cars[i]
    feat = pd.DataFrame([{
        "speed": car["speed"],
        "urgency": max(0, (150 - car["distance_to_turn"]) / 150),
        "aggressiveness": car["aggressiveness"],
        "rel_target": car["target_lane"] - car["lane"],
        "perceived_gap": 1 
    }])
    # 0 = Stay, 1 = Change
    pred_action = model.predict(feat)[0]
    action_text = "CHANGE" if pred_action == 1 else "STAY"
    print(f"Car {i} → Current: {int(car['lane'])} | ML Suggests: {action_text}")