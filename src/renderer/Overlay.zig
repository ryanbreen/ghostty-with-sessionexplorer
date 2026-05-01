/// The debug overlay that can be drawn on top of the terminal
/// during the rendering process.
///
/// This is implemented by doing all the drawing on the CPU via z2d,
/// since the debug overlay isn't that common, z2d is pretty fast, and
/// it simplifies our implementation quite a bit by not relying on us
/// having a bunch of shaders that we have to write per-platform.
///
/// Initialize the overlay, apply features with `applyFeatures`, then
/// get the resulting image with `pendingImage` to upload to the GPU.
/// This works in concert with `renderer.image.State` to simplify. Draw
/// it on the GPU as an image composited on top of the terminal output.
const Overlay = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const z2d = @import("z2d");
const terminal = @import("../terminal/main.zig");
const size = @import("size.zig");
const Size = size.Size;
const CellSize = size.CellSize;
const Image = @import("image.zig").Image;

const log = std.log.scoped(.renderer_overlay);

/// The colors we use for overlays.
pub const Color = enum {
    hyperlink, // light blue
    semantic_prompt, // orange/gold
    semantic_input, // cyan
    prompt_editor, // magenta — distinct so the editor bar reads as ours

    pub fn rgb(self: Color) z2d.pixel.RGB {
        return switch (self) {
            .hyperlink => .{ .r = 180, .g = 180, .b = 255 },
            .semantic_prompt => .{ .r = 255, .g = 200, .b = 64 },
            .semantic_input => .{ .r = 64, .g = 200, .b = 255 },
            .prompt_editor => .{ .r = 220, .g = 80, .b = 220 },
        };
    }

    /// The fill color for rectangles.
    pub fn rectFill(self: Color) z2d.Pixel {
        return self.alphaPixel(96);
    }

    /// The border color for rectangles.
    pub fn rectBorder(self: Color) z2d.Pixel {
        return self.alphaPixel(200);
    }

    /// The raw RGB as a pixel.
    pub fn pixel(self: Color) z2d.Pixel {
        return self.rgb().asPixel();
    }

    fn alphaPixel(self: Color, alpha: u8) z2d.Pixel {
        var rgba: z2d.pixel.RGBA = .fromPixel(self.pixel());
        rgba.a = alpha;
        return rgba.multiply().asPixel();
    }
};

/// The surface we're drawing our overlay to.
surface: z2d.Surface,

/// Cell size information so we can map grid coordinates to pixels.
cell_size: CellSize,

/// Lazy-loaded font for rendering prompt-editor text. Loaded on first
/// `.prompt_editor` feature application from the system mono font.
prompt_editor_font: ?z2d.Font = null,
prompt_editor_font_loaded: bool = false,

/// Snapshot of the prompt editor's buffer text for the current frame.
/// Set by the renderer just before applyFeatures and cleared after.
/// Lifetime is tied to the renderer's per-frame arena.
prompt_editor_buffer: []const u8 = &.{},

/// Byte offset of the cursor within `prompt_editor_buffer` for the
/// current frame. The overlay uses this together with `\n` characters
/// and column-overflow wrapping to compute the caret's visual line+col.
prompt_editor_cursor: usize = 0,

/// Sticky scroll position: the buffer-line index that's currently the
/// FIRST visible line in the bar. Persists across frames so the bar
/// only scrolls when the caret would otherwise leave the visible
/// window — Up arrow within an already-visible region just moves the
/// caret without moving the surrounding text. Reset to 0 when the
/// buffer is empty (i.e. activate / commitDone / Ctrl+C / Escape).
prompt_editor_view_top: usize = 0,

/// The set of available features and their configuration.
pub const Feature = union(enum) {
    highlight_hyperlinks,
    semantic_prompts,
    /// Draw the prompt editor's bottom-row indicator. Used while the
    /// `Surface.editor` is active (prompt-editor config enabled and the
    /// shell cursor is in an OSC 133 input region).
    prompt_editor,
};

pub const InitError = Allocator.Error || error{
    // The terminal dimensions are invalid to support an overlay.
    // Either too small or too big.
    InvalidDimensions,
};

/// Initialize a new, blank overlay.
pub fn init(alloc: Allocator, sz: Size) InitError!Overlay {
    // Our surface does NOT need to take into account padding because
    // we render the overlay using the image subsystem and shaders which
    // already take that into account.
    const term_size = sz.terminal();
    var sfc = z2d.Surface.initPixel(
        .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
        alloc,
        std.math.cast(i32, term_size.width) orelse
            return error.InvalidDimensions,
        std.math.cast(i32, term_size.height) orelse
            return error.InvalidDimensions,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWidth, error.InvalidHeight => return error.InvalidDimensions,
    };
    errdefer sfc.deinit(alloc);

    return .{
        .surface = sfc,
        .cell_size = sz.cell,
    };
}

pub fn deinit(self: *Overlay, alloc: Allocator) void {
    self.surface.deinit(alloc);
    if (self.prompt_editor_font) |*f| f.deinit(alloc);
}

/// Set the prompt editor's buffer snapshot for this frame. Called by
/// the renderer with an arena-allocated copy before `applyFeatures`.
/// `cursor_byte` is the byte offset within `buf` of the editor's cursor
/// (always on a UTF-8 codepoint boundary).
pub fn setPromptEditorBuffer(
    self: *Overlay,
    buf: []const u8,
    cursor_byte: usize,
) void {
    self.prompt_editor_buffer = buf;
    self.prompt_editor_cursor = cursor_byte;
}

/// Returns a pending image that can be used to copy, convert, upload, etc.
pub fn pendingImage(self: *const Overlay) Image.Pending {
    return .{
        .width = @intCast(self.surface.getWidth()),
        .height = @intCast(self.surface.getHeight()),
        .pixel_format = .rgba,
        .data = @ptrCast(self.surface.image_surface_rgba.buf.ptr),
    };
}

/// Clear the overlay.
pub fn reset(self: *Overlay) void {
    self.surface.paintPixel(.{ .rgba = .{
        .r = 0,
        .g = 0,
        .b = 0,
        .a = 0,
    } });
}

/// Apply the given features to this overlay. This will draw on top of
/// any pre-existing content in the overlay.
pub fn applyFeatures(
    self: *Overlay,
    alloc: Allocator,
    state: *const terminal.RenderState,
    features: []const Feature,
) void {
    for (features) |f| switch (f) {
        .highlight_hyperlinks => self.highlightHyperlinks(
            alloc,
            state,
        ),
        .semantic_prompts => self.highlightSemanticPrompts(
            alloc,
            state,
        ),
        .prompt_editor => self.drawPromptEditorBar(alloc, state),
    };
}

/// Draw the prompt editor's indicator bar pinned to the bottom of the
/// viewport. The bar's height is 1:1 with the buffer's wrapped-line
/// count, capped only by the available viewport rows — there's no
/// artificial maximum. When the buffer overflows the viewport the
/// caret-aware view_top scrolls within the bar; to see content above
/// the editor at that point, scroll the terminal's normal scrollback.
/// One row of breathing room is left between the bar and the viewport
/// bottom so macOS window chrome doesn't clip the bar.
fn drawPromptEditorBar(
    self: *Overlay,
    alloc: Allocator,
    state: *const terminal.RenderState,
) void {
    const row_count = state.row_data.len;
    const bottom_padding_cells: usize = 1;
    if (row_count < 2 + bottom_padding_cells) return;

    const cols = blk: {
        const row_slice = state.row_data.slice();
        const cells = row_slice.items(.cells);
        if (cells.len == 0) break :blk @as(usize, 0);
        break :blk cells[0].slice().items(.raw).len;
    };
    if (cols == 0) return;

    // -- Geometry & font --
    const font = self.ensurePromptEditorFont(alloc);
    const cell_w_f: f64 = @floatFromInt(self.cell_size.width);
    const cell_h_f: f64 = @floatFromInt(self.cell_size.height);
    const opts_size: f64 = cell_h_f * 0.85;
    const x_start: f64 = cell_w_f * 0.4;

    // Per-glyph advance for our editor font.
    const advance_px: f64 = if (font) |f| advance: {
        const upm: f64 = @floatFromInt(f.meta.units_per_em);
        const adv: f64 = @floatFromInt(f.meta.advance_width_max);
        break :advance adv * (opts_size / upm);
    } else cell_w_f;

    // How many editor-font glyphs fit between x_start and the right
    // edge of the viewport. We hard-wrap at this width so text never
    // runs off the right side of the bar.
    const total_width_px: f64 = @as(f64, @floatFromInt(cols)) * cell_w_f;
    const usable_px: f64 = total_width_px - x_start - cell_w_f * 0.4;
    const cols_per_line: usize = blk: {
        if (advance_px <= 0) break :blk 1;
        const fit: f64 = usable_px / advance_px;
        if (fit < 1.0) break :blk 1;
        break :blk @intFromFloat(fit);
    };

    // -- Compute visual lines + caret position --
    const lines = self.computeVisualLines(
        alloc,
        cols_per_line,
    ) catch return;
    defer alloc.free(lines.starts);

    // The bar would like to be 1:1 with the buffer's line count, but
    // it can only physically occupy the available viewport rows. When
    // the buffer overflows, only the visible_lines tail-or-window of
    // it renders.
    const available_rows = row_count - bottom_padding_cells;
    const visible_lines = @min(lines.line_count, available_rows);

    // Sticky view_top. If the buffer is empty (typically right after
    // activate / commitDone / Ctrl+C), reset. Otherwise, only scroll
    // when the caret moves outside the current visible window — Up
    // within the visible region moves the caret only, NOT the text.
    if (self.prompt_editor_buffer.len == 0) {
        self.prompt_editor_view_top = 0;
    } else {
        // Pull view down if the caret moved above the visible top.
        if (lines.cursor_line < self.prompt_editor_view_top) {
            self.prompt_editor_view_top = lines.cursor_line;
        }
        // Push view up if the caret moved below the visible bottom.
        const view_bottom_excl = self.prompt_editor_view_top + visible_lines;
        if (lines.cursor_line + 1 > view_bottom_excl) {
            self.prompt_editor_view_top = lines.cursor_line + 1 - visible_lines;
        }
        // Clamp so we never show empty rows below the buffer's end —
        // happens when content was deleted or after a buffer shrink
        // that doesn't otherwise touch the cursor.
        if (lines.line_count >= visible_lines and
            self.prompt_editor_view_top + visible_lines > lines.line_count)
        {
            self.prompt_editor_view_top = lines.line_count - visible_lines;
        }
        if (lines.line_count < visible_lines) {
            self.prompt_editor_view_top = 0;
        }
    }
    const first_visible_line = self.prompt_editor_view_top;

    // Bar height: matches the visible content. Minimum of 2 cells so
    // an empty buffer (single empty visual line) still shows a real
    // bar with vertical breathing room around the caret.
    const bar_height_cells = @max(2, visible_lines);
    if (row_count < bar_height_cells + bottom_padding_cells) return;

    const bar_top_row = row_count - bar_height_cells - bottom_padding_cells;
    const bar_top_f: f64 = @as(f64, @floatFromInt(bar_top_row)) * cell_h_f;

    // Vertical content offset within the bar so a 1-line buffer in a
    // 2-cell bar reads as "centered" rather than "anchored to top".
    // For visible_lines >= bar_height_cells this evaluates to 0.
    const v_padding_px: f64 = (@as(f64, @floatFromInt(bar_height_cells)) -
        @as(f64, @floatFromInt(visible_lines))) * cell_h_f / 2.0;

    // -- Bar background --
    const border = Color.prompt_editor.rectBorder();
    const fill: z2d.Pixel = blk: {
        var rgba: z2d.pixel.RGBA = .fromPixel(Color.prompt_editor.pixel());
        rgba.a = 230;
        break :blk rgba.multiply().asPixel();
    };
    self.highlightGridRect(
        alloc,
        0,
        bar_top_row,
        cols,
        bar_height_cells,
        border,
        fill,
    ) catch |err| {
        log.warn("Error drawing prompt editor bar: {}", .{err});
        return;
    };

    // -- Text per visible line --
    const white: z2d.Pixel = .{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } };
    if (font) |f| {
        var pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = white } };

        var visual_idx: usize = 0;
        while (visual_idx < visible_lines) : (visual_idx += 1) {
            const line_idx = first_visible_line + visual_idx;
            const start = lines.starts[line_idx];
            const end = if (line_idx + 1 < lines.starts.len)
                lines.starts[line_idx + 1]
            else
                self.prompt_editor_buffer.len;

            // Slice this line's bytes, stripping a trailing newline.
            var line_slice = self.prompt_editor_buffer[start..end];
            if (line_slice.len > 0 and line_slice[line_slice.len - 1] == '\n') {
                line_slice = line_slice[0 .. line_slice.len - 1];
            }
            if (line_slice.len == 0) continue;

            // z2d.text.show treats `y` as the screen y of the
            // outline-coord origin, which (after the outline's
            // pre-applied scale(1,-1).translate(0,-em)) corresponds
            // to the TOP of the em square. With opts_size = 0.85 *
            // cell_h, em-bottom (the baseline) sits at y + 0.85 *
            // cell_h. Cap-top is roughly at y + 0.30 * opts_size and
            // descender at y + 1.20 * opts_size, so the visible body
            // spans 0.9 * opts_size = ~0.765 * cell_h. To center
            // that body inside the cell, we put y at
            // cell_top - 0.14 * cell_h.
            const cell_top: f64 = bar_top_f + v_padding_px +
                @as(f64, @floatFromInt(visual_idx)) * cell_h_f;
            const line_y: f64 = cell_top - cell_h_f * 0.14;

            z2d.text.show(
                alloc,
                &self.surface,
                &pattern,
                f,
                line_slice,
                x_start,
                line_y,
                .{ .size = opts_size, .fill_opts = .{} },
            ) catch |err| {
                log.warn("Error rendering prompt editor text: {}", .{err});
            };
        }
    }

    // -- Caret --
    // Drawn even on empty buffer. Caret-aware scrolling above ensures
    // the cursor line is always inside the visible window. The caret
    // spans ~80% of the cell height (10% inset top and bottom), which
    // visually matches the text body's vertical extent computed above
    // — so the caret reads as "this is the line I'm editing", not
    // "this is a tall cursor next to short text".
    if (lines.cursor_line >= first_visible_line and
        lines.cursor_line < first_visible_line + visible_lines)
    {
        const visual_caret_line = lines.cursor_line - first_visible_line;
        const caret_x: f64 = x_start +
            @as(f64, @floatFromInt(lines.cursor_col)) * advance_px;
        const cell_top: f64 = bar_top_f + v_padding_px +
            @as(f64, @floatFromInt(visual_caret_line)) * cell_h_f;
        const caret_top: f64 = cell_top + cell_h_f * 0.1;
        const caret_bottom: f64 = cell_top + cell_h_f * 0.9;
        self.drawCaret(alloc, caret_x, caret_top, caret_bottom) catch |err| {
            log.warn("Error rendering prompt editor caret: {}", .{err});
        };
    }
}

const VisualLines = struct {
    /// Byte offsets where each visual line starts. Length is the number
    /// of lines.
    starts: []usize,
    line_count: usize,
    cursor_line: usize,
    cursor_col: usize,
};

/// Walk the buffer, splitting into visual lines on `\n` and at every
/// `cols_per_line` codepoints. Also locates the cursor's (line, col).
/// Caller owns `result.starts` (allocated from `alloc`).
fn computeVisualLines(
    self: *Overlay,
    alloc: Allocator,
    cols_per_line: usize,
) !VisualLines {
    const buf = self.prompt_editor_buffer;
    const cursor = self.prompt_editor_cursor;

    var starts: std.ArrayListUnmanaged(usize) = .empty;
    errdefer starts.deinit(alloc);

    try starts.append(alloc, 0);

    var col: usize = 0;
    var i: usize = 0;
    var cursor_line: usize = 0;
    var cursor_col: usize = 0;
    var cursor_assigned = false;

    while (i < buf.len) {
        if (i == cursor and !cursor_assigned) {
            cursor_line = starts.items.len - 1;
            cursor_col = col;
            cursor_assigned = true;
        }

        if (buf[i] == '\n') {
            i += 1;
            try starts.append(alloc, i);
            col = 0;
            continue;
        }

        // Walk to next codepoint boundary.
        var n: usize = i + 1;
        while (n < buf.len and (buf[n] & 0xC0) == 0x80) : (n += 1) {}

        col += 1;
        if (col >= cols_per_line) {
            try starts.append(alloc, n);
            col = 0;
        }
        i = n;
    }
    if (!cursor_assigned) {
        cursor_line = starts.items.len - 1;
        cursor_col = col;
    }

    const owned = try starts.toOwnedSlice(alloc);
    return .{
        .starts = owned,
        .line_count = owned.len,
        .cursor_line = cursor_line,
        .cursor_col = cursor_col,
    };
}

/// Draw a 2-pixel-wide white vertical caret at `x`, between `top` and
/// `bottom` pixel-y coordinates.
fn drawCaret(
    self: *Overlay,
    alloc: Allocator,
    x: f64,
    top: f64,
    bottom: f64,
) !void {
    const caret_w: f64 = 2.0;

    var ctx: z2d.Context = .init(alloc, &self.surface);
    defer ctx.deinit();
    ctx.setAntiAliasingMode(.none);

    try ctx.moveTo(x, top);
    try ctx.lineTo(x + caret_w, top);
    try ctx.lineTo(x + caret_w, bottom);
    try ctx.lineTo(x, bottom);
    try ctx.closePath();

    const white: z2d.Pixel = .{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } };
    ctx.setSourceToPixel(white);
    try ctx.fill();
}

/// Lazily load the prompt editor's render font. macOS-only path for now.
/// Returns null if loading fails (caller should silently skip text render).
fn ensurePromptEditorFont(self: *Overlay, alloc: Allocator) ?*z2d.Font {
    if (self.prompt_editor_font_loaded) {
        if (self.prompt_editor_font) |*f| return f;
        return null;
    }
    self.prompt_editor_font_loaded = true;

    // System monospace font on macOS. TODO: portable lookup for
    // Linux/Windows when this code reaches those targets.
    const path = "/System/Library/Fonts/SFNSMono.ttf";
    const f = z2d.Font.loadFile(alloc, path) catch |err| {
        log.warn("Failed to load prompt editor font path={s} err={}", .{ path, err });
        return null;
    };
    self.prompt_editor_font = f;
    return &self.prompt_editor_font.?;
}

/// Add rectangles around contiguous hyperlinks in the render state.
///
/// Note: this currently doesn't take into account unique hyperlink IDs
/// because the render state doesn't contain this. This will be added
/// later.
fn highlightHyperlinks(
    self: *Overlay,
    alloc: Allocator,
    state: *const terminal.RenderState,
) void {
    const border_color = Color.hyperlink.rectBorder();
    const fill_color = Color.hyperlink.rectFill();

    const row_slice = state.row_data.slice();
    const row_raw = row_slice.items(.raw);
    const row_cells = row_slice.items(.cells);
    for (row_raw, row_cells, 0..) |row, cells, y| {
        if (!row.hyperlink) continue;

        const cells_slice = cells.slice();
        const raw_cells = cells_slice.items(.raw);

        var x: usize = 0;
        while (x < raw_cells.len) {
            // Skip cells without hyperlinks
            if (!raw_cells[x].hyperlink) {
                x += 1;
                continue;
            }

            // Found start of a hyperlink run
            const start_x = x;

            // Find end of contiguous hyperlink cells
            while (x < raw_cells.len and raw_cells[x].hyperlink) x += 1;
            const end_x = x;

            self.highlightGridRect(
                alloc,
                start_x,
                y,
                end_x - start_x,
                1,
                border_color,
                fill_color,
            ) catch |err| {
                std.log.warn("Error drawing hyperlink border: {}", .{err});
            };
        }
    }
}

fn highlightSemanticPrompts(
    self: *Overlay,
    alloc: Allocator,
    state: *const terminal.RenderState,
) void {
    const row_slice = state.row_data.slice();
    const row_raw = row_slice.items(.raw);
    const row_cells = row_slice.items(.cells);

    // Highlight the row-level semantic prompt bars. The prompts are easy
    // because they're part of the row metadata.
    {
        const prompt_border = Color.semantic_prompt.rectBorder();
        const prompt_fill = Color.semantic_prompt.rectFill();

        var y: usize = 0;
        while (y < row_raw.len) {
            // If its not a semantic prompt row, skip it.
            if (row_raw[y].semantic_prompt == .none) {
                y += 1;
                continue;
            }

            // Find the full length of the semantic prompt row by connecting
            // all continuations.
            const start_y = y;
            y += 1;
            while (y < row_raw.len and
                row_raw[y].semantic_prompt == .prompt_continuation)
            {
                y += 1;
            }
            const end_y = y; // Exclusive

            const bar_width = @min(@as(usize, 5), self.cell_size.width);
            self.highlightPixelRect(
                alloc,
                0,
                start_y,
                bar_width,
                end_y - start_y,
                prompt_border,
                prompt_fill,
            ) catch |err| {
                log.warn("Error drawing semantic prompt bar: {}", .{err});
            };
        }
    }

    // Highlight contiguous semantic cells within rows.
    for (row_cells, 0..) |cells, y| {
        const cells_slice = cells.slice();
        const raw_cells = cells_slice.items(.raw);

        var x: usize = 0;
        while (x < raw_cells.len) {
            const cell = raw_cells[x];
            const content = cell.semantic_content;
            const start_x = x;

            // We skip output because its just the rest of the non-prompt
            // parts and it makes the overlay too noisy.
            if (cell.semantic_content == .output) {
                x += 1;
                continue;
            }

            // Find the end of this content.
            x += 1;
            while (x < raw_cells.len) {
                const next = raw_cells[x];
                if (next.semantic_content != content) break;
                x += 1;
            }

            const color: Color = switch (content) {
                .prompt => .semantic_prompt,
                .input => .semantic_input,
                .output => unreachable,
            };

            self.highlightGridRect(
                alloc,
                start_x,
                y,
                x - start_x,
                1,
                color.rectBorder(),
                color.rectFill(),
            ) catch |err| {
                log.warn("Error drawing semantic content highlight: {}", .{err});
            };
        }
    }
}

/// Creates a rectangle for highlighting a grid region. x/y/width/height
/// are all in grid cells.
fn highlightGridRect(
    self: *Overlay,
    alloc: Allocator,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    border_color: z2d.Pixel,
    fill_color: z2d.Pixel,
) !void {
    // All math below uses checked arithmetic to avoid overflows. The
    // inputs aren't trusted and the path this is in isn't hot enough
    // to wrarrant unsafe optimizations.

    // Calculate our width/height in pixels.
    const px_width = std.math.cast(i32, try std.math.mul(
        usize,
        width,
        self.cell_size.width,
    )) orelse return error.Overflow;
    const px_height = std.math.cast(i32, try std.math.mul(
        usize,
        height,
        self.cell_size.height,
    )) orelse return error.Overflow;

    // Calculate pixel coordinates
    const start_x: f64 = @floatFromInt(std.math.cast(i32, try std.math.mul(
        usize,
        x,
        self.cell_size.width,
    )) orelse return error.Overflow);
    const start_y: f64 = @floatFromInt(std.math.cast(i32, try std.math.mul(
        usize,
        y,
        self.cell_size.height,
    )) orelse return error.Overflow);
    const end_x: f64 = start_x + @as(f64, @floatFromInt(px_width));
    const end_y: f64 = start_y + @as(f64, @floatFromInt(px_height));

    // Grab our context to draw
    var ctx: z2d.Context = .init(alloc, &self.surface);
    defer ctx.deinit();

    // Don't need AA because we use sharp edges
    ctx.setAntiAliasingMode(.none);
    // Can use hairline since we have 1px borders
    ctx.setHairline(true);

    // Draw rectangle path
    try ctx.moveTo(start_x, start_y);
    try ctx.lineTo(end_x, start_y);
    try ctx.lineTo(end_x, end_y);
    try ctx.lineTo(start_x, end_y);
    try ctx.closePath();

    // Fill
    ctx.setSourceToPixel(fill_color);
    try ctx.fill();

    // Border
    ctx.setLineWidth(1);
    ctx.setSourceToPixel(border_color);
    try ctx.stroke();
}

/// Creates a rectangle for highlighting a region. x/y are grid cells and
/// width/height are pixels.
fn highlightPixelRect(
    self: *Overlay,
    alloc: Allocator,
    x: usize,
    y: usize,
    width_px: usize,
    height: usize,
    border_color: z2d.Pixel,
    fill_color: z2d.Pixel,
) !void {
    const px_width = std.math.cast(i32, width_px) orelse return error.Overflow;
    const px_height = std.math.cast(i32, try std.math.mul(
        usize,
        height,
        self.cell_size.height,
    )) orelse return error.Overflow;

    const start_x: f64 = @floatFromInt(std.math.cast(i32, try std.math.mul(
        usize,
        x,
        self.cell_size.width,
    )) orelse return error.Overflow);
    const start_y: f64 = @floatFromInt(std.math.cast(i32, try std.math.mul(
        usize,
        y,
        self.cell_size.height,
    )) orelse return error.Overflow);
    const end_x: f64 = start_x + @as(f64, @floatFromInt(px_width));
    const end_y: f64 = start_y + @as(f64, @floatFromInt(px_height));

    var ctx: z2d.Context = .init(alloc, &self.surface);
    defer ctx.deinit();

    ctx.setAntiAliasingMode(.none);
    ctx.setHairline(true);

    try ctx.moveTo(start_x, start_y);
    try ctx.lineTo(end_x, start_y);
    try ctx.lineTo(end_x, end_y);
    try ctx.lineTo(start_x, end_y);
    try ctx.closePath();

    ctx.setSourceToPixel(fill_color);
    try ctx.fill();

    ctx.setLineWidth(1);
    ctx.setSourceToPixel(border_color);
    try ctx.stroke();
}
