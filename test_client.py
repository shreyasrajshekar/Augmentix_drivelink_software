"""
Godot ML Client Example
Shows how to connect to ML Server and get predictions
Can be translated to GDScript for use in Godot
"""

import asyncio
import json
import websockets

async def test_ml_server():
    """Test ML Server with sample requests"""
    
    uri = "ws://localhost:8765"
    
    try:
        async with websockets.connect(uri) as websocket:
            print("\n" + "="*60)
            print("GODOT ML CLIENT - TEST")
            print("="*60)
            
            # Test 1: Ping
            print("\n[Test 1] Ping Server")
            await websocket.send(json.dumps({"type": "ping"}))
            response = await websocket.recv()
            print(f"Response: {response}")
            
            # Test 2: Get Models Info
            print("\n[Test 2] Get Available Models")
            await websocket.send(json.dumps({"type": "get_models"}))
            response = await websocket.recv()
            print(f"Response: {response}")
            
            # Test 3: Lane Change Prediction
            print("\n[Test 3] Lane Change Prediction")
            car_state = {
                'speed': 15.5,
                'urgency': 0.75,
                'aggressiveness': 0.85,
                'rel_target': 1,
                'perceived_gap': 1
            }
            await websocket.send(json.dumps({
                "type": "predict_lane_change",
                "car_state": car_state
            }))
            response = await websocket.recv()
            result = json.loads(response)
            print(f"Response: {json.dumps(result, indent=2)}")
            
            # Test 4: Batch Prediction
            print("\n[Test 4] Batch Prediction (3 cars)")
            car_states = [
                {'speed': 12, 'urgency': 0.3, 'aggressiveness': 0.7, 'rel_target': 1, 'perceived_gap': 1},
                {'speed': 18, 'urgency': 0.8, 'aggressiveness': 0.9, 'rel_target': -1, 'perceived_gap': 0},
                {'speed': 14, 'urgency': 0.5, 'aggressiveness': 0.5, 'rel_target': 1, 'perceived_gap': 1},
            ]
            await websocket.send(json.dumps({
                "type": "batch_predict",
                "scenario": "lane_change",
                "car_states": car_states
            }))
            response = await websocket.recv()
            result = json.loads(response)
            print(f"Response: {json.dumps(result, indent=2)}")
            
            # Test 5: V2V Negotiation
            print("\n[Test 5] V2V Negotiation Prediction")
            await websocket.send(json.dumps({
                "type": "predict_v2v",
                "car_state": car_state
            }))
            response = await websocket.recv()
            result = json.loads(response)
            print(f"Response: {json.dumps(result, indent=2)}")
            
            print("\n" + "="*60)
            print("ALL TESTS COMPLETED")
            print("="*60 + "\n")
    
    except ConnectionRefusedError:
        print("\n✗ ERROR: Could not connect to ML Server")
        print("  Make sure ml_server.py is running")
        print("  Run: python ml_server.py")
    except Exception as e:
        print(f"\n✗ ERROR: {e}")


if __name__ == "__main__":
    print("\nConnecting to ML Server at ws://localhost:8765...")
    asyncio.run(test_ml_server())
