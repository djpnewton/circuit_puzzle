/// Simple electricity-flow simulator.
///
/// Model:
///   - Parts snap to integer grid positions.
///   - Each part exposes two connection ports (directions in world space).
///   - Two adjacent parts are electrically connected when each faces the
///     other with a matching port.
///   - Wires and LEDs are conductors: current entering one port exits the other.
///   - The battery (cell) is a source: no internal connection. BFS starts at
///     the battery's + port and, if it reaches the battery's − port, the
///     circuit is closed.
///   - Every LED whose ports are traversed in a closed circuit is marked powered.
const parts = @import("parts.zig");

/// Maximum number of parts the map may hold (must match map.zig).
const MAX_PARTS = 8;

/// Voltage supplied by a single battery cell.
pub const CELL_VOLTAGE: f32 = 1.5;
/// Forward voltage drop across a red LED.
pub const LED_FORWARD_VOLTAGE: f32 = 1.8;

/// Per-part voltage stats written by `simulate`.
pub const ComponentStats = struct {
    volts_in: f32 = 0,
    voltage_drop: f32 = 0,
};

const GPos = struct { x: i32, z: i32 };

fn toGrid(pos: parts.Vec3) GPos {
    return .{
        .x = @intFromFloat(@round(pos.x)),
        .z = @intFromFloat(@round(pos.z)),
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

/// BFS node: "current is exiting part `idx` through port `exit` at `voltage` volts."
const ExitNode = struct { idx: u8, exit: parts.Dir, voltage: f32 };

/// Simulate the circuit.
///
/// `part_arr`  : slice of Part values (kind + orientation), one per placed part.
/// `pos_arr`   : world positions matching `part_arr`.
/// `powered`   : output slice, same length; `powered[i]` is set to true iff
///               part i is an LED that receives current in a closed loop.
pub fn simulate(
    part_arr: []const parts.Part,
    pos_arr: []const parts.Vec3,
    powered: []bool,
    stats: []ComponentStats,
) void {
    const n = part_arr.len;
    @memset(powered, false);
    for (stats[0..n]) |*s| s.* = .{};

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

    // Cell always show its EMF regardless of circuit state.
    for (part_arr[0..n], 0..) |p, i| {
        if (p.kind == .cell) stats[i] = .{ .volts_in = CELL_VOLTAGE, .voltage_drop = 0 };
    }

    // max_volt[i * 4 + dir] = highest voltage seen arriving at part i from dir.
    // A node is only re-processed if a higher voltage path reaches it.
    var max_volt = [_]f32{0.0} ** (MAX_PARTS * 4);

    // BFS queue.  Upper bound: each port visited at most once.
    var queue: [MAX_PARTS * 4]ExitNode = undefined;
    var qhead: usize = 0;
    var qtail: usize = 0;

    // Seed: current exits the battery through its + port at full cell voltage.
    queue[qtail] = .{ .idx = @intCast(b), .exit = batt_plus, .voltage = CELL_VOLTAGE };
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

        // Skip if we've already arrived here with equal or higher voltage.
        const vk = nb * 4 + @as(usize, @intFromEnum(arr_dir));
        if (cur.voltage <= max_volt[vk]) continue;
        max_volt[vk] = cur.voltage;

        // Did we reach the primary battery's − terminal? then circuit is closed.
        if (nb == b and arr_dir == batt_minus) {
            circuit_closed = true;
            continue; // don't propagate through the battery
        }
        // A secondary cell in series: current must enter its − terminal.
        // If it does, boost voltage by CELL_VOLTAGE and continue from its + terminal.
        // Arriving at the + terminal means reverse polarity so block.
        if (part_arr[nb].kind == .cell) {
            const cell_plus = parts.batteryPlusDir(part_arr[nb].orientation);
            const cell_minus = parts.opposite(cell_plus);
            if (arr_dir != cell_minus) continue; // reverse, block
            const v_boosted = cur.voltage + CELL_VOLTAGE;
            if (qtail < queue.len) {
                queue[qtail] = .{ .idx = @intCast(nb), .exit = cell_plus, .voltage = v_boosted };
                qtail += 1;
            }
            continue;
        }

        // Record voltage stats for this component.
        const v_drop: f32 = switch (part_arr[nb].kind) {
            .led => LED_FORWARD_VOLTAGE,
            else => 0.0,
        };
        stats[nb].volts_in = cur.voltage;
        stats[nb].voltage_drop = v_drop;
        const v_out = @max(0.0, cur.voltage - v_drop);

        // LEDs are diodes: current must enter the anode (port[0]) AND
        // there must be sufficient forward voltage to overcome the barrier.
        // Either condition failing breaks the circuit at this LED.
        if (part_arr[nb].kind == .led) {
            if (arr_dir != nb_ports[0]) continue;
            if (cur.voltage < LED_FORWARD_VOLTAGE) continue;
            powered[nb] = true;
        }

        // Propagate: exit through the other port.
        for (nb_ports) |port_dir| {
            if (port_dir == arr_dir) continue;
            if (qtail < queue.len) {
                queue[qtail] = .{ .idx = @intCast(nb), .exit = port_dir, .voltage = v_out };
                qtail += 1;
            }
        }
    }

    // LEDs and voltage stats (except cell EMF) only count if loop is closed.
    if (!circuit_closed) {
        @memset(powered, false);
        for (stats[0..n], part_arr[0..n]) |*s, p| {
            if (p.kind != .cell) s.* = .{};
        }
    }
}
