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

/// What handleKey reports back to the caller. In Phase 1 (shadow mode),
/// the editor never claims a key — keystrokes still flow to the PTY.
/// Subsequent phases will add `.consumed` to suppress PTY writes.
pub const Effect = enum {
    /// Key was recorded into the buffer (or ignored). Caller should
    /// continue normal handling — the keystroke still goes to the PTY.
    observed,

    /// Buffer was committed (Enter received). Caller should continue
    /// normal handling so the Enter reaches the shell. The buffer is
    /// cleared.
    committed,
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

/// Process a key event. In Phase 1 this is shadow-capture only: the
/// editor records typing into its buffer but never claims the keystroke,
/// so the shell still sees and echoes the key as usual. The buffer is
/// logged on Enter and cleared.
///
/// Returns `.observed` for normal capture, `.committed` when the buffer
/// reaches a commit point. Caller continues normal key handling in both
/// cases.
pub fn handleKey(
    self: *Editor,
    event: input.KeyEvent,
) Allocator.Error!Effect {
    std.debug.assert(self.state == .active);

    // We only act on press / repeat; release events are ignored.
    if (event.action != .press and event.action != .repeat) return .observed;

    // Enter (no mods) commits the buffer.
    if (event.key == .enter and event.mods.empty()) {
        log.info("commit buffer=\"{s}\" len={d}", .{
            self.buffer.text(),
            self.buffer.len(),
        });
        self.buffer.clear();
        return .committed;
    }

    // Backspace removes the last byte. UTF-8 codepoint-aware deletion
    // is Phase 2; for now ASCII-correct + best-effort on multi-byte.
    if (event.key == .backspace and event.mods.empty()) {
        if (self.buffer.len() > 0) {
            self.buffer.deleteRange(self.buffer.len() - 1, 1);
        }
        return .observed;
    }

    // Escape clears the buffer (treat as cancel).
    if (event.key == .escape and event.mods.empty()) {
        self.buffer.clear();
        return .observed;
    }

    // Anything that produced printable UTF-8 gets appended.
    if (event.utf8.len > 0) {
        try self.buffer.insertAt(self.buffer.len(), event.utf8);
    }

    return .observed;
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
