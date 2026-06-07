const std = @import("std");
const rl = @import("raylib");
const input = @import("input.zig");
const parts = @import("parts.zig");

/// MultiLine text layout with automatic word wrapping.
/// Breaks lines at word boundaries when text exceeds maxWidth.
pub const MultiLine = struct {
    text: [:0]const u8,
    fontSize: i32,
    pos: rl.Vector2,
    maxWidth: i32,
    color: rl.Color = rl.Color.white,
    lineHeight: i32 = 24,

    pub fn draw(self: *const MultiLine) void {
        var line_buf: [512]u8 = undefined;
        var line_y: f32 = self.pos.y;
        var line_len: usize = 0;
        var i: usize = 0;

        while (i < self.text.len) {
            // Skip spaces
            while (i < self.text.len and self.text[i] == ' ') i += 1;
            if (i >= self.text.len) break;

            // Handle explicit newline
            if (self.text[i] == '\n') {
                if (line_len > 0) {
                    self.drawLine(&line_buf, line_len, line_y);
                    line_y += @as(f32, @floatFromInt(self.lineHeight));
                    line_len = 0;
                }
                i += 1;
                continue;
            }

            // Extract next word
            const word_start = i;
            while (i < self.text.len and self.text[i] != ' ' and self.text[i] != '\n') i += 1;
            const word = self.text[word_start..i];

            // Test if word fits on current line
            if (line_len > 0) {
                // Simulate adding word with space
                @memcpy(line_buf[line_len .. line_len + 1], " ");
                @memcpy(line_buf[line_len + 1 .. line_len + 1 + word.len], word);
                line_buf[line_len + 1 + word.len] = 0;
                const test_width = rl.measureText(line_buf[0 .. line_len + 1 + word.len :0], self.fontSize);

                if (test_width > self.maxWidth) {
                    // Word doesn't fit; draw current line and start new one
                    self.drawLine(&line_buf, line_len, line_y);
                    line_y += @as(f32, @floatFromInt(self.lineHeight));
                    line_len = 0;
                }
            }

            // Add word to current line
            if (line_len > 0) {
                line_buf[line_len] = ' ';
                line_len += 1;
            }
            @memcpy(line_buf[line_len .. line_len + word.len], word);
            line_len += word.len;
        }

        // Draw final line
        if (line_len > 0) {
            self.drawLine(&line_buf, line_len, line_y);
        }
    }

    fn drawLine(self: *const MultiLine, buf: *[512]u8, len: usize, y: f32) void {
        buf[len] = 0;
        const line = buf[0..len :0];
        rl.drawText(line, @intFromFloat(self.pos.x), @intFromFloat(y), self.fontSize, self.color);
    }
};

/// A circular info button that opens the part info modal.
/// Call `update()` once per frame; it returns true when clicked.
/// Call `draw()` to render it (outside any beginMode3D block).
pub const InfoButton = struct {
    center: rl.Vector2,
    radius: f32,

    pub fn update(self: *const InfoButton) bool {
        if (!input.isPointerPressed()) return false;
        const mp = input.getPointerPosition();
        const dx = mp.x - self.center.x;
        const dy = mp.y - self.center.y;
        return dx * dx + dy * dy <= self.radius * self.radius;
    }

    pub fn isHovered(self: *const InfoButton) bool {
        const mp = input.getPointerPosition();
        const dx = mp.x - self.center.x;
        const dy = mp.y - self.center.y;
        return dx * dx + dy * dy <= self.radius * self.radius;
    }

    pub fn draw(self: *const InfoButton) void {
        const hovered = self.isHovered();
        const bg = if (hovered)
            rl.Color.init(80, 80, 110, 235)
        else
            rl.Color.init(35, 35, 50, 210);
        rl.drawCircleV(self.center, self.radius, bg);

        // Italic "i" label
        const font_size: i32 = @intFromFloat(self.radius * 2);
        const text = "i";
        const text_w = rl.measureText(text, font_size);
        rl.drawText(
            text,
            @as(i32, @intFromFloat(self.center.x)) - @divTrunc(text_w, 2),
            @as(i32, @intFromFloat(self.center.y)) - @divTrunc(font_size, 2),
            font_size,
            rl.Color.white,
        );
    }
};

/// Modal dialog that displays info about the selected part.
/// `update()` returns true when the modal should be dismissed.
/// `draw()` renders the overlay and box; call after all 3D drawing.
pub const InfoModal = struct {
    const BOX_W: i32 = 380;
    const BOX_H: i32 = 200;

    pub fn update() bool {
        if (rl.isKeyPressed(.escape)) return true;
        if (input.isPointerPressed()) return true;
        return false;
    }

    pub fn draw(kind: parts.PartType) void {
        const sw = rl.getScreenWidth();
        const sh = rl.getScreenHeight();

        // Dim overlay
        rl.drawRectangle(0, 0, sw, sh, rl.Color.init(0, 0, 0, 120));

        const bx = @divTrunc(sw - BOX_W, 2);
        const by = @divTrunc(sh - BOX_H, 2);

        // Box background + border
        rl.drawRectangleRounded(
            .{ .x = @floatFromInt(bx), .y = @floatFromInt(by), .width = @floatFromInt(BOX_W), .height = @floatFromInt(BOX_H) },
            0.08,
            8,
            rl.Color.init(30, 30, 45, 245),
        );
        rl.drawRectangleLines(bx, by, BOX_W, BOX_H, rl.Color.init(100, 100, 140, 255));

        // Title
        const title: [:0]const u8 = switch (kind) {
            .cell => "Battery Cell",
            .wire_straight => "Straight Wire",
            .wire_corner => "Corner Wire",
            .led => "LED",
        };
        const title_fs: i32 = 22;
        const title_w = rl.measureText(title, title_fs);
        rl.drawText(title, bx + @divTrunc(BOX_W - title_w, 2), by + 20, title_fs, rl.Color.white);

        // Divider
        rl.drawLine(bx + 20, by + 56, bx + BOX_W - 20, by + 56, rl.Color.init(100, 100, 140, 200));

        // Description text using MultiLine for automatic wrapping
        const desc: [:0]const u8 = switch (kind) {
            .cell => "Just like an AA battery, provides electrical current. Current flows from + to - terminal. Provides 1.5 volts of potential difference.",
            .wire_straight, .wire_corner => "Conducts current using a low resistance metal like copper. Infinite conductivity in this simulation, so no voltage drop across wires.",
            .led => "Light Emitting Diode. Lights up when current flows through it in the correct direction. Current must enter the anode (A) and exit the cathode (K). A diode is a one-way valve for current. A red LED requires about 1.8 volts to activate.",
        };

        const ml = MultiLine{
            .text = desc,
            .fontSize = 16,
            .pos = .{ .x = @as(f32, @floatFromInt(bx + 20)), .y = @as(f32, @floatFromInt(by + 72)) },
            .maxWidth = BOX_W - 40,
            .color = rl.Color.init(200, 200, 220, 255),
            .lineHeight = 22,
        };
        ml.draw();
    }
};

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
