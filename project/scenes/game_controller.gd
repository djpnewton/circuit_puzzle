extends Node3D
## Game Controller for Circuit Puzzle.
##
## Owns all game state, camera, input handling, circuit simulation,
## and writes meta for UI/BoardRenderer children to read.

# - Constants ---------------------------------------------------------------

const GRID_W: int = 5
const GRID_D: int = 5
const BLOCK_SIZE: float = 1.0
const MAX_PARTS: int = 12
const CELL_VOLTAGE: float = 1.5
const LED_FORWARD_VOLTAGE: float = 1.8

enum PartType { CELL, WIRE_STRAIGHT, WIRE_CORNER, LED, WIRE_T }
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
	var result: Array[int] = []
	match kind:
		PartType.CELL, PartType.WIRE_STRAIGHT, PartType.LED:
			result = [rotate_dir(Dir.EAST, o), rotate_dir(Dir.WEST, o)]
		PartType.WIRE_CORNER:
			result = [rotate_dir(Dir.WEST, o), rotate_dir(Dir.NORTH, o)]
		PartType.WIRE_T:
			# T-junction: crossbar EAST-WEST, stem SOUTH (opening faces NORTH)
			result = [rotate_dir(Dir.EAST, o), rotate_dir(Dir.WEST, o), rotate_dir(Dir.SOUTH, o)]
	return result

static func battery_plus_dir(o: int) -> int:
	return rotate_dir(Dir.EAST, o)

static func part_name(kind: int) -> String:
	match kind:
		PartType.CELL:          return "Cell (battery)"
		PartType.WIRE_STRAIGHT: return "Wire (straight)"
		PartType.WIRE_CORNER:   return "Wire (corner)"
		PartType.LED:           return "LED"
		PartType.WIRE_T:        return "Wire (T-junction)"
	return "???"

static func part_description(kind: int) -> String:
	match kind:
		PartType.CELL:
			return "Just like an AA battery, provides electrical current. Current flows from + to - terminal. Provides 1.5 volts of potential difference."
		PartType.WIRE_STRAIGHT, PartType.WIRE_CORNER, PartType.WIRE_T:
			return "Conducts current using a low resistance metal like copper. Infinite conductivity in this simulation, so no voltage drop across wires."
		PartType.LED:
			return "Light Emitting Diode. Lights up when current flows through it in the correct direction. Current must enter the anode (A) and exit the cathode (K). A diode is a one-way valve for current. A red LED requires about 1.8 volts to activate."
	return ""

# Returns the bounding box half-extents for each part type (in local unrotated space).
static func part_half_extents(kind: int) -> Vector3:
	match kind:
		PartType.CELL:          return Vector3(0.45, 0.30, 0.30)
		PartType.WIRE_STRAIGHT: return Vector3(0.50, 0.10, 0.45)
		PartType.WIRE_CORNER:   return Vector3(0.45, 0.10, 0.45)
		PartType.WIRE_T:        return Vector3(0.50, 0.10, 0.45)
		PartType.LED:           return Vector3(0.45, 0.60, 0.45)
	return Vector3(0.50, 0.50, 0.50)

# - Level system -----------------------------------------------------------------

static func level_count() -> int:
	return 2

static func level_name(level: int) -> String:
	match level:
		0:  return "Level 1: Light it up"
		1:  return "Level 2: Parallel lights"
	return "???"

static func level_description(level: int) -> String:
	match level:
		0:  return "Arrange the components to light up the LED. You need a closed loop with at least one cell (battery) and the LED must be oriented correctly."
		1:  return "Two LEDs in parallel! Use the T-junction (3-way splitter) to split current between two LEDs. Each LED gets the full 3.0V from two cells."
	return ""

# Returns the part indices that must have `powered == true` for level completion.
static func level_targets(level: int) -> Array[int]:
	match level:
		0:  return [7]   # single LED at index 7
		1:  return [1, 5] # two LEDs at indices 1 and 5 (parallel branches)
	return []

# - Circuit simulation ----------------------------------

# After the main BFS, verify that an LED's exit path (cathode port) leads to the battery.
static func _led_exit_reaches_battery(
	led_idx: int,
	kinds: Array[int],
	orients: Array[int],
	positions: Array[Vector3],
	batt: int,
	bm: int,
	n: int,
) -> bool:
	# Follow the LED's cathode port forward
	var led_ports := connect_dirs(kinds[led_idx], orients[led_idx])
	var exit_dir := led_ports[1]  # cathode = port[1]

	var visited: Array[bool] = []
	visited.resize(MAX_PARTS)

	var queue: Array[int] = [led_idx]
	var q_exit: Array[int] = [exit_dir]
	var qh := 0

	while qh < queue.size():
		var cur := queue[qh]
		var cur_exit := q_exit[qh]
		qh += 1

		var cur_pos := Vector2i(int(round(positions[cur].x)), int(round(positions[cur].z)))
		var nd := dir_delta(cur_exit)
		var nb_pos := Vector2i(cur_pos.x + nd.x, cur_pos.y + nd.y)

		# Find neighbour
		var nb := -1
		for j in n:
			if kinds[j] < 0 or visited[j]:
				continue
			var jpos := Vector2i(int(round(positions[j].x)), int(round(positions[j].z)))
			if jpos == nb_pos:
				nb = j
				break
		if nb < 0:
			continue  # dead end - LED's exit path is broken

		var arr_dir := opposite(cur_exit)
		var nb_ports := connect_dirs(kinds[nb], orients[nb])
		if not arr_dir in nb_ports:
			continue

		# Reached battery's return side?
		if nb == batt and arr_dir == bm:
			return true

		visited[nb] = true

		# Propagate through other ports
		for pd in nb_ports:
			if pd == arr_dir:
				continue
			queue.append(nb)
			q_exit.append(pd)

	return false


# Run BFS from a given primary battery. Returns (closed, pwr_snapshot, volts_snapshot, drop_snapshot).
static func _bfs_from_battery(
	batt: int,
	kinds: Array[int],
	orients: Array[int],
	positions: Array[Vector3],
	pwr: Array[bool],
	volts_in: Array[float],
	drop: Array[float],
) -> bool:
	var n := kinds.size()
	var bp := battery_plus_dir(orients[batt])
	var bm := opposite(bp)

	# max_volt[i * 4 + dir_ordinal]
	var max_volt: Array[float] = []
	max_volt.resize(MAX_PARTS * 4)
	for i in MAX_PARTS * 4:
		max_volt[i] = 0.0

	# BFS queue - uses depth-first expansion for cells: when exploring from a
	# cell, follow the path through non-cells until reaching another cell or
	# the battery, so voltage accumulates before hitting LEDs.
	var queue_idx: Array[int] = [batt]
	var queue_exit: Array[int] = [bp]
	var queue_volt: Array[float] = [CELL_VOLTAGE]
	var qhead := 0

	var circuit_closed := false

	while qhead < queue_idx.size():
		var cur_idx := queue_idx[qhead]
		var cur_exit := queue_exit[qhead]
		var cur_volt := queue_volt[qhead]
		qhead += 1

		var my_gpos := Vector2i(
			int(round(positions[cur_idx].x)),
			int(round(positions[cur_idx].z)),
		)
		var dd2 := dir_delta(cur_exit)
		var nb_gpos := Vector2i(my_gpos.x + dd2.x, my_gpos.y + dd2.y)

		# Find neighbour (skip invalid parts)
		var nb := -1
		for j in n:
			if kinds[j] < 0:
				continue
			var j_gpos := Vector2i(
				int(round(positions[j].x)),
				int(round(positions[j].z)),
			)
			if j_gpos == nb_gpos:
				nb = j
				break
		if nb < 0:
			continue

		var arr_dir := opposite(cur_exit)
		var nb_ports := connect_dirs(kinds[nb], orients[nb])

		if not arr_dir in nb_ports:
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
		if kinds[nb] == PartType.CELL:
			var cp := battery_plus_dir(orients[nb])
			var cm := opposite(cp)
			if arr_dir != cm:
				continue
			# Push cell expansion to front of queue (depth-first) so cells
			# are processed before other components further back in the queue
			queue_idx.insert(qhead, nb)
			queue_exit.insert(qhead, cp)
			queue_volt.insert(qhead, cur_volt + CELL_VOLTAGE)
			continue

		# Voltage stats
		var v_drop: float = LED_FORWARD_VOLTAGE if kinds[nb] == PartType.LED else 0.0
		volts_in[nb] = cur_volt
		drop[nb] = v_drop
		var v_out := maxf(0.0, cur_volt - v_drop)

		# LED: must enter anode (port[0]) - undervoltage blocks (acts as open switch)
		if kinds[nb] == PartType.LED:
			if arr_dir != nb_ports[0]:
				continue
			if cur_volt < LED_FORWARD_VOLTAGE:
				continue  # blocks current - LED is an open switch below threshold
			pwr[nb] = true

		# Propagate through other ports
		for pd in nb_ports:
			if pd == arr_dir:
				continue
			# If the destination is a cell, insert at front for immediate processing
			var dest_idx := -1
			var dpos := Vector2i(
				int(round(positions[nb].x)) + dir_delta(pd).x,
				int(round(positions[nb].z)) + dir_delta(pd).y,
			)
			for j in n:
				if kinds[j] < 0:
					continue
				var jpos := Vector2i(int(round(positions[j].x)), int(round(positions[j].z)))
				if jpos == dpos:
					dest_idx = j
					break
			if dest_idx >= 0 and kinds[dest_idx] == PartType.CELL:
				queue_idx.insert(qhead, nb)
				queue_exit.insert(qhead, pd)
				queue_volt.insert(qhead, v_out)
			else:
				queue_idx.append(nb)
				queue_exit.append(pd)
				queue_volt.append(v_out)

	# After BFS: verify each powered LED's exit path independently closes
	if circuit_closed:
		for i in n:
			if kinds[i] == PartType.LED and pwr[i]:
				if not _led_exit_reaches_battery(i, kinds, orients, positions, batt, bm, n):
					pwr[i] = false
	else:
		for i in n:
			pwr[i] = false
			if kinds[i] != PartType.CELL:
				volts_in[i] = 0.0
				drop[i] = 0.0

	return circuit_closed


# Try each cell as the primary battery until one closes the circuit.
static func simulate_circuit(
	kinds: Array[int],
	orients: Array[int],
	positions: Array[Vector3],
	pwr: Array[bool],
	volts_in: Array[float],
	drop: Array[float],
) -> void:
	var n := kinds.size()
	for i in n:
		pwr[i] = false
		volts_in[i] = 0.0
		drop[i] = 0.0

	# Collect all cells
	var cells: Array[int] = []
	for i in n:
		if kinds[i] < 0:
			continue
		if kinds[i] == PartType.CELL:
			cells.append(i)

	if cells.is_empty():
		return

	# Cell EMF always shown for ALL cells
	for i in n:
		if kinds[i] == PartType.CELL:
			volts_in[i] = CELL_VOLTAGE
			drop[i] = 0.0

	# Try each cell as primary battery - first one that closes the circuit wins
	for batt in cells:
		# Snapshot-then-restore approach: write results directly into arrays
		# but reset on failure
		var saved_pwr: Array[bool] = pwr.duplicate()
		var saved_vi: Array[float] = volts_in.duplicate()
		var saved_dr: Array[float] = drop.duplicate()

		var closed := _bfs_from_battery(batt, kinds, orients, positions, pwr, volts_in, drop)

		if closed:
			return  # found a working battery ordering

		# Restore EMF display and try next cell
		for i in n:
			pwr[i] = saved_pwr[i]
			volts_in[i] = saved_vi[i]
			drop[i] = saved_dr[i]

	# Restore cell EMF on failure (no cell ordering closed the circuit)
	for i in n:
		if kinds[i] == PartType.CELL:
			volts_in[i] = CELL_VOLTAGE
			drop[i] = 0.0

# - Node references ----------------------------------------------------------

var camera: Camera3D

const LED_TOP_SCENE = preload("res://resources/models/LED/led_top.glb")
var led_models: Array[Node3D] = []
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
var drag_target: Vector3 = Vector3.ZERO
var drag_target_valid: bool = false

# - Level state -----------------------------------------------------------------

var current_level: int = 0
var level_complete: bool = false

# - Part state -------------------------------------------------------------------

var part_kinds: Array[int] = []
var part_orients: Array[int] = []
var part_positions: Array[Vector3] = []
var powered: Array[bool] = []
var stats_volts_in: Array[float] = []
var stats_drop: Array[float] = []

# - Init -------------------------------------------------------------------------

func _ready() -> void:
	part_kinds.resize(MAX_PARTS)
	part_orients.resize(MAX_PARTS)
	part_positions.resize(MAX_PARTS)
	powered.resize(MAX_PARTS)
	stats_volts_in.resize(MAX_PARTS)
	stats_drop.resize(MAX_PARTS)

	_load_level(0)
	_setup_camera()
	_setup_lights()

# - Level management -------------------------------------------------------------

func _load_level(level: int) -> void:
	current_level = level
	level_complete = false
	selected_part = -1
	hovered_part = -1

	match level:
		0:  _setup_level_1()
		1:  _setup_level_2()
		_:  _setup_level_1()

	_simulate()


func _check_level_complete() -> bool:
	if level_complete:
		return true
	var targets := level_targets(current_level)
	if targets.is_empty():
		return false
	for idx in targets:
		if idx < 0 or idx >= MAX_PARTS:
			return false
		if not powered[idx]:
			return false
	level_complete = true
	return true


func _advance_level() -> void:
	var next := current_level + 1
	if next < level_count():
		_load_level(next)
	else:
		# Back to level 0 if all levels done (wrap around)
		_load_level(0)


static func _setup_level_template(
	kinds: Array[int],
	orients: Array[int],
	positions: Array[Vector3],
	out_kinds: Array[int],
	out_orients: Array[int],
	out_positions: Array[Vector3],
) -> void:
	for i in MAX_PARTS:
		if i < kinds.size():
			out_kinds[i] = kinds[i]
			out_orients[i] = orients[i]
			out_positions[i] = positions[i]
		else:
			out_kinds[i] = -1
			out_orients[i] = 0
			out_positions[i] = Vector3(0, 0, 0)


func _setup_level_1() -> void:
	var y := 0.0
	part_kinds[0] = PartType.WIRE_CORNER;    part_orients[0] = Orientation.ROT90;   part_positions[0] = Vector3(0, y, 0)
	part_kinds[1] = PartType.WIRE_CORNER;    part_orients[1] = Orientation.ROT0;    part_positions[1] = Vector3(2, y, 0)
	part_kinds[2] = PartType.WIRE_CORNER;    part_orients[2] = Orientation.ROT270;  part_positions[2] = Vector3(2, y, 2)
	part_kinds[3] = PartType.WIRE_CORNER;    part_orients[3] = Orientation.ROT180;  part_positions[3] = Vector3(0, y, 2)
	part_kinds[4] = PartType.CELL;           part_orients[4] = Orientation.ROT270;  part_positions[4] = Vector3(0, y, 1)
	part_kinds[5] = PartType.WIRE_STRAIGHT;  part_orients[5] = Orientation.ROT0;    part_positions[5] = Vector3(1, y, 0)
	part_kinds[6] = PartType.CELL;           part_orients[6] = Orientation.ROT0;    part_positions[6] = Vector3(1, y, 2)
	part_kinds[7] = PartType.LED;            part_orients[7] = Orientation.ROT270;  part_positions[7] = Vector3(3, y, 1)
	for i in range(8, MAX_PARTS):
		part_kinds[i] = -1
		part_orients[i] = 0
		part_positions[i] = Vector3.ZERO

func _solve_level_1() -> void:
	# Solved closed circuit: cell + cell + LED around a rectangle
	var y := 0.0
	part_kinds[0] = PartType.WIRE_CORNER;    part_orients[0] = Orientation.ROT90;   part_positions[0] = Vector3(0, y, 0)
	part_kinds[1] = PartType.WIRE_CORNER;    part_orients[1] = Orientation.ROT0;    part_positions[1] = Vector3(2, y, 0)
	part_kinds[2] = PartType.WIRE_CORNER;    part_orients[2] = Orientation.ROT270;  part_positions[2] = Vector3(2, y, 2)
	part_kinds[3] = PartType.WIRE_CORNER;    part_orients[3] = Orientation.ROT180;  part_positions[3] = Vector3(0, y, 2)
	part_kinds[4] = PartType.CELL;           part_orients[4] = Orientation.ROT270;  part_positions[4] = Vector3(0, y, 1)
	part_kinds[5] = PartType.WIRE_STRAIGHT;  part_orients[5] = Orientation.ROT0;    part_positions[5] = Vector3(1, y, 0)
	part_kinds[6] = PartType.CELL;           part_orients[6] = Orientation.ROT0;    part_positions[6] = Vector3(1, y, 2)
	part_kinds[7] = PartType.LED;            part_orients[7] = Orientation.ROT270;  part_positions[7] = Vector3(2, y, 1)
	for i in range(8, MAX_PARTS):
		part_kinds[i] = -1
		part_orients[i] = 0
		part_positions[i] = Vector3.ZERO


func _setup_level_2() -> void:
	var y := 0.0
	part_kinds[0] = PartType.WIRE_CORNER;   part_orients[0] = Orientation.ROT180; part_positions[0] = Vector3(0, y, 2)
	part_kinds[1] = PartType.LED;            part_orients[1] = Orientation.ROT0;   part_positions[1] = Vector3(1, y, 2)
	part_kinds[2] = PartType.WIRE_STRAIGHT;  part_orients[2] = Orientation.ROT0;   part_positions[2] = Vector3(2, y, 2)
	part_kinds[3] = PartType.WIRE_CORNER;    part_orients[3] = Orientation.ROT270; part_positions[3] = Vector3(3, y, 2)
	part_kinds[4] = PartType.WIRE_T;         part_orients[4] = Orientation.ROT270; part_positions[4] = Vector3(0, y, 1)
	part_kinds[5] = PartType.LED;            part_orients[5] = Orientation.ROT0;   part_positions[5] = Vector3(1, y, 1)
	part_kinds[6] = PartType.WIRE_STRAIGHT;  part_orients[6] = Orientation.ROT0;   part_positions[6] = Vector3(2, y, 1)
	part_kinds[7] = PartType.WIRE_T;         part_orients[7] = Orientation.ROT90;  part_positions[7] = Vector3(3, y, 1)
	part_kinds[8] = PartType.WIRE_CORNER;    part_orients[8] = Orientation.ROT90;  part_positions[8] = Vector3(0, y, 0)
	part_kinds[9] = PartType.CELL;           part_orients[9] = Orientation.ROT0;   part_positions[9] = Vector3(1, y, 0)
	part_kinds[10] = PartType.CELL;          part_orients[10] = Orientation.ROT0;  part_positions[10] = Vector3(2, y, 0)
	part_kinds[11] = PartType.WIRE_CORNER;   part_orients[11] = Orientation.ROT0;  part_positions[11] = Vector3(4, y, 0)

func _solve_level_2() -> void:
	# Two cells (3.0V) -> T-junction splits to two parallel LEDs.
	# Both LEDs receive the full 3.0V through separate branches.
	# Each LED's exit path independently reaches the battery.
	#
	# ASCII layout (C=CORNER L=LED -=WIRE T=WIRE_T B=CELL):
	#   C L - C
	#   T L - T
	#   C B B C
	var y := 0.0
	part_kinds[0] = PartType.WIRE_CORNER;   part_orients[0] = Orientation.ROT180; part_positions[0] = Vector3(0, y, 2)
	part_kinds[1] = PartType.LED;            part_orients[1] = Orientation.ROT0;   part_positions[1] = Vector3(1, y, 2)
	part_kinds[2] = PartType.WIRE_STRAIGHT;  part_orients[2] = Orientation.ROT0;   part_positions[2] = Vector3(2, y, 2)
	part_kinds[3] = PartType.WIRE_CORNER;    part_orients[3] = Orientation.ROT270; part_positions[3] = Vector3(3, y, 2)
	part_kinds[4] = PartType.WIRE_T;         part_orients[4] = Orientation.ROT270; part_positions[4] = Vector3(0, y, 1)
	part_kinds[5] = PartType.LED;            part_orients[5] = Orientation.ROT0;   part_positions[5] = Vector3(1, y, 1)
	part_kinds[6] = PartType.WIRE_STRAIGHT;  part_orients[6] = Orientation.ROT0;   part_positions[6] = Vector3(2, y, 1)
	part_kinds[7] = PartType.WIRE_T;         part_orients[7] = Orientation.ROT90;  part_positions[7] = Vector3(3, y, 1)
	part_kinds[8] = PartType.WIRE_CORNER;    part_orients[8] = Orientation.ROT90;  part_positions[8] = Vector3(0, y, 0)
	part_kinds[9] = PartType.CELL;           part_orients[9] = Orientation.ROT0;   part_positions[9] = Vector3(1, y, 0)
	part_kinds[10] = PartType.CELL;          part_orients[10] = Orientation.ROT0;  part_positions[10] = Vector3(2, y, 0)
	part_kinds[11] = PartType.WIRE_CORNER;   part_orients[11] = Orientation.ROT0;  part_positions[11] = Vector3(3, y, 0)

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

	# Per-LED omni lights and top models
	led_lights.resize(MAX_PARTS)
	led_models.resize(MAX_PARTS)
	for i in MAX_PARTS:
		# Omni light (glow)
		var light := OmniLight3D.new()
		light.omni_range = 3.0
		light.light_energy = 0.0
		light.light_color = Color(1.0, 0.4, 0.4)
		add_child(light)
		led_lights[i] = light

		# LED top model (GLB)
		var model := LED_TOP_SCENE.instantiate()
		model.visible = false
		add_child(model)
		led_models[i] = model

# - LED model ------------------------------------------------------------------

func _update_led_model() -> void:
	for i in MAX_PARTS:
		# LED glow light and top model
		if i < led_lights.size() and is_instance_valid(led_lights[i]):
			if part_kinds[i] == PartType.LED:
				var p := part_positions[i]
				var top := p.y + BLOCK_SIZE * 0.12

				# Position GLB model on this LED
				if i < led_models.size() and is_instance_valid(led_models[i]):
					var angle := float(part_orients[i]) * PI * 0.5 + PI
					var xf_basis := Basis(Vector3.UP, angle)
					var s: float = 0.3
					xf_basis = xf_basis.scaled(Vector3(s, s, s))
					var origin := Vector3(p.x, top + 0.5, p.z)
					led_models[i].transform = Transform3D(xf_basis, origin)
					led_models[i].visible = true

				# Glow light
				if powered[i]:
					led_lights[i].position = Vector3(p.x, p.y + 0.6, p.z)
					led_lights[i].light_energy = 4.0
				else:
					led_lights[i].light_energy = 0.0
			else:
				# Not an LED - hide the model
				if i < led_models.size() and is_instance_valid(led_models[i]):
					led_models[i].visible = false
				led_lights[i].light_energy = 0.0

# - Circuit simulation wrapper ------------------------------------------------

func _simulate() -> void:
	simulate_circuit(part_kinds, part_orients, part_positions, powered, stats_volts_in, stats_drop)

# - Per-frame ------------------------------------------------------------------

func _process(delta: float) -> void:
	_handle_camera_keys(delta)
	_update_camera_transform()
	_update_led_model()
	_check_level_complete()
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

	# Ghost part data (for drag preview)
	if dragging >= 0 and drag_target != Vector3.ZERO:
		set_meta("_ghost_part_pos", drag_target)
		set_meta("_ghost_part_kind", part_kinds[dragging])
		set_meta("_ghost_part_orient", part_orients[dragging])
		set_meta("_ghost_valid", drag_target_valid)
	else:
		remove_meta("_ghost_part_pos")
		remove_meta("_ghost_part_kind")
		remove_meta("_ghost_part_orient")
		remove_meta("_ghost_valid")

	for i in MAX_PARTS:
		set_meta("_part_pos_%d" % i, part_positions[i])
		set_meta("_part_kind_%d" % i, part_kinds[i])
		set_meta("_part_orient_%d" % i, part_orients[i])
		set_meta("_part_powered_%d" % i, powered[i])

	# Level info
	set_meta("_level_current", current_level)
	set_meta("_level_count", level_count())
	set_meta("_level_name", level_name(current_level))
	set_meta("_level_complete", level_complete)
	set_meta("_level_targets", level_targets(current_level))

	# Handle action triggers from UI
	var act_rotate: bool = get_meta("_action_rotate", false)
	if act_rotate:
		remove_meta("_action_rotate")
		_rotate_selected()

	var act_solve: bool = get_meta("_action_solve", false)
	if act_solve:
		remove_meta("_action_solve")
		_debug_solve()

	var act_next: bool = get_meta("_action_next_level", false)
	if act_next:
		remove_meta("_action_next_level")
		_advance_level()

	var act_save: bool = get_meta("_action_save", false)
	if act_save:
		remove_meta("_action_save")
		_save_to_json()

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
	# Reload the current level's intended solution
	match current_level:
		0:  _solve_level_1()
		1:  _solve_level_2()
		_:  _solve_level_1()
	_simulate()

# - JSON save -----------------------------------------------------------------

func _save_to_json() -> void:
	var parts: Array[Dictionary] = []
	for i in MAX_PARTS:
		if part_kinds[i] < 0:
			continue
		var kind_name: String = ""
		match part_kinds[i]:
			PartType.CELL:          kind_name = "CELL"
			PartType.WIRE_STRAIGHT: kind_name = "WIRE_STRAIGHT"
			PartType.WIRE_CORNER:   kind_name = "WIRE_CORNER"
			PartType.LED:           kind_name = "LED"
			PartType.WIRE_T:        kind_name = "WIRE_T"

		var orient_name: String = ""
		match part_orients[i]:
			Orientation.ROT0:   orient_name = "ROT0"
			Orientation.ROT90:  orient_name = "ROT90"
			Orientation.ROT180: orient_name = "ROT180"
			Orientation.ROT270: orient_name = "ROT270"

		parts.append({
			"kind": kind_name,
			"orient": orient_name,
			"x": part_positions[i].x,
			"z": part_positions[i].z,
		})

	var data: Dictionary = {
		"level": level_name(current_level),
		"parts": parts,
	}

	var json_str: String = JSON.stringify(data, "\t")
	var time_str: String = Time.get_datetime_string_from_system(false, true).replace("-", "").replace(":", "")
	var path: String = "user://circuit_%s.json" % time_str
	var abs_path: String = ProjectSettings.globalize_path(path)

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(json_str)
		file.close()
		print("Saved circuit to: ", abs_path)
	else:
		push_error("Failed to save circuit to: ", abs_path)


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
		# Use the stored drag_target (ghost position) for final placement
		if drag_target != Vector3.ZERO:
			if not _is_occupied(dragging, drag_target):
				part_positions[dragging] = drag_target
				_simulate()
			else:
				part_positions[dragging] = drag_origin
		else:
			# Fallback: raycast again at release point
			var target := _screen_raycast_terrain(screen_pos)
			if target != null:
				if not _is_occupied(dragging, target):
					part_positions[dragging] = target
					_simulate()
				else:
					part_positions[dragging] = drag_origin
			else:
				part_positions[dragging] = drag_origin
		drag_target = Vector3.ZERO
		drag_target_valid = false
		dragging = -1
	camera_drag_active = false

func _on_pointer_drag(screen_pos: Vector2) -> void:
	if dragging >= 0:
		var target := _screen_raycast_terrain(screen_pos)
		if target != null:
			# Store ghost position but DON'T move actual part
			drag_target = target
			drag_target_valid = not _is_occupied(dragging, target)
			target_block = target
			target_valid = drag_target_valid

# - Raycasting -----------------------------------------------------------------

func _screen_raycast_parts(screen_pos: Vector2) -> int:
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var best_dist: float = INF
	var result: int = -1

	for i in MAX_PARTS:
		var kind := part_kinds[i]
		if kind < 0:
			continue
		var p := part_positions[i]
		var he := part_half_extents(kind)
		var angle := float(part_orients[i]) * TAU / 4.0
		var b := Basis(Vector3.UP, angle)
		var dist := _ray_obb(from, dir, p + Vector3(0.0, he.y, 0.0), he, b)
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

# Ray vs Oriented Bounding Box test.
# Transforms the ray into the OBB's local space, then does an AABB test.
static func _ray_obb(origin: Vector3, dir: Vector3, center: Vector3, half_extents: Vector3, obb_basis: Basis) -> float:
	var local_origin := obb_basis.inverse() * (origin - center)
	var local_dir := obb_basis.inverse() * dir
	return _ray_aabb(local_origin, local_dir, -half_extents, half_extents)
