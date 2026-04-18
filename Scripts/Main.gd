extends Node3D

# ── Road configuration ────────────────────────────────────────────────────────
## Change NUM_LANES to 1, 2, 3, or 4 — everything adapts automatically
const NUM_LANES: int = 3
const LANE_WIDTH: float = 3.5
const ROAD_LENGTH: float = 800.0
const NUM_CARS: int = 15

# ── Infinite city scrolling ───────────────────────────────────────────────────
const CITY_SEGMENT_LENGTH: float = 40.0   # one "block" of buildings
const CITY_POOL_SIZE: int = 10             # segments kept alive
const CITY_SPAWN_AHEAD: float = 80.0      # spawn when within this distance

# ── Internal ──────────────────────────────────────────────────────────────────
var ml_client: MLClient
var hud: CanvasLayer
var cars: Array = []             # Array[Car]
var camera_pivot: Node3D
# (Add these alongside your other Internal variables)
var main_cam: Camera3D
var cam_distance: float = 25.0
var cam_yaw: float = -35.0
var cam_pitch: float = -18.0

var _lane_x_positions: Array = []   # world-X for each lane
var _road_half_width: float = 0.0

var virtual_camera_z: float = 0.0
var road_container: Node3D

# Infinite city state
var _city_segments: Array = []       # Array of {z: float, nodes: Array[Node3D]}
var _last_segment_z: float = 0.0

const CAR_SCRIPT = preload("res://Scripts/Car.gd")
const HUD_SCRIPT = preload("res://Scripts/HUD.gd")

# ── Ready ─────────────────────────────────────────────────────────────────────
func _ready():
	randomize()
	_compute_lane_geometry()
	_setup_environment()
	_build_static_road()
	_setup_ml_client()
	_setup_camera()
	_setup_hud()
	_spawn_cars()
	# Seed initial city segments behind and ahead
	for i in range(CITY_POOL_SIZE):
		_spawn_city_segment(-i * CITY_SEGMENT_LENGTH)
	_last_segment_z = -(CITY_POOL_SIZE - 1) * CITY_SEGMENT_LENGTH
	print("🎮 Simulation ready | %d lanes | %d cars" % [NUM_LANES, NUM_CARS])

# ── Lane geometry ─────────────────────────────────────────────────────────────
func _compute_lane_geometry():
	_road_half_width = (NUM_LANES * LANE_WIDTH) / 2.0
	_lane_x_positions.clear()
	for i in range(NUM_LANES):
		# Centred: lane 1 is leftmost
		var x = -_road_half_width + LANE_WIDTH * 0.5 + i * LANE_WIDTH
		_lane_x_positions.append(x)

func get_lane_x(lane: int) -> float:
	var idx = clamp(lane - 1, 0, _lane_x_positions.size() - 1)
	return _lane_x_positions[idx]

# ── Environment ───────────────────────────────────────────────────────────────
func _setup_environment():
	var we = WorldEnvironment.new()
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.48, 0.60, 0.80)
	env.ambient_light_color = Color(0.68, 0.72, 0.82)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_bloom = 0.12
	we.environment = env
	add_child(we)

	var sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 42, 0)
	sun.light_color = Color(1.0, 0.94, 0.82)
	sun.light_energy = 1.5
	sun.shadow_enabled = true
	add_child(sun)

	var fill = DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-90, 0, 0)
	fill.light_color = Color(0.58, 0.72, 1.0)
	fill.light_energy = 0.22
	fill.shadow_enabled = false
	add_child(fill)

# ── Static road (now wrapped in a container for infinite scrolling) ───────────
func _build_static_road():
	road_container = Node3D.new()
	add_child(road_container)
	
	var rw = NUM_LANES * LANE_WIDTH
	# Shift the center of the road backwards so it covers behind the camera!
	var center_z = -200.0

	# Ground plane
	var ground = _box(Vector3(0, -0.22, center_z), Vector3(rw + 40.0, 0.1, ROAD_LENGTH), Color(0.20, 0.24, 0.17))
	road_container.add_child(ground)

	# Asphalt
	var road = _box(Vector3(0, -0.05, center_z), Vector3(rw, 0.20, ROAD_LENGTH), Color(0.16, 0.16, 0.17), 0.95)
	road_container.add_child(road)

	# Lane dashes (yellow)
	if NUM_LANES > 1:
		var dash_mat = _mat(Color(0.98, 0.88, 0.08))
		for li in range(NUM_LANES - 1):
			var lx = _lane_x_positions[li] + LANE_WIDTH * 0.5
			var num_dashes = int(ROAD_LENGTH / 12.0)
			for di in range(num_dashes):
				var dash = MeshInstance3D.new()
				var dm = BoxMesh.new()
				dm.size = Vector3(0.13, 0.21, 4.2)
				dash.mesh = dm
				dash.material_override = dash_mat
				# Start drawing dashes from +200 (behind camera) down to -600
				dash.position = Vector3(lx, 0.02, 200.0 - (di * 12.0))
				road_container.add_child(dash)

	# White edge lines
	var edge_mat = _mat(Color(0.94, 0.94, 0.94))
	for ex in [_road_half_width + 0.1, -_road_half_width - 0.1]:
		var edge = _box(Vector3(ex, 0.02, center_z), Vector3(0.18, 0.21, ROAD_LENGTH), Color(0.94, 0.94, 0.94))
		road_container.add_child(edge)

	# Kerbs
	for kx in [_road_half_width + 0.25, -_road_half_width - 0.25]:
		var kerb = _box(Vector3(kx, 0.08, center_z), Vector3(0.28, 0.30, ROAD_LENGTH), Color(0.76, 0.74, 0.70))
		road_container.add_child(kerb)

	# Pavements / footpaths
	var pave_w = 5.0
	for px in [_road_half_width + pave_w * 0.5 + 0.4, -(_road_half_width + pave_w * 0.5 + 0.4)]:
		var pave = _box(Vector3(px, 0.04, center_z), Vector3(pave_w, 0.26, ROAD_LENGTH), Color(0.70, 0.68, 0.62))
		road_container.add_child(pave)
		
func _get_safe_spawn_z(lane: int, base_z: float) -> float:
	var z = base_z
	var safe = false
	
	while not safe:
		safe = true
		for other in cars:
			if other.lane == lane:
				if abs(other.position.z - z) < 12.0:
					z -= 15.0   # push further back
					safe = false
					break
	return z
# ── Infinite city streaming ────────────────────────────────────────────────────
func _process(delta: float):
	_stream_city()
	_update_camera(delta)

func _stream_city():
	var cam_z = virtual_camera_z

	# Spawn new segment ahead when the frontier gets close
	if cam_z - CITY_SPAWN_AHEAD < _last_segment_z:
		_last_segment_z -= CITY_SEGMENT_LENGTH
		_spawn_city_segment(_last_segment_z)

	# Recycle segments that are far behind
	for i in range(_city_segments.size() - 1, -1, -1):
		var seg = _city_segments[i]
		if seg["z"] > cam_z + CITY_SEGMENT_LENGTH * 3:
			for n in seg["nodes"]:
				n.queue_free()
			_city_segments.remove_at(i)

func _spawn_city_segment(z: float):
	var nodes: Array = []
	var pave_x = _road_half_width + 0.4

	for side in [-1, 1]:
		var x_base = side * (pave_x + 2.5 + randf_range(3, 7))

		# Building
		var bw = randf_range(6, 13)
		var bh = randf_range(7, 32)
		var bd = CITY_SEGMENT_LENGTH * randf_range(0.55, 0.85)

		var bld = _box(
			Vector3(x_base, bh * 0.5, z - bd * 0.5),
			Vector3(bw, bh, bd),
			_random_building_color()
		)
		add_child(bld)
		nodes.append(bld)

		# Window glow (face toward road)
		var face_z_offset = bd * 0.5 * -float(side) * 0.0   # perpendicular face
		var win_mat = StandardMaterial3D.new()
		win_mat.albedo_color = Color(0.90, 0.84, 0.56)
		win_mat.emission_enabled = true
		win_mat.emission = Color(1.0, 0.92, 0.60)
		win_mat.emission_energy_multiplier = 0.50
		var win_node = MeshInstance3D.new()
		var wm = BoxMesh.new()
		# The face of building closest to road
		var road_face_x = x_base - sign(x_base) * (bw * 0.5 + 0.04)
		wm.size = Vector3(0.06, bh - 1.2, bd - 0.5)
		win_node.mesh = wm
		win_node.material_override = win_mat
		win_node.position = Vector3(road_face_x, bh * 0.5, z - bd * 0.5)
		add_child(win_node)
		nodes.append(win_node)

		# Rooftop detail
		if randf() > 0.4:
			var rh = randf_range(1.5, 5.0)
			var roof = _box(
				Vector3(x_base + randf_range(-1.5, 1.5), bh + rh * 0.5, z - bd * 0.4),
				Vector3(bw * randf_range(0.3, 0.55), rh, bd * randf_range(0.3, 0.55)),
				_random_building_color().darkened(0.22)
			)
			add_child(roof)
			nodes.append(roof)

		# Water tower (rare)
		if randf() > 0.80:
			var wt_nodes = _make_water_tower(Vector3(x_base, bh, z - bd * 0.3))
			for wtn in wt_nodes:
				add_child(wtn)
				nodes.append(wtn)

		# Street light at start of segment
		var light_x = sign(x_base) * (_road_half_width + 0.8)
		var sl_nodes = _make_streetlight(Vector3(light_x, 0, z - 2.0))
		for sn in sl_nodes:
			add_child(sn)
			nodes.append(sn)

		# Tree (random chance)
		if randf() > 0.45:
			var tree_x = sign(x_base) * (_road_half_width + 1.8 + randf_range(0, 2.0))
			var tree_nodes = _make_tree(Vector3(tree_x, 0, z - randf_range(4, bd - 4)))
			for tn in tree_nodes:
				add_child(tn)
				nodes.append(tn)

	_city_segments.append({"z": z, "nodes": nodes})

# ── City prop builders ─────────────────────────────────────────────────────────
func _make_water_tower(base: Vector3) -> Array:
	var nodes: Array = []
	var pole_mat = _mat(Color(0.28, 0.20, 0.14))
	var tank_mat = _mat(Color(0.40, 0.28, 0.18))

	var pole = MeshInstance3D.new()
	var pm = CylinderMesh.new()
	pm.top_radius = 0.06; pm.bottom_radius = 0.08; pm.height = 3.5
	pm.radial_segments = 6
	pole.mesh = pm; pole.position = base + Vector3(0, 1.75, 0)
	pole.material_override = pole_mat
	nodes.append(pole)

	var tank = MeshInstance3D.new()
	var tm = CylinderMesh.new()
	tm.top_radius = 1.0; tm.bottom_radius = 1.0; tm.height = 1.8
	tm.radial_segments = 10
	tank.mesh = tm; tank.position = base + Vector3(0, 3.9, 0)
	tank.material_override = tank_mat
	nodes.append(tank)
	return nodes

func _make_streetlight(base: Vector3) -> Array:
	var nodes: Array = []
	var pole_mat = _mat_metal(Color(0.28, 0.28, 0.30))

	var pole = MeshInstance3D.new()
	var pm = CylinderMesh.new()
	pm.top_radius = 0.06; pm.bottom_radius = 0.09; pm.height = 6.0
	pm.radial_segments = 8
	pole.mesh = pm; pole.position = base + Vector3(0, 3.0, 0)
	pole.material_override = pole_mat
	nodes.append(pole)

	# Arm reaches toward road centre
	var arm_dir = -sign(base.x) if base.x != 0 else 1
	var arm = MeshInstance3D.new()
	var am = BoxMesh.new(); am.size = Vector3(1.3, 0.08, 0.08)
	arm.mesh = am; arm.position = base + Vector3(arm_dir * 0.65, 6.0, 0)
	arm.material_override = pole_mat
	nodes.append(arm)

	# Light head
	var head = MeshInstance3D.new()
	var hm = BoxMesh.new(); hm.size = Vector3(0.52, 0.18, 0.32)
	head.mesh = hm; head.position = base + Vector3(arm_dir * 1.3, 5.88, 0)
	var hmat = StandardMaterial3D.new()
	hmat.albedo_color = Color(1.0, 0.96, 0.74)
	hmat.emission_enabled = true
	hmat.emission = Color(1.0, 0.96, 0.74)
	hmat.emission_energy_multiplier = 2.8
	head.material_override = hmat
	nodes.append(head)

	var light = OmniLight3D.new()
	light.position = base + Vector3(arm_dir * 1.3, 5.6, 0)
	light.light_color = Color(1.0, 0.92, 0.66)
	light.light_energy = 1.8
	light.omni_range = 13.0
	light.shadow_enabled = false
	nodes.append(light)
	return nodes

func _make_tree(base: Vector3) -> Array:
	var nodes: Array = []
	var trunk_mat = _mat(Color(0.30, 0.18, 0.08))

	var trunk = MeshInstance3D.new()
	var tm = CylinderMesh.new()
	tm.top_radius = 0.10; tm.bottom_radius = 0.15; tm.height = 2.0
	tm.radial_segments = 6
	trunk.mesh = tm; trunk.position = base + Vector3(0, 1.0, 0)
	trunk.material_override = trunk_mat
	nodes.append(trunk)

	var layers = randi() % 2 + 2
	for l in range(layers):
		var fol = MeshInstance3D.new()
		var fm = SphereMesh.new()
		var r = 1.0 - l * 0.18
		fm.radius = r; fm.height = r * 1.35
		fm.radial_segments = 8; fm.rings = 5
		fol.mesh = fm
		fol.position = base + Vector3(0, 2.7 + l * 0.72, 0)
		var fmat = StandardMaterial3D.new()
		fmat.albedo_color = Color(0.10 + randf()*0.07, 0.34 + randf()*0.18, 0.08)
		fmat.roughness = 0.9
		fol.material_override = fmat
		nodes.append(fol)
	return nodes

# ── Camera ─────────────────────────────────────────────────────────────────────
func _setup_camera():
	camera_pivot = Node3D.new()
	camera_pivot.name = "CameraPivot"
	add_child(camera_pivot)

	main_cam = Camera3D.new()
	main_cam.fov = 65
	main_cam.far = 500.0
	camera_pivot.add_child(main_cam)
	
	_update_camera_transform()

func _update_camera_transform():
	# Orbit logic: The pivot rotates, and the camera pulls back on its local Z axis
	camera_pivot.rotation_degrees = Vector3(cam_pitch, cam_yaw, 0)
	main_cam.position = Vector3(0, 0, cam_distance)

func _update_camera(delta: float):
	# Move the virtual camera continuously forward at standard traffic speed
	virtual_camera_z -= 15.0 * delta
	
	var target = Vector3(0, 0, virtual_camera_z + 15.0)
	camera_pivot.global_position = camera_pivot.global_position.lerp(target, delta * 3.2)

	# The Treadmill Trick: Snap the road to exact multiples of the dash spacing (12m)
	# This moves the road seamlessly with the camera, ensuring cars never fall off 
	# the edge, without visually interrupting the yellow lines.
	if road_container:
		road_container.position.z = snapped(virtual_camera_z, 12.0)

# ── ML Client ─────────────────────────────────────────────────────────────────
func _setup_ml_client():
	ml_client = MLClient.new()
	ml_client.name = "MLClient"
	add_child(ml_client)
	ml_client.connection_established.connect(_on_ml_connected)
	ml_client.connection_lost.connect(_on_ml_disconnected)

func _on_ml_connected():
	if hud and hud.has_method("set_ml_connected"):
		hud.set_ml_connected(true)

func _on_ml_disconnected():
	if hud and hud.has_method("set_ml_connected"):
		hud.set_ml_connected(false)

# ── HUD ───────────────────────────────────────────────────────────────────────
func _setup_hud():
	hud = CanvasLayer.new()
	hud.name = "HUD"
	hud.set_script(HUD_SCRIPT)
	add_child(hud)

# ── Cars ──────────────────────────────────────────────────────────────────────
func _spawn_cars():
	for i in range(NUM_CARS):
		# FIX: Instantiate the script directly instead of a base Node3D
		var car = CAR_SCRIPT.new()
		car.name = "Car_%d" % i

		# Set config before _ready fires
		var start_lane = (i % NUM_LANES) + 1
		car.car_index = i
		car.lane = start_lane
		car.target_lane = start_lane
		car.base_speed = randf_range(11.0, 22.0)
		car.aggressiveness = randf_range(0.35, 0.92)
		
		# FIX: Use the setter function to safely pass the arrays
		car.set_lane_config(NUM_LANES, LANE_WIDTH, _lane_x_positions.duplicate())

		add_child(car)
		car.position = Vector3(_lane_x_positions[start_lane - 1], 0.0, -i * 13.0)
		cars.append(car)

		if hud and hud.has_method("register_car"):
			hud.register_car(i)
			var base_z = -i * 13.0
			var safe_z = _get_safe_spawn_z(start_lane, base_z)

			car.position = Vector3(_lane_x_positions[start_lane - 1], 0.0, safe_z)
		print("🚗 %d cars spawned across %d lanes" % [NUM_CARS, NUM_LANES])

# Called by Car.gd to find other cars for collision avoidance
func get_cars() -> Array:
	return cars

# ── Input ─────────────────────────────────────────────────────────────────────
func _input(event):
	# 1. Mouse wheel for ZOOM (Closeness)
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_distance = max(5.0, cam_distance - 1.5)
			_update_camera_transform()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_distance = min(80.0, cam_distance + 1.5)
			_update_camera_transform()

	# 2. Right-click drag for ANGLE (Orbit)
	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		cam_yaw -= event.relative.x * 0.3
		# Clamp pitch between -85 (looking straight down) and 0 (ground level)
		cam_pitch = clamp(cam_pitch - event.relative.y * 0.3, -85.0, 0.0) 
		_update_camera_transform()

	# 3. Keyboard shortcuts (Your existing logic)
	if not (event is InputEventKey and event.pressed):
		return
		
	match event.keycode:
		KEY_SPACE:  _batch_predict()
		KEY_P:      ml_client.ping()
		KEY_R:      _reset_all_cars()
		KEY_1:      _set_all_lanes(1)
		KEY_2:      _set_all_lanes(min(2, NUM_LANES))
		KEY_3:      _set_all_lanes(min(3, NUM_LANES))
		KEY_4:      _set_all_lanes(min(4, NUM_LANES))

func _batch_predict():
	if not ml_client.connected: return
	var states = []
	for car in cars:
		states.append({
			"speed": car.current_speed,
			"urgency": car.urgency,
			"aggressiveness": car.aggressiveness,
			"rel_target": car.target_lane - car.lane,
			"perceived_gap": car.perceived_gap
		})
	ml_client.batch_predict("lane_change", states)

func _set_all_lanes(l: int):
	for car in cars:
		if car.has_method("set_target_lane"):
			car.set_target_lane(l)

func _reset_all_cars():
	for i in range(cars.size()):
		var car = cars[i]
		var sl = (i % NUM_LANES) + 1
		car.lane = sl
		car.target_lane = sl
		car.position = Vector3(_lane_x_positions[sl - 1], 0.0, -i * 13.0)
		car.is_merging = false
		car.merge_t = 0.0
		car.awaiting_prediction = false

# ── Mesh helpers ───────────────────────────────────────────────────────────────
func _box(pos: Vector3, size: Vector3, color: Color,
		roughness: float = 0.88) -> MeshInstance3D:
	var mi = MeshInstance3D.new()
	var bm = BoxMesh.new(); bm.size = size
	mi.mesh = bm; mi.position = pos
	mi.material_override = _mat(color, roughness)
	return mi

func _mat(color: Color, roughness: float = 0.88) -> StandardMaterial3D:
	var m = StandardMaterial3D.new()
	m.albedo_color = color; m.roughness = roughness
	return m

func _mat_metal(color: Color) -> StandardMaterial3D:
	var m = StandardMaterial3D.new()
	m.albedo_color = color; m.metallic = 0.65; m.roughness = 0.38
	return m

func _random_building_color() -> Color:
	var palettes = [
		[Color(0.50, 0.46, 0.55), Color(0.40, 0.50, 0.62), Color(0.36, 0.42, 0.38)],
		[Color(0.60, 0.50, 0.38), Color(0.56, 0.36, 0.32), Color(0.62, 0.58, 0.50)],
		[Color(0.34, 0.38, 0.48), Color(0.44, 0.46, 0.52), Color(0.28, 0.36, 0.42)],
	]
	var p = palettes[randi() % palettes.size()]
	return p[randi() % p.size()]
