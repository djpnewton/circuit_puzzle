/// Plain 3D vector used throughout the codebase.
pub const Vec3 = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

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

/// Rotate (dx, dz) by `o` steps of 90° CW (looking down the +Y axis).
/// CW 90°: (x, z) -> (z, -x)
pub fn rotDir(dx: f32, dz: f32, o: Orientation) struct { x: f32, z: f32 } {
    return switch (o) {
        .rot0 => .{ .x = dx, .z = dz },
        .rot90 => .{ .x = dz, .z = -dx },
        .rot180 => .{ .x = -dx, .z = -dz },
        .rot270 => .{ .x = -dz, .z = dx },
    };
}

pub const Part = struct {
    kind: PartType,
    orientation: Orientation = .rot0,

    pub fn rotateCW(self: *Part) void {
        self.orientation = switch (self.orientation) {
            .rot0 => .rot90,
            .rot90 => .rot180,
            .rot180 => .rot270,
            .rot270 => .rot0,
        };
    }
};

pub fn name(self: PartType) []const u8 {
    return switch (self) {
        .cell => "Cell (battery)",
        .wire_straight => "Wire (straight)",
        .wire_corner => "Wire (corner)",
        .led => "LED",
    };
}

pub fn description(self: PartType) []const u8 {
    return switch (self) {
        .cell => "Just like an AA battery, provides electrical current. Current flows from + to - terminal. Provides 1.5 volts of potential difference.",
        .wire_straight, .wire_corner => "Conducts current using a low resistance metal like copper. Infinite conductivity in this simulation, so no voltage drop across wires.",
        .led => "Light Emitting Diode. Lights up when current flows through it in the correct direction. Current must enter the anode (A) and exit the cathode (K). A diode is a one-way valve for current. A red LED requires about 1.8 volts to activate.",
    };
}
