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

/// Cached prompt text, captured from the terminal cells just before
/// the renderer erases them. Populated on each activation transition;
/// cleared on deactivation. Surfaced to the apprt via
/// `ghostty_surface_read_prompt`.
cached_prompt: std.ArrayListUnmanaged(u8) = .empty,

/// Cursor row recorded by `Surface.editorCommit` right before the
/// command bytes are queued to the PTY. The stream handler reads this
/// when OSC 133;C arrives and uses `deleteLines` to strip the kernel's
/// echoed command line out of the visible grid — the apprt's block
/// separator already shows the command, so the bare echo is redundant.
commit_echo_start_row: ?u32 = null,

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

pub fn deinit(self: *Editor) void {
    self.cached_prompt.deinit(self.alloc);
}

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
    self.cached_prompt.clearRetainingCapacity();
    log.debug("prompt editor deactivated", .{});
    if (self.state_changed_cb) |cb| cb(self.state_changed_userdata, false, 0);
}

/// Replace the cached prompt text with `text`. Called by the renderer
/// on the inactive→active transition, just before it erases the prompt
/// cells from the terminal grid.
pub fn capturePrompt(self: *Editor, text: []const u8) Allocator.Error!void {
    self.cached_prompt.clearRetainingCapacity();
    try self.cached_prompt.appendSlice(self.alloc, text);
}

/// Read the cached prompt text. Empty when the editor isn't active or
/// no prompt has been captured yet.
pub fn cachedPrompt(self: *const Editor) []const u8 {
    return self.cached_prompt.items;
}

/// Record the cursor row at the moment a commit is shipped to the PTY.
pub fn markCommitStart(self: *Editor, row: u32) void {
    self.commit_echo_start_row = row;
}

/// Take and clear the recorded commit start row. Returns null if no
/// commit is in flight.
pub fn takeCommitStart(self: *Editor) ?u32 {
    const row = self.commit_echo_start_row;
    self.commit_echo_start_row = null;
    return row;
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
