extends Node3D
class_name Car

@export var base_speed: float = 15.0
@export var aggressiveness: float = 0.7

var car_index: int = 0
var lane: int = 1
var target_lane: int = 1
var current_speed: float = 0.0
var urgency: float = 0.0
var perceived_gap: int = 1

var travel_axis: int = 0
var travel_dir: float = 1.0

enum TurnState { STRAIGHT, WAITING_AT_INTERSECTION, TURNING }
var turn_state: int = TurnState.STRAIGHT

var _turn_start_pos: Vector3   = Vector3.ZERO
var _turn_pivot: Vector3       = Vector3.ZERO
var _turn_radius: float        = 0.0
var _turn_angle_total: float   = 0.0
var _turn_angle_done: float    = 0.0
var _turn_speed: float         = 0.0

var _next_axis: int   = 0
var _next_dir: float  = 1.0
var _next_lane: int   = 1
var _turning_straight: bool = false

var _stop_wait_timer: float = 0.0
const STOP_WAIT_MIN: float  = 0.3
const STOP_WAIT_MAX: float  = 1.0

const INTERSECTION_LOOK: float = 14.0
const INTERSECTION_SNAP: float = 4.5

var _committed_intersection: Vector2 = Vector2(INF, INF)

var ml_client: MLClient
var awaiting_prediction: bool = false
var prediction_cooldown: float = 0.0
const PREDICT_INTERVAL: float = 0.8

var is_merging: bool = false
var merge_start_offset: float = 0.0
var merge_target_offset: float = 0.0
var merge_t: float = 0.0
const MERGE_DURATION: float = 1.6

var _braking: bool = false
var _brake_target_speed: float = 0.0
var _emergency_stop: bool = false

const LOOK_AHEAD:    float = 28.0
const SAFE_GAP:      float = 8.0
const HARD_STOP_GAP: float = 3.5
const BRAKE_RATE:    float = 12.0
const ACCEL_RATE:    float = 3.0

var num_lanes: int = 2
var lane_width: float = 3.5
var lane_x_positions: Array = []

var map_half: float   = 200.0
var block_size: float = 100.0

var body_mat: StandardMaterial3D
var indicator_mat_L: StandardMaterial3D
var indicator_mat_R: StandardMaterial3D
var _indicator_blink: float = 0.0

const CAR_COLORS: Array = [
	Color(0.90, 0.12, 0.12), Color(0.12, 0.40, 0.92),
	Color(0.08, 0.76, 0.22), Color(0.95, 0.70, 0.04),
	Color(0.58, 0.10, 0.85), Color(0.92, 0.42, 0.08),
	Color(0.08, 0.72, 0.80), Color(0.85, 0.85, 0.85),
]

func set_lane_config(n: int, w: float, pos: Array) -> void:
	num_lanes = n; lane_width = w; lane_x_positions = pos

func set_travel(axis: int, dir: float) -> void:
	travel_axis = axis; travel_dir = dir

func set_map_info(mhalf: float, bsize: float) -> void:
	map_half = mhalf; block_size = bsize

func _ready() -> void:
	current_speed = base_speed * randf_range(0.80, 1.15)
	_build_car_mesh(); _align_to_travel_direction()
	ml_client = get_node_or_null("/root/Main/MLClient")
	if ml_client: ml_client.prediction_received.connect(_on_ml_prediction)

func _align_to_travel_direction() -> void:
	if travel_axis == 1: rotation_degrees.y = 90.0 if travel_dir > 0 else -90.0
	else:                rotation_degrees.y = 0.0  if travel_dir < 0 else 180.0

func _process(delta: float) -> void:
	match turn_state:
		TurnState.STRAIGHT:
			_handle_collision_avoidance(delta)
			_handle_movement(delta)
			_handle_merge_animation(delta)
			_handle_intersection_approach()
		TurnState.WAITING_AT_INTERSECTION:
			current_speed = move_toward(current_speed, 0.0, BRAKE_RATE * delta)
			_stop_wait_timer -= delta
			if _stop_wait_timer <= 0.0: _execute_chosen_turn()
		TurnState.TURNING:
			_handle_turn_movement(delta)
	_handle_indicator_blink(delta)
	_update_urgency()
	_handle_prediction_request(delta)

func _handle_movement(delta: float) -> void:
	if _emergency_stop:
		current_speed = move_toward(current_speed, 0.0, BRAKE_RATE * 3.0 * delta); return
	if _braking: current_speed = move_toward(current_speed, max(_brake_target_speed, 0.0), BRAKE_RATE * delta)
	else:        current_speed = move_toward(current_speed, base_speed, ACCEL_RATE * delta)
	var move = current_speed * travel_dir * delta
	if travel_axis == 0: position.z += move
	else:                position.x += move

func _handle_collision_avoidance(_delta: float) -> void:
	var result = _find_car_ahead()
	if result.is_empty():
		_braking = false; _emergency_stop = false; perceived_gap = int(LOOK_AHEAD * 2); return
	var dist: float = result["dist"]; var ahead_speed: float = result["speed"]
	perceived_gap = int(dist)
	if dist <= HARD_STOP_GAP:
		_emergency_stop = true; _braking = false
	elif dist <= LOOK_AHEAD:
		_emergency_stop = false; _braking = true
		var gap_ratio = clamp((dist - SAFE_GAP) / (LOOK_AHEAD - SAFE_GAP), 0.0, 1.0)
		_brake_target_speed = max(ahead_speed * gap_ratio, 0.5)
		if dist < SAFE_GAP * 1.5 and not is_merging and not awaiting_prediction and target_lane == lane:
			_pick_escape_lane()
	else:
		_braking = false; _emergency_stop = false

func _find_car_ahead() -> Dictionary:
	var main = get_node_or_null("/root/Main")
	if not main or not main.has_method("get_cars"): return {}
	var my_t = position.z if travel_axis == 0 else position.x
	var my_p = position.x if travel_axis == 0 else position.z
	var cd: float = LOOK_AHEAD + 1.0; var cs: float = 0.0; var found = false
	for other in main.get_cars():
		if other == self or other.turn_state == TurnState.TURNING: continue
		if other.travel_axis != travel_axis or other.travel_dir != travel_dir: continue
		var op = other.position.x if travel_axis == 0 else other.position.z
		if abs(op - my_p) > lane_width * 0.75: continue
		var ot = other.position.z if travel_axis == 0 else other.position.x
		var rd = (ot - my_t) * travel_dir
		if rd > 0.0 and rd < cd: cd = rd; cs = other.current_speed; found = true
	if not found: return {}
	return {"dist": cd, "speed": cs}

func _pick_escape_lane() -> void:
	var cands: Array = []
	if lane > 1: cands.append(lane - 1)
	if lane < num_lanes: cands.append(lane + 1)
	cands.shuffle()
	var main = get_node_or_null("/root/Main")
	for c in cands:
		if _lane_is_clear(c, main): target_lane = c; return

func _lane_is_clear(check_lane: int, main: Node) -> bool:
	if not main or not main.has_method("get_cars"): return true
	var my_t = position.z if travel_axis == 0 else position.x
	var tp = _lane_offset(check_lane)
	for other in main.get_cars():
		if other == self: continue
		if other.travel_axis != travel_axis or other.travel_dir != travel_dir: continue
		var op = other.position.x if travel_axis == 0 else other.position.z
		if abs(op - tp) > lane_width * 0.75: continue
		var ot = other.position.z if travel_axis == 0 else other.position.x
		if abs(ot - my_t) < SAFE_GAP * 2.0: return false
	return true

func _handle_intersection_approach() -> void:
	if is_merging: return
	var my_t : float = position.z if travel_axis == 0 else position.x
	var my_p : float = position.x if travel_axis == 0 else position.z
	var road_c : float = snappedf(my_p, block_size)
	var nc : float = _next_grid_line(my_t, travel_dir)
	var dist : float = (nc - my_t) * travel_dir
	if dist < 0.0 or dist > INTERSECTION_LOOK: return
	var ix : float = road_c if travel_axis == 0 else nc
	var iz : float = nc     if travel_axis == 0 else road_c
	if abs(ix) >= map_half - block_size * 0.4 or abs(iz) >= map_half - block_size * 0.4: return
	var key = Vector2(ix, iz)
	if key == _committed_intersection: return
	if dist <= INTERSECTION_SNAP:
		_committed_intersection = key
		_choose_and_queue_turn(ix, iz)

func _next_grid_line(tp: float, dir: float) -> float:
	if dir > 0: return (floor(tp / block_size) + 1.0) * block_size
	else:       return (ceil(tp / block_size)  - 1.0) * block_size

func _choose_and_queue_turn(ix: float, iz: float) -> void:
	if turn_state != TurnState.STRAIGHT: return
	var options : Array = []
	if _exit_in_bounds(travel_axis, travel_dir, ix, iz):
		options.append({"axis": travel_axis, "dir": travel_dir, "lane": lane, "straight": true})
	var perp_axis : int = 1 if travel_axis == 0 else 0
	for pd in [1.0, -1.0]:
		if _exit_in_bounds(perp_axis, pd, ix, iz):
			options.append({"axis": perp_axis, "dir": pd, "lane": 1, "straight": false})
	if options.is_empty(): return
	options.shuffle()
	var chosen = options[0]
	_next_axis = chosen["axis"]; _next_dir = chosen["dir"]
	_next_lane = chosen["lane"]; _turning_straight = chosen["straight"]
	if travel_axis == 0: position.z = iz - travel_dir * (lane_width * 0.8)
	else:                position.x = ix - travel_dir * (lane_width * 0.8)
	position.y = 0.0
	turn_state = TurnState.WAITING_AT_INTERSECTION
	_stop_wait_timer = randf_range(STOP_WAIT_MIN, STOP_WAIT_MAX)
	_braking = false; _emergency_stop = false

func _exit_in_bounds(axis: int, dir: float, ix: float, iz: float) -> bool:
	var margin : float = block_size * 0.6
	if axis == 0: return abs(iz + dir * block_size) < map_half - margin and abs(ix) < map_half - margin
	else:         return abs(ix + dir * block_size) < map_half - margin and abs(iz) < map_half - margin

func _execute_chosen_turn() -> void:
	if _turning_straight:
		travel_axis = _next_axis; travel_dir = _next_dir
		lane = _next_lane; target_lane = _next_lane
		turn_state = TurnState.STRAIGHT; _align_to_travel_direction(); return
	_build_turn_arc()
	turn_state = TurnState.TURNING

func _build_turn_arc() -> void:
	var r : float = lane_width * 1.3; _turn_radius = r
	var cur_h = Vector3(0, 0, travel_dir) if travel_axis == 0 else Vector3(travel_dir, 0, 0)
	var new_h = Vector3(0, 0, _next_dir) if _next_axis == 0 else Vector3(_next_dir, 0, 0)
	var cy = cur_h.x * new_h.z - cur_h.z * new_h.x
	var ts : float = sign(cy); if ts == 0.0: ts = 1.0
	var rh = Vector3(cur_h.z, 0.0, -cur_h.x)
	_turn_pivot = position + rh * (-ts) * r; _turn_pivot.y = 0.0
	_turn_start_pos = position
	_turn_angle_total = -ts * PI * 0.5; _turn_angle_done = 0.0
	_turn_speed = max(current_speed, 2.0) / r

func _handle_turn_movement(delta: float) -> void:
	current_speed = move_toward(current_speed, base_speed * 0.5, ACCEL_RATE * delta)
	_turn_speed = max(current_speed, 1.0) / max(_turn_radius, 0.5)
	var step = _turn_speed * delta
	var remaining = _turn_angle_total - _turn_angle_done
	if abs(remaining) <= abs(step) + 0.002: _finish_arc(); return
	_turn_angle_done += sign(_turn_angle_total) * step
	var sa = atan2(_turn_start_pos.z - _turn_pivot.z, _turn_start_pos.x - _turn_pivot.x)
	var ca = sa + _turn_angle_done
	position.x = _turn_pivot.x + _turn_radius * cos(ca)
	position.z = _turn_pivot.z + _turn_radius * sin(ca); position.y = 0.0
	rotation.y = -(ca + sign(_turn_angle_total) * PI * 0.5)

func _finish_arc() -> void:
	travel_axis = _next_axis; travel_dir = _next_dir
	lane = _next_lane; target_lane = _next_lane
	var loff : float = _get_lane_world_offset(_next_lane, _next_dir)
	if travel_axis == 0: position.x = snappedf(position.x, block_size) + loff
	else:                position.z = snappedf(position.z, block_size) + loff
	position.y = 0.0
	turn_state = TurnState.STRAIGHT; _align_to_travel_direction(); _set_indicators(0)
	current_speed = base_speed * randf_range(0.70, 1.0)
	_committed_intersection = Vector2(INF, INF)

func _get_lane_world_offset(l: int, dir: float) -> float:
	if lane_x_positions.is_empty(): return lane_width * 0.5 * dir
	return lane_x_positions[clamp(l - 1, 0, lane_x_positions.size() - 1)] * dir

func _handle_merge_animation(delta: float) -> void:
	if not is_merging: return
	merge_t = clamp(merge_t + delta / MERGE_DURATION, 0.0, 1.0)
	var no = lerp(merge_start_offset, merge_target_offset, _ease_in_out(merge_t))
	if travel_axis == 0: position.x = no
	else:                position.z = no
	if merge_t >= 1.0: is_merging = false; lane = target_lane; _set_indicators(0)

func _start_merge() -> void:
	if target_lane == lane or is_merging: return
	var main = get_node_or_null("/root/Main")
	if not _lane_is_clear(target_lane, main): target_lane = lane; return
	is_merging = true; merge_t = 0.0
	merge_start_offset = position.x if travel_axis == 0 else position.z
	merge_target_offset = _lane_offset(target_lane)
	_set_indicators(sign(target_lane - lane))

func _update_urgency() -> void:
	urgency = clamp(float(abs(target_lane - lane)) / float(max(num_lanes, 1)), 0.0, 1.0)

func _handle_prediction_request(delta: float) -> void:
	prediction_cooldown -= delta
	if prediction_cooldown > 0 or awaiting_prediction or is_merging or turn_state != TurnState.STRAIGHT: return
	if target_lane != lane: _request_ml_decision(); prediction_cooldown = PREDICT_INTERVAL

func _request_ml_decision() -> void:
	if not ml_client or not ml_client.connected: return
	awaiting_prediction = true
	ml_client.predict_lane_change({"speed": current_speed, "urgency": urgency,
		"aggressiveness": aggressiveness, "rel_target": target_lane - lane,
		"perceived_gap": perceived_gap}, car_index)

func _on_ml_prediction(prediction_data: Dictionary, target_car_index: int) -> void:
	if target_car_index != -1 and target_car_index != -2 and target_car_index != car_index: return
	if not prediction_data.has("result"): awaiting_prediction = false; return
	var result = prediction_data["result"]
	if target_car_index == -2 and typeof(result) == TYPE_ARRAY:
		if car_index < result.size(): result = result[car_index]
		else: return
	var decision = result.get("decision", "WAIT"); awaiting_prediction = false
	if decision == "WAIT" and perceived_gap > 15 and aggressiveness > 0.7: decision = "MERGE"
	if decision == "MERGE": _start_merge()
	var hud = get_node_or_null("/root/Main/HUD")
	if hud and hud.has_method("update_car"):
		hud.update_car(car_index, lane, decision, result.get("confidence", 0.0), current_speed)

func _handle_indicator_blink(delta: float) -> void:
	if not awaiting_prediction and not is_merging and turn_state == TurnState.STRAIGHT: return
	_indicator_blink += delta
	var on = fmod(_indicator_blink, 0.5) < 0.25
	if indicator_mat_L: indicator_mat_L.emission_energy_multiplier = 3.0 if on else 0.0
	if indicator_mat_R: indicator_mat_R.emission_energy_multiplier = 3.0 if on else 0.0

func _set_indicators(direction: int) -> void:
	_indicator_blink = 0.0
	if indicator_mat_L: indicator_mat_L.emission_energy_multiplier = 0.0
	if indicator_mat_R: indicator_mat_R.emission_energy_multiplier = 0.0

func set_target_lane(new_target: int) -> void:
	if new_target >= 1 and new_target <= num_lanes: target_lane = new_target

func _lane_offset(l: int) -> float:
	if lane_x_positions.is_empty(): return 0.0
	return lane_x_positions[clamp(l - 1, 0, lane_x_positions.size() - 1)] * travel_dir

func _ease_in_out(t: float) -> float: return t * t * (3.0 - 2.0 * t)

func _build_car_mesh() -> void:
	var color = CAR_COLORS[car_index % CAR_COLORS.size()]
	body_mat = StandardMaterial3D.new(); body_mat.albedo_color = color; body_mat.roughness = 0.32; body_mat.metallic = 0.35
	var glass_mat = StandardMaterial3D.new(); glass_mat.albedo_color = Color(0.15, 0.20, 0.30, 0.65)
	glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; glass_mat.roughness = 0.05
	var wheel_mat = StandardMaterial3D.new(); wheel_mat.albedo_color = Color(0.08, 0.08, 0.08); wheel_mat.roughness = 0.92
	var hub_mat = StandardMaterial3D.new(); hub_mat.albedo_color = Color(0.72, 0.72, 0.76); hub_mat.metallic = 0.88; hub_mat.roughness = 0.18
	_add_box(Vector3(0, 0.5, 0), Vector3(1.8, 0.55, 4.0), body_mat)
	_add_box(Vector3(0, 1.08, 0.20), Vector3(1.35, 0.50, 2.20), body_mat)
	_add_box_rot(Vector3(0, 1.04, -0.88), Vector3(1.30, 0.44, 0.06), Vector3(-18, 0, 0), glass_mat)
	_add_box_rot(Vector3(0, 1.04,  1.44), Vector3(1.30, 0.44, 0.06), Vector3( 18, 0, 0), glass_mat)
	var hl = _emissive_mat(Color(1.0, 0.98, 0.88), 3.0)
	_add_box(Vector3(-0.62, 0.52, -2.04), Vector3(0.28, 0.12, 0.05), hl)
	_add_box(Vector3( 0.62, 0.52, -2.04), Vector3(0.28, 0.12, 0.05), hl)
	var tl = _emissive_mat(Color(0.9, 0.05, 0.05), 2.0)
	_add_box(Vector3(-0.62, 0.52, 2.04), Vector3(0.28, 0.12, 0.05), tl)
	_add_box(Vector3( 0.62, 0.52, 2.04), Vector3(0.28, 0.12, 0.05), tl)
	indicator_mat_L = _emissive_mat(Color(1.0, 0.50, 0.0), 0.0)
	indicator_mat_R = _emissive_mat(Color(1.0, 0.50, 0.0), 0.0)
	_add_box(Vector3(-0.92, 0.52, 0.0), Vector3(0.05, 0.10, 0.28), indicator_mat_L)
	_add_box(Vector3( 0.92, 0.52, 0.0), Vector3(0.05, 0.10, 0.28), indicator_mat_R)
	for wx in [-1.0, 1.0]:
		for wz in [-1.30, 1.30]:
			var wn = MeshInstance3D.new(); var wm = CylinderMesh.new()
			wm.top_radius = 0.32; wm.bottom_radius = 0.32; wm.height = 0.22; wm.radial_segments = 16
			wn.mesh = wm; wn.rotation_degrees = Vector3(0, 0, 90); wn.position = Vector3(wx, 0.32, wz)
			wn.material_override = wheel_mat; add_child(wn)
			var hn = MeshInstance3D.new(); var hm = CylinderMesh.new()
			hm.top_radius = 0.16; hm.bottom_radius = 0.16; hm.height = 0.24; hm.radial_segments = 8
			hn.mesh = hm; hn.rotation_degrees = Vector3(0, 0, 90); hn.position = Vector3(wx, 0.32, wz)
			hn.material_override = hub_mat; add_child(hn)

func _add_box(pos, size, mat) -> MeshInstance3D:
	var mi = MeshInstance3D.new(); var bm = BoxMesh.new(); bm.size = size
	mi.mesh = bm; mi.position = pos; mi.material_override = mat; add_child(mi); return mi

func _add_box_rot(pos, size, rot_deg, mat) -> MeshInstance3D:
	var mi = _add_box(pos, size, mat); mi.rotation_degrees = rot_deg; return mi

func _emissive_mat(color, energy) -> StandardMaterial3D:
	var mat = StandardMaterial3D.new(); mat.albedo_color = color
	mat.emission_enabled = true; mat.emission = color; mat.emission_energy_multiplier = energy; return mat
