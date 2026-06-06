/// Unified pointer input abstraction for mouse and touch.
/// Call `update()` once at the top of your game loop each frame.
/// All other functions return cached values from that frame.
const rl = @import("raylib");

var prev_touch_pos: rl.Vector2 = .{ .x = 0, .y = 0 };
var prev_pinch_dist: f32 = 0;
var touch_count_last: i32 = 0;

var cached_down: bool = false;
var cached_pressed: bool = false;
var cached_released: bool = false;
var cached_delta: rl.Vector2 = .{ .x = 0, .y = 0 };
var cached_position: rl.Vector2 = .{ .x = 0, .y = 0 };
var cached_scroll: f32 = 0;

/// Must be called once per frame before reading any other functions.
pub fn update() void {
    const touch_count = rl.getTouchPointCount();
    const single_touch = touch_count == 1;

    // Touch is checked before mouse: on many platforms (web, Android) a touch
    // also fires isMouseButtonDown, whose delta includes the cursor "teleport"
    // to the touch position - causing a large unwanted rotation jump.
    if (single_touch) {
        const pos = rl.getTouchPosition(0);
        const is_new_touch = touch_count_last == 0;
        cached_pressed = is_new_touch;
        // A transition 2->1 is not a fresh press (finger was already down).
        cached_released = false;
        cached_down = true;
        // Zero delta on the first frame to avoid a position-jump.
        cached_delta = if (!is_new_touch)
            .{ .x = pos.x - prev_touch_pos.x, .y = pos.y - prev_touch_pos.y }
        else
            .{ .x = 0, .y = 0 };
        cached_position = pos;
        prev_touch_pos = pos;
        cached_scroll = 0;
        prev_pinch_dist = 0;
    } else if (touch_count >= 2) {
        // Two-finger pinch/zoom - not a pointer drag.
        // Emit a release on the frame we go from 1 finger to 2 so that any
        // in-progress part drag or camera gesture is cleanly cancelled.
        cached_pressed = false;
        cached_released = touch_count_last == 1;
        cached_down = false;
        cached_delta = .{ .x = 0, .y = 0 };
        cached_position = rl.getTouchPosition(0);
        // Pinch distance > scroll-equivalent.
        const p0 = rl.getTouchPosition(0);
        const p1 = rl.getTouchPosition(1);
        const dx = p1.x - p0.x;
        const dy = p1.y - p0.y;
        const dist = @sqrt(dx * dx + dy * dy);
        cached_scroll = if (touch_count_last >= 2 and prev_pinch_dist > 0)
            (dist - prev_pinch_dist) * 0.05
        else
            0;
        prev_pinch_dist = dist;
    } else {
        // No active touch - use mouse.
        const mouse_down = rl.isMouseButtonDown(.left);
        cached_down = mouse_down;
        cached_pressed = rl.isMouseButtonPressed(.left);
        // Also catch touch-lift on platforms that don't fire mouse-released.
        cached_released = rl.isMouseButtonReleased(.left) or touch_count_last == 1;
        cached_position = rl.getMousePosition();
        cached_delta = if (mouse_down) rl.getMouseDelta() else .{ .x = 0, .y = 0 };
        cached_scroll = rl.getMouseWheelMove();
        prev_pinch_dist = 0;
    }

    touch_count_last = touch_count;
}

/// True while the primary pointer is held (left mouse button or a single touch).
pub fn isPointerDown() bool {
    return cached_down;
}

/// True on the frame the primary pointer was first pressed.
pub fn isPointerPressed() bool {
    return cached_pressed;
}

/// True on the frame the primary pointer was released.
pub fn isPointerReleased() bool {
    return cached_released;
}

/// Per-frame movement delta of the primary pointer.
pub fn getPointerDelta() rl.Vector2 {
    return cached_delta;
}

/// Current screen-space position of the primary pointer.
pub fn getPointerPosition() rl.Vector2 {
    return cached_position;
}

/// Scroll amount this frame: mouse wheel units or pinch-zoom equivalent.
pub fn getScrollDelta() f32 {
    return cached_scroll;
}
