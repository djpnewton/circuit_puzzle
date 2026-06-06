const std = @import("std");

const rl = @import("raylib");

const map = @import("map.zig");
const camera = @import("camera.zig");
const gizmos = @import("gizmos.zig");
const world = @import("world.zig");
const input = @import("input.zig");

pub fn main(_: std.process.Init) !void {
    rl.setConfigFlags(rl.ConfigFlags{ .window_resizable = true, .msaa_4x_hint = true });
    rl.initWindow(1280, 720, "circuit puzzle");
    defer rl.closeWindow();

    var m = try map.Map.init();
    defer m.deinit();

    var cam: camera.Camera = .{};

    rl.setTargetFPS(60);
    rl.setExitKey(.null);

    // Index of the part currently being dragged with the left mouse button.
    var dragging: ?usize = null;
    // True when the current pointer-down began on empty space (camera gesture).
    // While set, part picking is suppressed so rotate/scroll can't grab parts.
    var camera_drag_active: bool = false;

    while (!rl.windowShouldClose()) {
        input.update();
        const raw_ray = rl.getScreenToWorldRay(input.getPointerPosition(), cam.rl_cam);
        // Nudge any zero direction component by a tiny epsilon to prevent
        // ±infinity in AABB slab intersection, which causes a raylib crash
        // when it casts the infinite normal to int.
        const eps = 1e-7;
        const ray = rl.Ray{
            .position = raw_ray.position,
            .direction = .{
                .x = if (@abs(raw_ray.direction.x) < eps) eps else raw_ray.direction.x,
                .y = if (@abs(raw_ray.direction.y) < eps) eps else raw_ray.direction.y,
                .z = if (@abs(raw_ray.direction.z) < eps) eps else raw_ray.direction.z,
            },
        };

        // --- part interaction -------------------------------------------
        // While a part is grabbed (or being grabbed) the left button drives
        // the move, so camera rotation is suppressed.
        var hovered_part: ?usize = null;
        var target_block: ?rl.Vector3 = null;
        var suppress_rotate = false;

        // Release clears both gesture states.
        if (input.isPointerReleased()) {
            camera_drag_active = false;
        }

        if (dragging) |idx| {
            suppress_rotate = true;
            target_block = m.world.raycast(ray);
            if (input.isPointerReleased()) {
                if (target_block) |bc| {
                    const candidate = rl.Vector3{
                        .x = bc.x,
                        .y = bc.y + world.BLOCK_SIZE * 0.5,
                        .z = bc.z,
                    };
                    if (!m.isOccupied(idx, candidate)) {
                        m.parts[idx].pos = candidate;
                    }
                }
                dragging = null;
            }
        } else if (!camera_drag_active) {
            // Only raycast parts when we're not already in a camera gesture.
            hovered_part = m.raycastPart(ray);
            if (hovered_part != null) {
                suppress_rotate = input.isPointerDown();
                if (input.isPointerPressed()) dragging = hovered_part;
            } else if (input.isPointerPressed()) {
                // Press on empty space - lock into camera mode for this gesture.
                camera_drag_active = true;
            }
        }

        cam.update(!suppress_rotate);

        m.updateCircuit();

        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.init(135, 206, 235, 255)); // sky blue
        // Vertical sky gradient: deeper blue overhead fading to a pale horizon
        rl.drawRectangleGradientV(0, 0, rl.getScreenWidth(), rl.getScreenHeight(), rl.Color.init(105, 160, 214, 255), rl.Color.init(170, 205, 232, 255));

        {
            rl.beginMode3D(cam.rl_cam);
            defer rl.endMode3D();
            m.draw(cam.rl_cam.position);
            if (dragging) |idx| {
                gizmos.drawPartHighlight(m.parts[idx].pos);
                if (target_block) |bc| {
                    const candidate = rl.Vector3{
                        .x = bc.x,
                        .y = bc.y + world.BLOCK_SIZE * 0.5,
                        .z = bc.z,
                    };
                    if (m.isOccupied(idx, candidate)) {
                        gizmos.drawPlacementTargetBlocked(bc);
                    } else {
                        gizmos.drawPlacementTarget(bc);
                    }
                }
            } else if (hovered_part) |idx| {
                gizmos.drawPartHighlight(m.parts[idx].pos);
            }
        }
    }
}
