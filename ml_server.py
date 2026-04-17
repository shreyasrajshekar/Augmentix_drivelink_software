"""
ML WebSocket Server for Godot Integration
Real-time ML predictions via WebSocket for Godot cars
"""

import asyncio
import json
import websockets
from model_manager import ModelManager

# Initialize model manager
print("Starting ML Server...")
manager = ModelManager()

clients = set()

async def handle_client(websocket, path):
    """Handle incoming WebSocket connections from Godot"""
    clients.add(websocket)
    print(f"[WebSocket] Client connected. Total clients: {len(clients)}")
    
    try:
        async for message in websocket:
            try:
                data = json.loads(message)
                
                # Route to appropriate handler
                request_type = data.get('type', '')
                
                if request_type == 'predict_lane_change':
                    result = manager.predict_lane_change(data.get('car_state', {}))
                    await websocket.send(json.dumps({
                        'type': 'prediction',
                        'scenario': 'lane_change',
                        'result': result
                    }))
                
                elif request_type == 'predict_turning':
                    result = manager.predict_turning(data.get('car_state', {}))
                    await websocket.send(json.dumps({
                        'type': 'prediction',
                        'scenario': 'turning',
                        'result': result
                    }))
                
                elif request_type == 'predict_v2v':
                    result = manager.predict_v2v_negotiation(data.get('car_state', {}))
                    await websocket.send(json.dumps({
                        'type': 'prediction',
                        'scenario': 'v2v',
                        'result': result
                    }))
                
                elif request_type == 'batch_predict':
                    scenario = data.get('scenario', 'lane_change')
                    car_states = data.get('car_states', [])
                    results = manager.batch_predict(scenario, car_states)
                    await websocket.send(json.dumps({
                        'type': 'batch_prediction',
                        'scenario': scenario,
                        'results': results
                    }))
                
                elif request_type == 'get_models':
                    models_info = manager.get_model_info()
                    await websocket.send(json.dumps({
                        'type': 'models_info',
                        'models': {k: str(v) for k, v in models_info.items()}
                    }))
                
                elif request_type == 'ping':
                    await websocket.send(json.dumps({
                        'type': 'pong',
                        'status': 'alive'
                    }))
                
                else:
                    await websocket.send(json.dumps({
                        'error': f'Unknown request type: {request_type}'
                    }))
            
            except json.JSONDecodeError:
                await websocket.send(json.dumps({
                    'error': 'Invalid JSON'
                }))
            except Exception as e:
                await websocket.send(json.dumps({
                    'error': str(e)
                }))
    
    except websockets.exceptions.ConnectionClosed:
        print("[WebSocket] Client disconnected")
    finally:
        clients.remove(websocket)
        print(f"[WebSocket] Client removed. Total clients: {len(clients)}")


async def main():
    """Start WebSocket server"""
    server = await websockets.serve(handle_client, "localhost", 8765)
    print("\n" + "="*60)
    print("ML WebSocket Server Started")
    print("="*60)
    print("\nServer: ws://localhost:8765")
    print("\nAvailable Models:")
    for model_name in manager.models.keys():
        print(f"  • {model_name}")
    
    print("\nRequest Types:")
    print("  • predict_lane_change")
    print("  • predict_turning")
    print("  • predict_v2v")
    print("  • batch_predict")
    print("  • get_models")
    print("  • ping")
    
    print("\nExample Godot Request:")
    example = {
        "type": "predict_lane_change",
        "car_state": {
            "speed": 15.5,
            "urgency": 0.75,
            "aggressiveness": 0.85,
            "rel_target": 1,
            "perceived_gap": 1
        }
    }
    print(f"  {json.dumps(example, indent=2)}")
    
    print("\n" + "="*60)
    print("Waiting for connections...\n")
    
    await server.wait_closed()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n\n[Server] Shutting down...")
