extends Node3D
## 3D Node-based Board Renderer for Circuit Puzzle.
## 
## creates/manages Godot 3D nodes (MeshInstance3D) to render the terrain grid
## and all circuit parts.

# -- Constants  --------------------------------------
enum PartType { CELL, WIRE_STRAIGHT, WIRE_CORNER, LED }
enum Orientation { ROT0, ROT90, ROT180, ROT270 }

const GRASS_TOP   := Color(0.357, 0.639, 0.294, 1.0)
const GRASS_SIDE  := Color(0.467, 0.376, 0.227, 1.0)
const DIRT_TOP    := Color(0.475, 0.333, 0.204, 1.0)
const DIRT_SIDE   := Color(0.357, 0.227, 0.129, 1.0)
const STONE_TOP   := Color(0.471, 0.471, 0.471, 1.0)
const STONE_SIDE  := Color(0.353, 0.353, 0.353, 1.0)
const PLATFORM_CLR := Color(0.275, 0.294, 0.333, 1.0)
const COPPER      := Color(0.804, 0.588, 0.353, 1.0)
const BLACK       := Color(0.137, 0.137, 0.137, 1.0)
const METAL       := Color(0.745, 0.745, 0.765, 1.0)
const SHEATH      := Color(0.157, 0.549, 0.275, 1.0)
const HOVER_CLR   := Color(1.0, 0.85, 0.2, 1.0)
const SELECT_CLR  := Color(0.863, 0.941, 1.0, 1.0)
const TARGET_VALID   := Color(0.3, 0.9, 0.3, 0.5)
const TARGET_INVALID := Color(0.9, 0.3, 0.3, 0.5)

# -- Node references --------------------------------------------------------
var game_node: Node

var terrain_container: Node3D
var parts_container: Node3D
var highlights_container: Node3D
var target_container: Node3D

# Per-grid-cell terrain blocks
var terrain_blocks: Array[MeshInstance3D] = []

# Per-part root nodes and their visual children
var part_roots: Array[Node3D] = []
var part_visuals: Array[Array] = []  # each entry is Array[MeshInstance3D]

# Direct material references for rapid updating
var glow_materials: Array[StandardMaterial3D] = []

# Highlights (hover + selection wireframe boxes)
var hover_highlight: MeshInstance3D
var select_highlight: MeshInstance3D
var target_highlight: MeshInstance3D

# Cached state to avoid unnecessary rebuilds
var grid_w: int = 5
var grid_d: int = 5
var block_size: float = 1.0
var part_count: int = 8
var prev_kinds: Array[int] = []
var prev_orients: Array[int] = []
var prev_powered: Array[bool] = []

# Current state read each frame
var cur_positions: Array[Vector3] = []
var cur_kinds: Array[int] = []
var cur_orients: Array[int] = []
var cur_powered: Array[bool] = []
var cur_selected: int = -1
var cur_hovered: int = -1

# -- Lifecycle --------------------------------------------------------------

func _ready() -> void:
	game_node = get_parent()
	_read_constants()
	_build_terrain()
	_build_part_nodes()
	_build_highlights()
	_build_target_highlight()

	glow_materials.resize(part_count)

	# Init cached state arrays
	prev_kinds.resize(part_count)
	prev_orients.resize(part_count)
	prev_powered.resize(part_count)
	cur_positions.resize(part_count)
	cur_kinds.resize(part_count)
	cur_orients.resize(part_count)
	cur_powered.resize(part_count)

	# Initial read
	_read_state()
	for i in part_count:
		prev_kinds[i] = -1  # force rebuild
		prev_orients[i] = -1
		prev_powered[i] = false
	_rebuild_all_parts()


func _process(_delta: float) -> void:
	_read_state()
	_update_terrain_visibility()
	_update_parts()
	_update_highlights()


# -- Data reading ----------------------------------------------------------

func _read_constants() -> void:
	grid_w = game_node.get_meta("_grid_w", 5)
	grid_d = game_node.get_meta("_grid_d", 5)
	block_size = game_node.get_meta("_block_size", 1.0)
	part_count = game_node.get_meta("_part_count", 8)


func _read_state() -> void:
	cur_selected = game_node.get_meta("selected_index", -1)
	cur_hovered = game_node.get_meta("_hovered_index", -1)

	for i in part_count:
		var pos_key := "_part_pos_%d" % i
		var kind_key := "_part_kind_%d" % i
		var orient_key := "_part_orient_%d" % i
		var powered_key := "_part_powered_%d" % i

		cur_positions[i] = game_node.get_meta(pos_key, Vector3.ZERO)
		cur_kinds[i] = game_node.get_meta(kind_key, -1)
		cur_orients[i] = game_node.get_meta(orient_key, 0)
		cur_powered[i] = game_node.get_meta(powered_key, false)


# -- Terrain building ------------------------------------------------------

func _make_material(albedo: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = albedo
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat


func _terrain_variant(xi: int, zi: int) -> Dictionary:
	var variant := (xi * 7 + zi * 13) % 12
	if variant == 0:
		return { "top": DIRT_TOP, "side": DIRT_SIDE }
	elif variant == 1:
		return { "top": STONE_TOP, "side": STONE_SIDE }
	else:
		return { "top": GRASS_TOP, "side": GRASS_SIDE }


func _build_terrain() -> void:
	terrain_container = Node3D.new()
	terrain_container.name = "Terrain"
	add_child(terrain_container)

	for xi in grid_w:
		for zi in grid_d:
			var mi := MeshInstance3D.new()
			var mesh := BoxMesh.new()
			mesh.size = Vector3(block_size, block_size, block_size)

			var v := _terrain_variant(xi, zi)
			var mat := _make_material(v["top"])
			mesh.material = mat

			mi.mesh = mesh
			mi.position = Vector3(
				xi * block_size,
				-block_size * 0.5,
				zi * block_size
			)
			terrain_container.add_child(mi)
			terrain_blocks.append(mi)


func _update_terrain_visibility() -> void:
	# Terrain is static - no per-frame update needed.
	# This method exists for future extensibility (e.g. hide blocks under parts).
	pass


# -- Part node management --------------------------------------------------

func _build_part_nodes() -> void:
	parts_container = Node3D.new()
	parts_container.name = "Parts"
	add_child(parts_container)

	part_roots.resize(part_count)
	part_visuals.resize(part_count)
	for i in part_count:
		var root := Node3D.new()
		root.name = "Part_%d" % i
		parts_container.add_child(root)
		part_roots[i] = root
		part_visuals[i] = []


func _clear_part_visuals(idx: int) -> void:
	for child in part_visuals[idx]:
		if is_instance_valid(child):
			child.queue_free()
	part_visuals[idx].clear()


func _rebuild_all_parts() -> void:
	for i in part_count:
		_clear_part_visuals(i)
		_rebuild_part(i, cur_kinds[i], cur_orients[i], cur_powered[i])


func _rebuild_part(idx: int, kind: int, orient: int, powered: bool) -> void:
	_clear_part_visuals(idx)
	var root := part_roots[idx]
	var pos := cur_positions[idx]

	# Reposition root
	var top_y := _platform_top(pos)
	var angle := float(orient) * TAU / 4.0

	root.position = Vector3(pos.x, 0.0, pos.z)
	root.rotation = Vector3(0.0, angle, 0.0)

	# Platform (always drawn)
	var platform := _make_platform_mesh(top_y)
	root.add_child(platform)
	part_visuals[idx].append(platform)

	match kind:
		PartType.CELL:
			_build_cell_visuals(root, idx, top_y)
		PartType.WIRE_STRAIGHT:
			_build_wire_straight_visuals(root, idx, top_y)
		PartType.WIRE_CORNER:
			_build_wire_corner_visuals(root, idx, top_y)
		PartType.LED:
			_build_led_visuals(root, idx, top_y, powered)


func _platform_top(pos: Vector3) -> float:
	return pos.y + block_size * 0.12


func _make_platform_mesh(top_y: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	var s := block_size
	var thickness := s * 0.12
	mesh.size = Vector3(s * 0.95, thickness, s * 0.95)

	var mat := _make_material(PLATFORM_CLR)
	mesh.material = mat

	mi.mesh = mesh
	mi.position = Vector3(0.0, top_y - thickness * 0.5, 0.0)
	return mi


# -- Part type builders ----------------------------------------------------

func _make_cylinder_mesh(radius: float, height: float, color: Color) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	var mat := _make_material(color)
	mesh.material = mat
	return mesh


func _make_box_mesh(size: Vector3, color: Color) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := _make_material(color)
	mesh.material = mat
	return mesh


func _add_cylinder(parent: Node3D, pos_a: Vector3, pos_b: Vector3, radius: float, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var dx := pos_b.x - pos_a.x
	var dy := pos_b.y - pos_a.y
	var dz := pos_b.z - pos_a.z
	var l := sqrt(dx * dx + dy * dy + dz * dz)
	if l < 0.001:
		return mi  # degenerate

	mi.mesh = _make_cylinder_mesh(radius, l, color)

	# Position at midpoint and rotate to align +Y with axis
	var mid := (pos_a + pos_b) * 0.5
	mi.position = mid

	# Align Y axis with cylinder direction
	var axis := Vector3(dx, dy, dz).normalized()
	if axis.distance_squared_to(Vector3.UP) > 0.001:
		var rot := Quaternion(Vector3.UP, axis)
		mi.quaternion = rot
	elif axis.y < 0:
		mi.quaternion = Quaternion(Vector3.UP, Vector3.DOWN)

	parent.add_child(mi)
	return mi


func _build_cell_visuals(root: Node3D, _idx: int, top_y: float) -> void:
	var s := block_size
	var r := s * 0.18
	var y := top_y + r

	# Cylinder segments along +X axis in local space
	var neg_end   := Vector3(-s * 0.4, y, 0.0)
	var split_pt  := Vector3( s * 0.18, y, 0.0)
	var pos_end   := Vector3( s * 0.4, y, 0.0)
	var nub_end   := Vector3( s * 0.47, y, 0.0)
	var cap_start := Vector3(-s * 0.42, y, 0.0)

	part_visuals[_idx].append(_add_cylinder(root, neg_end, split_pt, r, BLACK))
	part_visuals[_idx].append(_add_cylinder(root, split_pt, pos_end, r, COPPER))
	part_visuals[_idx].append(_add_cylinder(root, pos_end, nub_end, r * 0.45, METAL))
	part_visuals[_idx].append(_add_cylinder(root, cap_start, neg_end, r * 1.02, METAL))


func _build_wire_straight_visuals(root: Node3D, _idx: int, top_y: float) -> void:
	var s := block_size
	var r := s * 0.08
	var y := top_y + r

	var left  := Vector3(-s * 0.5, y, 0.0)
	var sl    := Vector3(-s * 0.32, y, 0.0)
	var sr    := Vector3( s * 0.32, y, 0.0)
	var right := Vector3( s * 0.5, y, 0.0)

	part_visuals[_idx].append(_add_cylinder(root, sl, sr, r, SHEATH))
	part_visuals[_idx].append(_add_cylinder(root, left, sl, r * 0.45, COPPER))
	part_visuals[_idx].append(_add_cylinder(root, sr, right, r * 0.45, COPPER))


func _build_wire_corner_visuals(root: Node3D, _idx: int, top_y: float) -> void:
	var s := block_size
	var r := s * 0.08
	var y := top_y + r
	var arm := s * 0.5
	var sf := 0.64

	# Two arms: along -X and +Z in local space (canonical corner)
	var arms := [
		Vector3(-arm, y, 0.0),  # direction -X
		Vector3(0.0, y, arm),    # direction +Z
	]
	for dir in arms:
		var tip_local: Vector3 = dir
		var sh_local := Vector3(dir.x * sf, dir.y, dir.z * sf)
		var ctr := Vector3(0.0, y, 0.0)

		part_visuals[_idx].append(_add_cylinder(root, ctr, sh_local, r, SHEATH))
		part_visuals[_idx].append(_add_cylinder(root, sh_local, tip_local, r * 0.45, COPPER))

	# Corner sphere (small box approximation)
	var sphere_mi := MeshInstance3D.new()
	sphere_mi.mesh = _make_box_mesh(Vector3(r * 2, r * 2, r * 2), SHEATH)
	sphere_mi.position = Vector3(0.0, y, 0.0)
	root.add_child(sphere_mi)
	part_visuals[_idx].append(sphere_mi)


func _build_led_visuals(root: Node3D, _idx: int, top_y: float, powered: bool) -> void:
	var s := block_size
	var r := s * 0.12
	var y := top_y + r

	# Simple LED body: red cylinder
	var body := _add_cylinder(root, Vector3(-s * 0.25, y, 0.0), Vector3(s * 0.25, y, 0.0), r, Color(0.9, 0.2, 0.2, 1.0))
	part_visuals[_idx].append(body)

	# Glow indicator
	var glow_mi := MeshInstance3D.new()
	var glow_size := s * 0.15
	var glow_mat := _make_material(Color(1.0, 0.4, 0.4, 1.0) if powered else Color(0.3, 0.1, 0.1, 1.0))
	var glow_mesh := BoxMesh.new()
	glow_mesh.size = Vector3(glow_size, glow_size, glow_size)
	glow_mesh.material = glow_mat
	glow_mi.mesh = glow_mesh
	glow_mi.position = Vector3(0.0, top_y + s * 0.35, 0.0)
	root.add_child(glow_mi)
	part_visuals[_idx].append(glow_mi)
	glow_materials[_idx] = glow_mat


# -- Per-frame update ------------------------------------------------------

func _update_parts() -> void:
	for i in part_count:
		var kind_changed := prev_kinds[i] != cur_kinds[i]
		var powered_changed := prev_powered[i] != cur_powered[i]

		if kind_changed:
			_rebuild_part(i, cur_kinds[i], cur_orients[i], cur_powered[i])
			prev_kinds[i] = cur_kinds[i]
			prev_orients[i] = cur_orients[i]
			prev_powered[i] = cur_powered[i]
			continue

		# Update root transform
		var root := part_roots[i]
		var pos := cur_positions[i]
		var angle := float(cur_orients[i]) * TAU / 4.0
		root.position = Vector3(pos.x, 0.0, pos.z)
		root.rotation = Vector3(0.0, angle, 0.0)

		# Update powered state
		if powered_changed:
			if cur_kinds[i] == PartType.LED:
				_update_led_powered(i, cur_powered[i])
			prev_powered[i] = cur_powered[i]

		prev_orients[i] = cur_orients[i]


func _update_led_powered(idx: int, powered: bool) -> void:
	if idx < glow_materials.size() and is_instance_valid(glow_materials[idx]):
		glow_materials[idx].albedo_color = Color(1.0, 0.4, 0.4, 1.0) if powered else Color(0.3, 0.1, 0.1, 1.0)


# -- Highlights ------------------------------------------------------------

func _build_highlights() -> void:
	highlights_container = Node3D.new()
	highlights_container.name = "Highlights"
	add_child(highlights_container)

	hover_highlight = MeshInstance3D.new()
	hover_highlight.name = "HoverHighlight"
	highlights_container.add_child(hover_highlight)

	select_highlight = MeshInstance3D.new()
	select_highlight.name = "SelectHighlight"
	highlights_container.add_child(select_highlight)


func _build_target_highlight() -> void:
	target_container = Node3D.new()
	target_container.name = "PlacementTarget"
	add_child(target_container)

	target_highlight = MeshInstance3D.new()
	target_highlight.name = "TargetHighlight"
	target_container.add_child(target_highlight)


func _make_wireframe_box_mesh(size: Vector3, color: Color) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var half := size * 0.5

	# 8 corners
	var c := [
		Vector3(-half.x, -half.y, -half.z),
		Vector3( half.x, -half.y, -half.z),
		Vector3( half.x, -half.y,  half.z),
		Vector3(-half.x, -half.y,  half.z),
		Vector3(-half.x,  half.y, -half.z),
		Vector3( half.x,  half.y, -half.z),
		Vector3( half.x,  half.y,  half.z),
		Vector3(-half.x,  half.y,  half.z),
	]

	# 12 edges (pairs of corner indices)
	var indices := PackedInt32Array([
		0, 1, 1, 2, 2, 3, 3, 0,  # bottom
		4, 5, 5, 6, 6, 7, 7, 4,  # top
		0, 4, 1, 5, 2, 6, 3, 7,  # vertical
	])

	var verts := PackedVector3Array()
	for idx in indices:
		verts.append(c[idx])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)

	var mat := _make_material(color)
	mesh.surface_set_material(0, mat)
	return mesh


func _update_highlights() -> void:
	# Hover highlight
	if cur_hovered >= 0 and cur_hovered < part_count and cur_hovered != cur_selected:
		var pos := cur_positions[cur_hovered]
		var s := block_size
		_hover_highlight_at(pos, s)
	else:
		if is_instance_valid(hover_highlight):
			hover_highlight.visible = false

	# Selection highlight
	if cur_selected >= 0 and cur_selected < part_count:
		var pos := cur_positions[cur_selected]
		var s := block_size
		_select_highlight_at(pos, s)
	else:
		if is_instance_valid(select_highlight):
			select_highlight.visible = false

	# Target highlight (read target from meta - or check if any part is being dragged)
	var target_pos: Variant = game_node.get_meta("_target_block", null) if game_node.has_meta("_target_block") else null
	if target_pos != null:
		var s := block_size
		var valid: bool = game_node.get_meta("_target_valid", false)
		_show_target_at(target_pos, s, valid)
	else:
		if is_instance_valid(target_highlight):
			target_highlight.visible = false


func _position_highlight_at(mi: MeshInstance3D, pos: Vector3, s: float, color: Color) -> void:
	if not is_instance_valid(mi):
		return
	var margin := 0.04
	var wire_size := Vector3(s + margin * 2, s + margin * 2, s + margin * 2)
	mi.mesh = _make_wireframe_box_mesh(wire_size, color)
	mi.position = Vector3(pos.x, pos.y + s * 0.5, pos.z)
	mi.visible = true


func _hover_highlight_at(pos: Vector3, s: float) -> void:
	_position_highlight_at(hover_highlight, pos, s, HOVER_CLR)


func _select_highlight_at(pos: Vector3, s: float) -> void:
	_position_highlight_at(select_highlight, pos, s, SELECT_CLR)


func _show_target_at(pos: Vector3, s: float, valid: bool) -> void:
	_position_highlight_at(target_highlight, pos, s, TARGET_VALID if valid else TARGET_INVALID)
