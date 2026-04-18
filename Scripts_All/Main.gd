extends Node3D

# =============================================================================
#  MAIN — City Navigator
#
#  Flow:
#   1. Build city (ring road + inner grid + traffic cars)
#   2. Show GameUI start screen
#   3. User picks start + goal on top-down map view
#   4. A* finds path through RoadGraph
#   5. GhostCar follows path with smooth arcs + speed multiplier
#   6. Arrived screen → replay
# =============================================================================

const LANE_WIDTH          : float = 3.5
const INNER_LANES_PER_DIR : int   = 2
const INNER_ROAD_W        : float = LANE_WIDTH * INNER_LANES_PER_DIR * 2.0
const RING_LANES_PER_DIR  : int   = 3
const RING_ROAD_W         : float = LANE_WIDTH * RING_LANES_PER_DIR * 2.0

const BLOCK_SIZE    : float = 100.0
const MAP_HALF      : float = 200.0
const GRID_RADIUS   : int   = 10
const STREAM_RADIUS : int   = 5

const NUM_INNER_CARS : int = 60
const NUM_RING_CARS  : int = 24

const DIV_COLOR : Color = Color(1.0, 1.0, 1.0)
const DIV_Y     : float = 0.18
const DIV_H     : float = 0.06
const DIV_THICK : float = 0.60

# ── Nodes ─────────────────────────────────────────────────────────────────────
var ml_client    : MLClient
var cars         : Array = []

var camera_pivot : Node3D
var main_cam     : Camera3D
var top_cam      : Camera3D   # orthographic top-down for map picking

var cam_distance : float = 120.0
var cam_yaw      : float = -30.0
var cam_pitch    : float = -45.0

# ── Lane offsets ──────────────────────────────────────────────────────────────
var _inner_lane_offsets : Array = []
var _ring_lane_offsets  : Array = []

# ── Streamed grid ─────────────────────────────────────────────────────────────
var _loaded_cells : Dictionary = {}
var _ring_nodes   : Array = []

# ── Ghost navigation ──────────────────────────────────────────────────────────
var _road_graph  : RoadGraph
var _ghost_car   : GhostCar
var _game_ui     : GameUI

const CAR_SCRIPT   = preload("res://Scripts/Car.gd")
const HUD_SCRIPT   = preload("res://Scripts/HUD.gd")
const GHOST_SCRIPT = preload("res://Scripts/GhostCar.gd")
const UI_SCRIPT    = preload("res://Scripts/GameUI.gd")
const GRAPH_SCRIPT = preload("res://Scripts/RoadGraph.gd")

# =============================================================================
#  STARTUP
# =============================================================================
func _ready() -> void:
	randomize()
	_compute_lane_offsets()
	_setup_environment()
	_setup_ml_client()
	_setup_cameras()
	_build_ring_road()
	_build_grid_around(0, 0)
	_spawn_cars()
	_setup_road_graph()
	_setup_ghost_car()
	_setup_game_ui()
	print("🏙️ City Navigator ready — %d inner + %d ring cars" % [NUM_INNER_CARS, NUM_RING_CARS])

func _compute_lane_offsets() -> void:
	_inner_lane_offsets.clear()
	for i in range(INNER_LANES_PER_DIR):
		_inner_lane_offsets.append(LANE_WIDTH * 0.5 + i * LANE_WIDTH)
	_ring_lane_offsets.clear()
	for i in range(RING_LANES_PER_DIR):
		_ring_lane_offsets.append(LANE_WIDTH * 0.5 + i * LANE_WIDTH)

func get_lane_x(lane: int) -> float:
	return _inner_lane_offsets[clamp(lane - 1, 0, _inner_lane_offsets.size() - 1)]

# =============================================================================
#  ROAD GRAPH  (A* over the intersection grid)
# =============================================================================
func _setup_road_graph() -> void:
	_road_graph = GRAPH_SCRIPT.new()
	_road_graph.setup(MAP_HALF, BLOCK_SIZE)

# =============================================================================
#  GHOST CAR
# =============================================================================
func _setup_ghost_car() -> void:
	_ghost_car = GHOST_SCRIPT.new()
	_ghost_car.name = "GhostCar"
	_ghost_car.visible = false
	add_child(_ghost_car)
	_ghost_car.arrived.connect(_on_ghost_arrived)
	_ghost_car.progress_updated.connect(_on_ghost_progress)

func _on_path_requested(start: Vector2, goal: Vector2) -> void:
	var path = _road_graph.find_path(start, goal)
	if path.is_empty() or path.size() < 2:
		_game_ui.on_no_path()
		return

	# Determine start axis/dir from first two waypoints
	var d = path[1] - path[0]
	var axis : int
	var dir  : float
	if abs(d.x) > abs(d.z):
		axis = 1; dir = sign(d.x)
	else:
		axis = 0; dir = sign(d.z)

	var loff = _inner_lane_offsets[0] if not _inner_lane_offsets.is_empty() else LANE_WIDTH * 0.5

	_ghost_car.visible         = true
	_ghost_car.speed_multiplier = 1.0
	_ghost_car.init_path(path, loff, axis, dir)

	# Place 3D markers
	_ghost_car.place_markers(path[0], path[path.size() - 1])

	# Point main camera at start
	camera_pivot.global_position = path[0]
	cam_pitch = -55.0; cam_yaw = -20.0; cam_distance = 90.0
	_update_camera_transform()

	_game_ui.on_driving_started()

func _on_ghost_arrived() -> void:
	_game_ui.on_arrived()

func _on_ghost_progress(ratio: float) -> void:
	_game_ui.on_progress(ratio)
	# Keep main camera loosely following the ghost
	if _ghost_car and _ghost_car.visible:
		var target = _ghost_car.global_position
		camera_pivot.global_position = camera_pivot.global_position.lerp(target, 0.04)

func _on_speed_changed(mult: float) -> void:
	if _ghost_car:
		_ghost_car.speed_multiplier = mult

# =============================================================================
#  GAME UI
# =============================================================================
func _setup_game_ui() -> void:
	_game_ui = UI_SCRIPT.new()
	_game_ui.name = "GameUI"
	add_child(_game_ui)
	_game_ui.setup(MAP_HALF, BLOCK_SIZE, top_cam)
	_game_ui.path_requested.connect(_on_path_requested)
	_game_ui.speed_changed.connect(_on_speed_changed)

# =============================================================================
#  ENVIRONMENT
# =============================================================================
func _setup_environment() -> void:
	var we  = WorldEnvironment.new()
	var env = Environment.new()
	env.background_mode      = Environment.BG_COLOR
	env.background_color     = Color(0.48, 0.60, 0.80)
	env.ambient_light_color  = Color(0.68, 0.72, 0.82)
	env.ambient_light_energy = 0.55
	env.tonemap_mode         = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled         = true; env.glow_intensity = 0.35; env.glow_bloom = 0.12
	we.environment = env; add_child(we)

	var sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 42, 0)
	sun.light_color = Color(1.0, 0.94, 0.82); sun.light_energy = 1.5; sun.shadow_enabled = true
	add_child(sun)

	var fill = DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-90, 0, 0)
	fill.light_color = Color(0.58, 0.72, 1.0); fill.light_energy = 0.22
	add_child(fill)

# =============================================================================
#  CAMERAS
# =============================================================================
func _setup_cameras() -> void:
	# ── Perspective camera (follows ghost, normal driving view) ───────────────
	camera_pivot = Node3D.new(); camera_pivot.name = "CameraPivot"; add_child(camera_pivot)
	main_cam = Camera3D.new(); main_cam.name = "MainCam"
	main_cam.fov = 65; main_cam.far = 1200.0
	camera_pivot.add_child(main_cam)
	_update_camera_transform()

	# ── Orthographic top-down camera (used during map picking) ────────────────
	top_cam = Camera3D.new(); top_cam.name = "TopCam"
	top_cam.projection   = Camera3D.PROJECTION_ORTHOGONAL
	top_cam.size         = MAP_HALF * 2.2          # show full map
	top_cam.position     = Vector3(0, 600, 0)
	top_cam.rotation_degrees = Vector3(-90, 0, 0)
	top_cam.far          = 1500.0
	top_cam.current      = false
	add_child(top_cam)

func _update_camera_transform() -> void:
	camera_pivot.rotation_degrees = Vector3(cam_pitch, cam_yaw, 0)
	main_cam.position = Vector3(0, 0, cam_distance)

func _set_top_view(enable: bool) -> void:
	top_cam.current  = enable
	main_cam.current = not enable

# =============================================================================
#  PROCESS
# =============================================================================
func _process(delta: float) -> void:
	_update_camera(delta)
	_stream_grid()

func _update_camera(delta: float) -> void:
	var speed = 60.0 * (cam_distance / 80.0)
	var move  = Vector3.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):    move.z -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):  move.z += 1
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):  move.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): move.x += 1
	if move.length() > 0:
		camera_pivot.global_position += move.normalized() * speed * delta

# =============================================================================
#  INPUT
# =============================================================================
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_distance = max(10.0, cam_distance - 6.0); _update_camera_transform()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_distance = min(500.0, cam_distance + 6.0); _update_camera_transform()
	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		cam_yaw -= event.relative.x * 0.3
		cam_pitch = clamp(cam_pitch - event.relative.y * 0.3, -85.0, -5.0)
		_update_camera_transform()
	if not (event is InputEventKey and event.pressed): return
	match event.keycode:
		KEY_SPACE: _batch_predict()
		KEY_P:     if ml_client: ml_client.ping()
		KEY_R:     _reset_all_cars()
		KEY_T:     _set_top_view(not top_cam.current)  # T toggles top view

# =============================================================================
#  OUTER RING ROAD
# =============================================================================
func _build_ring_road() -> void:
	var outer_size = MAP_HALF * 2.0 + RING_ROAD_W + 20.0
	var ground = _box(Vector3(0, -0.22, 0), Vector3(outer_size, 0.10, outer_size), Color(0.20, 0.24, 0.17))
	add_child(ground); _ring_nodes.append(ground)

	var seg_len = MAP_HALF * 2.0 + RING_ROAD_W
	_build_ring_segment_ew(0.0,  MAP_HALF, seg_len)
	_build_ring_segment_ew(0.0, -MAP_HALF, seg_len)
	_build_ring_segment_ns( MAP_HALF, 0.0, seg_len)
	_build_ring_segment_ns(-MAP_HALF, 0.0, seg_len)

	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var c = _box(Vector3(sx * MAP_HALF, -0.04, sz * MAP_HALF),
				Vector3(RING_ROAD_W, 0.21, RING_ROAD_W), Color(0.36, 0.36, 0.38), 0.95)
			add_child(c); _ring_nodes.append(c)

func _build_ring_segment_ew(cx: float, cz: float, seg_len: float) -> void:
	var road = _box(Vector3(cx, -0.05, cz), Vector3(seg_len, 0.20, RING_ROAD_W),
		Color(0.38, 0.38, 0.40), 0.95)
	add_child(road); _ring_nodes.append(road)
	var half_r = RING_ROAD_W * 0.5; var inner_len = seg_len - RING_ROAD_W
	for off in [-0.12, 0.12]:
		var yd = _stripe(Vector3(cx, DIV_Y, cz + off), Vector3(inner_len, DIV_H, 0.09), Color(0.98, 0.88, 0.08))
		add_child(yd); _ring_nodes.append(yd)
	for d in [-1.0, 1.0]:
		for li in range(1, RING_LANES_PER_DIR):
			var ld = _stripe(Vector3(cx, DIV_Y, cz + d * li * LANE_WIDTH), Vector3(inner_len, DIV_H, DIV_THICK), DIV_COLOR)
			add_child(ld); _ring_nodes.append(ld)
	for sz in [-1.0, 1.0]:
		var e = _stripe(Vector3(cx, DIV_Y, cz + sz * half_r), Vector3(inner_len, DIV_H, DIV_THICK * 1.2), Color(0.92, 0.92, 0.92))
		add_child(e); _ring_nodes.append(e)
		var k = _box(Vector3(cx, 0.08, cz + sz * (half_r + 0.14)), Vector3(inner_len, 0.30, 0.30), Color(0.76, 0.74, 0.70))
		add_child(k); _ring_nodes.append(k)

func _build_ring_segment_ns(cx: float, cz: float, seg_len: float) -> void:
	var road = _box(Vector3(cx, -0.05, cz), Vector3(RING_ROAD_W, 0.20, seg_len),
		Color(0.38, 0.38, 0.40), 0.95)
	add_child(road); _ring_nodes.append(road)
	var half_r = RING_ROAD_W * 0.5; var inner_len = seg_len - RING_ROAD_W
	for off in [-0.12, 0.12]:
		var yd = _stripe(Vector3(cx + off, DIV_Y, cz), Vector3(0.09, DIV_H, inner_len), Color(0.98, 0.88, 0.08))
		add_child(yd); _ring_nodes.append(yd)
	for d in [-1.0, 1.0]:
		for li in range(1, RING_LANES_PER_DIR):
			var ld = _stripe(Vector3(cx + d * li * LANE_WIDTH, DIV_Y, cz), Vector3(DIV_THICK, DIV_H, inner_len), DIV_COLOR)
			add_child(ld); _ring_nodes.append(ld)
	for sx in [-1.0, 1.0]:
		var e = _stripe(Vector3(cx + sx * half_r, DIV_Y, cz), Vector3(DIV_THICK * 1.2, DIV_H, inner_len), Color(0.92, 0.92, 0.92))
		add_child(e); _ring_nodes.append(e)
		var k = _box(Vector3(cx + sx * (half_r + 0.14), 0.08, cz), Vector3(0.30, 0.30, inner_len), Color(0.76, 0.74, 0.70))
		add_child(k); _ring_nodes.append(k)

# =============================================================================
#  INNER GRID
# =============================================================================
func _build_grid_around(cam_gx: int, cam_gz: int) -> void:
	for dgx in range(-GRID_RADIUS, GRID_RADIUS + 1):
		for dgz in range(-GRID_RADIUS, GRID_RADIUS + 1):
			var gx = cam_gx + dgx; var gz = cam_gz + dgz
			if abs(gx * BLOCK_SIZE) > MAP_HALF or abs(gz * BLOCK_SIZE) > MAP_HALF: continue
			var key = "%d,%d" % [gx, gz]
			if not _loaded_cells.has(key):
				_loaded_cells[key] = _build_cell(gx, gz)

func _build_cell(gx: int, gz: int) -> Dictionary:
	var nodes : Array = []
	var cx = gx * BLOCK_SIZE; var cz = gz * BLOCK_SIZE
	var road_w = INNER_ROAD_W; var half_road = road_w * 0.5; var block_in = BLOCK_SIZE - road_w

	for n in [
		_box(Vector3(cx, -0.22, cz), Vector3(BLOCK_SIZE, 0.10, BLOCK_SIZE), Color(0.20, 0.24, 0.17)),
		_box(Vector3(cx, -0.05, cz), Vector3(BLOCK_SIZE, 0.20, road_w), Color(0.38, 0.38, 0.40), 0.95),
		_box(Vector3(cx, -0.05, cz), Vector3(road_w, 0.20, BLOCK_SIZE), Color(0.38, 0.38, 0.40), 0.95),
		_box(Vector3(cx, -0.04, cz), Vector3(road_w, 0.21, road_w), Color(0.36, 0.36, 0.38), 0.95),
	]: add_child(n); nodes.append(n)

	var half_in = block_in * 0.5
	if block_in > 4.0:
		for sx in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				var pave = _box(
					Vector3(cx + sx * (half_road + half_in * 0.5), 0.04, cz + sz * (half_road + half_in * 0.5)),
					Vector3(block_in, 0.26, block_in), Color(0.70, 0.68, 0.62))
				add_child(pave); nodes.append(pave)

	_add_ew_markings(cx, cz, road_w, block_in, nodes)
	_add_ns_markings(cx, cz, road_w, block_in, nodes)
	_add_stop_lines(cx, cz, road_w, nodes)
	_add_kerbs(cx, cz, road_w, block_in, nodes)
	if block_in > 10.0: _fill_city_block(cx, cz, road_w, block_in, nodes)
	return {"nodes": nodes, "gx": gx, "gz": gz}

func _add_ew_markings(cx, cz, road_w, block_in, nodes) -> void:
	var inner = block_in; var hr = road_w * 0.5
	for off in [-0.12, 0.12]:
		var n = _stripe(Vector3(cx, DIV_Y, cz + off), Vector3(inner, DIV_H, 0.09), Color(0.98, 0.88, 0.08))
		add_child(n); nodes.append(n)
	for d in [-1.0, 1.0]:
		for li in range(1, INNER_LANES_PER_DIR):
			var n = _stripe(Vector3(cx, DIV_Y, cz + d * li * LANE_WIDTH), Vector3(inner, DIV_H, DIV_THICK), DIV_COLOR)
			add_child(n); nodes.append(n)
	for sz in [-1.0, 1.0]:
		var n = _stripe(Vector3(cx, DIV_Y, cz + sz * hr), Vector3(inner, DIV_H, DIV_THICK * 1.2), Color(0.92, 0.92, 0.92))
		add_child(n); nodes.append(n)

func _add_ns_markings(cx, cz, road_w, block_in, nodes) -> void:
	var inner = block_in; var hr = road_w * 0.5
	for off in [-0.12, 0.12]:
		var n = _stripe(Vector3(cx + off, DIV_Y, cz), Vector3(0.09, DIV_H, inner), Color(0.98, 0.88, 0.08))
		add_child(n); nodes.append(n)
	for d in [-1.0, 1.0]:
		for li in range(1, INNER_LANES_PER_DIR):
			var n = _stripe(Vector3(cx + d * li * LANE_WIDTH, DIV_Y, cz), Vector3(DIV_THICK, DIV_H, inner), DIV_COLOR)
			add_child(n); nodes.append(n)
	for sx in [-1.0, 1.0]:
		var n = _stripe(Vector3(cx + sx * hr, DIV_Y, cz), Vector3(DIV_THICK * 1.2, DIV_H, inner), Color(0.92, 0.92, 0.92))
		add_child(n); nodes.append(n)

func _add_stop_lines(cx, cz, road_w, nodes) -> void:
	var hr = road_w * 0.5; var so = hr + 0.5; var lh = road_w * 0.25
	for n in [
		_stripe(Vector3(cx + so, DIV_Y, cz + lh), Vector3(0.22, DIV_H, road_w * 0.4), Color(0.94, 0.94, 0.94)),
		_stripe(Vector3(cx - so, DIV_Y, cz - lh), Vector3(0.22, DIV_H, road_w * 0.4), Color(0.94, 0.94, 0.94)),
		_stripe(Vector3(cx + lh, DIV_Y, cz + so), Vector3(road_w * 0.4, DIV_H, 0.22), Color(0.94, 0.94, 0.94)),
		_stripe(Vector3(cx - lh, DIV_Y, cz - so), Vector3(road_w * 0.4, DIV_H, 0.22), Color(0.94, 0.94, 0.94)),
	]: add_child(n); nodes.append(n)

func _add_kerbs(cx, cz, road_w, block_in, nodes) -> void:
	var hr = road_w * 0.5
	for sz in [-1.0, 1.0]:
		var k = _box(Vector3(cx, 0.08, cz + sz * hr), Vector3(block_in, 0.30, 0.28), Color(0.76, 0.74, 0.70))
		add_child(k); nodes.append(k)
	for sx in [-1.0, 1.0]:
		var k = _box(Vector3(cx + sx * hr, 0.08, cz), Vector3(0.28, 0.30, block_in), Color(0.76, 0.74, 0.70))
		add_child(k); nodes.append(k)

# =============================================================================
#  GRID STREAMING
# =============================================================================
func _stream_grid() -> void:
	var cam_gx = int(round(camera_pivot.global_position.x / BLOCK_SIZE))
	var cam_gz = int(round(camera_pivot.global_position.z / BLOCK_SIZE))
	for dgx in range(-STREAM_RADIUS, STREAM_RADIUS + 1):
		for dgz in range(-STREAM_RADIUS, STREAM_RADIUS + 1):
			var gx = cam_gx + dgx; var gz = cam_gz + dgz
			if abs(gx * BLOCK_SIZE) > MAP_HALF or abs(gz * BLOCK_SIZE) > MAP_HALF: continue
			var key = "%d,%d" % [gx, gz]
			if not _loaded_cells.has(key): _loaded_cells[key] = _build_cell(gx, gz)
	var to_remove : Array = []
	for key in _loaded_cells.keys():
		var parts = key.split(",")
		if abs(int(parts[0]) - cam_gx) > STREAM_RADIUS + 1 or abs(int(parts[1]) - cam_gz) > STREAM_RADIUS + 1:
			for n in _loaded_cells[key]["nodes"]: n.queue_free()
			to_remove.append(key)
	for key in to_remove: _loaded_cells.erase(key)

# =============================================================================
#  CAR SPAWNING (traffic cars — same as before)
# =============================================================================
func _spawn_cars() -> void:
	cars.clear()
	var car_id : int = 0

	var ew_roads : Array = []; var ns_roads : Array = []
	for gi in range(GRID_RADIUS * 2 + 1):
		var coord = float((gi - GRID_RADIUS) * int(BLOCK_SIZE))
		if abs(coord) > MAP_HALF: continue
		ew_roads.append(coord); ns_roads.append(coord)

	var spawn_list : Array = []
	for road_z in ew_roads:
		for li in range(INNER_LANES_PER_DIR):
			for d in [1.0, -1.0]:
				spawn_list.append({"axis": 1, "dir": d, "lane": li + 1, "road": road_z, "offsets": _inner_lane_offsets})
	for road_x in ns_roads:
		for li in range(INNER_LANES_PER_DIR):
			for d in [1.0, -1.0]:
				spawn_list.append({"axis": 0, "dir": d, "lane": li + 1, "road": road_x, "offsets": _inner_lane_offsets})
	spawn_list.shuffle()

	for desc in spawn_list:
		if car_id >= NUM_INNER_CARS: break
		var perp   = desc["road"] + desc["dir"] * desc["offsets"][desc["lane"] - 1]
		var travel = randf_range(-MAP_HALF + 20.0, MAP_HALF - 20.0)
		var px = perp if desc["axis"] == 1 else travel
		var pz = travel if desc["axis"] == 1 else perp
		_create_car(car_id, px, pz, desc["lane"], INNER_LANES_PER_DIR, desc["axis"], desc["dir"], desc["offsets"])
		car_id += 1

	var ring_slots : Array = []
	for seg in [{"axis": 1, "road": MAP_HALF}, {"axis": 1, "road": -MAP_HALF},
				{"axis": 0, "road": MAP_HALF},  {"axis": 0, "road": -MAP_HALF}]:
		for li in range(RING_LANES_PER_DIR):
			for d in [1.0, -1.0]:
				ring_slots.append({"axis": seg["axis"], "road": seg["road"], "lane": li + 1, "dir": d})

	var ring_i : int = 0
	while ring_i < NUM_RING_CARS:
		var slot = ring_slots[ring_i % ring_slots.size()]
		var perp   = slot["road"] + slot["dir"] * _ring_lane_offsets[slot["lane"] - 1]
		var travel = randf_range(-MAP_HALF + 20.0, MAP_HALF - 20.0)
		var rx = perp if slot["axis"] == 1 else travel
		var rz = travel if slot["axis"] == 1 else perp
		_create_car(car_id, rx, rz, slot["lane"], RING_LANES_PER_DIR,
			slot["axis"], slot["dir"], _ring_lane_offsets)
		car_id += 1; ring_i += 1

	print("🚗 %d cars spawned" % cars.size())

func _create_car(idx: int, px: float, pz: float, start_lane: int, num_lanes_for_car: int,
		axis: int, dir: float, lane_offsets: Array) -> void:
	var car = CAR_SCRIPT.new(); car.name = "Car_%d" % idx
	car.car_index = idx; car.lane = start_lane; car.target_lane = start_lane
	car.base_speed = randf_range(11.0, 22.0); car.aggressiveness = randf_range(0.35, 0.92)
	car.set_lane_config(num_lanes_for_car, LANE_WIDTH, lane_offsets.duplicate())
	car.set_travel(axis, dir)
	car.set_map_info(MAP_HALF, BLOCK_SIZE)
	add_child(car); car.position = Vector3(px, 0.0, pz); cars.append(car)

func get_cars() -> Array: return cars

# =============================================================================
#  ML
# =============================================================================
func _setup_ml_client() -> void:
	ml_client = MLClient.new(); ml_client.name = "MLClient"; add_child(ml_client)

func _batch_predict() -> void:
	if not ml_client or not ml_client.connected: return
	var states = []
	for car in cars:
		states.append({"speed": car.current_speed, "urgency": car.urgency,
			"aggressiveness": car.aggressiveness, "rel_target": car.target_lane - car.lane,
			"perceived_gap": car.perceived_gap})
	ml_client.batch_predict("lane_change", states)

func _reset_all_cars() -> void:
	for i in range(cars.size()):
		var car = cars[i]; var sl = (i % INNER_LANES_PER_DIR) + 1
		car.lane = sl; car.target_lane = sl
		car.position = Vector3(_inner_lane_offsets[sl - 1], 0.0, -i * 13.0)
		car.is_merging = false; car.merge_t = 0.0
		car.awaiting_prediction = false; car.turn_state = 0

# =============================================================================
#  CITY BLOCK FILL
# =============================================================================
func _fill_city_block(cx, cz, road_w, block_in, nodes) -> void:
	var half_road = road_w * 0.5; var half_in = block_in * 0.5
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var ccx = cx + sx * (half_road + half_in * 0.5)
			var ccz = cz + sz * (half_road + half_in * 0.5)
			for _b in range(randi() % 2 + 1):
				var bw = randf_range(6, min(18, half_in * 1.4)); var bh = randf_range(7, 32)
				var bd = randf_range(6, min(18, half_in * 1.4))
				var bx = ccx + randf_range(-half_in * 0.28, half_in * 0.28)
				var bz = ccz + randf_range(-half_in * 0.28, half_in * 0.28)
				var bld = _box(Vector3(bx, bh * 0.5, bz), Vector3(bw, bh, bd), _random_building_color())
				add_child(bld); nodes.append(bld)
				if randf() > 0.4:
					var rh = randf_range(1.5, 5.0)
					var rf = _box(Vector3(bx, bh + rh * 0.5, bz), Vector3(bw * 0.42, rh, bd * 0.42), _random_building_color().darkened(0.22))
					add_child(rf); nodes.append(rf)
			for sln in _make_streetlight(Vector3(cx + sx * (half_road + 0.8), 0, cz + sz * (half_road + 0.8))):
				add_child(sln); nodes.append(sln)
			for _t in range(randi() % 3 + 1):
				var tx = ccx + randf_range(-half_in * 0.5, half_in * 0.5)
				for tn in _make_tree(Vector3(tx, 0, cz + sz * (half_road + 1.6))):
					add_child(tn); nodes.append(tn)

# =============================================================================
#  PROPS
# =============================================================================
func _make_streetlight(base: Vector3) -> Array:
	var nodes : Array = []
	var pm = CylinderMesh.new(); pm.top_radius = 0.06; pm.bottom_radius = 0.09; pm.height = 6.0; pm.radial_segments = 8
	var pole = MeshInstance3D.new(); pole.mesh = pm; pole.position = base + Vector3(0, 3.0, 0)
	pole.material_override = _mat_metal(Color(0.28, 0.28, 0.30)); nodes.append(pole)
	var arm_dir = -sign(base.x) if base.x != 0 else 1
	var am = BoxMesh.new(); am.size = Vector3(1.3, 0.08, 0.08)
	var arm = MeshInstance3D.new(); arm.mesh = am; arm.position = base + Vector3(arm_dir * 0.65, 6.0, 0)
	arm.material_override = _mat_metal(Color(0.28, 0.28, 0.30)); nodes.append(arm)
	var hm = BoxMesh.new(); hm.size = Vector3(0.52, 0.18, 0.32)
	var head = MeshInstance3D.new(); head.mesh = hm; head.position = base + Vector3(arm_dir * 1.3, 5.88, 0)
	var hmat = StandardMaterial3D.new(); hmat.albedo_color = Color(1.0, 0.96, 0.74)
	hmat.emission_enabled = true; hmat.emission = Color(1.0, 0.96, 0.74); hmat.emission_energy_multiplier = 2.8
	head.material_override = hmat; nodes.append(head)
	var light = OmniLight3D.new(); light.position = base + Vector3(arm_dir * 1.3, 5.6, 0)
	light.light_color = Color(1.0, 0.92, 0.66); light.light_energy = 1.8; light.omni_range = 13.0
	nodes.append(light)
	return nodes

func _make_tree(base: Vector3) -> Array:
	var nodes : Array = []
	var tm = CylinderMesh.new(); tm.top_radius = 0.10; tm.bottom_radius = 0.15; tm.height = 2.0; tm.radial_segments = 6
	var trunk = MeshInstance3D.new(); trunk.mesh = tm; trunk.position = base + Vector3(0, 1.0, 0)
	trunk.material_override = _mat(Color(0.30, 0.18, 0.08)); nodes.append(trunk)
	for l in range(randi() % 2 + 2):
		var fm = SphereMesh.new(); var rv = 1.0 - l * 0.18; fm.radius = rv; fm.height = rv * 1.35; fm.radial_segments = 8; fm.rings = 5
		var fol = MeshInstance3D.new(); fol.mesh = fm; fol.position = base + Vector3(0, 2.7 + l * 0.72, 0)
		var fmat = StandardMaterial3D.new(); fmat.albedo_color = Color(0.10 + randf() * 0.07, 0.34 + randf() * 0.18, 0.08)
		fmat.roughness = 0.9; fol.material_override = fmat; nodes.append(fol)
	return nodes

# =============================================================================
#  MESH / MATERIAL HELPERS
# =============================================================================
func _box(pos: Vector3, size: Vector3, color: Color, roughness: float = 0.88) -> MeshInstance3D:
	var mi = MeshInstance3D.new(); var bm = BoxMesh.new(); bm.size = size
	mi.mesh = bm; mi.position = pos; mi.material_override = _mat(color, roughness); return mi

func _mat(color: Color, roughness: float = 0.88) -> StandardMaterial3D:
	var m = StandardMaterial3D.new(); m.albedo_color = color; m.roughness = roughness; return m

func _mat_stripe(color: Color) -> StandardMaterial3D:
	var m = StandardMaterial3D.new(); m.albedo_color = color
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; m.roughness = 1.0; return m

func _stripe(pos: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var mi = MeshInstance3D.new(); var bm = BoxMesh.new(); bm.size = size
	mi.mesh = bm; mi.position = pos; mi.material_override = _mat_stripe(color); return mi

func _mat_metal(color: Color) -> StandardMaterial3D:
	var m = StandardMaterial3D.new(); m.albedo_color = color; m.metallic = 0.65; m.roughness = 0.38; return m

func _random_building_color() -> Color:
	var p = [[Color(0.50, 0.46, 0.55), Color(0.40, 0.50, 0.62), Color(0.36, 0.42, 0.38)],
			 [Color(0.60, 0.50, 0.38), Color(0.56, 0.36, 0.32), Color(0.62, 0.58, 0.50)],
			 [Color(0.34, 0.38, 0.48), Color(0.44, 0.46, 0.52), Color(0.28, 0.36, 0.42)]]
	var pal = p[randi() % p.size()]; return pal[randi() % pal.size()]
