/// GameNode: the central Godot Node3D for the Circuit Puzzle game.
///
/// This node owns the game state, handles mouse/touch input through
/// Godot's input system, runs the camera, and updates the UI/BoardRenderer
/// nodes via meta properties.
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
const Engine = godot.class.Engine;
const Input = godot.class.Input;
const InputEvent = godot.class.InputEvent;
const InputEventMouseButton = godot.class.InputEventMouseButton;
const InputEventMouseMotion = godot.class.InputEventMouseMotion;
const InputEventKey = godot.class.InputEventKey;
const InputEventScreenTouch = godot.class.InputEventScreenTouch;
const InputEventScreenDrag = godot.class.InputEventScreenDrag;
const NodePath = godot.builtin.NodePath;

const Vector2 = godot.builtin.Vector2;
const Vector3 = godot.builtin.Vector3;
const Color = godot.builtin.Color;
const Transform3D = godot.builtin.Transform3d;
const Basis = godot.builtin.Basis;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const Variant = godot.builtin.Variant;

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
        self.setupLights();
        self.setupLEDModel();
        self.updateCircuit();
    }

    fn initParts(self: *GameNode) void {
        // Start with a solved closed circuit so the LED lights up immediately.
        self.part_data[0] = .{ .kind = .wire_corner, .orientation = .rot90 };
        self.part_pos[0] = .{ .x = 0.0, .y = 0.0, .z = 0.0 };
        self.part_data[1] = .{ .kind = .wire_corner, .orientation = .rot0 };
        self.part_pos[1] = .{ .x = 2.0, .y = 0.0, .z = 0.0 };
        self.part_data[2] = .{ .kind = .wire_corner, .orientation = .rot270 };
        self.part_pos[2] = .{ .x = 2.0, .y = 0.0, .z = 2.0 };
        self.part_data[3] = .{ .kind = .wire_corner, .orientation = .rot180 };
        self.part_pos[3] = .{ .x = 0.0, .y = 0.0, .z = 2.0 };
        self.part_data[4] = .{ .kind = .cell, .orientation = .rot270 };
        self.part_pos[4] = .{ .x = 0.0, .y = 0.0, .z = 1.0 };
        self.part_data[5] = .{ .kind = .wire_straight, .orientation = .rot0 };
        self.part_pos[5] = .{ .x = 1.0, .y = 0.0, .z = 0.0 };
        self.part_data[6] = .{ .kind = .cell, .orientation = .rot0 };
        self.part_pos[6] = .{ .x = 1.0, .y = 0.0, .z = 2.0 };
        self.part_data[7] = .{ .kind = .led, .orientation = .rot270 };
        self.part_pos[7] = .{ .x = 2.0, .y = 0.0, .z = 1.0 };
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

        // Write all part data for the GDScript board renderer
        self.writePartMeta();

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

    fn writePartMeta(self: *GameNode) void {
        const count: i64 = MAX_PARTS;
        self.base.setMeta(StringName.fromLatin1("_part_count", false), Variant.init(i64, count));
        self.base.setMeta(StringName.fromLatin1("_grid_w", false), Variant.init(i64, GRID_W));
        self.base.setMeta(StringName.fromLatin1("_grid_d", false), Variant.init(i64, GRID_D));
        self.base.setMeta(StringName.fromLatin1("_block_size", false), Variant.init(f64, BLOCK_SIZE));

        const hover_idx: i64 = if (self.hovered_part) |h| @as(i64, @intCast(h)) else -1;
        self.base.setMeta(StringName.fromLatin1("_hovered_index", false), Variant.init(i64, hover_idx));

        // Drag placement target
        if (self.target_block) |tb| {
            self.base.setMeta(StringName.fromLatin1("_target_block", false), Variant.init(Vector3, Vector3{ .x = tb.x, .y = tb.y, .z = tb.z }));
            self.base.setMeta(StringName.fromLatin1("_target_valid", false), Variant.init(bool, self.target_valid));
        } else {
            self.base.removeMeta(StringName.fromLatin1("_target_block", false));
        }

        for (0..MAX_PARTS) |i| {
            const pos = self.part_pos[i];
            const kind = self.part_data[i].kind;
            const orient = self.part_data[i].orientation;

            var kbuf0: [32]u8 = undefined;
            const key0 = std.fmt.bufPrintZ(&kbuf0, "_part_pos_{d}", .{i}) catch unreachable;
            self.base.setMeta(StringName.fromLatin1(key0, false), Variant.init(Vector3, Vector3{ .x = pos.x, .y = pos.y, .z = pos.z }));

            var kbuf1: [32]u8 = undefined;
            const key1 = std.fmt.bufPrintZ(&kbuf1, "_part_kind_{d}", .{i}) catch unreachable;
            self.base.setMeta(StringName.fromLatin1(key1, false), Variant.init(i64, @intFromEnum(kind)));

            var kbuf2: [32]u8 = undefined;
            const key2 = std.fmt.bufPrintZ(&kbuf2, "_part_orient_{d}", .{i}) catch unreachable;
            self.base.setMeta(StringName.fromLatin1(key2, false), Variant.init(i64, @intFromEnum(orient)));

            var kbuf3: [32]u8 = undefined;
            const key3 = std.fmt.bufPrintZ(&kbuf3, "_part_powered_{d}", .{i}) catch unreachable;
            self.base.setMeta(StringName.fromLatin1(key3, false), Variant.init(bool, self.powered[i]));
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

    fn platformTop(pos: parts.Vec3) f32 {
        return pos.y + BLOCK_SIZE * 0.12;
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
        // Working closed circuit (counter-clockwise loop):
        //  row0: wire_corner rot90  - wire_straight rot0 - wire_corner rot0
        //  row1: cell rot270        - (empty)            - LED rot270
        //  row2: wire_corner rot180 - cell rot0          - wire_corner rot270
        self.part_data[0] = .{ .kind = .wire_corner, .orientation = .rot90 };
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
};

// --- Module-level registration functions ---------------------------------

pub fn register(r: *godot.extension.Registry) void {
    GameNode.register(r);
}

pub fn unregister(r: *godot.extension.Registry) void {
    GameNode.unregister(r);
}
