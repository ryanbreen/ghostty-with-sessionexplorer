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

/// Codepoint index of the cursor within `prompt_editor_buffer` for the
/// current frame. Used to position the visible caret in the bar.
prompt_editor_cursor: usize = 0,

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
pub fn setPromptEditorBuffer(
    self: *Overlay,
    buf: []const u8,
    cursor_codepoint_idx: usize,
) void {
    self.prompt_editor_buffer = buf;
    self.prompt_editor_cursor = cursor_codepoint_idx;
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

/// Draw the prompt editor's bottom-rows indicator. A 2-cell-tall bar
/// painted with a near-opaque magenta fill, sitting one row above the
/// viewport's bottom (so the entire bar is comfortably visible — macOS
/// window chrome can otherwise eat the very-bottom row). Editor buffer
/// text is rendered in white inside the bar.
fn drawPromptEditorBar(
    self: *Overlay,
    alloc: Allocator,
    state: *const terminal.RenderState,
) void {
    const row_count = state.row_data.len;
    const bar_height_cells: usize = 2;
    const bottom_padding_cells: usize = 1;
    if (row_count < bar_height_cells + bottom_padding_cells) return;

    const cols = blk: {
        const row_slice = state.row_data.slice();
        const cells = row_slice.items(.cells);
        if (cells.len == 0) break :blk @as(usize, 0);
        break :blk cells[0].slice().items(.raw).len;
    };
    if (cols == 0) return;

    const bar_top_row = row_count - bar_height_cells - bottom_padding_cells;
    const border = Color.prompt_editor.rectBorder();

    // Use a high-alpha (near opaque) fill so the bar reads clearly even
    // against arbitrary terminal output behind it. The standard
    // rectFill (alpha 96 / 38%) is too faint at editor sizes.
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

    // Set up shared rendering geometry (used for both text and cursor).
    const font = self.ensurePromptEditorFont(alloc);

    const cell_w_f: f64 = @floatFromInt(self.cell_size.width);
    const cell_h_f: f64 = @floatFromInt(self.cell_size.height);
    const bar_top_f: f64 = @as(f64, @floatFromInt(bar_top_row)) * cell_h_f;
    const opts_size: f64 = cell_h_f * 0.85;
    const x_start: f64 = cell_w_f * 0.4;
    const text_y: f64 = bar_top_f + cell_h_f * 0.45;

    // Per-glyph advance in pixels for monospace. SFNSMono returns the
    // same advance for every glyph, so advance_width_max scaled to
    // opts_size gives us a precise caret position too.
    const advance_px: f64 = if (font) |f| advance: {
        const upm: f64 = @floatFromInt(f.meta.units_per_em);
        const adv: f64 = @floatFromInt(f.meta.advance_width_max);
        break :advance adv * (opts_size / upm);
    } else cell_w_f;

    // Render buffer text on top of the bar.
    const white: z2d.Pixel = .{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } };
    if (self.prompt_editor_buffer.len > 0) {
        if (font) |f| {
            var pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = white } };
            z2d.text.show(
                alloc,
                &self.surface,
                &pattern,
                f,
                self.prompt_editor_buffer,
                x_start,
                text_y,
                .{ .size = opts_size, .fill_opts = .{} },
            ) catch |err| {
                log.warn("Error rendering prompt editor text: {}", .{err});
            };
        }
    }

    // Caret. Drawn even on an empty buffer so the user sees where their
    // input will land.
    const caret_x: f64 = x_start + @as(f64, @floatFromInt(
        self.prompt_editor_cursor,
    )) * advance_px;
    self.drawCaret(alloc, caret_x, bar_top_f, cell_h_f) catch |err| {
        log.warn("Error rendering prompt editor caret: {}", .{err});
    };
}

/// Draw a 2-pixel-wide white vertical caret at `(x, bar_top_y)`,
/// spanning the full 2-cell bar height. Inset 2px top/bottom so the
/// caret doesn't touch the bar's border.
fn drawCaret(
    self: *Overlay,
    alloc: Allocator,
    x: f64,
    bar_top_y: f64,
    cell_h: f64,
) !void {
    const caret_w: f64 = 2.0;
    const inset: f64 = 2.0;
    const top: f64 = bar_top_y + inset;
    const bottom: f64 = bar_top_y + (cell_h * 2.0) - inset;

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
