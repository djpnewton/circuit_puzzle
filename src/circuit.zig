/// Simple electricity-flow simulator.
///
/// Model:
///   - Parts snap to integer grid positions.
///   - Each part exposes two connection ports (directions in world space).
///   - Two adjacent parts are electrically connected when each faces the
///     other with a matching port.
///   - Wires and LEDs are conductors: current entering one port exits the
///     other.
///   - The battery (cell) is a source: no internal connection.  BFS starts
///     at the battery's + port and, if it reaches the battery's − port, the
///     circuit is closed.
///   - Every LED whose ports are traversed in a closed circuit is marked
///     powered.
///
/// Call `simulate` after any part is moved.  It writes `true` into
/// `powered[i]` for every powered LED at index i; all other entries are
/// set to `false`.
const rl = @import("raylib");
const world = @import("world.zig");
const parts = @import("parts.zig");

/// Maximum number of parts the map may hold (must match map.zig).
const MAX_PARTS = 8;

const GPos = struct { x: i32, z: i32 };

fn toGrid(pos: rl.Vector3) GPos {
    return .{
        .x = @intFromFloat(@round(pos.x / world.BLOCK_SIZE)),
        .z = @intFromFloat(@round(pos.z / world.BLOCK_SIZE)),
    };
}

fn dirDelta(d: parts.Dir) GPos {
    return switch (d) {
        .east => .{ .x = 1, .z = 0 },
        .west => .{ .x = -1, .z = 0 },
        .north => .{ .x = 0, .z = 1 },
        .south => .{ .x = 0, .z = -1 },
    };
}

/// BFS node: "current is exiting part `idx` through port `exit`."
const ExitNode = struct { idx: u8, exit: parts.Dir };

/// Simulate the circuit.
///
/// `part_arr`  : slice of Part values (kind + orientation), one per placed part.
/// `pos_arr`   : world positions matching `part_arr`.
/// `powered`   : output slice, same length; `powered[i]` is set to true iff
///               part i is an LED that receives current in a closed loop.
pub fn simulate(
    part_arr: []const parts.Part,
    pos_arr: []const rl.Vector3,
    powered: []bool,
) void {
    const n = part_arr.len;
    @memset(powered, false);

    // Grid positions for fast adjacency lookup.
    var grid: [MAX_PARTS]GPos = undefined;
    for (pos_arr[0..n], 0..) |p, i| grid[i] = toGrid(p);

    // Find the first battery.
    var batt: ?usize = null;
    for (part_arr[0..n], 0..) |p, i| {
        if (p.kind == .cell) {
            batt = i;
            break;
        }
    }
    const b = batt orelse return;

    const batt_plus = parts.batteryPlusDir(part_arr[b].orientation);
    const batt_minus = parts.opposite(batt_plus);

    // visited[i * 4 + dir_index] = current has arrived at part i from that dir.
    var visited = [_]bool{false} ** (MAX_PARTS * 4);

    // BFS queue.  Upper bound: each port visited at most once.
    var queue: [MAX_PARTS * 4]ExitNode = undefined;
    var qhead: usize = 0;
    var qtail: usize = 0;

    // Seed: current exits the battery through its + port.
    queue[qtail] = .{ .idx = @intCast(b), .exit = batt_plus };
    qtail += 1;

    var circuit_closed = false;

    while (qhead < qtail) {
        const cur = queue[qhead];
        qhead += 1;

        // Neighbour position in the exit direction.
        const my_gpos = grid[cur.idx];
        const delta = dirDelta(cur.exit);
        const nb_gpos = GPos{ .x = my_gpos.x + delta.x, .z = my_gpos.z + delta.z };

        // Find part at nb_gpos.
        var nb_idx: ?usize = null;
        for (grid[0..n], 0..) |gp, i| {
            if (gp.x == nb_gpos.x and gp.z == nb_gpos.z) {
                nb_idx = i;
                break;
            }
        }
        const nb = nb_idx orelse continue;

        // The direction current arrives at the neighbour.
        const arr_dir = parts.opposite(cur.exit);
        const nb_ports = parts.connectDirs(part_arr[nb].kind, part_arr[nb].orientation);

        // Neighbour must expose a port in the arrival direction.
        if (nb_ports[0] != arr_dir and nb_ports[1] != arr_dir) continue;

        // Avoid revisiting the same (part, arrival) state.
        const vk = nb * 4 + @as(usize, @intFromEnum(arr_dir));
        if (visited[vk]) continue;
        visited[vk] = true;

        // Did we reach the battery's − terminal? then circuit is closed.
        if (nb == b and arr_dir == batt_minus) {
            circuit_closed = true;
            continue; // don't propagate through the battery
        }
        // Don't propagate through any battery's internals.
        if (part_arr[nb].kind == .cell) continue;

        // Track LED visitation (will be cleared if circuit is not closed).
        if (part_arr[nb].kind == .led) powered[nb] = true;

        // Propagate: exit through the other port.
        for (nb_ports) |port_dir| {
            if (port_dir == arr_dir) continue;
            if (qtail < queue.len) {
                queue[qtail] = .{ .idx = @intCast(nb), .exit = port_dir };
                qtail += 1;
            }
        }
    }

    // LEDs only count if the loop was actually closed.
    if (!circuit_closed) @memset(powered, false);
}
