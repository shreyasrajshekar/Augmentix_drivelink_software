extends Node3D
class_name Car

# ── Exports ──────────────────────────────────────────────────────────────────
@export var base_speed: float = 15.0
@export var aggressiveness: float = 0.7

# ── Public state (read by Main / HUD) ────────────────────────────────────────
var car_index: int = 0
var lane: int = 1
var target_lane: int = 1
var current_speed: float = 0.0
var urgency: float = 0.0
var perceived_gap: int = 1

# ── Internal ──────────────────────────────────────────────────────────────────
var ml_client: MLClient
var awaiting_prediction: bool = false
var prediction_cooldown: float = 0.0
const PREDICT_INTERVAL: float = 0.6

# Merge animation
var is_merging: bool = false
var merge_start_x: float = 0.0
var merge_target_x: float = 0.0
var merge_t: float = 0.0
const MERGE_DURATION: float = 1.4

# Collision avoidance
var _braking: bool = false
var _brake_target_speed: float = 0.0
const LOOK_AHEAD: float = 20.0      # metres to scan for cars ahead
const SAFE_GAP: float = 5.0         # desired following distance
const BRAKE_RATE: float = 8.0       # m/s² deceleration
const ACCEL_RATE: float = 4.0       # m/s² acceleration

# Lane geometry – set by Main before _ready via set_lane_config()
var num_lanes: int = 3
var lane_width: float = 3.5
var lane_x_positions: Array = []    # index 0 = lane 1

# Visual
var body_mat: StandardMaterial3D
var indicator_mat_L: StandardMaterial3D
var indicator_mat_R: StandardMaterial3D
var _indicator_blink: float = 0.0

# Car colour palette
const CAR_COLORS: Array = [
	Color(0.90, 0.12, 0.12),
	Color(0.12, 0.40, 0.92),
	Color(0.08, 0.76, 0.22),
	Color(0.95, 0.70, 0.04),
	Color(0.58, 0.10, 0.85),
	Color(0.92, 0.42, 0.08),
	Color(0.08, 0.72, 0.80),
	Color(0.85, 0.85, 0.85),
]

# ── Called by Main before adding to scene tree ───────────────────────────────
func set_lane_config(n_lanes: int, l_width: float, positions: Array):
	num_lanes = n_lanes
	lane_width = l_width
	lane_x_positions = positions

# ── Lifecycle ─────────────────────────────────────────────────────────────────
func _ready():
	current_speed = base_speed * randf_range(0.85, 1.15)
	_build_car_mesh()
	position.x = _lane_x(lane)
	position.y = 0.0

	ml_client = get_node_or_null("/root/Main/MLClient")
	if ml_client:
		ml_client.prediction_received.connect(_on_ml_prediction)
	else:
		push_warning("Car %d: MLClient not found" % car_index)

func _process(delta: float):
	_handle_collision_avoidance(delta)
	_handle_movement(delta)
	_handle_merge_animation(delta)
	_handle_indicator_blink(delta)
	_handle_road_loop()
	_update_urgency()
	_handle_prediction_request(delta)

# ── Movement ──────────────────────────────────────────────────────────────────
func _handle_movement(delta: float):
	# Accelerate toward base speed when not braking
	if _braking:
		current_speed = move_toward(current_speed, _brake_target_speed, BRAKE_RATE * delta)
	else:
		current_speed = move_toward(current_speed, base_speed, ACCEL_RATE * delta)

	position.z -= current_speed * delta

# ── Collision avoidance ───────────────────────────────────────────────────────
func _handle_collision_avoidance(delta: float):
	var car_ahead = _find_car_ahead()
	if car_ahead == null:
		_braking = false
		return

	var dist = position.z - car_ahead.position.z   # both move in -Z; we are behind
	if dist < 0:
		dist = -dist

	if dist < LOOK_AHEAD or randf() < 0.02:
		_braking = true
		var gap_ratio = clamp((dist - SAFE_GAP) / LOOK_AHEAD, 0.0, 1.0)
		_brake_target_speed = car_ahead.current_speed * gap_ratio

		# Store actual measured gap
		perceived_gap = int(dist)

		# Try to change lane if blocked long enough and ML says ok
		if not is_merging and not awaiting_prediction and target_lane == lane:
			_pick_escape_lane()
	else:
		_braking = false
		perceived_gap = int(LOOK_AHEAD * 2)

func _find_car_ahead() -> Car:
	# Ask Main for the car list
	var main = get_node_or_null("/root/Main")
	if main == null or not main.has_method("get_cars"):
		return null

	var closest: Car = null
	var closest_dist: float = LOOK_AHEAD

	for other in main.get_cars():
		if other == self:
			continue
		if other.lane != lane:
			continue
		# 'ahead' means smaller Z value (cars move in -Z)
		var dz = position.z - other.position.z
		if dz > 0 and dz < closest_dist:
			closest_dist = dz
			closest = other

	return closest

func _pick_escape_lane():
	# Try adjacent lanes; pick one that has space
	var candidates: Array = []
	if lane > 1:
		candidates.append(lane - 1)
	if lane < num_lanes:
		candidates.append(lane + 1)
	candidates.shuffle()

	var main = get_node_or_null("/root/Main")
	for candidate in candidates:
		if _lane_is_clear(candidate, main):
			target_lane = candidate
			return

func _lane_is_clear(check_lane: int, main: Node) -> bool:
	if main == null or not main.has_method("get_cars"):
		return true
	for other in main.get_cars():
		if other == self or other.lane != check_lane:
			continue
		var dz = abs(position.z - other.position.z)
		if dz < SAFE_GAP * 1.5:
			return false
	return true

# ── Lane merge animation ──────────────────────────────────────────────────────
func _handle_merge_animation(delta: float):
	if not is_merging:
		return
	merge_t += delta / MERGE_DURATION
	merge_t = clamp(merge_t, 0.0, 1.0)
	position.x = lerp(merge_start_x, merge_target_x, _ease_in_out(merge_t))
	if merge_t >= 1.0:
		is_merging = false
		lane = target_lane
		_set_indicators(0)

func _start_merge():
	if target_lane == lane or is_merging:
		return
	# Final gap check before committing
	var main = get_node_or_null("/root/Main")
	print("Car", car_index, "ML APPROVED MERGE")
	if not _lane_is_clear(target_lane, main):
		print("❌ Merge blocked by lane safety check")
		target_lane = lane   # abort
		return
	is_merging = true
	merge_t = 0.0
	merge_start_x = position.x
	merge_target_x = _lane_x(target_lane)
	_set_indicators(sign(target_lane - lane))
	print("🚗 Car %d: merging lane %d → %d" % [car_index, lane, target_lane])

# ── Road loop ─────────────────────────────────────────────────────────────────
func _handle_road_loop():
	var main = get_node_or_null("/root/Main")
	if not main or not "virtual_camera_z" in main:
		return
		
	var cam_z = main.virtual_camera_z

	# Widened the limits so cars don't respawn mid-merge if they drive a bit slow!
	if position.z > cam_z + 40.0:
		_respawn_at(cam_z - randf_range(80.0, 110.0))
	elif position.z < cam_z - 200.0:
		_respawn_at(cam_z + randf_range(15.0, 25.0))

func _respawn_at(new_z: float):
	lane = randi() % num_lanes + 1
	target_lane = lane
	position.x = _lane_x(lane)
	var main = get_node("/root/Main")

	if main and main.has_method("_get_safe_spawn_z"):
		position.z = main._get_safe_spawn_z(lane, new_z)
	else:
		position.z = new_z
	
	is_merging = false
	merge_t = 0.0
	awaiting_prediction = false
	_braking = false
	current_speed = base_speed * randf_range(0.85, 1.15)
	_set_indicators(0)

# ── Urgency ───────────────────────────────────────────────────────────────────
func _update_urgency():
	urgency = clamp(float(abs(target_lane - lane)) / float(num_lanes), 0.0, 1.0)

# ── ML prediction ─────────────────────────────────────────────────────────────
func _handle_prediction_request(delta: float):
	prediction_cooldown -= delta

	if prediction_cooldown > 0 or awaiting_prediction or is_merging:
		return

	# Only request ML if we actually want to change lane
	if target_lane != lane:
		_request_ml_decision()
		prediction_cooldown = PREDICT_INTERVAL
func _request_ml_decision():
	if not ml_client or not ml_client.connected:
		return
	awaiting_prediction = true
	# Pass the car_index so MLClient knows who is asking
	ml_client.predict_lane_change({
		"speed": current_speed,
		"urgency": urgency,
		"aggressiveness": aggressiveness,
		"rel_target": target_lane - lane,
		"perceived_gap": perceived_gap
	}, car_index)

func _on_ml_prediction(prediction_data: Dictionary, target_car_index: int):
	# 1. Ignore responses meant for other cars (-2 is a batch predict)
	if target_car_index != -1 and target_car_index != -2 and target_car_index != car_index:
		return
	
	if not prediction_data.has("result"):
		awaiting_prediction = false
		return
		
	var result = prediction_data["result"]

	# 2. If it was a batch prediction (SPACEBAR), grab this specific car's result from the array
	if target_car_index == -2 and typeof(result) == TYPE_ARRAY:
		if car_index < result.size():
			result = result[car_index]
		else:
			return

	var decision = result.get("decision", "WAIT")
	awaiting_prediction = false

	if decision == "WAIT" and perceived_gap > 10 and aggressiveness > 0.6:
		decision = "MERGE"

	if decision == "MERGE":
		_start_merge()

	var hud = get_node_or_null("/root/Main/HUD")
	if hud and hud.has_method("update_car"):
		hud.update_car(car_index, lane, decision,
			result.get("confidence", 0.0), current_speed)
	print("Car", car_index, "Decision:", decision)
# ── Indicator lights ──────────────────────────────────────────────────────────
func _handle_indicator_blink(delta: float):
	if not awaiting_prediction and not is_merging:
		return
	_indicator_blink += delta
	var on = fmod(_indicator_blink, 0.5) < 0.25
	if indicator_mat_L:
		indicator_mat_L.emission_energy_multiplier = 3.0 if on else 0.0
	if indicator_mat_R:
		indicator_mat_R.emission_energy_multiplier = 3.0 if on else 0.0

func _set_indicators(direction: int):
	# direction: -1 left, 0 off, 1 right
	_indicator_blink = 0.0
	if indicator_mat_L:
		indicator_mat_L.emission_energy_multiplier = 0.0
	if indicator_mat_R:
		indicator_mat_R.emission_energy_multiplier = 0.0

# ── Helpers ───────────────────────────────────────────────────────────────────
func _lane_x(l: int) -> float:
	# Safeguard to prevent crashes if the array is empty
	if lane_x_positions.is_empty():
		push_warning("Car %d: lane_x_positions is empty!" % car_index)
		return 0.0
		
	var idx = clamp(l - 1, 0, lane_x_positions.size() - 1)
	return lane_x_positions[idx]

func _ease_in_out(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)

func set_target_lane(new_target: int):
	if new_target >= 1 and new_target <= num_lanes:
		target_lane = new_target

# ── Car mesh builder ──────────────────────────────────────────────────────────
func _build_car_mesh():
	var color = CAR_COLORS[car_index % CAR_COLORS.size()]

	body_mat = StandardMaterial3D.new()
	body_mat.albedo_color = color
	body_mat.roughness = 0.32
	body_mat.metallic = 0.35

	var glass_mat = StandardMaterial3D.new()
	glass_mat.albedo_color = Color(0.15, 0.20, 0.30, 0.65)
	glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass_mat.roughness = 0.05

	var wheel_mat = StandardMaterial3D.new()
	wheel_mat.albedo_color = Color(0.08, 0.08, 0.08)
	wheel_mat.roughness = 0.92

	var hub_mat = StandardMaterial3D.new()
	hub_mat.albedo_color = Color(0.72, 0.72, 0.76)
	hub_mat.metallic = 0.88
	hub_mat.roughness = 0.18

	# Body
	_add_box(Vector3(0, 0.5, 0), Vector3(1.8, 0.55, 4.0), body_mat)
	# Cabin
	_add_box(Vector3(0, 1.08, 0.20), Vector3(1.35, 0.50, 2.20), body_mat)
	# Front windshield
	_add_box_rot(Vector3(0, 1.04, -0.88), Vector3(1.30, 0.44, 0.06),
		Vector3(-18, 0, 0), glass_mat)
	# Rear windshield
	_add_box_rot(Vector3(0, 1.04, 1.44), Vector3(1.30, 0.44, 0.06),
		Vector3(18, 0, 0), glass_mat)

	# Headlights
	var hl_mat = _emissive_mat(Color(1.0, 0.98, 0.88), 3.0)
	_add_box(Vector3(-0.62, 0.52, -2.04), Vector3(0.28, 0.12, 0.05), hl_mat)
	_add_box(Vector3( 0.62, 0.52, -2.04), Vector3(0.28, 0.12, 0.05), hl_mat)

	# Tail lights
	var tl_mat = _emissive_mat(Color(0.9, 0.05, 0.05), 2.0)
	_add_box(Vector3(-0.62, 0.52, 2.04), Vector3(0.28, 0.12, 0.05), tl_mat)
	_add_box(Vector3( 0.62, 0.52, 2.04), Vector3(0.28, 0.12, 0.05), tl_mat)

	# Indicators (orange, off by default)
	indicator_mat_L = _emissive_mat(Color(1.0, 0.50, 0.0), 0.0)
	indicator_mat_R = _emissive_mat(Color(1.0, 0.50, 0.0), 0.0)
	_add_box(Vector3(-0.92, 0.52,  0.0), Vector3(0.05, 0.10, 0.28), indicator_mat_L)
	_add_box(Vector3( 0.92, 0.52,  0.0), Vector3(0.05, 0.10, 0.28), indicator_mat_R)

	# Wheels + hubcaps
	for wx in [-1.0, 1.0]:
		for wz in [-1.30, 1.30]:
			var wn = MeshInstance3D.new()
			var wm = CylinderMesh.new()
			wm.top_radius = 0.32
			wm.bottom_radius = 0.32
			wm.height = 0.22
			wm.radial_segments = 16
			wn.mesh = wm
			wn.rotation_degrees = Vector3(0, 0, 90)
			wn.position = Vector3(wx, 0.32, wz)
			wn.material_override = wheel_mat
			add_child(wn)

			var hn = MeshInstance3D.new()
			var hm = CylinderMesh.new()
			hm.top_radius = 0.16
			hm.bottom_radius = 0.16
			hm.height = 0.24
			hm.radial_segments = 8
			hn.mesh = hm
			hn.rotation_degrees = Vector3(0, 0, 90)
			hn.position = Vector3(wx, 0.32, wz)
			hn.material_override = hub_mat
			add_child(hn)

# ── Mesh helpers ──────────────────────────────────────────────────────────────
func _add_box(pos: Vector3, size: Vector3, mat: Material) -> MeshInstance3D:
	var mi = MeshInstance3D.new()
	var bm = BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	add_child(mi)
	return mi

func _add_box_rot(pos: Vector3, size: Vector3, rot_deg: Vector3,
		mat: Material) -> MeshInstance3D:
	var mi = _add_box(pos, size, mat)
	mi.rotation_degrees = rot_deg
	return mi

func _emissive_mat(color: Color, energy: float) -> StandardMaterial3D:
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	return mat
