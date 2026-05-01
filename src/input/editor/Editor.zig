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

/// Cursor position as a byte offset into `buffer.bytes`. Always lies on
/// a UTF-8 codepoint boundary. Inserts happen at the cursor; backspace
/// deletes the codepoint before it; delete-forward deletes the
/// codepoint at it.
cursor: usize = 0,

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
    self.cursor = 0;
    self.state = .active;
    log.debug("prompt editor activated", .{});
}

/// Deactivate the editor without committing. Called on OSC 133;C
/// (start-of-output), surface unfocus, or explicit cancel.
pub fn deactivate(self: *Editor) void {
    if (self.state == .inactive) return;
    self.state = .inactive;
    self.buffer.clear();
    self.cursor = 0;
    log.debug("prompt editor deactivated", .{});
}

/// Returns true if the editor is currently intercepting input.
pub fn isActive(self: *const Editor) bool {
    return self.state == .active;
}

/// Process a key event in active mode. Returns `.observed` for keys the
/// editor doesn't want (modifiers alone, function keys, etc.) so the
/// caller continues normal PTY encoding. Returns `.consumed` for keys
/// the editor handled fully (typing, backspace, escape, arrows). Returns
/// `.commit` when the user pressed Enter — caller reads `buffer.text()`,
/// ships it to the PTY (with a trailing CR), then calls `commitDone()`.
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

    // -- Cursor navigation --

    // Left arrow: previous codepoint. Cmd+Left → start, Alt+Left → word.
    if (event.key == .arrow_left) {
        if (event.mods.super) {
            self.cursor = 0;
        } else if (event.mods.alt) {
            self.cursor = wordBoundaryBack(self.buffer.text(), self.cursor);
        } else {
            self.cursor = prevCodepointBoundary(self.buffer.text(), self.cursor);
        }
        return .consumed;
    }

    // Right arrow: next codepoint. Cmd+Right → end, Alt+Right → word.
    if (event.key == .arrow_right) {
        if (event.mods.super) {
            self.cursor = self.buffer.len();
        } else if (event.mods.alt) {
            self.cursor = wordBoundaryForward(self.buffer.text(), self.cursor);
        } else {
            self.cursor = nextCodepointBoundary(self.buffer.text(), self.cursor);
        }
        return .consumed;
    }

    // Home / End jump the cursor.
    if (event.key == .home) {
        self.cursor = 0;
        return .consumed;
    }
    if (event.key == .end) {
        self.cursor = self.buffer.len();
        return .consumed;
    }

    // Ctrl chords. A/E for emacs-style line start/end. C clears the
    // editor's buffer and lets \x03 fall through to the shell so the
    // shell aborts and prints a fresh prompt — matches the muscle
    // memory of "Ctrl+C abandons what I was typing".
    if (event.mods.ctrl and !event.mods.alt and !event.mods.super) {
        switch (event.key) {
            .key_a => {
                self.cursor = 0;
                return .consumed;
            },
            .key_e => {
                self.cursor = self.buffer.len();
                return .consumed;
            },
            .key_c => {
                self.buffer.clear();
                self.cursor = 0;
                // Return .observed so encodeKey still ships \x03 to
                // the PTY. The shell's SIGINT handler prints a fresh
                // prompt; the next keystroke's activate cycle will
                // reset us cleanly on that new prompt.
                return .observed;
            },
            else => {},
        }
    }

    // -- Editing --

    // Backspace deletes the codepoint BEFORE the cursor.
    if (event.key == .backspace and event.mods.empty()) {
        const buf = self.buffer.text();
        const start = prevCodepointBoundary(buf, self.cursor);
        if (start < self.cursor) {
            self.buffer.deleteRange(start, self.cursor - start);
            self.cursor = start;
        }
        return .consumed;
    }

    // Forward Delete deletes the codepoint AT the cursor.
    if (event.key == .delete and event.mods.empty()) {
        const buf = self.buffer.text();
        const end = nextCodepointBoundary(buf, self.cursor);
        if (end > self.cursor) {
            self.buffer.deleteRange(self.cursor, end - self.cursor);
        }
        return .consumed;
    }

    // Escape clears the buffer (cancel-without-deactivate). Editor stays
    // active so the user can keep typing on the same prompt.
    if (event.key == .escape and event.mods.empty()) {
        self.buffer.clear();
        self.cursor = 0;
        return .consumed;
    }

    // Anything that produced printable UTF-8 gets inserted at the cursor.
    if (event.utf8.len > 0) {
        try self.buffer.insertAt(self.cursor, event.utf8);
        self.cursor += event.utf8.len;
        return .consumed;
    }

    // Modifier-only events, function keys, anything we don't yet
    // handle — fall through so existing Ghostty machinery can decide.
    return .observed;
}

/// Called by the caller after a `.commit` was returned and the buffer
/// has been shipped to the PTY. Clears the buffer and leaves the
/// editor active so the next prompt cycle reuses the same instance.
pub fn commitDone(self: *Editor) void {
    self.buffer.clear();
    self.cursor = 0;
}

/// Insert raw UTF-8 text at the cursor position. Used by paste and any
/// other "drop these bytes in" flow. Caller is responsible for ensuring
/// the editor is active.
pub fn insertText(self: *Editor, text: []const u8) Allocator.Error!void {
    std.debug.assert(self.state == .active);
    try self.buffer.insertAt(self.cursor, text);
    self.cursor += text.len;
}

// -- UTF-8 + word-boundary helpers --

/// Returns the byte offset of the start of the codepoint immediately
/// before `offset`. Returns 0 if `offset` is at or before the start.
fn prevCodepointBoundary(buf: []const u8, offset: usize) usize {
    if (offset == 0) return 0;
    var i: usize = offset - 1;
    while (i > 0 and (buf[i] & 0xC0) == 0x80) : (i -= 1) {}
    return i;
}

/// Returns the byte offset of the start of the codepoint immediately
/// after `offset`. Returns `buf.len` if `offset` is at or past the end.
fn nextCodepointBoundary(buf: []const u8, offset: usize) usize {
    if (offset >= buf.len) return buf.len;
    var i: usize = offset + 1;
    while (i < buf.len and (buf[i] & 0xC0) == 0x80) : (i += 1) {}
    return i;
}

fn isWordChar(b: u8) bool {
    return (b >= '0' and b <= '9') or
        (b >= 'a' and b <= 'z') or
        (b >= 'A' and b <= 'Z') or
        b == '_';
}

/// Move backward over (zero or more) non-word chars, then over (zero or
/// more) word chars. ASCII-only word definition for now; multi-byte
/// codepoints are treated as non-word.
fn wordBoundaryBack(buf: []const u8, offset: usize) usize {
    var i = @min(offset, buf.len);
    while (i > 0 and !isWordChar(buf[i - 1])) : (i -= 1) {}
    while (i > 0 and isWordChar(buf[i - 1])) : (i -= 1) {}
    return i;
}

/// Symmetric counterpart of wordBoundaryBack.
fn wordBoundaryForward(buf: []const u8, offset: usize) usize {
    var i = offset;
    while (i < buf.len and isWordChar(buf[i])) : (i += 1) {}
    while (i < buf.len and !isWordChar(buf[i])) : (i += 1) {}
    return i;
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
