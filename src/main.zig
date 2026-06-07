const std = @import("std");

const rl = @import("raylib");

const map = @import("map.zig");
const camera = @import("camera.zig");
const gizmos = @import("gizmos.zig");
const world = @import("world.zig");
const input = @import("input.zig");
const ui = @import("ui.zig");

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
    // Index of the currently selected part (persists after releasing a drag).
    var selected_part: ?usize = null;
    // Whether the part-info modal is currently visible.
    var show_info_modal: bool = false;

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

        // --- buttons & part interaction -------------------------------------------
        const btn_y = @as(f32, @floatFromInt(rl.getScreenHeight())) - 60.0;
        const info_btn = ui.InfoButton{ .center = .{ .x = 60.0, .y = btn_y }, .radius = 28.0 };
        const rotate_btn = ui.RotateButton{ .center = .{ .x = 128.0, .y = btn_y }, .radius = 28.0 };

        var hovered_part: ?usize = null;
        var target_block: ?rl.Vector3 = null;
        var ui_btn_clicked = false;
        var suppress_rotate = false;

        if (show_info_modal) {
            if (ui.InfoModal.update()) show_info_modal = false;
            suppress_rotate = true;
        } else {
            // Release clears both gesture states.
            if (input.isPointerReleased()) {
                camera_drag_active = false;
            }

            if (selected_part) |idx| {
                if (info_btn.update()) {
                    ui_btn_clicked = true;
                    show_info_modal = true;
                } else if (rotate_btn.update()) {
                    ui_btn_clicked = true;
                    m.parts[idx].part.rotateCW();
                    m.updateCircuit();
                }
            }

            // --- part interaction ------------------------------------------
            // While a part is grabbed the left button drives the move,
            // so camera rotation is suppressed.
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
            } else if (!camera_drag_active and !ui_btn_clicked) {
                // Only raycast parts when not in a camera gesture or UI click.
                hovered_part = m.raycastPart(ray);
                if (hovered_part != null) {
                    suppress_rotate = input.isPointerDown();
                    if (input.isPointerPressed()) {
                        dragging = hovered_part;
                        selected_part = hovered_part;
                    }
                } else if (input.isPointerPressed()) {
                    // Press on empty space - lock into camera mode for this gesture.
                    camera_drag_active = true;
                    selected_part = null;
                }
            }
        } // end !show_info_modal

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
            // Persistent selection outline
            if (selected_part) |idx| {
                gizmos.drawSelectedHighlight(m.parts[idx].pos);
            }
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

        // --- 2D UI -------------------------------------------------------
        if (selected_part != null) {
            info_btn.draw();
            rotate_btn.draw();
        }
        if (show_info_modal) {
            if (selected_part) |idx| {
                ui.InfoModal.draw(m.parts[idx].part.kind);
            }
        }
    }
}
