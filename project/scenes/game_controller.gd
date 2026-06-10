extends Node3D
## Game Controller for Circuit Puzzle.
##
## Owns all game state, camera, input handling, circuit simulation,
## and writes meta for UI/BoardRenderer children to read.

# - Constants ---------------------------------------------------------------

const GRID_W: int = 5
const GRID_D: int = 5
const BLOCK_SIZE: float = 1.0
const MAX_PARTS: int = 8
const CELL_VOLTAGE: float = 1.5
const LED_FORWARD_VOLTAGE: float = 1.8

enum PartType { CELL, WIRE_STRAIGHT, WIRE_CORNER, LED }
enum Orientation { ROT0, ROT90, ROT180, ROT270 }
enum Dir { EAST, WEST, NORTH, SOUTH }

# - Direction utilities ----------------------------------

static func dir_delta(d: int) -> Vector2i:
	match d:
		Dir.EAST:  return Vector2i(1, 0)
		Dir.WEST:  return Vector2i(-1, 0)
		Dir.NORTH: return Vector2i(0, 1)
		Dir.SOUTH: return Vector2i(0, -1)
	return Vector2i(0, 0)

static func opposite(d: int) -> int:
	match d:
		Dir.EAST:  return Dir.WEST
		Dir.WEST:  return Dir.EAST
		Dir.NORTH: return Dir.SOUTH
		Dir.SOUTH: return Dir.NORTH
	return Dir.EAST

static func rot_dir(dx: float, dz: float, o: int) -> Vector2:
	match o:
		Orientation.ROT0:   return Vector2(dx, dz)
		Orientation.ROT90:  return Vector2(dz, -dx)
		Orientation.ROT180: return Vector2(-dx, -dz)
		Orientation.ROT270: return Vector2(-dz, dx)
	return Vector2(dx, dz)

static func rotate_dir(d: int, o: int) -> int:
	var dx: float = 0.0
	var dz: float = 0.0
	match d:
		Dir.EAST:  dx = 1.0
		Dir.WEST:  dx = -1.0
		Dir.NORTH: dz = 1.0
		Dir.SOUTH: dz = -1.0
	var r := rot_dir(dx, dz, o)
	if r.x > 0.5:   return Dir.EAST
	if r.x < -0.5:  return Dir.WEST
	if r.y > 0.5:   return Dir.NORTH
	return Dir.SOUTH

static func connect_dirs(kind: int, o: int) -> Array[int]:
	var canon: Array[int]
	match kind:
		PartType.CELL, PartType.WIRE_STRAIGHT, PartType.LED:
			canon = [Dir.EAST, Dir.WEST]
		PartType.WIRE_CORNER:
			canon = [Dir.WEST, Dir.NORTH]
	return [rotate_dir(canon[0], o), rotate_dir(canon[1], o)]

static func battery_plus_dir(o: int) -> int:
	return rotate_dir(Dir.EAST, o)

static func part_name(kind: int) -> String:
	match kind:
		PartType.CELL:          return "Cell (battery)"
		PartType.WIRE_STRAIGHT: return "Wire (straight)"
		PartType.WIRE_CORNER:   return "Wire (corner)"
		PartType.LED:           return "LED"
	return "???"

static func part_description(kind: int) -> String:
	match kind:
		PartType.CELL:
			return "Just like an AA battery, provides electrical current. Current flows from + to - terminal. Provides 1.5 volts of potential difference."
		PartType.WIRE_STRAIGHT, PartType.WIRE_CORNER:
			return "Conducts current using a low resistance metal like copper. Infinite conductivity in this simulation, so no voltage drop across wires."
		PartType.LED:
			return "Light Emitting Diode. Lights up when current flows through it in the correct direction. Current must enter the anode (A) and exit the cathode (K). A diode is a one-way valve for current. A red LED requires about 1.8 volts to activate."
	return ""

# - Circuit simulation ----------------------------------

static func simulate_circuit(
	part_kinds: Array[int],
	part_orients: Array[int],
	part_positions: Array[Vector3],
	powered: Array[bool],
	stats_volts_in: Array[float],
	stats_drop: Array[float],
) -> void:
	var n := part_kinds.size()
	for i in n:
		powered[i] = false
		stats_volts_in[i] = 0.0
		stats_drop[i] = 0.0

	# Grid positions
	var grid: Array[Vector2i] = []
	grid.resize(MAX_PARTS)
	for i in n:
		grid[i] = Vector2i(
			int(round(part_positions[i].x)),
			int(round(part_positions[i].z)),
		)

	# Find first battery
	var batt := -1
	for i in n:
		if part_kinds[i] == PartType.CELL:
			batt = i
			break
	if batt < 0:
		return

	var bp := battery_plus_dir(part_orients[batt])
	var bm := opposite(bp)

	# Cell EMF always shown
	for i in n:
		if part_kinds[i] == PartType.CELL:
			stats_volts_in[i] = CELL_VOLTAGE
			stats_drop[i] = 0.0

	# max_volt[i * 4 + dir_ordinal]
	var max_volt: Array[float] = []
	max_volt.resize(MAX_PARTS * 4)
	for i in MAX_PARTS * 4:
		max_volt[i] = 0.0

	# BFS queue
	var queue_idx: Array[int] = []
	var queue_exit: Array[int] = []
	var queue_volt: Array[float] = []
	var qhead := 0

	# Seed: current exits battery + terminal
	queue_idx.append(batt)
	queue_exit.append(bp)
	queue_volt.append(CELL_VOLTAGE)

	var circuit_closed := false

	while qhead < queue_idx.size():
		var cur_idx := queue_idx[qhead]
		var cur_exit := queue_exit[qhead]
		var cur_volt := queue_volt[qhead]
		qhead += 1

		var my_gpos := grid[cur_idx]
		var dd := dir_delta(cur_exit)
		var nb_gpos := Vector2i(my_gpos.x + dd.x, my_gpos.y + dd.y)

		# Find neighbour
		var nb := -1
		for j in n:
			if grid[j] == nb_gpos:
				nb = j
				break
		if nb < 0:
			continue

		var arr_dir := opposite(cur_exit)
		var nb_ports := connect_dirs(part_kinds[nb], part_orients[nb])

		if nb_ports[0] != arr_dir and nb_ports[1] != arr_dir:
			continue

		var vk := nb * 4 + int(arr_dir)
		if cur_volt <= max_volt[vk]:
			continue
		max_volt[vk] = cur_volt

		# Reached battery -terminal?
		if nb == batt and arr_dir == bm:
			circuit_closed = true
			continue

		# Secondary cell in series
		if part_kinds[nb] == PartType.CELL:
			var cp := battery_plus_dir(part_orients[nb])
			var cm := opposite(cp)
			if arr_dir != cm:
				continue
			queue_idx.append(nb)
			queue_exit.append(cp)
			queue_volt.append(cur_volt + CELL_VOLTAGE)
			continue

		# Voltage stats
		var v_drop: float = LED_FORWARD_VOLTAGE if part_kinds[nb] == PartType.LED else 0.0
		stats_volts_in[nb] = cur_volt
		stats_drop[nb] = v_drop
		var v_out := maxf(0.0, cur_volt - v_drop)

		# LED: must enter anode (port[0]) with sufficient voltage
		if part_kinds[nb] == PartType.LED:
			if arr_dir != nb_ports[0]:
				continue
			if cur_volt < LED_FORWARD_VOLTAGE:
				continue
			powered[nb] = true

		# Propagate through other port
		for pd in nb_ports:
			if pd == arr_dir:
				continue
			queue_idx.append(nb)
			queue_exit.append(pd)
			queue_volt.append(v_out)

	# If circuit not closed, LEDs and stats (except cell EMF) are reset
	if not circuit_closed:
		for i in n:
			powered[i] = false
			if part_kinds[i] != PartType.CELL:
				stats_volts_in[i] = 0.0
				stats_drop[i] = 0.0

# - Node references ----------------------------------------------------------

var camera: Camera3D
@onready var led_model_root: Node3D = get_node_or_null("led_top")
var led_lights: Array[OmniLight3D] = []

# - Camera state --------------------------------------------------------------

var cam_azimuth: float = PI
var cam_pitch: float = 0.68
var cam_dist: float = 16.0
var cam_target: Vector3 = Vector3(2.0, 0.5, 2.0)

# - Interaction state ---------------------------------------------------------

var dragging: int = -1
var drag_origin: Vector3
var selected_part: int = -1
var hovered_part: int = -1
var camera_drag_active: bool = false
var last_mouse_pos: Vector2
var mouse_pressed: bool = false
var target_block: Vector3
var target_valid: bool = false

# - Part state -----------------------------------------------------------------

var part_kinds: Array[int] = []
var part_orients: Array[int] = []
var part_positions: Array[Vector3] = []
var powered: Array[bool] = []
var stats_volts_in: Array[float] = []
var stats_drop: Array[float] = []

# - Init -----------------------------------------------------------------------

func _ready() -> void:
	_init_parts()
	_setup_camera()
	_setup_lights()
	# led_model_root is set via @onready
	_simulate()

func _init_parts() -> void:
	part_kinds.resize(MAX_PARTS)
	part_orients.resize(MAX_PARTS)
	part_positions.resize(MAX_PARTS)
	powered.resize(MAX_PARTS)
	stats_volts_in.resize(MAX_PARTS)
	stats_drop.resize(MAX_PARTS)

	# Start with a solved closed circuit
	part_kinds[0] = PartType.WIRE_CORNER;    part_orients[0] = Orientation.ROT90;   part_positions[0] = Vector3(0, 0, 0)
	part_kinds[1] = PartType.WIRE_CORNER;    part_orients[1] = Orientation.ROT0;    part_positions[1] = Vector3(2, 0, 0)
	part_kinds[2] = PartType.WIRE_CORNER;    part_orients[2] = Orientation.ROT270;  part_positions[2] = Vector3(2, 0, 2)
	part_kinds[3] = PartType.WIRE_CORNER;    part_orients[3] = Orientation.ROT180;  part_positions[3] = Vector3(0, 0, 2)
	part_kinds[4] = PartType.CELL;           part_orients[4] = Orientation.ROT270;  part_positions[4] = Vector3(0, 0, 1)
	part_kinds[5] = PartType.WIRE_STRAIGHT;  part_orients[5] = Orientation.ROT0;    part_positions[5] = Vector3(1, 0, 0)
	part_kinds[6] = PartType.CELL;           part_orients[6] = Orientation.ROT0;    part_positions[6] = Vector3(1, 0, 2)
	part_kinds[7] = PartType.LED;            part_orients[7] = Orientation.ROT270;  part_positions[7] = Vector3(2, 0, 1)

# - Camera ---------------------------------------------------------------------

func _setup_camera() -> void:
	camera = Camera3D.new()
	camera.fov = 60.0
	add_child(camera)
	_update_camera_transform()

func _update_camera_transform() -> void:
	var cos_p := cos(cam_pitch)
	var pos := Vector3(
		cam_target.x + cam_dist * cos_p * sin(cam_azimuth),
		cam_target.y + cam_dist * sin(cam_pitch),
		cam_target.z + cam_dist * cos_p * cos(cam_azimuth),
	)
	camera.position = pos
	camera.look_at(cam_target)

func _handle_camera_keys(dt: float) -> void:
	var pan := 10.0 * dt
	var rot := 1.5 * dt
	var fwd_x := -sin(cam_azimuth)
	var fwd_z := -cos(cam_azimuth)
	var rgt_x := cos(cam_azimuth)
	var rgt_z := -sin(cam_azimuth)

	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		cam_target.x += fwd_x * pan;  cam_target.z += fwd_z * pan
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		cam_target.x -= fwd_x * pan;  cam_target.z -= fwd_z * pan
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		cam_target.x -= rgt_x * pan;  cam_target.z -= rgt_z * pan
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		cam_target.x += rgt_x * pan;  cam_target.z += rgt_z * pan
	if Input.is_key_pressed(KEY_Q):
		cam_azimuth -= rot
	if Input.is_key_pressed(KEY_E):
		cam_azimuth += rot

# - Lights ---------------------------------------------------------------------

func _setup_lights() -> void:
	# Directional sun
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	sun.rotation.x = -0.785398
	add_child(sun)

	# Per-LED omni lights
	led_lights.resize(MAX_PARTS)
	for i in MAX_PARTS:
		var light := OmniLight3D.new()
		light.omni_range = 3.0
		light.light_energy = 0.0
		light.light_color = Color(1.0, 0.4, 0.4)
		add_child(light)
		led_lights[i] = light

# - LED model ------------------------------------------------------------------

func _update_led_model() -> void:
	for i in MAX_PARTS:
		if part_kinds[i] == PartType.LED:
			var p := part_positions[i]
			var top := p.y + BLOCK_SIZE * 0.12

			# Position led_top GLB model (spun 180° to align with circuit direction)
			if is_instance_valid(led_model_root):
				var angle := float(part_orients[i]) * PI * 0.5 + PI
				var basis := Basis(Vector3.UP, angle)
				var s: float = 0.3
				basis = basis.scaled(Vector3(s, s, s))
				var origin := Vector3(p.x, top + 0.5, p.z)
				led_model_root.transform = Transform3D(basis, origin)

			# LED glow light
			if i < led_lights.size() and is_instance_valid(led_lights[i]):
				if powered[i]:
					led_lights[i].position = Vector3(p.x, p.y + 0.6, p.z)
					led_lights[i].light_energy = 4.0
				else:
					led_lights[i].light_energy = 0.0

# - Circuit simulation wrapper ------------------------------------------------

func _simulate() -> void:
	simulate_circuit(part_kinds, part_orients, part_positions, powered, stats_volts_in, stats_drop)

# - Per-frame ------------------------------------------------------------------

func _process(delta: float) -> void:
	_handle_camera_keys(delta)
	_update_camera_transform()
	_update_led_model()
	_write_meta()

# - Meta writing (for GDScript UI and BoardRenderer) --------------------------

func _write_meta() -> void:
	var sel: int = selected_part
	set_meta("selected_index", sel)

	if sel >= 0:
		var k := part_kinds[sel]
		set_meta("_part_name", part_name(k))
		set_meta("_part_kind", k)
		set_meta("_part_volts_in", stats_volts_in[sel])
		set_meta("_part_drop", stats_drop[sel])
		set_meta("_part_description", part_description(k))

	# Board renderer data
	set_meta("_part_count", MAX_PARTS)
	set_meta("_grid_w", GRID_W)
	set_meta("_grid_d", GRID_D)
	set_meta("_block_size", BLOCK_SIZE)
	set_meta("_hovered_index", hovered_part)

	if target_block != Vector3.ZERO:
		set_meta("_target_block", target_block)
		set_meta("_target_valid", target_valid)
	else:
		remove_meta("_target_block")

	for i in MAX_PARTS:
		set_meta("_part_pos_%d" % i, part_positions[i])
		set_meta("_part_kind_%d" % i, part_kinds[i])
		set_meta("_part_orient_%d" % i, part_orients[i])
		set_meta("_part_powered_%d" % i, powered[i])

	# Handle action triggers from UI
	var act_rotate: bool = get_meta("_action_rotate", false)
	if act_rotate:
		remove_meta("_action_rotate")
		_rotate_selected()

	var act_solve: bool = get_meta("_action_solve", false)
	if act_solve:
		remove_meta("_action_solve")
		_debug_solve()

# - Part interaction -----------------------------------------------------------

func _rotate_selected() -> void:
	if selected_part >= 0:
		var o := part_orients[selected_part]
		match o:
			Orientation.ROT0:   part_orients[selected_part] = Orientation.ROT90
			Orientation.ROT90:  part_orients[selected_part] = Orientation.ROT180
			Orientation.ROT180: part_orients[selected_part] = Orientation.ROT270
			Orientation.ROT270: part_orients[selected_part] = Orientation.ROT0
		_simulate()

func _debug_solve() -> void:
	var y: float = 0.0
	part_kinds[0] = PartType.WIRE_CORNER;    part_orients[0] = Orientation.ROT90;   part_positions[0] = Vector3(0, y, 0)
	part_kinds[1] = PartType.WIRE_CORNER;    part_orients[1] = Orientation.ROT0;    part_positions[1] = Vector3(2, y, 0)
	part_kinds[2] = PartType.WIRE_CORNER;    part_orients[2] = Orientation.ROT270;  part_positions[2] = Vector3(2, y, 2)
	part_kinds[3] = PartType.WIRE_CORNER;    part_orients[3] = Orientation.ROT180;  part_positions[3] = Vector3(0, y, 2)
	part_kinds[4] = PartType.CELL;           part_orients[4] = Orientation.ROT270;  part_positions[4] = Vector3(0, y, 1)
	part_kinds[5] = PartType.WIRE_STRAIGHT;  part_orients[5] = Orientation.ROT0;    part_positions[5] = Vector3(1, y, 0)
	part_kinds[6] = PartType.CELL;           part_orients[6] = Orientation.ROT0;    part_positions[6] = Vector3(1, y, 2)
	part_kinds[7] = PartType.LED;            part_orients[7] = Orientation.ROT270;  part_positions[7] = Vector3(2, y, 1)
	_simulate()

func _is_occupied(ignore_idx: int, pos: Vector3) -> bool:
	for i in MAX_PARTS:
		if i == ignore_idx: continue
		if abs(part_positions[i].x - pos.x) < 0.5 and abs(part_positions[i].z - pos.z) < 0.5:
			return true
	return false

# - Input: Keyboard ------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var ke := event as InputEventKey
		if ke.pressed and not ke.echo:
			if ke.keycode == KEY_R:
				_rotate_selected()

# - Input: Mouse / Touch -------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	# Mouse button
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_on_pointer_pressed(mb.position)
			else:
				_on_pointer_released(mb.position)
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_dist = maxf(4.0, cam_dist - 1.5)
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_dist = minf(80.0, cam_dist + 1.5)

	# Mouse motion
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var delta := mm.relative
		var pos := mm.position

		if mouse_pressed:
			if dragging >= 0:
				_on_pointer_drag(pos)
			elif camera_drag_active:
				cam_azimuth += delta.x * 0.005
				cam_pitch -= delta.y * 0.005
				cam_pitch = clampf(cam_pitch, 0.1, PI * 0.45)
		else:
			hovered_part = _screen_raycast_parts(pos)

	# Touch
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_on_pointer_pressed(touch.position)
		else:
			_on_pointer_released(touch.position)

	if event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		var delta := drag.relative
		var pos := drag.position

		if mouse_pressed:
			if dragging >= 0:
				_on_pointer_drag(pos)
			elif camera_drag_active:
				var s: float = 0.005
				cam_azimuth += delta.x * s
				cam_pitch -= delta.y * s
				cam_pitch = clampf(cam_pitch, 0.1, PI * 0.45)

func _on_pointer_pressed(screen_pos: Vector2) -> void:
	mouse_pressed = true
	last_mouse_pos = screen_pos

	var hit := _screen_raycast_parts(screen_pos)
	if hit >= 0:
		dragging = hit
		selected_part = hit
		drag_origin = part_positions[hit]
	else:
		camera_drag_active = true
		selected_part = -1

func _on_pointer_released(screen_pos: Vector2) -> void:
	mouse_pressed = false
	target_block = Vector3.ZERO
	if dragging >= 0:
		var target := _screen_raycast_terrain(screen_pos)
		if target != null:
			if not _is_occupied(dragging, target):
				part_positions[dragging] = target
				_simulate()
			else:
				part_positions[dragging] = drag_origin
		else:
			part_positions[dragging] = drag_origin
		dragging = -1
	camera_drag_active = false

func _on_pointer_drag(screen_pos: Vector2) -> void:
	if dragging >= 0:
		var target := _screen_raycast_terrain(screen_pos)
		if target != null:
			part_positions[dragging] = target
			target_block = target
			target_valid = not _is_occupied(dragging, target)

# - Raycasting -----------------------------------------------------------------

func _screen_raycast_parts(screen_pos: Vector2) -> int:
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var best_dist: float = INF
	var result: int = -1

	for i in MAX_PARTS:
		var p := part_positions[i]
		var half: float = BLOCK_SIZE * 0.5
		var dist := _ray_aabb(from, dir,
			Vector3(p.x - half, p.y, p.z - half),
			Vector3(p.x + half, p.y + BLOCK_SIZE, p.z + half))
		if dist >= 0 and dist < best_dist:
			best_dist = dist
			result = i
	return result

func _screen_raycast_terrain(screen_pos: Vector2) -> Vector3:
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)

	if abs(dir.y) < 1e-7:
		return Vector3.ZERO
	var t: float = -from.y / dir.y
	if t < 0:
		return Vector3.ZERO

	var hit_x: float = from.x + dir.x * t
	var hit_z: float = from.z + dir.z * t

	var gx: float = round(hit_x / BLOCK_SIZE)
	var gz: float = round(hit_z / BLOCK_SIZE)

	var clamped_x := maxf(0.0, minf(float(GRID_W - 1) * BLOCK_SIZE, gx * BLOCK_SIZE))
	var clamped_z := maxf(0.0, minf(float(GRID_D - 1) * BLOCK_SIZE, gz * BLOCK_SIZE))

	return Vector3(clamped_x, 0.0, clamped_z)

static func _ray_aabb(origin: Vector3, dir: Vector3, mn: Vector3, mx: Vector3) -> float:
	var eps: float = 1e-7
	var dx := dir.x if abs(dir.x) >= eps else eps
	var dy := dir.y if abs(dir.y) >= eps else eps
	var dz := dir.z if abs(dir.z) >= eps else eps
	var tx1 := (mn.x - origin.x) / dx
	var tx2 := (mx.x - origin.x) / dx
	var ty1 := (mn.y - origin.y) / dy
	var ty2 := (mx.y - origin.y) / dy
	var tz1 := (mn.z - origin.z) / dz
	var tz2 := (mx.z - origin.z) / dz
	var tmin := maxf(maxf(minf(tx1, tx2), minf(ty1, ty2)), minf(tz1, tz2))
	var tmax := minf(minf(maxf(tx1, tx2), maxf(ty1, ty2)), maxf(tz1, tz2))
	if tmax < 0 or tmin > tmax:
		return -1.0
	return tmin if tmin >= 0 else tmax
