# 🚗 Permanent ML Infrastructure for Godot

## Quick Start

### 1️⃣ Setup (One-time)
```bash
# Install dependencies
pip install -r requirements.txt

# Train and save all models permanently
python train_models.py
```

### 2️⃣ Start ML Server
```bash
# Run WebSocket server for Godot
python ml_server.py
```

Server will be available at: `ws://localhost:8765`

### 3️⃣ Test Connection (Optional)
```bash
# In another terminal, test the server
python test_client.py
```

---

## 📡 Godot Integration

### GDScript Example (WebSocket Client)

```gdscript
extends Node

var websocket = WebSocketClient.new()
var ml_server_url = "ws://localhost:8765"

func _ready():
    websocket.connect_to_url(ml_server_url)
    websocket.connect("connection_established", self, "_on_connection_established")
    websocket.connect("data_received", self, "_on_data_received")

func _on_connection_established():
    print("Connected to ML Server!")

func _on_data_received():
    var message = websocket.get_message()
    var data = JSON.parse(message).result
    print("ML Prediction: ", data)

func predict_lane_change(car_state: Dictionary):
    var request = {
        "type": "predict_lane_change",
        "car_state": car_state
    }
    websocket.put_packet(JSON.stringify(request).to_utf8())

func _process(_delta):
    websocket.poll()
    
    # Example: Get prediction for car
    if Input.is_action_just_pressed("ui_accept"):
        var car_state = {
            "speed": 15.5,
            "urgency": 0.75,
            "aggressiveness": 0.85,
            "rel_target": 1,
            "perceived_gap": 1
        }
        predict_lane_change(car_state)
```

---

## 🤖 Available Models

### 1. **Lane Change Model** (0.84 accuracy)
**When to use**: Best for general lane-changing decisions

```json
{
  "type": "predict_lane_change",
  "car_state": {
    "speed": 15.5,
    "urgency": 0.75,
    "aggressiveness": 0.85,
    "rel_target": 1,
    "perceived_gap": 1
  }
}
```

**Response**:
```json
{
  "type": "prediction",
  "scenario": "lane_change",
  "result": {
    "decision": "MERGE",
    "confidence": 0.92,
    "target_lane": 3,
    "model": "lane_change"
  }
}
```

### 2. **Turning Model**
**When to use**: Exit/turn maneuvers with specific turning logic

### 3. **V2V Chat Model**
**When to use**: Multi-car negotiation and vehicle-to-vehicle communication

---

## 📊 Feature Definitions

All models expect the same 5 features:

| Feature | Type | Range | Description |
|---------|------|-------|-------------|
| `speed` | float | 0-25 m/s | Current velocity |
| `urgency` | float | 0-1 | How critical the maneuver is (0=relaxed, 1=critical) |
| `aggressiveness` | float | 0-1 | Driver personality (0=cautious, 1=aggressive) |
| `rel_target` | int | -2 to +2 | Relative lanes to target (-1=left, +1=right) |
| `perceived_gap` | int | 0 or 1 | Is a safe gap visible? (1=yes, 0=no) |

---

## 🔄 Batch Predictions

For multiple cars in one request:

```json
{
  "type": "batch_predict",
  "scenario": "lane_change",
  "car_states": [
    {"speed": 12, "urgency": 0.3, "aggressiveness": 0.7, "rel_target": 1, "perceived_gap": 1},
    {"speed": 18, "urgency": 0.8, "aggressiveness": 0.9, "rel_target": -1, "perceived_gap": 0},
    {"speed": 14, "urgency": 0.5, "aggressiveness": 0.5, "rel_target": 1, "perceived_gap": 1}
  ]
}
```

---

## 🛠️ Architecture

```
train_models.py (Train once, save forever)
        ↓
    models/ (Persistent saved models)
        ↓
model_manager.py (Load & manage models)
        ↓
    ml_server.py (WebSocket server)
        ↓
    Godot Client (Your game)
```

---

## 📝 Files

- `train_models.py` - Train all 3 ML models, save to disk
- `model_manager.py` - Load models, make predictions
- `ml_server.py` - WebSocket server for Godot
- `test_client.py` - Test client to verify server works
- `models/` - Persistent trained models (created after train_models.py)

---

## ⚙️ Performance

- **Inference latency**: ~5-10ms per prediction
- **Batch latency**: ~2-5ms per car (for batch_predict)
- **Model load time**: ~100ms (one-time at startup)

Suitable for **real-time** Godot gameplay!

---

## 🔌 Troubleshooting

### Server won't start
```bash
# Check if port 8765 is in use
netstat -ano | findstr :8765

# Try different port in ml_server.py (line 45)
# await websockets.serve(handle_client, "localhost", 9999)
```

### Models not found
```bash
# Ensure train_models.py completed successfully
python train_models.py

# Check models/ directory exists
dir models
```

### Godot connection fails
```gdscript
# Make sure WebSocket server is running
# Check URL: ws://localhost:8765
# Both must be on same machine OR use machine IP instead of localhost
```

---

## 🚀 Next Steps

1. ✅ Train models: `python train_models.py`
2. ✅ Start server: `python ml_server.py`
3. ✅ Test it: `python test_client.py`
4. 🔧 Integrate GDScript in Godot
5. 🎮 Use predictions in game logic
