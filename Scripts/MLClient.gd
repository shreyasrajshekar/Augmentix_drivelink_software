extends Node
class_name MLClient

signal prediction_received(prediction_data, target_car_index)
signal connection_established
signal connection_lost

var websocket = WebSocketPeer.new()
var server_url = "ws://localhost:8765"
var connected = false
var last_state = null

# Tracks which car made the request so we can route the response back to it
var request_queue: Array = []

func _ready():
	connect_to_server()

func connect_to_server():
	print("🔌 Connecting to ML Server: ", server_url)
	var error = websocket.connect_to_url(server_url)
	if error != OK:
		print("❌ Failed to connect: ", error)
		await get_tree().create_timer(3.0).timeout
		connect_to_server()

func _process(_delta):
	websocket.poll()
	var state = websocket.get_ready_state()
	
	
	
	if state == WebSocketPeer.STATE_OPEN:
		if not connected:
			print("✅ Connected to ML Server!")
			connected = true
			emit_signal("connection_established")
		while websocket.get_available_packet_count() > 0:
			var packet = websocket.get_packet()
			var text = packet.get_string_from_utf8()
			var json = JSON.new()
			var err = json.parse(text)
			if err == OK:
				# Pop the oldest requester from the queue
				var target_car = -1
				if request_queue.size() > 0:
					target_car = request_queue.pop_front()
				emit_signal("prediction_received", json.data, target_car)
			else:
				print("❌ JSON parse error: ", text)

	elif state == WebSocketPeer.STATE_CLOSED:
		if connected:
			print("❌ Connection lost - reconnecting...")
			connected = false
			emit_signal("connection_lost")
			await get_tree().create_timer(3.0).timeout
			connect_to_server()
	
func _send_request(request: Dictionary):
	websocket.send_text(JSON.stringify(request))

# Notice we now pass car_index into these functions
func predict_lane_change(car_state: Dictionary, car_index: int):
	if not connected: return
	
	print("\n=== SENDING TO ML ===")
	print("Car:", car_index)
	print(car_state)
	
	request_queue.append(car_index)
	last_state = car_state
	_send_request({"type": "predict_lane_change", "car_state": car_state})

func predict_turning(car_state: Dictionary, car_index: int):
	if not connected: return
	request_queue.append(car_index)
	last_state = car_state
	_send_request({"type": "predict_turning", "car_state": car_state})

func predict_v2v(car_state: Dictionary, car_index: int):
	if not connected: return
	request_queue.append(car_index)
	last_state = car_state
	_send_request({"type": "predict_v2v", "car_state": car_state})

func batch_predict(scenario: String, car_states: Array):
	if not connected: return
	request_queue.append(-2) # -2 signifies a batch request
	_send_request({"type": "batch_predict", "scenario": scenario, "car_states": car_states})

func ping():
	if not connected: return
	_send_request({"type": "ping"})
