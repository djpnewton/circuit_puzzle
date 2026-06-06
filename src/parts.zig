const world = @import("world.zig");
const rl = @import("raylib");

pub const PartType = enum {
    cell,
    wire_straight,
    wire_corner,
    led,
};

/// Y-axis rotation in 90° CW steps (viewed from above).
pub const Orientation = enum(u2) {
    rot0,
    rot90,
    rot180,
    rot270,
};

/// Cardinal connection directions in world space (+X=east, -X=west, +Z=north, -Z=south).
pub const Dir = enum(u2) { east, west, north, south };

pub fn opposite(d: Dir) Dir {
    return switch (d) {
        .east => .west,
        .west => .east,
        .north => .south,
        .south => .north,
    };
}

/// Rotate a canonical direction by the part's orientation.
fn rotateDir(d: Dir, o: Orientation) Dir {
    const dx: f32 = switch (d) {
        .east => 1.0,
        .west => -1.0,
        .north => 0.0,
        .south => 0.0,
    };
    const dz: f32 = switch (d) {
        .east => 0.0,
        .west => 0.0,
        .north => 1.0,
        .south => -1.0,
    };
    const r = rotDir(dx, dz, o);
    if (r.x > 0.5) return .east;
    if (r.x < -0.5) return .west;
    if (r.z > 0.5) return .north;
    return .south;
}

/// The two connection-port directions for a part after applying its orientation.
/// Canonical (rot0) ports:
///   cell          : east(+) and west(−)
///   wire_straight : east and west
///   wire_corner   : west and north  (arms: rotDir(-1,0) and rotDir(0,+1))
///   led           : east(anode) and west(cathode)
pub fn connectDirs(kind: PartType, o: Orientation) [2]Dir {
    const canon: [2]Dir = switch (kind) {
        .cell => .{ .east, .west },
        .wire_straight => .{ .east, .west },
        .wire_corner => .{ .west, .north },
        .led => .{ .east, .west },
    };
    return .{ rotateDir(canon[0], o), rotateDir(canon[1], o) };
}

/// The positive (+) terminal direction of a battery cell after orientation.
pub fn batteryPlusDir(o: Orientation) Dir {
    return rotateDir(.east, o);
}

pub const Part = struct {
    kind: PartType,
    orientation: Orientation = .rot0,

    pub fn draw(self: *const Part, pos: rl.Vector3, powered: bool) void {
        drawPart(self.kind, self.orientation, pos, powered);
    }
};

/// Rotate (dx, dz) by `o` steps of 90° CW (looking down the +Y axis).
/// CW 90°: (x, z) → (z, -x)
fn rotDir(dx: f32, dz: f32, o: Orientation) struct { x: f32, z: f32 } {
    return switch (o) {
        .rot0 => .{ .x = dx, .z = dz },
        .rot90 => .{ .x = dz, .z = -dx },
        .rot180 => .{ .x = -dx, .z = -dz },
        .rot270 => .{ .x = -dz, .z = dx },
    };
}

pub fn partSize(self: PartType) f32 {
    _ = self;
    return world.BLOCK_SIZE;
}

/// Axis-aligned bounding box for a part sitting on the terrain.
/// `pos.y` is the terrain top surface the part rests on; the box spans one
/// block upward from there.
pub fn partBounds(pos: rl.Vector3) rl.BoundingBox {
    const half = world.BLOCK_SIZE * 0.5;
    return .{
        .min = .{ .x = pos.x - half, .y = pos.y, .z = pos.z - half },
        .max = .{ .x = pos.x + half, .y = pos.y + world.BLOCK_SIZE, .z = pos.z + half },
    };
}

pub fn partColor(self: PartType) rl.Color {
    return switch (self) {
        .cell => rl.Color.init(220, 180, 80, 255),
        .wire_straight => rl.Color.init(200, 200, 200, 255),
        .wire_corner => rl.Color.init(180, 180, 180, 255),
        .led => rl.Color.init(255, 100, 100, 255),
    };
}

pub fn drawPart(self: PartType, orientation: Orientation, pos: rl.Vector3, powered: bool) void {
    drawPlatform(pos);
    switch (self) {
        .cell => drawCell(pos, orientation),
        .wire_straight => drawWireStraight(pos, orientation),
        .wire_corner => drawWireCorner(pos, orientation),
        .led => drawLed(pos, orientation, powered),
    }
}

/// Top surface height of the platform every part sits on.
/// `pos.y` is the terrain top surface, so the platform rests on top of it.
fn platformTop(pos: rl.Vector3) f32 {
    return pos.y + world.BLOCK_SIZE * 0.12;
}

fn drawPlatform(pos: rl.Vector3) void {
    const s = world.BLOCK_SIZE;
    const top = platformTop(pos);
    const thickness = s * 0.12;
    const cy = top - thickness * 0.5;
    const w = s * 0.95;
    const color = rl.Color.init(70, 75, 85, 255);
    rl.drawCube(.{ .x = pos.x, .y = cy, .z = pos.z }, w, thickness, w, color);
    rl.drawCubeWires(.{ .x = pos.x, .y = cy, .z = pos.z }, w, thickness, w, rl.Color.init(0, 0, 0, 120));
}

fn drawCell(pos: rl.Vector3, o: Orientation) void {
    const s = world.BLOCK_SIZE;
    const copper_color = rl.Color.init(205, 150, 90, 255);
    const black_color = rl.Color.init(35, 35, 35, 255);
    const metal_color = rl.Color.init(190, 190, 195, 255);
    const radius = s * 0.18;
    const y = platformTop(pos) + radius;

    // Canonical: +X is the positive terminal direction; rotated by orientation.
    const d = rotDir(1, 0, o);
    const neg = rl.Vector3{ .x = pos.x - d.x * s * 0.4, .y = y, .z = pos.z - d.z * s * 0.4 };
    const split = rl.Vector3{ .x = pos.x + d.x * s * 0.18, .y = y, .z = pos.z + d.z * s * 0.18 };
    const pos_ = rl.Vector3{ .x = pos.x + d.x * s * 0.4, .y = y, .z = pos.z + d.z * s * 0.4 };
    const nub = rl.Vector3{ .x = pos.x + d.x * (s * 0.4 + s * 0.07), .y = y, .z = pos.z + d.z * (s * 0.4 + s * 0.07) };
    const cap = rl.Vector3{ .x = pos.x - d.x * (s * 0.4 + s * 0.02), .y = y, .z = pos.z - d.z * (s * 0.4 + s * 0.02) };

    // Black main body
    rl.drawCylinderEx(neg, split, radius, radius, 20, black_color);
    // Copper shoulder near the positive end
    rl.drawCylinderEx(split, pos_, radius, radius, 20, copper_color);
    // Positive terminal nub
    rl.drawCylinderEx(pos_, nub, radius * 0.45, radius * 0.45, 12, metal_color);
    // Negative terminal flat cap
    rl.drawCylinderEx(cap, neg, radius * 1.02, radius * 1.02, 20, metal_color);
}

fn drawWireStraight(pos: rl.Vector3, o: Orientation) void {
    const s = world.BLOCK_SIZE;
    const sheath_color = rl.Color.init(40, 140, 70, 255);
    const copper_color = rl.Color.init(205, 150, 90, 255);
    const r = s * 0.08;
    const y = platformTop(pos) + r;

    // Canonical axis: +X; rotated by orientation.
    const d = rotDir(1, 0, o);
    const left = rl.Vector3{ .x = pos.x - d.x * s * 0.5, .y = y, .z = pos.z - d.z * s * 0.5 };
    const sl = rl.Vector3{ .x = pos.x - d.x * s * 0.32, .y = y, .z = pos.z - d.z * s * 0.32 };
    const sr = rl.Vector3{ .x = pos.x + d.x * s * 0.32, .y = y, .z = pos.z + d.z * s * 0.32 };
    const right = rl.Vector3{ .x = pos.x + d.x * s * 0.5, .y = y, .z = pos.z + d.z * s * 0.5 };

    // Rubber sheath in the middle.
    rl.drawCylinderEx(sl, sr, r, r, 14, sheath_color);
    // Exposed copper at each end.
    rl.drawCylinderEx(left, sl, r * 0.45, r * 0.45, 10, copper_color);
    rl.drawCylinderEx(sr, right, r * 0.45, r * 0.45, 10, copper_color);
}

fn drawWireCorner(pos: rl.Vector3, o: Orientation) void {
    const s = world.BLOCK_SIZE;
    const sheath_color = rl.Color.init(40, 140, 70, 255);
    const copper_color = rl.Color.init(205, 150, 90, 255);
    const r = s * 0.08;
    const y = platformTop(pos) + r;

    const arm = s * 0.5;
    const sf = 0.64; // sheath fraction
    const ctr = rl.Vector3{ .x = pos.x, .y = y, .z = pos.z };

    // Canonical arm directions: (-1, 0) and (0, +1), rotated by orientation.
    // rot0: -X and +Z  |  rot90: +Z and +X  |  rot180: +X and -Z  |  rot270: -Z and -X
    const d = [2]@TypeOf(rotDir(0, 0, .rot0)){
        rotDir(-1, 0, o),
        rotDir(0, 1, o),
    };
    inline for (d) |di| {
        const sh = rl.Vector3{ .x = pos.x + di.x * arm * sf, .y = y, .z = pos.z + di.z * arm * sf };
        const tip = rl.Vector3{ .x = pos.x + di.x * arm, .y = y, .z = pos.z + di.z * arm };
        rl.drawCylinderEx(ctr, sh, r, r, 14, sheath_color);
        rl.drawCylinderEx(sh, tip, r * 0.45, r * 0.45, 10, copper_color);
    }
    // Smooth the inner corner.
    rl.drawSphere(ctr, r, sheath_color);
}

fn drawLed(pos: rl.Vector3, o: Orientation, powered: bool) void {
    const s = world.BLOCK_SIZE;
    const lead_color = rl.Color.init(190, 190, 195, 255);
    const die_color = partColor(.led);
    const epoxy_color = if (powered)
        rl.Color.init(255, 245, 80, 220)
    else
        rl.Color.init(255, 120, 120, 110);

    const top = platformTop(pos);
    const body_radius = s * 0.13;
    const body_bottom_y = top + s * 0.16;
    const body_top_y = top + s * 0.5;
    const lead_radius = s * 0.018;
    const post_radius = s * 0.025;
    const lead_off = s * 0.05; // offset from center to each lead
    const bend_y = top + s * 0.02;
    const edge = s * 0.42;

    // Canonical: +X is the anode direction; rotated by orientation.
    const d = rotDir(1, 0, o);
    const cathode_base = rl.Vector3{ .x = pos.x - d.x * lead_off, .y = body_bottom_y, .z = pos.z - d.z * lead_off };
    const cathode_bend = rl.Vector3{ .x = pos.x - d.x * lead_off, .y = bend_y, .z = pos.z - d.z * lead_off };
    const cathode_floor = rl.Vector3{ .x = pos.x - d.x * edge, .y = bend_y, .z = pos.z - d.z * edge };
    const anode_base = rl.Vector3{ .x = pos.x + d.x * lead_off, .y = body_bottom_y, .z = pos.z + d.z * lead_off };
    const anode_bend = rl.Vector3{ .x = pos.x + d.x * lead_off, .y = bend_y, .z = pos.z + d.z * lead_off };
    const anode_floor = rl.Vector3{ .x = pos.x + d.x * edge, .y = bend_y, .z = pos.z + d.z * edge };

    // --- External leads ---
    rl.drawCylinderEx(cathode_base, cathode_bend, lead_radius, lead_radius, 8, lead_color);
    rl.drawCylinderEx(cathode_bend, cathode_floor, lead_radius, lead_radius, 8, lead_color);
    rl.drawCylinderEx(anode_base, anode_bend, lead_radius, lead_radius, 8, lead_color);
    rl.drawCylinderEx(anode_bend, anode_floor, lead_radius, lead_radius, 8, lead_color);

    // --- Internal posts ---
    const anvil_top_y = body_bottom_y + s * 0.14;
    const anode_top_y = body_bottom_y + s * 0.26;
    const anvil_bot = rl.Vector3{ .x = cathode_base.x, .y = body_bottom_y, .z = cathode_base.z };
    const anvil_top = rl.Vector3{ .x = cathode_base.x, .y = anvil_top_y, .z = cathode_base.z };
    const apost_bot = rl.Vector3{ .x = anode_base.x, .y = body_bottom_y, .z = anode_base.z };
    const apost_top = rl.Vector3{ .x = anode_base.x, .y = anode_top_y, .z = anode_base.z };
    rl.drawCylinderEx(anvil_bot, anvil_top, post_radius, post_radius * 1.3, 8, lead_color);
    rl.drawCylinderEx(apost_bot, apost_top, post_radius, post_radius, 8, lead_color);

    // Die sitting in the anvil cup.
    rl.drawCube(.{ .x = anvil_top.x, .y = anvil_top_y + s * 0.01, .z = anvil_top.z }, s * 0.03, s * 0.03, s * 0.03, die_color);

    // Bond wire from die to anode post.
    rl.drawCylinderEx(
        .{ .x = anvil_top.x, .y = anvil_top_y + s * 0.02, .z = anvil_top.z },
        .{ .x = apost_top.x, .y = anode_top_y, .z = apost_top.z },
        s * 0.006,
        s * 0.006,
        6,
        lead_color,
    );

    // --- Translucent epoxy shell (last, so internals show through) ---
    rl.drawCylinderEx(
        .{ .x = pos.x, .y = body_bottom_y, .z = pos.z },
        .{ .x = pos.x, .y = body_top_y, .z = pos.z },
        body_radius,
        body_radius,
        16,
        epoxy_color,
    );
    rl.drawSphere(.{ .x = pos.x, .y = body_top_y, .z = pos.z }, body_radius, epoxy_color);

    // --- Glow when powered ---
    if (powered) {
        const dome_center = rl.Vector3{ .x = pos.x, .y = body_top_y, .z = pos.z };
        rl.drawSphere(dome_center, s * 0.38, rl.Color.init(255, 255, 160, 55));
        rl.drawSphere(dome_center, s * 0.55, rl.Color.init(255, 230, 100, 30));
        rl.drawSphere(dome_center, s * 0.80, rl.Color.init(255, 210, 60, 14));
        // soft light pool on the ground
        rl.drawCylinder(
            .{ .x = pos.x, .y = pos.y + world.BLOCK_SIZE * 0.01, .z = pos.z },
            s * 0.9,
            s * 0.9,
            0.002,
            24,
            rl.Color.init(255, 240, 130, 40),
        );
    }
}

pub fn name(self: PartType) [:0]const u8 {
    return switch (self) {
        .cell => "Cell (battery)",
        .wire_straight => "Wire (straight)",
        .wire_corner => "Wire (corner)",
        .led => "LED",
    };
}
