extends Node
## UI Controller for the Circuit Puzzle game.
## Creates and manages all 2D UI elements, polling game state each frame.

var ui_layer: CanvasLayer
var stats_panel: ColorRect
var stats_name_label: Label
var stats_volts_label: Label
var stats_drop_label: Label
var info_btn: Panel
var rotate_btn: Panel
var solve_btn: Panel
var save_btn: Panel
var modal_overlay: ColorRect
var modal_title: Label
var modal_desc: Label
var show_info: bool = false

var level_label: Label
var next_btn: Panel
var comp_label: Label  # "Level Complete!" banner


func _ready() -> void:
	setup_ui()
	hide_stats()
	_update_level_ui()


func _process(_delta: float) -> void:
	var game = get_parent()
	var idx: int = game.get_meta("selected_index", -1)
	if idx >= 0:
		show_stats(game, idx)
	else:
		hide_stats()
	_update_level_ui()


# -- UI creation ------------------------------------------------------------

func setup_ui() -> void:
	ui_layer = CanvasLayer.new()
	add_child(ui_layer)

	_create_stats_panel()
	_create_info_button()
	_create_rotate_button()
	_create_solve_button()
	_create_save_button()
	_create_modal()
	_create_level_ui()


func _create_stats_panel() -> void:
	stats_panel = ColorRect.new()
	stats_panel.position = Vector2(8, 8)
	stats_panel.size = Vector2(220, 80)
	stats_panel.color = Color(0.1, 0.1, 0.15, 0.85)
	stats_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_layer.add_child(stats_panel)

	stats_name_label = Label.new()
	stats_name_label.position = Vector2(16, 12)
	stats_name_label.add_theme_font_size_override("font_size", 16)
	ui_layer.add_child(stats_name_label)

	stats_volts_label = Label.new()
	stats_volts_label.position = Vector2(16, 36)
	stats_volts_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.67))
	ui_layer.add_child(stats_volts_label)

	stats_drop_label = Label.new()
	stats_drop_label.position = Vector2(16, 54)
	stats_drop_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.67))
	ui_layer.add_child(stats_drop_label)


func _make_circle_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.12, 0.12, 0.18, 0.9)
	s.corner_radius_top_left = 18
	s.corner_radius_top_right = 18
	s.corner_radius_bottom_left = 18
	s.corner_radius_bottom_right = 18
	return s


func _add_label(parent: Panel, text: String, font_size: int = 24) -> void:
	var label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)

	# Measure text and center within parent
	var font = label.get_theme_default_font()
	var text_size = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	label.position = Vector2(
		(parent.size.x - text_size.x) / 2.0,
		(parent.size.y - text_size.y) / 2.0
	)


func _create_button(label: String, pos: Vector2, size: Vector2, click_handler: Callable, font_size: int = 24) -> Panel:
	var btn = Panel.new()
	btn.position = pos
	btn.size = size
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.add_theme_stylebox_override("panel", _make_circle_style())
	btn.gui_input.connect(click_handler)
	ui_layer.add_child(btn)

	_add_label(btn, label, font_size)
	return btn

func _create_info_button() -> void:
	info_btn = _create_button("i", Vector2(24, -72), Vector2(36, 36), _on_info_clicked)
	info_btn.set_anchors_preset(Control.PRESET_BOTTOM_LEFT, true)


func _create_rotate_button() -> void:
	rotate_btn = _create_button("↺", Vector2(68, -72), Vector2(36, 36), _on_rotate_clicked, 20)
	rotate_btn.set_anchors_preset(Control.PRESET_BOTTOM_LEFT, true)


func _create_solve_button() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.7, 0.1, 0.1, 1.0)
	style.border_color = Color(0.5, 0.05, 0.05, 1.0)
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6

	solve_btn = Panel.new()
	solve_btn.position = Vector2(-120, -72)
	solve_btn.size = Vector2(80, 36)
	solve_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	solve_btn.add_theme_stylebox_override("panel", style)
	solve_btn.gui_input.connect(_on_solve_clicked)
	solve_btn.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT, true)
	ui_layer.add_child(solve_btn)

	_add_label(solve_btn, "SOLVE", 17)


func _create_modal() -> void:
	modal_overlay = ColorRect.new()
	modal_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	modal_overlay.color = Color(0, 0, 0, 0.6)
	modal_overlay.visible = false
	modal_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	modal_overlay.gui_input.connect(_on_modal_dismiss)
	ui_layer.add_child(modal_overlay)

	modal_title = Label.new()
	modal_title.position = Vector2(450, 280)
	modal_title.add_theme_font_size_override("font_size", 24)
	modal_title.visible = false
	ui_layer.add_child(modal_title)

	modal_desc = Label.new()
	modal_desc.position = Vector2(460, 330)
	modal_desc.size = Vector2(360, 200)
	modal_desc.add_theme_font_size_override("font_size", 14)
	modal_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	modal_desc.visible = false
	ui_layer.add_child(modal_desc)

# -- Level UI --------------------------------------------------------------

func _create_level_ui() -> void:
	# Level name label (top center)
	level_label = Label.new()
	level_label.add_theme_font_size_override("font_size", 18)
	level_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	level_label.add_theme_constant_override("outline_size", 4)
	level_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.6))
	level_label.set_anchors_preset(Control.PRESET_TOP_WIDE, true)
	level_label.position = Vector2(0, 12)
	level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ui_layer.add_child(level_label)

	# "Level Complete!" banner (below level name)
	comp_label = Label.new()
	comp_label.add_theme_font_size_override("font_size", 22)
	comp_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
	comp_label.add_theme_constant_override("outline_size", 4)
	comp_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.7))
	comp_label.set_anchors_preset(Control.PRESET_TOP_WIDE, true)
	comp_label.position = Vector2(0, 40)
	comp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	comp_label.visible = false
	ui_layer.add_child(comp_label)

	# Next Level button (top right)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.55, 0.15, 1.0)
	style.border_color = Color(0.1, 0.4, 0.1, 1.0)
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6

	next_btn = Panel.new()
	next_btn.size = Vector2(130, 36)
	next_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	next_btn.add_theme_stylebox_override("panel", style)
	next_btn.gui_input.connect(_on_next_clicked)
	next_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT, true)
	next_btn.position = Vector2(-140, 12)
	next_btn.visible = false
	ui_layer.add_child(next_btn)

	_add_label(next_btn, "Next Level", 16)


func _update_level_ui() -> void:
	var game = get_parent()
	var level: int = game.get_meta("_level_current", 0)
	var total: int = game.get_meta("_level_count", 1)
	var name_str: String = game.get_meta("_level_name", "???")
	var completed: bool = game.get_meta("_level_complete", false)

	level_label.text = "%s  (%d / %d)" % [name_str, level + 1, total]

	comp_label.text = "Level Complete!" if completed else ""
	comp_label.visible = completed

	next_btn.visible = completed

func _on_next_clicked(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return
	print("Next level clicked")
	get_parent().set_meta("_action_next_level", true)


# -- Visibility helpers ----------------------------------------------------

func show_stats(game: Node, _idx: int) -> void:
	stats_panel.visible = true
	stats_name_label.visible = true
	stats_volts_label.visible = true
	stats_drop_label.visible = true
	info_btn.visible = true
	rotate_btn.visible = true

	var name_str: String = game.get_meta("_part_name", "???")
	var kind: int = game.get_meta("_part_kind", -1)
	var volts_in: float = game.get_meta("_part_volts_in", 0.0)
	var drop: float = game.get_meta("_part_drop", 0.0)

	stats_name_label.text = name_str
	if kind == 0:
		stats_volts_label.text = "EMF: %.2fV" % volts_in
	else:
		stats_volts_label.text = "Volts in: %.2fV" % volts_in
	stats_drop_label.text = "Drop: %.2fV" % drop


func hide_stats() -> void:
	if show_info:
		return
	stats_panel.visible = false
	stats_name_label.visible = false
	stats_volts_label.visible = false
	stats_drop_label.visible = false
	info_btn.visible = false
	rotate_btn.visible = false


# -- Button handlers --------------------------------------------------------

func _on_info_clicked(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return
	print("Info clicked")
	var game = get_parent()
	show_info = true
	modal_overlay.visible = true
	var title_str: String = game.get_meta("_part_name", "???")
	var desc_str: String = game.get_meta("_part_description", "")
	modal_title.text = title_str
	modal_desc.text = desc_str
	modal_title.visible = true
	modal_desc.visible = true


func _on_rotate_clicked(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return
	print("Rotate clicked")
	get_parent().set_meta("_action_rotate", true)


func _create_save_button() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.2, 0.2, 0.35, 1.0)
	style.border_color = Color(0.15, 0.15, 0.25, 1.0)
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6

	save_btn = Panel.new()
	save_btn.position = Vector2(-210, -72)
	save_btn.size = Vector2(80, 36)
	save_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	save_btn.add_theme_stylebox_override("panel", style)
	save_btn.gui_input.connect(_on_save_clicked)
	save_btn.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT, true)
	ui_layer.add_child(save_btn)

	_add_label(save_btn, "SAVE", 17)


func _on_solve_clicked(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return
	print("Solve clicked")
	get_parent().set_meta("_action_solve", true)


func _on_save_clicked(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return
	print("Save clicked")
	get_parent().set_meta("_action_save", true)


func _on_modal_dismiss(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		show_info = false
		modal_overlay.visible = false
		modal_title.visible = false
		modal_desc.visible = false
