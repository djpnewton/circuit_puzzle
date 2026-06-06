const rl = @import("raylib");

const world = @import("world.zig");

/// Highlight a part resting on the terrain surface.
/// `pos.y` is the terrain top surface the part sits on.
/// Must be called inside a beginMode3D / endMode3D block.
pub fn drawPartHighlight(pos: rl.Vector3) void {
    const s = world.BLOCK_SIZE;
    const center = rl.Vector3{ .x = pos.x, .y = pos.y + s * 0.5, .z = pos.z };
    const col = rl.Color.init(255, 235, 90, 255);
    rl.drawCubeWires(center, s * 1.02, s * 1.02, s * 1.02, col);
}

/// Same as drawPlacementTarget but tinted red to indicate an occupied cell.
pub fn drawPlacementTargetBlocked(block_center: rl.Vector3) void {
    const s = world.BLOCK_SIZE;
    const center = rl.Vector3{ .x = block_center.x, .y = block_center.y + s, .z = block_center.z };
    const col = rl.Color.init(230, 80, 80, 255);
    rl.drawCubeWires(center, s * 1.02, s * 1.02, s * 1.02, col);
}

/// Highlight the cell above a terrain block where a dragged part will land.
/// `block_center` is the center of the terrain block under the cursor.
/// Must be called inside a beginMode3D / endMode3D block.
pub fn drawPlacementTarget(block_center: rl.Vector3) void {
    const s = world.BLOCK_SIZE;
    const center = rl.Vector3{ .x = block_center.x, .y = block_center.y + s, .z = block_center.z };
    const col = rl.Color.init(120, 230, 120, 255);
    rl.drawCubeWires(center, s * 1.02, s * 1.02, s * 1.02, col);
}

