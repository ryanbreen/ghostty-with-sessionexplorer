//! Prompt editor: a modern editing surface that activates over the active
//! shell prompt (detected via OSC 133) and provides multi-line editing,
//! real selection, undo/redo, and system clipboard integration.
//!
//! Spiritual port of Warp's block-based input editor, scoped to live only
//! at the prompt region. Outside the active prompt, Ghostty renders as a
//! traditional terminal.
//!
//! See `~/Downloads/ghostty-prompt-editor-port-plan-2026-05-01.md` for
//! the design.

pub const Editor = @import("editor/Editor.zig");
pub const Buffer = @import("editor/Buffer.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
