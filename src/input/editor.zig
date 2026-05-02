//! Prompt editor activation hook. Just an active/inactive state machine
//! plus a state-change callback into the apprt; the apprt's native
//! editor view (e.g. macOS NSTextView) owns the buffer, cursor, and
//! rendering.

pub const Editor = @import("editor/Editor.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
