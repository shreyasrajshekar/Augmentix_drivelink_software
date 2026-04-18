extends Node3D
class_name GhostCar

# =============================================================================
#  GhostCar — follows a pre-computed waypoint path through the road grid.
#
#  Behaviour:
#   • Moves between intersection waypoints along axis-aligned road segments.
#   • Executes smooth 90° arc turns at each waypoint where direction changes.
#   • Slows for turns, accelerates on straights.
#   • Supports a speed_multiplier for "fast travel" mode (e.g. 5×).
#   • Emits signal arrived() when the final waypoint is reached.
#   • Semi-transparent cyan ghost appearance.
# =============================================================================

signal arrived()
signal progress_updated(ratio: float)

# ── Settings ──────────────────────────────────────────────────────────────────
@export var base_speed       : float = 18.0   # m/s at normal speed
@export var speed_multiplier : float = 1.0    # set to 5.0 for fast travel
@export var turn_radius      : float = 4.5    # arc radius at intersections (m)

# ── Path state ────────────────────────────────────────────────────────────────
var _waypoints   : Array  = []   # Array of Vector3 intersection centres
var _wp_index    : int    = 0    # next waypoint we're heading to
var _total_dist  : float  = 0.0
var _dist_done   : float  = 0.0
var _arrived     : bool   = false

# ── Movement state ────────────────────────────────────────────────────────────
enum Phase { STRAIGHT, TURNING }
var _phase       : int    = Phase.STRAIGHT
var current_speed: float  = 0.0

# Straight segment
var _seg_from    : Vector3 = Vector3.ZERO
var _seg_to      : Vector3 = Vector3.ZERO   # centre of next waypoint

# Arc turn
var _arc_pivot   : Vector3 = Vector3.ZERO
var _arc_radius  : float   = 0.0
var _arc_start_a : float   = 0.0
var _arc_total_a : float   = 0.0   # signed radians (PI/2 or -PI/2)
var _arc_done_a  : float   = 0.0
var _arc_after_axis : int  = 0
var _arc_after_dir  : float = 1.0

# Current heading
var _travel_axis : int   = 0
var _travel_dir  : float = 1.0

# Lane offset so ghost stays in lane 1 on its side
var lane_offset  : float = 1.75   # half lane_width default

# Visual
var _ghost_mat   : StandardMaterial3D
var _marker_start: MeshInstance3D
var _marker_end  : MeshInstance3D

const ACCEL      : float = 6.0
const BRAKE      : float = 14.0
const TURN_SPEED_RATIO : float = 0.45   # fraction of base_speed during turns

# =============================================================================
#  SETUP
# =============================================================================
func init_path(waypoints: Array, lane_off: float, start_axis: int, start_dir: float) -> void:
	_waypoints   = waypoints
	_wp_index    = 1
	_arrived     = false
	lane_offset  = lane_off
	_travel_axis = start_axis
	_travel_dir  = start_dir
	current_speed = 0.0

	# Compute total path length for progress bar
	_total_dist = 0.0
	for i in range(1, waypoints.size()):
		_total_dist += waypoints[i].distance_to(waypoints[i - 1])
	_dist_done = 0.0

	# Snap to start waypoint + lane offset
	_apply_lane_offset_to_position(waypoints[0], start_axis, start_dir)
	_seg_from = position
	_begin_segment()
	_align_heading()

func _apply_lane_offset_to_position(intersection: Vector3, axis: int, dir: float) -> void:
	if axis == 0:   # travelling along Z → perpendicular is X
		position = Vector3(intersection.x + dir * lane_offset, 0.0, intersection.z)
	else:           # travelling along X → perpendicular is Z
		position = Vector3(intersection.x, 0.0, intersection.z + dir * lane_offset)

# =============================================================================
#  LIFECYCLE
# =============================================================================
func _ready() -> void:
	_build_ghost_mesh()

func _process(delta: float) -> void:
	if _arrived or _waypoints.is_empty():
		return

	var eff_delta = delta * speed_multiplier

	match _phase:
		Phase.STRAIGHT:
			_process_straight(eff_delta)
		Phase.TURNING:
			_process_turn(eff_delta)

	emit_signal("progress_updated", clamp(_dist_done / max(_total_dist, 1.0), 0.0, 1.0))

# =============================================================================
#  STRAIGHT SEGMENT
# =============================================================================
func _begin_segment() -> void:
	if _wp_index >= _waypoints.size():
		_finish()
		return

	_seg_from = position
	_seg_to   = _waypoints[_wp_index]

	# Apply lane offset to target
	var perp_offset = _travel_dir * lane_offset
	if _travel_axis == 0:
		_seg_to.x = _waypoints[_wp_index].x + perp_offset
	else:
		_seg_to.z = _waypoints[_wp_index].z + perp_offset

	_phase = Phase.STRAIGHT

func _process_straight(delta: float) -> void:
	# Target speed: slow as we near the next waypoint if a turn is coming
	var dist_left   = position.distance_to(_seg_to)
	var is_last_seg = (_wp_index >= _waypoints.size() - 1)
	var turning_next = not is_last_seg and _is_turn_at(_wp_index)

	var target_spd : float
	if is_last_seg:
		# Brake smoothly to stop
		var brake_dist = (current_speed * current_speed) / (2.0 * BRAKE) + 1.0
		target_spd = base_speed if dist_left > brake_dist else max(dist_left * 1.5, 0.0)
	elif turning_next:
		target_spd = base_speed * TURN_SPEED_RATIO
	else:
		target_spd = base_speed

	current_speed = move_toward(current_speed, target_spd,
		(ACCEL if current_speed < target_spd else BRAKE) * delta)
	current_speed = max(current_speed, 0.0)

	var step = current_speed * delta
	if step >= dist_left:
		# Reach the waypoint
		position  = _seg_to
		_dist_done += dist_left

		if is_last_seg:
			_finish()
			return

		# Decide: turn or continue straight
		if _is_turn_at(_wp_index):
			_begin_arc()
		else:
			_wp_index += 1
			_begin_segment()
	else:
		var dir3 = (_seg_to - position).normalized()
		position += dir3 * step
		_dist_done += step

func _is_turn_at(wp_idx: int) -> bool:
	# A turn is needed if the direction from wp[idx-1]→wp[idx] differs from wp[idx]→wp[idx+1]
	if wp_idx <= 0 or wp_idx + 1 >= _waypoints.size():
		return false
	var d1 = (_waypoints[wp_idx]     - _waypoints[wp_idx - 1]).normalized()
	var d2 = (_waypoints[wp_idx + 1] - _waypoints[wp_idx]).normalized()
	return d1.dot(d2) < 0.9   # not parallel → it's a turn

# =============================================================================
#  ARC TURN
# =============================================================================
func _begin_arc() -> void:
	# Figure out the new axis/dir after the turn
	var next_wp  = _waypoints[_wp_index + 1]
	var curr_wp  = _waypoints[_wp_index]
	var delta_wp = next_wp - curr_wp

	if abs(delta_wp.x) > abs(delta_wp.z):
		_arc_after_axis = 1
		_arc_after_dir  = sign(delta_wp.x)
	else:
		_arc_after_axis = 0
		_arc_after_dir  = sign(delta_wp.z)

	# Current heading vector
	var cur_h = Vector3.ZERO
	if _travel_axis == 0: cur_h = Vector3(0, 0, _travel_dir)
	else:                  cur_h = Vector3(_travel_dir, 0, 0)

	var new_h = Vector3.ZERO
	if _arc_after_axis == 0: new_h = Vector3(0, 0, _arc_after_dir)
	else:                     new_h = Vector3(_arc_after_dir, 0, 0)

	var cross_y    = cur_h.x * new_h.z - cur_h.z * new_h.x
	var turn_sign  = sign(cross_y)
	if turn_sign == 0.0: turn_sign = 1.0

	var r = turn_radius
	_arc_radius = r

	var right_h   = Vector3(cur_h.z, 0, -cur_h.x)
	var pivot_dir = right_h * (-turn_sign)
	_arc_pivot        = position + pivot_dir * r
	_arc_pivot.y      = 0.0
	_arc_start_a      = atan2(position.z - _arc_pivot.z, position.x - _arc_pivot.x)
	_arc_total_a      = -turn_sign * PI * 0.5
	_arc_done_a       = 0.0
	_phase            = Phase.TURNING

func _process_turn(delta: float) -> void:
	current_speed = move_toward(current_speed, base_speed * TURN_SPEED_RATIO, ACCEL * delta)
	var ang_speed = max(current_speed, 0.5) / max(_arc_radius, 0.1)
	var step      = ang_speed * delta
	var remaining = _arc_total_a - _arc_done_a

	if abs(remaining) <= abs(step) + 0.002:
		# Snap to end of arc
		_travel_axis = _arc_after_axis
		_travel_dir  = _arc_after_dir
		_wp_index   += 1
		_align_heading()
		_begin_segment()
		return

	_arc_done_a += sign(_arc_total_a) * step
	var cur_a    = _arc_start_a + _arc_done_a
	position.x   = _arc_pivot.x + _arc_radius * cos(cur_a)
	position.z   = _arc_pivot.z + _arc_radius * sin(cur_a)
	position.y   = 0.0

	# Face along tangent
	var tangent_a = cur_a + sign(_arc_total_a) * PI * 0.5
	rotation.y    = -tangent_a

# =============================================================================
#  ALIGN HEADING (for straight segments)
# =============================================================================
func _align_heading() -> void:
	if _travel_axis == 1:
		rotation_degrees.y = 90.0 if _travel_dir > 0 else -90.0
	else:
		rotation_degrees.y = 0.0  if _travel_dir < 0 else 180.0

# =============================================================================
#  FINISH
# =============================================================================
func _finish() -> void:
	_arrived      = true
	current_speed = 0.0
	emit_signal("arrived")
	# Pulse the ghost mesh
	if _ghost_mat:
		_ghost_mat.emission_energy_multiplier = 4.0

# =============================================================================
#  MARKERS  (set externally by GameUI after path is chosen)
# =============================================================================
func place_markers(start: Vector3, goal: Vector3) -> void:
	_remove_markers()
	_marker_start = _make_marker(start, Color(0.1, 1.0, 0.3))
	_marker_end   = _make_marker(goal,  Color(1.0, 0.2, 0.2))
	add_child(_marker_start)
	add_child(_marker_end)
	# markers use global pos, so undo parent transform
	_marker_start.global_position = start + Vector3(0, 0.5, 0)
	_marker_end.global_position   = goal  + Vector3(0, 0.5, 0)

func _remove_markers() -> void:
	if _marker_start: _marker_start.queue_free(); _marker_start = null
	if _marker_end:   _marker_end.queue_free();   _marker_end   = null

func _make_marker(pos: Vector3, color: Color) -> MeshInstance3D:
	var mi  = MeshInstance3D.new()
	var cyl = CylinderMesh.new()
	cyl.top_radius    = 1.8
	cyl.bottom_radius = 1.8
	cyl.height        = 0.25
	cyl.radial_segments = 16
	mi.mesh = cyl
	var mat = StandardMaterial3D.new()
	mat.albedo_color              = color
	mat.emission_enabled          = true
	mat.emission                  = color
	mat.emission_energy_multiplier = 2.5
	mat.transparency              = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color.a            = 0.85
	mi.material_override = mat
	return mi

# =============================================================================
#  GHOST MESH
# =============================================================================
func _build_ghost_mesh() -> void:
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.albedo_color              = Color(0.35, 0.95, 1.0, 0.55)
	_ghost_mat.transparency              = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.emission_enabled          = true
	_ghost_mat.emission                  = Color(0.2, 0.8, 1.0)
	_ghost_mat.emission_energy_multiplier = 1.8
	_ghost_mat.roughness                 = 0.15
	_ghost_mat.metallic                  = 0.4
	_ghost_mat.cull_mode                 = BaseMaterial3D.CULL_DISABLED

	# Body
	_add_box(Vector3(0, 0.5,  0),        Vector3(1.8, 0.55, 4.0))
	_add_box(Vector3(0, 1.08, 0.20),     Vector3(1.35, 0.50, 2.20))

	# Headlights
	var hl = _emissive_mat(Color(1.0, 0.98, 0.88), 3.5)
	_add_box_mat(Vector3(-0.62, 0.52, -2.04), Vector3(0.28, 0.12, 0.05), hl)
	_add_box_mat(Vector3( 0.62, 0.52, -2.04), Vector3(0.28, 0.12, 0.05), hl)

	# Tail lights
	var tl = _emissive_mat(Color(1.0, 0.1, 0.1), 2.0)
	_add_box_mat(Vector3(-0.62, 0.52, 2.04), Vector3(0.28, 0.12, 0.05), tl)
	_add_box_mat(Vector3( 0.62, 0.52, 2.04), Vector3(0.28, 0.12, 0.05), tl)

	# Wheels (darker ghost tint)
	var wm = StandardMaterial3D.new()
	wm.albedo_color  = Color(0.1, 0.5, 0.6, 0.6)
	wm.transparency  = BaseMaterial3D.TRANSPARENCY_ALPHA
	wm.emission_enabled = true; wm.emission = Color(0.1, 0.5, 0.6)
	wm.emission_energy_multiplier = 1.0
	for wx in [-1.0, 1.0]:
		for wz in [-1.3, 1.3]:
			var wn = MeshInstance3D.new()
			var cm = CylinderMesh.new()
			cm.top_radius = 0.32; cm.bottom_radius = 0.32; cm.height = 0.22; cm.radial_segments = 12
			wn.mesh = cm; wn.rotation_degrees = Vector3(0, 0, 90)
			wn.position = Vector3(wx, 0.32, wz); wn.material_override = wm; add_child(wn)

func _add_box(pos: Vector3, size: Vector3) -> MeshInstance3D:
	return _add_box_mat(pos, size, _ghost_mat)

func _add_box_mat(pos: Vector3, size: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi = MeshInstance3D.new(); var bm = BoxMesh.new(); bm.size = size
	mi.mesh = bm; mi.position = pos; mi.material_override = mat; add_child(mi); return mi

func _emissive_mat(color: Color, energy: float) -> StandardMaterial3D:
	var mat = StandardMaterial3D.new()
	mat.albedo_color              = color
	mat.emission_enabled          = true
	mat.emission                  = color
	mat.emission_energy_multiplier = energy
	mat.transparency              = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color.a            = 0.8
	return mat
