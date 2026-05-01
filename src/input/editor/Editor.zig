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
const input = @import("../../input.zig");

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

/// What handleKey reports back to the caller.
pub const Effect = enum {
    /// Key was not relevant to the editor. Caller should fall through
    /// to normal handling (encode + queueIo to PTY).
    observed,

    /// Editor consumed the key — buffer was edited, or the key was a
    /// no-op for the editor but still shouldn't reach the PTY (e.g. an
    /// Escape that just clears the buffer). Caller must NOT encode the
    /// key to the PTY.
    consumed,

    /// Editor wants to commit. The caller should send the editor's
    /// buffer (followed by a CR) to the PTY and then call
    /// `commitDone()` to clear the buffer and deactivate.
    commit,
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

/// Process a key event in active mode. Returns `.observed` for keys the
/// editor doesn't want (modifiers alone, function keys, etc.) so the
/// caller continues normal PTY encoding. Returns `.consumed` for keys
/// the editor handled fully (typing, backspace, escape) — caller must
/// NOT encode. Returns `.commit` when the user pressed Enter — caller
/// reads `buffer.text()`, ships it to the PTY (with a trailing CR), then
/// calls `commitDone()`.
pub fn handleKey(
    self: *Editor,
    event: input.KeyEvent,
) Allocator.Error!Effect {
    std.debug.assert(self.state == .active);

    // Release events do not interact with the editor at all.
    if (event.action == .release) return .observed;

    // Enter (no mods) → commit. Buffer stays populated until commitDone()
    // so the caller can read it.
    if (event.key == .enter and event.mods.empty()) {
        log.info("commit buffer=\"{s}\" len={d}", .{
            self.buffer.text(),
            self.buffer.len(),
        });
        return .commit;
    }

    // Backspace deletes the last byte. UTF-8 codepoint-aware deletion
    // is Phase 2; for now ASCII-correct + best-effort on multi-byte.
    if (event.key == .backspace and event.mods.empty()) {
        if (self.buffer.len() > 0) {
            self.buffer.deleteRange(self.buffer.len() - 1, 1);
        }
        return .consumed;
    }

    // Escape clears the buffer (cancel-without-deactivate). Editor stays
    // active so the user can keep typing on the same prompt.
    if (event.key == .escape and event.mods.empty()) {
        self.buffer.clear();
        return .consumed;
    }

    // Anything that produced printable UTF-8 gets appended and consumed.
    if (event.utf8.len > 0) {
        try self.buffer.insertAt(self.buffer.len(), event.utf8);
        return .consumed;
    }

    // Modifier-only events, arrows we don't yet handle, function keys,
    // etc. — let through so other Ghostty machinery (binding lookups
    // etc.) can decide.
    return .observed;
}

/// Called by the caller after a `.commit` was returned and the buffer
/// has been shipped to the PTY. Clears the buffer and leaves the
/// editor active so the next prompt cycle reuses the same instance.
pub fn commitDone(self: *Editor) void {
    self.buffer.clear();
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
