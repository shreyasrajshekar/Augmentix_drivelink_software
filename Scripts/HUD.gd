extends CanvasLayer

var car_labels: Dictionary = {}
var ml_label: Label
var fps_label: Label
var vbox: VBoxContainer

func _ready():
	var panel = PanelContainer.new()
	panel.position = Vector2(12, 12)

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.68)
	style.corner_radius_top_left    = 8
	style.corner_radius_top_right   = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	style.content_margin_left   = 14
	style.content_margin_right  = 14
	style.content_margin_top    = 10
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	_lbl("🚦  ML TRAFFIC CONTROL", 15, Color(1.0, 0.84, 0.18))
	vbox.add_child(HSeparator.new())

	ml_label = _lbl("⚪  ML Server: connecting…", 12, Color(0.65, 0.65, 0.65))
	vbox.add_child(HSeparator.new())

	# Footer added last; car labels inserted before it
	vbox.add_child(HSeparator.new())
	_lbl("[SPACE] batch  [1-4] lanes  [P] ping  [R] reset", 10, Color(0.42, 0.42, 0.42))
	fps_label = _lbl("FPS: --", 11, Color(0.48, 0.48, 0.48))

func _process(_delta):
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()

func register_car(index: int):
	if car_labels.has(index):
		return
	var lbl = Label.new()
	lbl.text = "🚗 Car %d  initialising…" % index
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(0.80, 0.80, 0.80))
	# Insert before the last 3 footer children (sep, hint, fps)
	var pos = max(0, vbox.get_child_count() - 3)
	vbox.add_child(lbl)
	vbox.move_child(lbl, pos)
	car_labels[index] = lbl

func update_car(index: int, lane: int, decision: String,
		confidence: float, spd: float):
	if not car_labels.has(index):
		register_car(index)
	var icon  = "✅ MERGE" if decision == "MERGE" else "⏳ WAIT "
	var color = Color(0.28, 1.0, 0.42) if decision == "MERGE" else Color(0.82, 0.82, 0.82)
	car_labels[index].text = (
		"🚗 Car %d  |  Lane %d  |  %s  | %.0f%%  |  %.1f m/s"
		% [index, lane, icon, confidence * 100.0, spd]
	)
	car_labels[index].add_theme_color_override("font_color", color)

func set_ml_connected(is_connected: bool):
	if is_connected:
		ml_label.text = "🟢
		
		  ML Server: connected"
		ml_label.add_theme_color_override("font_color", Color(0.28, 1.0, 0.42))
	else:
		ml_label.text = "🔴  ML Server: disconnected"
		ml_label.add_theme_color_override("font_color", Color(1.0, 0.30, 0.30))

# ── Helper ─────────────────────────────────────────────────────────────────────
func _lbl(text: String, size: int, color: Color) -> Label:
	var l = Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	vbox.add_child(l)
	return l
