extends CanvasLayer
class_name GameUI

# =============================================================================
#  GameUI — manages all 2D UI layers:
#
#   STATE_START   : full-screen splash with "Start" button
#   STATE_PICK    : top-down map shows; user clicks start then end point
#   STATE_DRIVING : ghost is driving; shows progress bar + speed controls
#   STATE_ARRIVED : "Arrived!" overlay with replay option
#
#  Signals emitted to Main:
#   path_requested(start: Vector2, goal: Vector2)   → trigger pathfinding
#   speed_changed(multiplier: float)
# =============================================================================

signal path_requested(start: Vector2, goal: Vector2)
signal speed_changed(multiplier: float)

enum State { START, PICK_START, PICK_GOAL, DRIVING, ARRIVED }
var _state : int = State.START

# Map info (set by Main)
var _map_half   : float = 200.0
var _block_size : float = 100.0

# Picked world coords
var _pick_start : Vector2 = Vector2.ZERO
var _pick_goal  : Vector2 = Vector2.ZERO

# Speed options
const SPEED_OPTIONS : Array = [1.0, 2.0, 5.0, 10.0]
var _speed_idx : int = 0

# Top-down camera reference (set by Main)
var _top_cam : Camera3D = null

# ── Controls ──────────────────────────────────────────────────────────────────
var _start_screen  : Control
var _pick_screen   : Control
var _drive_screen  : Control
var _arrived_panel : Control
var _status_label  : Label
var _progress_bar  : ProgressBar
var _speed_label   : Label
var _start_dot     : ColorRect
var _goal_dot      : ColorRect

# =============================================================================
#  SETUP
# =============================================================================
func setup(map_half: float, block_size: float, top_cam: Camera3D) -> void:
	_map_half   = map_half
	_block_size = block_size
	_top_cam    = top_cam
	_build_ui()
	_show_state(State.START)

# =============================================================================
#  BUILD UI
# =============================================================================
func _build_ui() -> void:
	# ── Start Screen ──────────────────────────────────────────────────────────
	_start_screen = _panel(Color(0.04, 0.06, 0.12, 0.96))
	_start_screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_start_screen)

	var logo = _label("🏙  CITY NAVIGATOR", 46, Color(0.3, 0.9, 1.0))
	logo.set_anchors_preset(Control.PRESET_CENTER)
	logo.position = Vector2(-260, -120)
	_start_screen.add_child(logo)

	var sub = _label("AI-powered ghost vehicle routing", 18, Color(0.6, 0.8, 0.9))
	sub.set_anchors_preset(Control.PRESET_CENTER)
	sub.position = Vector2(-200, -55)
	_start_screen.add_child(sub)

	var btn = _button("▶  START JOURNEY", 22, Color(0.1, 0.7, 1.0))
	btn.set_anchors_preset(Control.PRESET_CENTER)
	btn.custom_minimum_size = Vector2(280, 58)
	btn.position = Vector2(-140, 20)
	btn.pressed.connect(_on_start_pressed)
	_start_screen.add_child(btn)

	var hint = _label("Use WASD / arrow keys to pan  •  Scroll to zoom  •  Right-drag to orbit", 13, Color(0.4, 0.55, 0.65))
	hint.set_anchors_preset(Control.PRESET_CENTER)
	hint.position = Vector2(-310, 110)
	_start_screen.add_child(hint)

	# ── Pick Screen overlay (transparent, click to pick) ──────────────────────
	_pick_screen = Control.new()
	_pick_screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pick_screen.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_pick_screen)

	_status_label = _label("", 20, Color(1.0, 0.92, 0.3))
	_status_label.position = Vector2(18, 12)
	_status_label.z_index  = 10
	_pick_screen.add_child(_status_label)

	# Dot markers on the 2D overlay
	_start_dot = _dot(Color(0.1, 1.0, 0.3, 0.9))
	_goal_dot  = _dot(Color(1.0, 0.2, 0.2, 0.9))
	_pick_screen.add_child(_start_dot)
	_pick_screen.add_child(_goal_dot)
	_start_dot.visible = false
	_goal_dot.visible  = false

	# ── Drive Screen HUD ──────────────────────────────────────────────────────
	_drive_screen = Control.new()
	_drive_screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	_drive_screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_drive_screen)

	# Progress bar
	var pb_bg = _panel(Color(0.0, 0.0, 0.0, 0.55))
	pb_bg.custom_minimum_size = Vector2(320, 48)
	pb_bg.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	pb_bg.position = Vector2(-338, 14)
	_drive_screen.add_child(pb_bg)

	_progress_bar = ProgressBar.new()
	_progress_bar.custom_minimum_size = Vector2(290, 18)
	_progress_bar.position            = Vector2(15, 26)
	_progress_bar.value               = 0.0
	_progress_bar.max_value           = 1.0
	pb_bg.add_child(_progress_bar)

	var prog_lbl = _label("ROUTE PROGRESS", 11, Color(0.6, 0.85, 1.0))
	prog_lbl.position = Vector2(15, 8)
	pb_bg.add_child(prog_lbl)

	# Speed control panel
	var spd_panel = _panel(Color(0.0, 0.0, 0.0, 0.55))
	spd_panel.custom_minimum_size = Vector2(200, 56)
	spd_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	spd_panel.position = Vector2(-338, 72)
	_drive_screen.add_child(spd_panel)

	_speed_label = _label("Speed: 1×", 15, Color(1.0, 0.85, 0.3))
	_speed_label.position = Vector2(12, 8)
	spd_panel.add_child(_speed_label)

	var spd_row = HBoxContainer.new()
	spd_row.position = Vector2(12, 30)
	spd_panel.add_child(spd_row)

	for spd in SPEED_OPTIONS:
		var sb = _button(str(spd) + "x", 13, Color(0.3, 0.6, 1.0))
		sb.custom_minimum_size = Vector2(40, 22)
		sb.pressed.connect(_on_speed_btn.bind(spd))
		spd_row.add_child(sb)

	# ── Arrived panel ─────────────────────────────────────────────────────────
	_arrived_panel = _panel(Color(0.04, 0.12, 0.06, 0.94))
	_arrived_panel.custom_minimum_size = Vector2(360, 180)
	_arrived_panel.set_anchors_preset(Control.PRESET_CENTER)
	_arrived_panel.position = Vector2(-180, -90)
	add_child(_arrived_panel)

	var arr_lbl = _label("✅  Destination Reached!", 28, Color(0.3, 1.0, 0.5))
	arr_lbl.position = Vector2(20, 20)
	_arrived_panel.add_child(arr_lbl)

	var replay_btn = _button("🔄  New Journey", 18, Color(0.3, 0.8, 0.4))
	replay_btn.custom_minimum_size = Vector2(200, 48)
	replay_btn.position            = Vector2(80, 110)
	replay_btn.pressed.connect(_on_replay_pressed)
	_arrived_panel.add_child(replay_btn)

# =============================================================================
#  STATE TRANSITIONS
# =============================================================================
func _show_state(s: int) -> void:
	_state = s
	_start_screen.visible  = (s == State.START)
	_pick_screen.visible   = (s == State.PICK_START or s == State.PICK_GOAL or s == State.DRIVING)
	_drive_screen.visible  = (s == State.DRIVING)
	_arrived_panel.visible = (s == State.ARRIVED)

	match s:
		State.PICK_START:
			_status_label.text = "🟢  Click to set START location"
			_start_dot.visible = false
			_goal_dot.visible  = false
		State.PICK_GOAL:
			_status_label.text = "🔴  Click to set DESTINATION"
		State.DRIVING:
			_status_label.text = "👻  Ghost vehicle en route…"
		State.ARRIVED:
			_status_label.text = ""

# =============================================================================
#  INPUT — handle map clicks during PICK states
# =============================================================================
func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton): return
	if not event.pressed: return
	if event.button_index != MOUSE_BUTTON_LEFT: return

	if _state == State.PICK_START:
		var world = _screen_to_world(event.position)
		if world != null:
			_pick_start = world
			_place_dot(_start_dot, event.position)
			_show_state(State.PICK_GOAL)

	elif _state == State.PICK_GOAL:
		var world = _screen_to_world(event.position)
		if world != null and world.distance_to(_pick_start) > _block_size * 0.5:
			_pick_goal = world
			_place_dot(_goal_dot, event.position)
			_status_label.text = "🔄  Calculating route…"
			await get_tree().process_frame
			emit_signal("path_requested", _pick_start, _pick_goal)

# =============================================================================
#  WORLD ↔ SCREEN (using the top-down camera)
# =============================================================================
func _screen_to_world(screen_pos: Vector2):
	if _top_cam == null: return Vector2.ZERO
	var viewport = get_viewport()
	if viewport == null: return Vector2.ZERO

	# Cast ray from camera through screen point onto Y=0 plane
	var from = _top_cam.project_ray_origin(screen_pos)
	var dir  = _top_cam.project_ray_normal(screen_pos)
	if abs(dir.y) < 0.001: return null
	var t    = -from.y / dir.y
	var hit  = from + dir * t

	# Snap to nearest intersection
	var gx = int(round(hit.x / _block_size))
	var gz = int(round(hit.z / _block_size))
	gx = clamp(gx, -int(_map_half / _block_size), int(_map_half / _block_size))
	gz = clamp(gz, -int(_map_half / _block_size), int(_map_half / _block_size))
	return Vector2(gx * _block_size, gz * _block_size)

func world_to_screen(world_xz: Vector2) -> Vector2:
	if _top_cam == null: return Vector2.ZERO
	var vp = get_viewport()
	if vp == null: return Vector2.ZERO
	return _top_cam.unproject_position(Vector3(world_xz.x, 0, world_xz.y))

func _place_dot(dot: ColorRect, screen_pos: Vector2) -> void:
	dot.visible  = true
	dot.position = screen_pos - Vector2(10, 10)

# =============================================================================
#  BUTTON CALLBACKS
# =============================================================================
func _on_start_pressed() -> void:
	_show_state(State.PICK_START)

func _on_speed_btn(spd: float) -> void:
	_speed_label.text = "Speed: %g×" % spd
	emit_signal("speed_changed", spd)

func _on_replay_pressed() -> void:
	_show_state(State.PICK_START)

# =============================================================================
#  CALLED BY MAIN
# =============================================================================
func on_driving_started() -> void:
	_show_state(State.DRIVING)
	_progress_bar.value = 0.0
	_speed_label.text   = "Speed: 1×"
	_speed_idx          = 0

func on_progress(ratio: float) -> void:
	if _progress_bar:
		_progress_bar.value = ratio

func on_arrived() -> void:
	_show_state(State.ARRIVED)

func on_no_path() -> void:
	_status_label.text = "⚠  No route found — pick points on the road grid"
	_show_state(State.PICK_START)

# =============================================================================
#  WIDGET HELPERS
# =============================================================================
func _panel(color: Color) -> PanelContainer:
	var pc  = PanelContainer.new()
	var sb  = StyleBoxFlat.new()
	sb.bg_color          = color
	sb.corner_radius_top_left     = 8
	sb.corner_radius_top_right    = 8
	sb.corner_radius_bottom_left  = 8
	sb.corner_radius_bottom_right = 8
	pc.add_theme_stylebox_override("panel", sb)
	return pc

func _label(text: String, size: int, color: Color) -> Label:
	var l = Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

func _button(text: String, size: int, color: Color) -> Button:
	var b = Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", size)
	var sb = StyleBoxFlat.new()
	sb.bg_color                   = color.darkened(0.35)
	sb.border_color               = color
	sb.border_width_top    = 2; sb.border_width_bottom = 2
	sb.border_width_left   = 2; sb.border_width_right  = 2
	sb.corner_radius_top_left     = 6
	sb.corner_radius_top_right    = 6
	sb.corner_radius_bottom_left  = 6
	sb.corner_radius_bottom_right = 6
	b.add_theme_stylebox_override("normal", sb)
	var sb_hover = sb.duplicate()
	sb_hover.bg_color = color.darkened(0.1)
	b.add_theme_stylebox_override("hover", sb_hover)
	return b

func _dot(color: Color) -> ColorRect:
	var cr = ColorRect.new()
	cr.custom_minimum_size = Vector2(20, 20)
	cr.color = color
	return cr
