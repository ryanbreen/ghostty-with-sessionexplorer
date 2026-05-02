//! Prompt editor activation hook.
//!
//! This struct is the bridge between libghostty (the renderer's
//! auto-activation, driven by OSC 133 semantic_content) and the apprt
//! layer's native editor view (e.g. macOS NSTextView). It owns NO
//! editing state — buffer, cursor, selection, scroll, and rendering all
//! live in the apprt's native text view. Here we just track active /
//! inactive and fire a state-change callback on every transition.
const Editor = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.prompt_editor);

pub const State = enum {
    /// Editor is dormant. Apprt's native editor view is hidden.
    inactive,

    /// Editor owns input. Apprt's native view is visible and accepts
    /// keystrokes; libghostty does not see them.
    active,
};

alloc: Allocator,
state: State = .inactive,
enabled: bool = false,

/// Optional state-change callback. Invoked on every activate/deactivate
/// transition. The apprt layer (e.g. macOS) uses this to show/hide the
/// native CoreText prompt-editor view. The callback may fire on the
/// renderer thread; consumers must marshal to their main thread.
state_changed_cb: ?*const fn (?*anyopaque, bool, u32) callconv(.c) void = null,
state_changed_userdata: ?*anyopaque = null,

pub fn init(alloc: Allocator, enabled: bool) Editor {
    return .{
        .alloc = alloc,
        .enabled = enabled,
    };
}

pub fn deinit(_: *Editor) void {}

/// Activate the editor in response to an OSC 133;B (end-of-prompt)
/// sequence. No-op if already active or if the feature is disabled.
pub fn activate(self: *Editor) void {
    if (!self.enabled) return;
    if (self.state == .active) return;
    self.state = .active;
    log.debug("prompt editor activated", .{});
    if (self.state_changed_cb) |cb| cb(self.state_changed_userdata, true, 2);
}

/// Deactivate the editor. Called on OSC 133;C (start-of-output) or
/// surface unfocus.
pub fn deactivate(self: *Editor) void {
    if (self.state == .inactive) return;
    self.state = .inactive;
    log.debug("prompt editor deactivated", .{});
    if (self.state_changed_cb) |cb| cb(self.state_changed_userdata, false, 0);
}

/// Returns true if the editor is currently active.
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
