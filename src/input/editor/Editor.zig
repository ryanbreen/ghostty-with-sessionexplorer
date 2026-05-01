//! Prompt editor state machine.
//!
//! The editor lives on every Surface but stays in `.inactive` unless the
//! `prompt-editor` config is enabled AND OSC 133;B has fired (signaling
//! the shell finished printing its prompt and is ready for input). In
//! `.active` the editor owns the bottom N rows of the terminal viewport
//! and intercepts keystrokes; on commit it ships the buffer to the PTY
//! and returns to `.inactive`.
//!
//! Phase 1 scope: state machine + Buffer + skeleton of handleKey. Activation,
//! interception, and rendering are wired in subsequent commits.
const Editor = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Buffer = @import("Buffer.zig");

const log = std.log.scoped(.prompt_editor);

pub const State = enum {
    /// Editor is dormant. Keystrokes flow through to the PTY normally.
    inactive,

    /// Editor owns input. Keystrokes are routed to handleKey() and the
    /// editor renders the buffer contents in the bottom N rows of the
    /// viewport.
    active,
};

alloc: Allocator,
state: State = .inactive,
enabled: bool = false,
buffer: Buffer,

pub fn init(alloc: Allocator, enabled: bool) Editor {
    return .{
        .alloc = alloc,
        .enabled = enabled,
        .buffer = .init(alloc),
    };
}

pub fn deinit(self: *Editor) void {
    self.buffer.deinit();
}

/// Activate the editor in response to an OSC 133;B (end-of-prompt)
/// sequence. No-op if already active or if the feature is disabled.
pub fn activate(self: *Editor) void {
    if (!self.enabled) return;
    if (self.state == .active) return;
    self.buffer.clear();
    self.state = .active;
    log.debug("prompt editor activated", .{});
}

/// Deactivate the editor without committing. Called on OSC 133;C
/// (start-of-output), surface unfocus, or explicit cancel.
pub fn deactivate(self: *Editor) void {
    if (self.state == .inactive) return;
    self.state = .inactive;
    self.buffer.clear();
    log.debug("prompt editor deactivated", .{});
}

/// Returns true if the editor is currently intercepting input.
pub fn isActive(self: *const Editor) bool {
    return self.state == .active;
}

test "Editor: starts inactive when disabled" {
    const testing = std.testing;
    var ed: Editor = .init(testing.allocator, false);
    defer ed.deinit();

    try testing.expect(!ed.isActive());
    ed.activate();
    try testing.expect(!ed.isActive());
}

test "Editor: activate/deactivate when enabled" {
    const testing = std.testing;
    var ed: Editor = .init(testing.allocator, true);
    defer ed.deinit();

    try testing.expect(!ed.isActive());
    ed.activate();
    try testing.expect(ed.isActive());
    ed.deactivate();
    try testing.expect(!ed.isActive());
}

test "Editor: deactivate clears buffer" {
    const testing = std.testing;
    var ed: Editor = .init(testing.allocator, true);
    defer ed.deinit();

    ed.activate();
    try ed.buffer.insertAt(0, "hello");
    ed.deactivate();
    try testing.expectEqual(@as(usize, 0), ed.buffer.len());
}
