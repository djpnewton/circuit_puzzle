const std = @import("std");
const rl = @import("raylib");
const input = @import("input.zig");

/// A circular rotate button that lives in 2D screen space.
/// Call `update()` once per frame; it returns whether the button was clicked.
/// Call `draw()` to render it (outside any beginMode3D block).
pub const RotateButton = struct {
    center: rl.Vector2,
    radius: f32,

    /// Process input for this frame. Returns true on the frame the button is clicked.
    pub fn update(self: *const RotateButton) bool {
        if (!input.isPointerPressed()) return false;
        const mp = input.getPointerPosition();
        const dx = mp.x - self.center.x;
        const dy = mp.y - self.center.y;
        return dx * dx + dy * dy <= self.radius * self.radius;
    }

    /// True when the pointer is currently over the button.
    pub fn isHovered(self: *const RotateButton) bool {
        const mp = input.getPointerPosition();
        const dx = mp.x - self.center.x;
        const dy = mp.y - self.center.y;
        return dx * dx + dy * dy <= self.radius * self.radius;
    }

    pub fn draw(self: *const RotateButton) void {
        const hovered = self.isHovered();
        const center = self.center;
        const radius = self.radius;

        // Background circle.
        const bg = if (hovered)
            rl.Color.init(80, 80, 110, 235)
        else
            rl.Color.init(35, 35, 50, 210);
        rl.drawCircleV(center, radius, bg);

        // Ring arc, almost a full circle (280° sweep)
        const ring_inner = radius * 0.36;
        const ring_outer = radius * 0.70;
        rl.drawRing(center, ring_inner, ring_outer, 40, 320, 28, rl.Color.white);

        // Arrowhead at the start of the arc (40°), pointing in the clockwise direction.
        const end_rad = 40.0 * std.math.pi / 180.0;
        const mid_r = (ring_inner + ring_outer) * 0.5;
        const ax = center.x + mid_r * @cos(end_rad);
        const ay = center.y + mid_r * @sin(end_rad);

        // CW tangent in screen coords (Y-down): (sin θ, -cos θ).
        const tang_x = @sin(end_rad);
        const tang_y = -@cos(end_rad);
        // Radially outward direction.
        const rad_x = @cos(end_rad);
        const rad_y = @sin(end_rad);

        const hw = (ring_outer - ring_inner) * 0.85;
        const fwd = radius * 0.45;

        const tip = rl.Vector2{ .x = ax + tang_x * fwd, .y = ay + tang_y * fwd };
        const base_a = rl.Vector2{ .x = ax + rad_x * hw, .y = ay + rad_y * hw };
        const base_b = rl.Vector2{ .x = ax - rad_x * hw, .y = ay - rad_y * hw };
        // CCW winding on screen (Y-down) -> visible fill.
        rl.drawTriangle(tip, base_b, base_a, rl.Color.white);
    }
};
