const std = @import("std");
const rl = @import("raylib");
const world = @import("world.zig");
const parts = @import("parts.zig");
const circuit = @import("circuit.zig");

pub const PartInstance = struct {
    part: parts.Part,
    pos: rl.Vector3,

    pub fn draw(self: *const PartInstance, powered: bool) void {
        self.part.draw(self.pos, powered);
    }
};

pub const Map = struct {
    world: world.World,
    parts: [8]PartInstance,
    powered: [8]bool = [_]bool{false} ** 8,
    stats: [8]circuit.ComponentStats = [_]circuit.ComponentStats{.{}} ** 8,

    pub fn init() !Map {
        const w = try world.World.init();
        const parts_arr = [_]PartInstance{
            .{ .part = .{ .kind = .wire_corner, .orientation = .rot90 }, .pos = .{ .x = 1.0, .y = 0.5, .z = 1.0 } },
            .{ .part = .{ .kind = .wire_corner, .orientation = .rot0 }, .pos = .{ .x = 3.0, .y = 0.5, .z = 1.0 } },
            .{ .part = .{ .kind = .wire_corner, .orientation = .rot270 }, .pos = .{ .x = 3.0, .y = 0.5, .z = 3.0 } },
            .{ .part = .{ .kind = .wire_corner, .orientation = .rot180 }, .pos = .{ .x = 1.0, .y = 0.5, .z = 3.0 } },
            .{ .part = .{ .kind = .cell }, .pos = .{ .x = 0.0, .y = 0.5, .z = 0.0 } },
            .{ .part = .{ .kind = .wire_straight, .orientation = .rot90 }, .pos = .{ .x = 2.0, .y = 0.5, .z = 0.0 } },
            .{ .part = .{ .kind = .cell, .orientation = .rot0 }, .pos = .{ .x = 4.0, .y = 0.5, .z = 2.0 } },
            .{ .part = .{ .kind = .led }, .pos = .{ .x = 0.0, .y = 0.5, .z = 4.0 } },
        };

        return Map{
            .world = w,
            .parts = parts_arr,
        };
    }

    pub fn deinit(self: *Map) void {
        self.world.deinit();
    }

    /// Re-run the circuit simulation after any part is moved.
    pub fn updateCircuit(self: *Map) void {
        var part_arr: [8]parts.Part = undefined;
        var pos_arr: [8]rl.Vector3 = undefined;
        for (self.parts, 0..) |inst, i| {
            part_arr[i] = inst.part;
            pos_arr[i] = inst.pos;
        }
        circuit.simulate(&part_arr, &pos_arr, &self.powered, &self.stats);
    }

    /// Returns true if any part other than `ignore_idx` occupies `pos`
    /// (matches on grid cell: same x and z, within half a block).
    pub fn isOccupied(self: *const Map, ignore_idx: usize, pos: rl.Vector3) bool {
        for (self.parts, 0..) |inst, i| {
            if (i == ignore_idx) continue;
            if (@abs(inst.pos.x - pos.x) < 0.5 and @abs(inst.pos.z - pos.z) < 0.5) return true;
        }
        return false;
    }

    /// Index of the part whose bounding box the ray hits first, or null.
    pub fn raycastPart(self: *const Map, ray: rl.Ray) ?usize {
        var best_dist: f32 = std.math.floatMax(f32);
        var result: ?usize = null;
        for (&self.parts, 0..) |*inst, i| {
            const col = rl.getRayCollisionBox(ray, parts.partBounds(inst.pos));
            if (col.hit and col.distance < best_dist) {
                best_dist = col.distance;
                result = i;
            }
        }
        return result;
    }

    pub fn draw(self: *const Map, view_pos: rl.Vector3) void {
        self.world.draw(view_pos);
        for (self.parts, 0..) |part, i| {
            part.draw(self.powered[i]);
        }
    }

    /// Debug: snap all parts to the known solution positions/orientations.
    pub fn debugSolve(self: *Map) void {
        const y = self.parts[0].pos.y; // keep existing terrain height
        self.parts[0] = .{ .part = .{ .kind = .wire_corner, .orientation = .rot90 }, .pos = .{ .x = 0.0, .y = y, .z = 0.0 } };
        self.parts[1] = .{ .part = .{ .kind = .wire_corner, .orientation = .rot0 }, .pos = .{ .x = 2.0, .y = y, .z = 0.0 } };
        self.parts[2] = .{ .part = .{ .kind = .wire_corner, .orientation = .rot270 }, .pos = .{ .x = 2.0, .y = y, .z = 2.0 } };
        self.parts[3] = .{ .part = .{ .kind = .wire_corner, .orientation = .rot180 }, .pos = .{ .x = 0.0, .y = y, .z = 2.0 } };
        self.parts[4] = .{ .part = .{ .kind = .cell, .orientation = .rot270 }, .pos = .{ .x = 0.0, .y = y, .z = 1.0 } };
        self.parts[5] = .{ .part = .{ .kind = .wire_straight, .orientation = .rot0 }, .pos = .{ .x = 1.0, .y = y, .z = 0.0 } };
        self.parts[6] = .{ .part = .{ .kind = .cell, .orientation = .rot0 }, .pos = .{ .x = 1.0, .y = y, .z = 2.0 } };
        self.parts[7] = .{ .part = .{ .kind = .led, .orientation = .rot270 }, .pos = .{ .x = 2.0, .y = y, .z = 1.0 } };
        self.updateCircuit();
    }
};
