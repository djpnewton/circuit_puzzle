/// GameNode: the central Godot Node3D for the Circuit Puzzle game.
///
/// This node owns the game state, builds 3D geometry via ImmediateMesh,
/// handles mouse/touch input through Godot's input system, runs the camera,
/// and updates the UI Label nodes.
///
/// Scene expectation: attach this script to a Node3D in the main scene.
/// The node will create all required child nodes itself in _ready.
const std = @import("std");
const godot = @import("godot");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// --- Godot types ----------------------------------------------------------
const Node3D = godot.class.Node3d;
const Camera3D = godot.class.Camera3d;
const DirectionalLight3D = godot.class.DirectionalLight3d;
const OmniLight3D = godot.class.OmniLight3d;
const MeshInstance3D = godot.class.MeshInstance3d;
const ImmediateMesh = godot.class.ImmediateMesh;
const StandardMaterial3D = godot.class.StandardMaterial3d;
const Engine = godot.class.Engine;
const Input = godot.class.Input;
const InputEvent = godot.class.InputEvent;
const InputEventMouseButton = godot.class.InputEventMouseButton;
const InputEventMouseMotion = godot.class.InputEventMouseMotion;
const InputEventKey = godot.class.InputEventKey;
const InputEventScreenTouch = godot.class.InputEventScreenTouch;
const InputEventScreenDrag = godot.class.InputEventScreenDrag;
const PhysicsRayQueryParameters3D = godot.class.PhysicsRayQueryParameters3d;
const NodePath = godot.builtin.NodePath;

const Vector2 = godot.builtin.Vector2;
const Vector2i = godot.builtin.Vector2i;
const Vector3 = godot.builtin.Vector3;
const Color = godot.builtin.Color;
const Transform3D = godot.builtin.Transform3d;
const Basis = godot.builtin.Basis;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const Array = godot.builtin.Array;
const Dictionary = godot.builtin.Dictionary;
const Variant = godot.builtin.Variant;
const Plane = godot.builtin.Plane;
const Rect2 = godot.builtin.Rect2;
const Callable = godot.builtin.Callable;

// --- Game logic modules ---------------------------------------------------
const parts = @import("parts.zig");
const circuit = @import("circuit.zig");

// --- Constants ------------------------------------------------------------
pub const GRID_W: usize = 5;
pub const GRID_D: usize = 5;
pub const BLOCK_SIZE: f32 = 1.0;
const MAX_PARTS: usize = 8;

// --- Node fields ----------------------------------------------------------

pub const GameNode = struct {
    allocator: Allocator,
    base: *Node3D,

    camera: *Camera3D = undefined,
    mesh_instance: *MeshInstance3D = undefined,
    immediate_mesh: *ImmediateMesh = undefined,
    flat_mat: *StandardMaterial3D = undefined,
    cam_azimuth: f32 = std.math.pi,
    cam_pitch: f32 = 0.68,
    cam_dist: f32 = 16.0,
    cam_target: Vector3 = .{ .x = 2.0, .y = 0.5, .z = 2.0 },

    // Interaction state
    dragging: ?usize = null,
    drag_origin: parts.Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    selected_part: ?usize = null,
    hovered_part: ?usize = null,
    camera_drag_active: bool = false,
    last_mouse_pos: Vector2 = .{ .x = 0, .y = 0 },
    mouse_pressed: bool = false,

    // Drag placement target
    target_block: ?parts.Vec3 = null,
    target_valid: bool = false,

    // Part state (fixed 8 parts matching original map.zig layout)
    part_data: [MAX_PARTS]parts.Part = undefined,
    part_pos: [MAX_PARTS]parts.Vec3 = undefined,
    powered: [MAX_PARTS]bool = [_]bool{false} ** MAX_PARTS,
    stats: [MAX_PARTS]circuit.ComponentStats = [_]circuit.ComponentStats{.{}} ** MAX_PARTS,

    // LED model (scene instance placed in main.tscn)
    led_model_root: ?*Node3D = null,

    // LED glow lights
    led_lights: [MAX_PARTS]*OmniLight3D = undefined,

    // --- gdzig boilerplate ---------------------------------------------------

    pub fn register(r: *godot.extension.Registry) void {
        r.addClass(GameNode, r.allocator, .{});
    }

    pub fn unregister(r: *godot.extension.Registry) void {
        r.removeClass(GameNode);
    }

    pub fn create(allocator: *Allocator) !*GameNode {
        const self = try allocator.create(GameNode);
        self.* = .{
            .allocator = allocator.*,
            .base = .init(),
        };
        self.base.setInstance(GameNode, self);
        return self;
    }

    pub fn recreate(allocator: *Allocator, obj: *godot.class.Object) *GameNode {
        const self = allocator.create(GameNode) catch @panic("OOM");
        self.* = .{
            .allocator = allocator.*,
            .base = @ptrCast(obj),
        };
        self.base.setInstance(GameNode, self);
        return self;
    }

    pub fn destroy(self: *GameNode, allocator: *Allocator) void {
        self.base.destroy();
        allocator.destroy(self);
    }

    // --- Initialisation -------------------------------------------------------

    pub fn _ready(self: *GameNode) void {
        if (Engine.isEditorHint()) return;

        self.initParts();
        self.setupCamera();
        self.setupMesh();
        self.setupLights();
        self.setupLEDModel();
        self.updateCircuit();
        self.rebuildMesh();
    }

    fn initParts(self: *GameNode) void {
        // Matches the original map.zig initial layout
        self.part_data[0] = .{ .kind = .wire_corner, .orientation = .rot90 };
        self.part_pos[0] = .{ .x = 1.0, .y = 0.0, .z = 1.0 };
        self.part_data[1] = .{ .kind = .wire_corner, .orientation = .rot0 };
        self.part_pos[1] = .{ .x = 3.0, .y = 0.0, .z = 1.0 };
        self.part_data[2] = .{ .kind = .wire_corner, .orientation = .rot270 };
        self.part_pos[2] = .{ .x = 3.0, .y = 0.0, .z = 3.0 };
        self.part_data[3] = .{ .kind = .wire_corner, .orientation = .rot180 };
        self.part_pos[3] = .{ .x = 1.0, .y = 0.0, .z = 3.0 };
        self.part_data[4] = .{ .kind = .cell, .orientation = .rot0 };
        self.part_pos[4] = .{ .x = 0.0, .y = 0.0, .z = 0.0 };
        self.part_data[5] = .{ .kind = .wire_straight, .orientation = .rot90 };
        self.part_pos[5] = .{ .x = 2.0, .y = 0.0, .z = 0.0 };
        self.part_data[6] = .{ .kind = .cell, .orientation = .rot0 };
        self.part_pos[6] = .{ .x = 4.0, .y = 0.0, .z = 2.0 };
        self.part_data[7] = .{ .kind = .led, .orientation = .rot0 };
        self.part_pos[7] = .{ .x = 0.0, .y = 0.0, .z = 4.0 };
    }

    fn setupCamera(self: *GameNode) void {
        self.camera = Camera3D.init();
        self.camera.setFov(@as(f64, 60.0));
        self.base.addChild(.upcast(self.camera), .{});
        self.updateCameraTransform();
    }

    fn updateCameraTransform(self: *GameNode) void {
        const cos_p = @cos(self.cam_pitch);
        const pos = Vector3{
            .x = self.cam_target.x + self.cam_dist * cos_p * @sin(self.cam_azimuth),
            .y = self.cam_target.y + self.cam_dist * @sin(self.cam_pitch),
            .z = self.cam_target.z + self.cam_dist * cos_p * @cos(self.cam_azimuth),
        };
        self.camera.setPosition(pos);
        self.camera.lookAt(self.cam_target, .{});
    }

    fn setupMesh(self: *GameNode) void {
        self.immediate_mesh = ImmediateMesh.init();
        self.mesh_instance = MeshInstance3D.init();
        self.mesh_instance.setMesh(.upcast(self.immediate_mesh));

        // Unshaded vertex-color material (no backface culling for procedurally generated geometry)
        self.flat_mat = StandardMaterial3D.init();
        self.flat_mat.setFlag(.flag_albedo_from_vertex_color, true);
        self.flat_mat.setShadingMode(.shading_mode_unshaded);
        self.flat_mat.setCullMode(.cull_disabled);
        self.mesh_instance.setMaterialOverride(.upcast(self.flat_mat));

        self.base.addChild(.upcast(self.mesh_instance), .{});
    }

    fn setupLights(self: *GameNode) void {
        // Main directional sun
        const sun = DirectionalLight3D.init();
        sun.setParam(.param_energy, @as(f64, 1.2));
        sun.setShadow(true);
        var sun_xform: Transform3D = .identity;
        sun_xform = sun_xform.rotatedLocal(.{ .x = 1, .y = 0, .z = 0 }, -0.785398);
        sun.setTransform(sun_xform);
        self.base.addChild(.upcast(sun), .{});

        // Per-LED omni lights (hidden until powered)
        for (0..MAX_PARTS) |i| {
            const light = OmniLight3D.init();
            light.setParam(.param_range, @as(f64, 3.0));
            light.setParam(.param_energy, @as(f64, 0.0));
            light.setColor(.{ .r = 1.0, .g = 0.4, .b = 0.4, .a = 1.0 });
            self.base.addChild(.upcast(light), .{});
            self.led_lights[i] = light;
        }
    }

    fn setupLEDModel(self: *GameNode) void {
        var path = NodePath.fromString(String.fromLatin1("led_top"));
        defer path.deinit();

        // Store the whole model root — it will be repositioned as a unit
        // in updateLEDLights so all its child mesh parts stay together.
        if (self.base.getNodeOrNull(path)) |node| {
            self.led_model_root = @ptrCast(node);
        }
    }

    // --- Per-frame update -----------------------------------------------------

    pub fn _process(self: *GameNode, delta: f64) void {
        if (Engine.isEditorHint()) return;
        const dt: f32 = @floatCast(delta);
        self.handleCameraKeys(dt);
        self.updateCameraTransform();
        self.updateLEDLights();
        self.rebuildMesh();

        // Write state to meta so GDScript UI can read it
        self.writeUIMeta();
    }

    fn writeUIMeta(self: *GameNode) void {
        const idx: i64 = if (self.selected_part) |i| @as(i64, @intCast(i)) else -1;
        self.base.setMeta(
            StringName.fromLatin1("selected_index", false),
            Variant.init(i64, idx),
        );

        if (self.selected_part) |i| {
            const kind = self.part_data[i].kind;
            self.base.setMeta(StringName.fromLatin1("_part_name", false), Variant.init(String, String.fromLatin1(parts.name(kind))));
            self.base.setMeta(StringName.fromLatin1("_part_kind", false), Variant.init(i64, @intFromEnum(kind)));
            self.base.setMeta(StringName.fromLatin1("_part_volts_in", false), Variant.init(f64, self.stats[i].volts_in));
            self.base.setMeta(StringName.fromLatin1("_part_drop", false), Variant.init(f64, self.stats[i].voltage_drop));
            self.base.setMeta(StringName.fromLatin1("_part_description", false), Variant.init(String, String.fromLatin1(parts.description(kind))));
        }

        // Handle action triggers from GDScript
        const act_rotate = self.base.getMeta(StringName.fromLatin1("_action_rotate", false), .{ .default = Variant.init(bool, false) });
        if (act_rotate.booleanize()) {
            self.base.removeMeta(StringName.fromLatin1("_action_rotate", false));
            self.rotateSelectedPart();
        }
        const act_solve = self.base.getMeta(StringName.fromLatin1("_action_solve", false), .{ .default = Variant.init(bool, false) });
        if (act_solve.booleanize()) {
            self.base.removeMeta(StringName.fromLatin1("_action_solve", false));
            self.debugSolve();
        }
    }

    // --- GDScript bridge: data access ----------------------------------------

    pub fn get_selected_index(self: *const GameNode) i64 {
        return if (self.selected_part) |i| @as(i64, @intCast(i)) else -1;
    }

    pub fn get_part_string(self: *const GameNode, idx: i64, which: i64) String {
        const i: usize = @intCast(idx);
        if (i >= MAX_PARTS) return String.fromLatin1("???");
        const kind = self.part_data[i].kind;
        return if (which == 0)
            String.fromLatin1(parts.name(kind))
        else
            String.fromLatin1(parts.description(kind));
    }

    pub fn get_part_kind(self: *const GameNode, idx: i64) i64 {
        const i: usize = @intCast(idx);
        if (i >= MAX_PARTS) return -1;
        return @intFromEnum(self.part_data[i].kind);
    }

    pub fn get_part_volts_in(self: *const GameNode, idx: i64) f64 {
        const i: usize = @intCast(idx);
        if (i >= MAX_PARTS) return 0;
        return self.stats[i].volts_in;
    }

    pub fn get_part_voltage_drop(self: *const GameNode, idx: i64) f64 {
        const i: usize = @intCast(idx);
        if (i >= MAX_PARTS) return 0;
        return self.stats[i].voltage_drop;
    }

    fn rotateSelectedPart(self: *GameNode) void {
        if (self.selected_part) |idx| {
            self.part_data[idx].rotateCW();
            self.updateCircuit();
        }
    }

    fn handleCameraKeys(self: *GameNode, dt: f32) void {
        const pan = 10.0 * dt;
        const rot = 1.5 * dt;
        const fwd_x = -@sin(self.cam_azimuth);
        const fwd_z = -@cos(self.cam_azimuth);
        const rgt_x = @cos(self.cam_azimuth);
        const rgt_z = -@sin(self.cam_azimuth);

        if (Input.isKeyPressed(.key_w) or Input.isKeyPressed(.key_up)) {
            self.cam_target.x += fwd_x * pan;
            self.cam_target.z += fwd_z * pan;
        }
        if (Input.isKeyPressed(.key_s) or Input.isKeyPressed(.key_down)) {
            self.cam_target.x -= fwd_x * pan;
            self.cam_target.z -= fwd_z * pan;
        }
        if (Input.isKeyPressed(.key_a) or Input.isKeyPressed(.key_left)) {
            self.cam_target.x -= rgt_x * pan;
            self.cam_target.z -= rgt_z * pan;
        }
        if (Input.isKeyPressed(.key_d) or Input.isKeyPressed(.key_right)) {
            self.cam_target.x += rgt_x * pan;
            self.cam_target.z += rgt_z * pan;
        }
        if (Input.isKeyPressed(.key_q)) self.cam_azimuth -= rot;
        if (Input.isKeyPressed(.key_e)) self.cam_azimuth += rot;
        // R key to rotate selected part
        if (Input.isKeyPressed(.key_r)) {
            self.rotateSelectedPart();
        }
    }

    fn updateLEDLights(self: *GameNode) void {
        for (0..MAX_PARTS) |i| {
            if (self.part_data[i].kind == .led) {
                const p = self.part_pos[i];
                const top = platformTop(p);

                // Position the whole model root as a unit so all parts stay together
                if (self.led_model_root) |root| {
                    const o = self.part_data[i].orientation;
                    const rot_i: u32 = @intFromEnum(o);
                    const angle: f64 = @as(f64, @floatFromInt(rot_i)) * std.math.pi * 0.5;
                    var basis = Basis.initAxisAngle(.{ .x = 0, .y = 1, .z = 0 }, angle);
                    const s: f32 = 0.3;
                    basis = basis.scaled(Vector3{ .x = s, .y = s, .z = s });
                    const origin = Vector3{ .x = p.x, .y = top + 0.5, .z = p.z };
                    root.setTransform(Transform3D.initBasisOrigin(basis, origin));
                }

                // LED glow light
                if (self.powered[i]) {
                    self.led_lights[i].setPosition(.{ .x = p.x, .y = p.y + 0.6, .z = p.z });
                    self.led_lights[i].setParam(.param_energy, @as(f64, 4.0));
                } else {
                    self.led_lights[i].setParam(.param_energy, @as(f64, 0.0));
                }
            }
        }
    }

    // --- Input handling -------------------------------------------------------

    pub fn _input(self: *GameNode, event: *InputEvent) void {
        if (Engine.isEditorHint()) return;

        // --- Keyboard: R to rotate (always handle, even when UI is focused) ---
        if (event.isClass(.fromLatin1("InputEventKey"))) {
            const ke: *InputEventKey = @ptrCast(event);
            if (ke.isPressed() and !ke.isEcho()) {
                if (ke.getKeycode() == .key_r) {
                    self.rotateSelectedPart();
                }
            }
        }
    }

    /// Mouse/touch events that should only fire when the GUI didn't consume them.
    pub fn _unhandled_input(self: *GameNode, event: *InputEvent) void {
        if (Engine.isEditorHint()) return;

        // --- Mouse button ---
        if (event.isClass(.fromLatin1("InputEventMouseButton"))) {
            const mb: *InputEventMouseButton = @ptrCast(event);
            const btn = mb.getButtonIndex();
            if (btn == .mouse_button_left) {
                if (mb.isPressed()) {
                    self.onPointerPressed(mb.getPosition());
                } else {
                    self.onPointerReleased(mb.getPosition());
                }
            }
            // Scroll wheel zoom
            if (btn == .mouse_button_wheel_up) {
                self.cam_dist = @max(4.0, self.cam_dist - 1.5);
            }
            if (btn == .mouse_button_wheel_down) {
                self.cam_dist = @min(80.0, self.cam_dist + 1.5);
            }
        }

        // --- Mouse motion: camera orbit, drag, or hover ---
        if (event.isClass(.fromLatin1("InputEventMouseMotion"))) {
            const mm: *InputEventMouseMotion = @ptrCast(event);
            const delta = mm.getRelative();
            const pos = mm.getPosition();

            if (self.mouse_pressed) {
                if (self.dragging != null) {
                    // Update drag target
                    self.onPointerDrag(pos);
                } else if (self.camera_drag_active) {
                    self.cam_azimuth += delta.x * 0.005;
                    self.cam_pitch -= delta.y * 0.005;
                    self.cam_pitch = @min(@max(self.cam_pitch, 0.1), std.math.pi * 0.45);
                }
            } else {
                // Update hovered part (when not dragging/rotating)
                self.hovered_part = self.screenRaycastParts(pos);
            }
        }

        // --- Touch input (mobile/tablet support) ---
        if (event.isClass(.fromLatin1("InputEventScreenTouch"))) {
            const touch: *InputEventScreenTouch = @ptrCast(event);
            if (touch.isPressed()) {
                self.onPointerPressed(touch.getPosition());
            } else {
                self.onPointerReleased(touch.getPosition());
            }
        }

        if (event.isClass(.fromLatin1("InputEventScreenDrag"))) {
            const drag: *InputEventScreenDrag = @ptrCast(event);
            const delta = drag.getRelative();
            const pos = drag.getPosition();

            if (self.mouse_pressed) {
                if (self.dragging != null) {
                    self.onPointerDrag(pos);
                } else if (self.camera_drag_active) {
                    const s = 0.005;
                    self.cam_azimuth += delta.x * s;
                    self.cam_pitch -= delta.y * s;
                    self.cam_pitch = @min(@max(self.cam_pitch, 0.1), std.math.pi * 0.45);
                }
            }
        }
    }

    fn onPointerPressed(self: *GameNode, screen_pos: Vector2) void {
        self.mouse_pressed = true;
        self.last_mouse_pos = screen_pos;

        const hit = self.screenRaycastParts(screen_pos);
        if (hit) |idx| {
            self.dragging = idx;
            self.selected_part = idx;
            self.drag_origin = self.part_pos[idx];
        } else {
            self.camera_drag_active = true;
            self.selected_part = null;
        }
    }

    fn onPointerReleased(self: *GameNode, screen_pos: Vector2) void {
        self.mouse_pressed = false;
        self.target_block = null;
        if (self.dragging) |idx| {
            // Try to snap to hovered grid cell
            if (self.screenRaycastTerrain(screen_pos)) |target| {
                if (!self.isOccupied(idx, target)) {
                    self.part_pos[idx] = target;
                    self.updateCircuit();
                } else {
                    // Blocked, return to original position
                    self.part_pos[idx] = self.drag_origin;
                }
            } else {
                // No valid terrain target, return to original position
                self.part_pos[idx] = self.drag_origin;
            }
            self.dragging = null;
        }
        self.camera_drag_active = false;
    }

    fn onPointerDrag(self: *GameNode, screen_pos: Vector2) void {
        if (self.dragging) |idx| {
            if (self.screenRaycastTerrain(screen_pos)) |target| {
                // Visually follow cursor during drag
                self.part_pos[idx] = target;
                self.target_block = target;
                self.target_valid = !self.isOccupied(idx, target);
            }
        }
    }

    /// Cast a ray from screen position and return the index of the closest part hit.
    fn screenRaycastParts(self: *GameNode, screen_pos: Vector2) ?usize {
        const vp = self.base.getViewport() orelse return null;
        const from = self.camera.projectRayOrigin(screen_pos);
        const dir = self.camera.projectRayNormal(screen_pos);
        const to = Vector3{
            .x = from.x + dir.x * 1000.0,
            .y = from.y + dir.y * 1000.0,
            .z = from.z + dir.z * 1000.0,
        };
        _ = vp;
        _ = to;

        var best_dist: f32 = std.math.floatMax(f32);
        var result: ?usize = null;

        for (0..MAX_PARTS) |i| {
            const p = self.part_pos[i];
            const half: f32 = BLOCK_SIZE * 0.5;
            // AABB slab test
            const dist = rayAABB(
                from,
                dir,
                .{ .x = p.x - half, .y = p.y, .z = p.z - half },
                .{ .x = p.x + half, .y = p.y + BLOCK_SIZE, .z = p.z + half },
            ) orelse continue;
            if (dist < best_dist) {
                best_dist = dist;
                result = i;
            }
        }
        return result;
    }

    /// Cast a ray and find which grid cell on Y=0 it hits.
    fn screenRaycastTerrain(self: *GameNode, screen_pos: Vector2) ?parts.Vec3 {
        const from = self.camera.projectRayOrigin(screen_pos);
        const dir = self.camera.projectRayNormal(screen_pos);

        // Intersect with Y=0 plane
        if (@abs(dir.y) < 1e-7) return null;
        const t = -from.y / dir.y;
        if (t < 0) return null;

        const hit_x = from.x + dir.x * t;
        const hit_z = from.z + dir.z * t;

        // Snap to grid
        const gx = @round(hit_x / BLOCK_SIZE);
        const gz = @round(hit_z / BLOCK_SIZE);

        // Clamp to map bounds
        const clamped_x = @max(0.0, @min(@as(f32, @floatFromInt(GRID_W - 1)) * BLOCK_SIZE, gx * BLOCK_SIZE));
        const clamped_z = @max(0.0, @min(@as(f32, @floatFromInt(GRID_D - 1)) * BLOCK_SIZE, gz * BLOCK_SIZE));

        return .{ .x = clamped_x, .y = 0.0, .z = clamped_z };
    }

    /// Ray vs AABB intersection. Returns distance along ray or null.
    fn rayAABB(origin: Vector3, dir: Vector3, mn: Vector3, mx: Vector3) ?f32 {
        const eps = 1e-7;
        const dx = if (@abs(dir.x) < eps) eps else dir.x;
        const dy = if (@abs(dir.y) < eps) eps else dir.y;
        const dz = if (@abs(dir.z) < eps) eps else dir.z;
        const tx1 = (mn.x - origin.x) / dx;
        const tx2 = (mx.x - origin.x) / dx;
        const ty1 = (mn.y - origin.y) / dy;
        const ty2 = (mx.y - origin.y) / dy;
        const tz1 = (mn.z - origin.z) / dz;
        const tz2 = (mx.z - origin.z) / dz;
        const tmin = @max(@max(@min(tx1, tx2), @min(ty1, ty2)), @min(tz1, tz2));
        const tmax = @min(@min(@max(tx1, tx2), @max(ty1, ty2)), @max(tz1, tz2));
        if (tmax < 0 or tmin > tmax) return null;
        return if (tmin >= 0) tmin else tmax;
    }

    fn isOccupied(self: *const GameNode, ignore_idx: usize, pos: parts.Vec3) bool {
        for (self.part_pos, 0..) |p, i| {
            if (i == ignore_idx) continue;
            if (@abs(p.x - pos.x) < 0.5 and @abs(p.z - pos.z) < 0.5) return true;
        }
        return false;
    }

    // --- Circuit simulation ---------------------------------------------------

    fn updateCircuit(self: *GameNode) void {
        circuit.simulate(&self.part_data, &self.part_pos, &self.powered, &self.stats);
    }

    /// Debug: snap all parts to the known solution positions/orientations.
    fn debugSolve(self: *GameNode) void {
        const y: f32 = 0.0;
        self.part_data[0] = .{ .kind = .wire_corner, .orientation = .rot270 };
        self.part_pos[0] = .{ .x = 0.0, .y = y, .z = 0.0 };
        self.part_data[1] = .{ .kind = .wire_corner, .orientation = .rot0 };
        self.part_pos[1] = .{ .x = 2.0, .y = y, .z = 0.0 };
        self.part_data[2] = .{ .kind = .wire_corner, .orientation = .rot270 };
        self.part_pos[2] = .{ .x = 2.0, .y = y, .z = 2.0 };
        self.part_data[3] = .{ .kind = .wire_corner, .orientation = .rot180 };
        self.part_pos[3] = .{ .x = 0.0, .y = y, .z = 2.0 };
        self.part_data[4] = .{ .kind = .cell, .orientation = .rot270 };
        self.part_pos[4] = .{ .x = 0.0, .y = y, .z = 1.0 };
        self.part_data[5] = .{ .kind = .wire_straight, .orientation = .rot0 };
        self.part_pos[5] = .{ .x = 1.0, .y = y, .z = 0.0 };
        self.part_data[6] = .{ .kind = .cell, .orientation = .rot0 };
        self.part_pos[6] = .{ .x = 1.0, .y = y, .z = 2.0 };
        self.part_data[7] = .{ .kind = .led, .orientation = .rot270 };
        self.part_pos[7] = .{ .x = 2.0, .y = y, .z = 1.0 };
        self.updateCircuit();
    }

    // --- Mesh building (ImmediateMesh) ----------------------------------------
    //
    // All geometry is drawn via ImmediateMesh each frame (like raylib immediate
    // mode drawing). Surfaces use PRIMITIVE_TRIANGLES with vertex colours.
    //
    // Colour packing: we use surface_begin + set_color + add_vertex triplets.

    fn rebuildMesh(self: *GameNode) void {
        self.immediate_mesh.clearSurfaces();
        self.drawTerrain();
        for (0..MAX_PARTS) |i| {
            self.drawPart(i);
        }
        // Part terminal labels (drawn on top of parts)
        self.drawPartLabels();
        // Placement target when dragging
        self.drawPlacementTarget();
    }

    // Helper: start a new triangle surface, draw, then commit.
    // We open ONE surface per "object" using PRIMITIVE_TRIANGLES.
    const PrimType = @TypeOf(ImmediateMesh.PrimitiveType.primitive_triangles);

    fn beginSurface(self: *GameNode) void {
        self.immediate_mesh.surfaceBegin(.primitive_triangles, .{});
    }

    fn endSurface(self: *GameNode) void {
        self.immediate_mesh.surfaceEnd();
    }

    fn beginLineSurface(self: *GameNode) void {
        self.immediate_mesh.surfaceBegin(.primitive_lines, .{});
    }

    fn addLine(self: *GameNode, from: Vector3, to: Vector3, c: Color) void {
        self.immediate_mesh.surfaceSetColor(c);
        self.immediate_mesh.surfaceAddVertex(from);
        self.immediate_mesh.surfaceSetColor(c);
        self.immediate_mesh.surfaceAddVertex(to);
    }

    /// Draw a wireframe box (12 edges) using line primitives.
    fn drawWireBox(self: *GameNode, cx: f32, cy: f32, cz: f32, hw: f32, hh: f32, hd: f32, c: Color) void {
        const x0 = cx - hw;
        const x1 = cx + hw;
        const y0 = cy - hh;
        const y1 = cy + hh;
        const z0 = cz - hd;
        const z1 = cz + hd;
        // 12 edges of the box
        // Bottom rectangle
        self.addLine(.{ .x = x0, .y = y0, .z = z0 }, .{ .x = x1, .y = y0, .z = z0 }, c);
        self.addLine(.{ .x = x1, .y = y0, .z = z0 }, .{ .x = x1, .y = y0, .z = z1 }, c);
        self.addLine(.{ .x = x1, .y = y0, .z = z1 }, .{ .x = x0, .y = y0, .z = z1 }, c);
        self.addLine(.{ .x = x0, .y = y0, .z = z1 }, .{ .x = x0, .y = y0, .z = z0 }, c);
        // Top rectangle
        self.addLine(.{ .x = x0, .y = y1, .z = z0 }, .{ .x = x1, .y = y1, .z = z0 }, c);
        self.addLine(.{ .x = x1, .y = y1, .z = z0 }, .{ .x = x1, .y = y1, .z = z1 }, c);
        self.addLine(.{ .x = x1, .y = y1, .z = z1 }, .{ .x = x0, .y = y1, .z = z1 }, c);
        self.addLine(.{ .x = x0, .y = y1, .z = z1 }, .{ .x = x0, .y = y1, .z = z0 }, c);
        // Vertical pillars
        self.addLine(.{ .x = x0, .y = y0, .z = z0 }, .{ .x = x0, .y = y1, .z = z0 }, c);
        self.addLine(.{ .x = x1, .y = y0, .z = z0 }, .{ .x = x1, .y = y1, .z = z0 }, c);
        self.addLine(.{ .x = x1, .y = y0, .z = z1 }, .{ .x = x1, .y = y1, .z = z1 }, c);
        self.addLine(.{ .x = x0, .y = y0, .z = z1 }, .{ .x = x0, .y = y1, .z = z1 }, c);
    }

    fn addTri(
        self: *GameNode,
        v0: Vector3,
        v1: Vector3,
        v2: Vector3,
        c: Color,
    ) void {
        self.immediate_mesh.surfaceSetColor(c);
        self.immediate_mesh.surfaceAddVertex(v0);
        self.immediate_mesh.surfaceSetColor(c);
        self.immediate_mesh.surfaceAddVertex(v1);
        self.immediate_mesh.surfaceSetColor(c);
        self.immediate_mesh.surfaceAddVertex(v2);
    }

    fn addQuad(
        self: *GameNode,
        v0: Vector3,
        v1: Vector3,
        v2: Vector3,
        v3: Vector3,
        c: Color,
    ) void {
        self.addTri(v0, v1, v2, c);
        self.addTri(v0, v2, v3, c);
    }

    fn addBox(
        self: *GameNode,
        cx: f32,
        cy: f32,
        cz: f32,
        hw: f32,
        hh: f32,
        hd: f32,
        top_c: Color,
        side_c: Color,
    ) void {
        const x0 = cx - hw;
        const x1 = cx + hw;
        const y0 = cy - hh;
        const y1 = cy + hh;
        const z0 = cz - hd;
        const z1 = cz + hd;
        // +Y top
        self.addQuad(.{ .x = x0, .y = y1, .z = z0 }, .{ .x = x0, .y = y1, .z = z1 }, .{ .x = x1, .y = y1, .z = z1 }, .{ .x = x1, .y = y1, .z = z0 }, top_c);
        // -Y bottom
        self.addQuad(.{ .x = x1, .y = y0, .z = z0 }, .{ .x = x1, .y = y0, .z = z1 }, .{ .x = x0, .y = y0, .z = z1 }, .{ .x = x0, .y = y0, .z = z0 }, side_c);
        // +Z front
        self.addQuad(.{ .x = x0, .y = y0, .z = z1 }, .{ .x = x1, .y = y0, .z = z1 }, .{ .x = x1, .y = y1, .z = z1 }, .{ .x = x0, .y = y1, .z = z1 }, side_c);
        // -Z back
        self.addQuad(.{ .x = x1, .y = y0, .z = z0 }, .{ .x = x0, .y = y0, .z = z0 }, .{ .x = x0, .y = y1, .z = z0 }, .{ .x = x1, .y = y1, .z = z0 }, side_c);
        // +X right
        self.addQuad(.{ .x = x1, .y = y0, .z = z1 }, .{ .x = x1, .y = y0, .z = z0 }, .{ .x = x1, .y = y1, .z = z0 }, .{ .x = x1, .y = y1, .z = z1 }, side_c);
        // -X left
        self.addQuad(.{ .x = x0, .y = y0, .z = z0 }, .{ .x = x0, .y = y0, .z = z1 }, .{ .x = x0, .y = y1, .z = z1 }, .{ .x = x0, .y = y1, .z = z0 }, side_c);
    }

    // Approximate a cylinder as a segmented box strip (8 segments)
    fn addCylinder(
        self: *GameNode,
        from: Vector3,
        to: Vector3,
        radius: f32,
        c: Color,
    ) void {
        const dx = to.x - from.x;
        const dy = to.y - from.y;
        const dz = to.z - from.z;
        const len = @sqrt(dx * dx + dy * dy + dz * dz);
        if (len < 1e-6) return;

        // Build an orthonormal basis around the axis
        const ax = Vector3{ .x = dx / len, .y = dy / len, .z = dz / len };
        // Pick a non-parallel up vector
        const up: Vector3 = if (@abs(ax.y) < 0.9) .{ .x = 0, .y = 1, .z = 0 } else .{ .x = 1, .y = 0, .z = 0 };
        const side1 = normalize(cross(ax, up));
        const side2 = cross(ax, side1);

        const segs = 8;
        var prev_a = Vector3{
            .x = from.x + side1.x * radius,
            .y = from.y + side1.y * radius,
            .z = from.z + side1.z * radius,
        };
        var prev_b = Vector3{
            .x = to.x + side1.x * radius,
            .y = to.y + side1.y * radius,
            .z = to.z + side1.z * radius,
        };
        var i: usize = 1;
        while (i <= segs) : (i += 1) {
            const angle = @as(f32, @floatFromInt(i)) * std.math.tau / @as(f32, @floatFromInt(segs));
            const s1 = @cos(angle);
            const s2 = @sin(angle);
            const cur_a = Vector3{
                .x = from.x + (side1.x * s1 + side2.x * s2) * radius,
                .y = from.y + (side1.y * s1 + side2.y * s2) * radius,
                .z = from.z + (side1.z * s1 + side2.z * s2) * radius,
            };
            const cur_b = Vector3{
                .x = to.x + (side1.x * s1 + side2.x * s2) * radius,
                .y = to.y + (side1.y * s1 + side2.y * s2) * radius,
                .z = to.z + (side1.z * s1 + side2.z * s2) * radius,
            };
            self.addTri(prev_a, cur_a, cur_b, c);
            self.addTri(prev_a, cur_b, prev_b, c);
            prev_a = cur_a;
            prev_b = cur_b;
        }
    }

    fn cross(a: Vector3, b: Vector3) Vector3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    fn normalize(v: Vector3) Vector3 {
        const len = @sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
        if (len < 1e-9) return .{ .x = 0, .y = 1, .z = 0 };
        return .{ .x = v.x / len, .y = v.y / len, .z = v.z / len };
    }

    // --- Terrain drawing ------------------------------------------------------

    fn terrainVariant(xi: usize, zi: usize) struct { top: Color, side: Color } {
        const grass_top = Color{ .r = 0.357, .g = 0.639, .b = 0.294, .a = 1 };
        const grass_side = Color{ .r = 0.467, .g = 0.376, .b = 0.227, .a = 1 };
        const dirt_top = Color{ .r = 0.475, .g = 0.333, .b = 0.204, .a = 1 };
        const dirt_side = Color{ .r = 0.357, .g = 0.227, .b = 0.129, .a = 1 };
        const stone_top = Color{ .r = 0.471, .g = 0.471, .b = 0.471, .a = 1 };
        const stone_side = Color{ .r = 0.353, .g = 0.353, .b = 0.353, .a = 1 };

        // Some blocks are dirt or stone instead of grass for variety
        const variant = (xi * 7 + zi * 13) % 12;
        return if (variant == 0)
            .{ .top = dirt_top, .side = dirt_side }
        else if (variant == 1)
            .{ .top = stone_top, .side = stone_side }
        else
            .{ .top = grass_top, .side = grass_side };
    }

    fn drawTerrain(self: *GameNode) void {
        self.beginSurface();
        for (0..GRID_W) |xi| {
            for (0..GRID_D) |zi| {
                const wx: f32 = @as(f32, @floatFromInt(xi)) * BLOCK_SIZE;
                const wz: f32 = @as(f32, @floatFromInt(zi)) * BLOCK_SIZE;
                const vt = terrainVariant(xi, zi);
                self.addBox(wx, -BLOCK_SIZE * 0.5, wz, BLOCK_SIZE * 0.5, BLOCK_SIZE * 0.5, BLOCK_SIZE * 0.5, vt.top, vt.side);
            }
        }
        self.endSurface();
    }

    // --- Part drawing ---------------------------------------------------------

    fn platformTop(pos: parts.Vec3) f32 {
        return pos.y + BLOCK_SIZE * 0.12;
    }

    fn drawPlatform(self: *GameNode, pos: parts.Vec3) void {
        const s = BLOCK_SIZE;
        const top = platformTop(pos);
        const thickness = s * 0.12;
        const cy = top - thickness * 0.5;
        const w = s * 0.475; // half-extent
        const color = Color{ .r = 0.275, .g = 0.294, .b = 0.333, .a = 1.0 };
        self.addBox(pos.x, cy, pos.z, w, thickness * 0.5, w, color, color);
    }

    fn drawPart(self: *GameNode, idx: usize) void {
        const p = &self.part_data[idx];
        const pos = self.part_pos[idx];

        const is_hovered = if (self.hovered_part) |h| h == idx else false;
        const is_selected = if (self.selected_part) |s| s == idx else false;

        self.beginSurface();
        self.drawPlatform(pos);

        switch (p.kind) {
            .cell => self.drawCell(pos, p.orientation),
            .wire_straight => self.drawWireStraight(pos, p.orientation),
            .wire_corner => self.drawWireCorner(pos, p.orientation),
            .led => {}, // LED model is handled by updateLEDLights()
        }
        self.endSurface();

        // Hover/selection wireframe highlights (separate line surface)
        if (is_hovered and !self.mouse_pressed) {
            const s = BLOCK_SIZE;
            const oc = Color{ .r = 1.0, .g = 0.85, .b = 0.2, .a = 1.0 };
            self.beginLineSurface();
            self.drawWireBox(pos.x, pos.y + s * 0.5, pos.z, s * 0.545, s * 0.545, s * 0.545, oc);
            self.endSurface();
        }

        if (is_selected and !is_hovered) {
            const s = BLOCK_SIZE;
            const oc = Color{ .r = 0.863, .g = 0.941, .b = 1.0, .a = 1.0 };
            self.beginLineSurface();
            self.drawWireBox(pos.x, pos.y + s * 0.5, pos.z, s * 0.535, s * 0.535, s * 0.535, oc);
            self.endSurface();
        }
    }

    fn drawCell(self: *GameNode, pos: parts.Vec3, o: parts.Orientation) void {
        const s = BLOCK_SIZE;
        const copper = Color{ .r = 0.804, .g = 0.588, .b = 0.353, .a = 1 };
        const black = Color{ .r = 0.137, .g = 0.137, .b = 0.137, .a = 1 };
        const metal = Color{ .r = 0.745, .g = 0.745, .b = 0.765, .a = 1 };
        const radius = s * 0.18;
        const y = platformTop(pos) + radius;
        const d = parts.rotDir(1, 0, o);

        const neg = Vector3{ .x = pos.x - d.x * s * 0.4, .y = y, .z = pos.z - d.z * s * 0.4 };
        const split = Vector3{ .x = pos.x + d.x * s * 0.18, .y = y, .z = pos.z + d.z * s * 0.18 };
        const pos_end = Vector3{ .x = pos.x + d.x * s * 0.4, .y = y, .z = pos.z + d.z * s * 0.4 };
        const nub = Vector3{ .x = pos.x + d.x * (s * 0.4 + s * 0.07), .y = y, .z = pos.z + d.z * (s * 0.4 + s * 0.07) };
        const cap = Vector3{ .x = pos.x - d.x * (s * 0.4 + s * 0.02), .y = y, .z = pos.z - d.z * (s * 0.4 + s * 0.02) };

        self.addCylinder(neg, split, radius, black);
        self.addCylinder(split, pos_end, radius, copper);
        self.addCylinder(pos_end, nub, radius * 0.45, metal);
        self.addCylinder(cap, neg, radius * 1.02, metal);
    }

    fn drawWireStraight(self: *GameNode, pos: parts.Vec3, o: parts.Orientation) void {
        const s = BLOCK_SIZE;
        const sheath = Color{ .r = 0.157, .g = 0.549, .b = 0.275, .a = 1 };
        const copper = Color{ .r = 0.804, .g = 0.588, .b = 0.353, .a = 1 };
        const r = s * 0.08;
        const y = platformTop(pos) + r;
        const d = parts.rotDir(1, 0, o);

        const left = Vector3{ .x = pos.x - d.x * s * 0.5, .y = y, .z = pos.z - d.z * s * 0.5 };
        const sl = Vector3{ .x = pos.x - d.x * s * 0.32, .y = y, .z = pos.z - d.z * s * 0.32 };
        const sr = Vector3{ .x = pos.x + d.x * s * 0.32, .y = y, .z = pos.z + d.z * s * 0.32 };
        const right = Vector3{ .x = pos.x + d.x * s * 0.5, .y = y, .z = pos.z + d.z * s * 0.5 };

        self.addCylinder(sl, sr, r, sheath);
        self.addCylinder(left, sl, r * 0.45, copper);
        self.addCylinder(sr, right, r * 0.45, copper);
    }

    fn drawWireCorner(self: *GameNode, pos: parts.Vec3, o: parts.Orientation) void {
        const s = BLOCK_SIZE;
        const sheath = Color{ .r = 0.157, .g = 0.549, .b = 0.275, .a = 1 };
        const copper = Color{ .r = 0.804, .g = 0.588, .b = 0.353, .a = 1 };
        const r = s * 0.08;
        const y = platformTop(pos) + r;
        const arm = s * 0.5;
        const sf = 0.64;
        const ctr = Vector3{ .x = pos.x, .y = y, .z = pos.z };

        const Dir2 = struct { x: f32, z: f32 };
        const d0: Dir2 = .{ .x = parts.rotDir(-1, 0, o).x, .z = parts.rotDir(-1, 0, o).z };
        const d1: Dir2 = .{ .x = parts.rotDir(0, 1, o).x, .z = parts.rotDir(0, 1, o).z };
        const dirs = [2]Dir2{ d0, d1 };
        inline for (dirs) |di| {
            const sh = Vector3{ .x = pos.x + di.x * arm * sf, .y = y, .z = pos.z + di.z * arm * sf };
            const tip = Vector3{ .x = pos.x + di.x * arm, .y = y, .z = pos.z + di.z * arm };
            self.addCylinder(ctr, sh, r, sheath);
            self.addCylinder(sh, tip, r * 0.45, copper);
        }
        // Corner sphere approximated as small box
        self.addBox(pos.x, y, pos.z, r, r, r, sheath, sheath);
    }

    // --- Placement target (green/red grid cell) ----------------------------

    fn drawPlacementTarget(self: *GameNode) void {
        const target = self.target_block orelse return;
        if (self.dragging == null) return;

        // Draw a semi-transparent box on the target grid cell
        const s = BLOCK_SIZE;
        const cx = target.x;
        const cz = target.z;
        const cy = 0.01; // just above terrain surface
        const hw = s * 0.48;
        const hd = s * 0.48;
        const hh = 0.01;

        const color = if (self.target_valid)
            Color{ .r = 0.3, .g = 0.9, .b = 0.3, .a = 0.5 }
        else
            Color{ .r = 0.9, .g = 0.3, .b = 0.3, .a = 0.5 };

        self.beginSurface();
        self.addBox(cx, cy, cz, hw, hh, hd, color, color);
        self.endSurface();
    }

    // --- Part terminal labels (+/- for cells, A/K for LEDs) ----------------

    fn drawPartLabels(self: *GameNode) void {
        self.beginSurface();
        for (0..MAX_PARTS) |i| {
            const p = &self.part_data[i];
            const pos = self.part_pos[i];
            switch (p.kind) {
                .cell => self.drawCellLabels(pos, p.orientation),
                .led => self.drawLedLabels(pos, p.orientation),
                else => {},
            }
        }
        self.endSurface();
    }

    fn drawCellLabels(self: *GameNode, pos: parts.Vec3, o: parts.Orientation) void {
        const s = BLOCK_SIZE;
        const top = platformTop(pos) + 0.01;
        const d = parts.rotDir(1, 0, o);
        const n = parts.rotDir(0, 1, o); // north (perpendicular to direction)
        const sym = s * 0.18;
        const line_r = s * 0.015;
        const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };

        // Positive terminal (+): at the + direction end
        const plus_cx = pos.x + d.x * s * 0.4;
        const plus_cz = pos.z + d.z * s * 0.4;
        // Vertical bar of +
        const pv0 = Vector3{ .x = plus_cx + n.x * sym * 0.5, .y = top, .z = plus_cz + n.z * sym * 0.5 };
        const pv1 = Vector3{ .x = plus_cx - n.x * sym * 0.5, .y = top, .z = plus_cz - n.z * sym * 0.5 };
        const pv_len = @sqrt((pv1.x - pv0.x) * (pv1.x - pv0.x) + (pv1.z - pv0.z) * (pv1.z - pv0.z));
        _ = pv_len;
        self.addCylinder(pv0, pv1, line_r, white);
        // Horizontal bar of +
        const ph0 = Vector3{ .x = plus_cx + d.x * sym * 0.5, .y = top, .z = plus_cz + d.z * sym * 0.5 };
        const ph1 = Vector3{ .x = plus_cx - d.x * sym * 0.5, .y = top, .z = plus_cz - d.z * sym * 0.5 };
        self.addCylinder(ph0, ph1, line_r, white);

        // Negative terminal (−): at the - direction end
        const minus_cx = pos.x - d.x * s * 0.4;
        const minus_cz = pos.z - d.z * s * 0.4;
        const mv0 = Vector3{ .x = minus_cx + d.x * sym * 0.5, .y = top, .z = minus_cz + d.z * sym * 0.5 };
        const mv1 = Vector3{ .x = minus_cx - d.x * sym * 0.5, .y = top, .z = minus_cz - d.z * sym * 0.5 };
        self.addCylinder(mv0, mv1, line_r, white);
    }

    fn drawLedLabels(self: *GameNode, pos: parts.Vec3, o: parts.Orientation) void {
        const s = BLOCK_SIZE;
        const top = platformTop(pos) + 0.01;
        const d = parts.rotDir(1, 0, o);
        const n = parts.rotDir(0, 1, o); // north
        const sym = s * 0.14;
        const line_r = s * 0.015;
        const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };

        // --- 'A' (Anode) at the positive end ---
        const acx = pos.x + d.x * s * 0.4;
        const acz = pos.z + d.z * s * 0.4;
        const a_apex = Vector3{ .x = acx + d.x * sym * 0.6, .y = top, .z = acz + d.z * sym * 0.6 };
        const a_bl = Vector3{ .x = acx + n.x * sym - d.x * sym * 0.3, .y = top, .z = acz + n.z * sym - d.z * sym * 0.3 };
        const a_br = Vector3{ .x = acx - n.x * sym - d.x * sym * 0.3, .y = top, .z = acz - n.z * sym - d.z * sym * 0.3 };
        const a_cross = Vector3{ .x = acx - d.x * sym * 0.2, .y = top, .z = acz - d.z * sym * 0.2 };
        self.addCylinder(a_bl, a_apex, line_r, white);
        self.addCylinder(a_br, a_apex, line_r, white);
        self.addCylinder(a_bl, a_cross, line_r, white);

        // --- 'K' (Cathode) at the negative end ---
        const kcx = pos.x - d.x * s * 0.4;
        const kcz = pos.z - d.z * s * 0.4;
        const k_spine_top = Vector3{ .x = kcx + d.x * sym * 0.5, .y = top, .z = kcz + d.z * sym * 0.5 };
        const k_spine_bot = Vector3{ .x = kcx - n.x * sym * 0.7 + d.x * sym * 0.3, .y = top, .z = kcz - n.z * sym * 0.7 + d.z * sym * 0.3 };
        const k_arm_top = Vector3{ .x = kcx + n.x * sym * 0.7 - d.x * sym * 0.1, .y = top, .z = kcz + n.z * sym * 0.7 - d.z * sym * 0.1 };
        const k_arm_bot = Vector3{ .x = kcx - n.x * sym * 0.7 - d.x * sym * 0.1, .y = top, .z = kcz - n.z * sym * 0.7 - d.z * sym * 0.1 };
        self.addCylinder(k_spine_bot, k_spine_top, line_r, white);
        self.addCylinder(k_spine_top, k_arm_top, line_r, white);
        self.addCylinder(k_spine_top, k_arm_bot, line_r, white);
    }
};

// --- Module-level registration functions ---------------------------------

pub fn register(r: *godot.extension.Registry) void {
    GameNode.register(r);
}

pub fn unregister(r: *godot.extension.Registry) void {
    GameNode.unregister(r);
}
