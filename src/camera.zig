const std = @import("std");
const rl = @import("raylib");
const input = @import("input.zig");

pub const Camera = struct {
    target: rl.Vector3 = .{ .x = 2.0, .y = 0.5, .z = 2.0 },
    azimuth: f32 = std.math.pi, // horizontal angle around Y
    pitch: f32 = 0.68, // elevation angle (radians)
    dist: f32 = 16.0, // distance from target
    rl_cam: rl.Camera3D = .{
        .position = .{ .x = 2.0, .y = 5.0, .z = -5 },
        .target = .{ .x = 2.0, .y = 0.5, .z = 2.0 },
        .up = .{ .x = 0.0, .y = 1.0, .z = 0.0 },
        .fovy = 60.0,
        .projection = .perspective,
    },

    pub fn update(self: *Camera, allow_mouse_rotate: bool) void {
        const dt = rl.getFrameTime();

        // Pan: WASD / arrow keys along camera XZ forward/right.
        const pan_speed: f32 = 10.0 * dt;
        const fwd_x = -@sin(self.azimuth);
        const fwd_z = -@cos(self.azimuth);
        const rgt_x = @cos(self.azimuth);
        const rgt_z = -@sin(self.azimuth);

        if (rl.isKeyDown(.w) or rl.isKeyDown(.up)) {
            self.target.x += fwd_x * pan_speed;
            self.target.z += fwd_z * pan_speed;
        }
        if (rl.isKeyDown(.s) or rl.isKeyDown(.down)) {
            self.target.x -= fwd_x * pan_speed;
            self.target.z -= fwd_z * pan_speed;
        }
        if (rl.isKeyDown(.a) or rl.isKeyDown(.left)) {
            self.target.x -= rgt_x * pan_speed;
            self.target.z -= rgt_z * pan_speed;
        }
        if (rl.isKeyDown(.d) or rl.isKeyDown(.right)) {
            self.target.x += rgt_x * pan_speed;
            self.target.z += rgt_z * pan_speed;
        }

        // Rotate: Q/E keys or drag outside of map.
        const rot_speed: f32 = 1.5 * dt;
        if (rl.isKeyDown(.q)) self.azimuth -= rot_speed;
        if (rl.isKeyDown(.e)) self.azimuth += rot_speed;

        if (allow_mouse_rotate and input.isPointerDown()) {
            const delta = input.getPointerDelta();
            self.azimuth += delta.x * 0.005;
            self.pitch -= delta.y * 0.005;
            self.pitch = @min(@max(self.pitch, 0.1), std.math.pi * 0.45);
        }

        // Zoom: scroll wheel or pinch.
        self.dist -= input.getScrollDelta() * 2.0;
        self.dist = @min(@max(self.dist, 4.0), 80.0);

        // Reconstruct position from spherical coords.
        const cos_p = @cos(self.pitch);
        self.rl_cam.position = .{
            .x = self.target.x + self.dist * cos_p * @sin(self.azimuth),
            .y = self.target.y + self.dist * @sin(self.pitch),
            .z = self.target.z + self.dist * cos_p * @cos(self.azimuth),
        };
        self.rl_cam.target = self.target;
    }
};
