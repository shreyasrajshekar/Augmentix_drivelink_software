extends CanvasLayer

var car_labels: Dictionary = {}
var ml_label: Label
var vbox: VBoxContainer
var chat_vbox: VBoxContainer
var scroll_container: ScrollContainer

func _ready():
	_setup_ui()

func _setup_ui():
	# Main Control Panel
	var panel = PanelContainer.new()
	panel.position = Vector2(12, 12)
	panel.custom_minimum_size = Vector2(300, 0)
	panel.add_theme_stylebox_override("panel", _get_style(Color(0, 0, 0, 0.7)))
	add_child(panel)

	vbox = VBoxContainer.new()
	panel.add_child(vbox)
	
	_lbl(vbox, "🚦 TRAFFIC CONTROL", 14, Color.YELLOW)
	
	# THE TOGGLE BUTTON
	var btn = CheckButton.new()
	btn.text = "ML SAFETY PROTOCOL"
	btn.button_pressed = true
	# We connect this to the Main node (the parent of HUD)
	btn.toggled.connect(get_parent()._on_ml_toggle_changed)
	vbox.add_child(btn)
	
	vbox.add_child(HSeparator.new())
	ml_label = _lbl(vbox, "🟢 ML Server: Online", 12, Color.GREEN)

	# V2X Log Panel (Bottom Left)
	var chat_panel = PanelContainer.new()
	chat_panel.custom_minimum_size = Vector2(400, 180)
	chat_panel.position = Vector2(12, 500) # Adjust based on screen height
	chat_panel.add_theme_stylebox_override("panel", _get_style(Color(0.05, 0.05, 0.1, 0.8)))
	add_child(chat_panel)

	var chat_layout = VBoxContainer.new()
	chat_panel.add_child(chat_layout)
	_lbl(chat_layout, "💬 V2X NETWORK LOG", 11, Color.SKY_BLUE)

	scroll_container = ScrollContainer.new()
	scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chat_layout.add_child(scroll_container)

	chat_vbox = VBoxContainer.new()
	scroll_container.add_child(chat_vbox)

# ── Public Logging Functions ──
func post_chat_message(msg: String, color: Color = Color.WHITE):
	var l = Label.new()
	l.text = "> " + msg
	l.add_theme_font_size_override("font_size", 10)
	l.add_theme_color_override("font_color", color)
	chat_vbox.add_child(l)
	
	await get_tree().process_frame
	scroll_container.scroll_vertical = scroll_container.get_v_scroll_bar().max_value
	get_tree().create_timer(6.0).timeout.connect(func(): if is_instance_valid(l): l.queue_free())

func _lbl(cont, txt, sz, col):
	var l = Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_color_override("font_color", col)
	cont.add_child(l)
	return l
func set_ml_connected(is_connected: bool):
	# If ml_label hasn't been initialized yet, wait
	if not is_instance_valid(ml_label): return
	
	if is_connected:
		ml_label.text = "🟢  ML Server: connected"
		ml_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))
	else:
		ml_label.text = "🔴  ML Server: disconnected"
		ml_label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
func _get_style(bg):
	var s = StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(5)
	s.set_content_margin_all(8)
	return s
