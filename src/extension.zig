/// GDExtension entry point for Circuit Puzzle.
/// Registers/unregisters all Zig-defined Godot classes.
const godot = @import("godot");
const Registry = godot.extension.Registry;

const gamenode_module = @import("GameNode.zig");

pub fn register(r: *Registry) void {
    gamenode_module.register(r);
}

pub fn unregister(r: *Registry) void {
    gamenode_module.unregister(r);
}
