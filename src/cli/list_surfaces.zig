const std = @import("std");
const Allocator = std.mem.Allocator;
const Action = @import("../cli.zig").ghostty.Action;
const apprt = @import("../apprt.zig");
const global = @import("../global.zig");
const args = @import("args.zig");
const TempDir = @import("../os/TempDir.zig");

pub const Options = struct {
    format: Format = .json,

    const Format = enum {
        json,
    };

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `list-surfaces` command lists every open terminal surface in the
/// currently running Ghostty instance.
///
/// The output is pretty-printed JSON intended for machine-readable tooling.
///
/// Flags:
///
///   * `--format=json`: Output surfaces as JSON.
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc, global.args());
    defer iter.deinit();

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &buffer);
    const stderr = &stderr_writer.interface;

    const result = runArgs(alloc, &iter, stderr);
    stderr.flush() catch {};
    return result;
}

fn runArgs(
    alloc: Allocator,
    args_iter: anytype,
    stderr: *std.Io.Writer,
) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    args.parse(Options, alloc, &opts, args_iter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.print("Error parsing args: {}\n", .{err});
            return 1;
        },
    };

    var temp_dir = try TempDir.init();
    defer temp_dir.deinit();

    const temp_path = try temp_dir.dir.realPathFileAlloc(global.io(), ".", alloc);
    defer alloc.free(temp_path);

    const response_path = try std.fs.path.joinZ(alloc, &.{ temp_path, "list-surfaces.json" });
    defer alloc.free(response_path);

    if (apprt.App.performIpc(
        alloc,
        .detect,
        .list_surfaces,
        .{
            .response_path = response_path,
        },
    ) catch |err| switch (err) {
        error.IPCFailed => {
            try stderr.print("No running Ghostty instance responded to +list-surfaces.\n", .{});
            return 1;
        },
        else => {
            try stderr.print("Sending the IPC failed: {}\n", .{err});
            return 1;
        },
    }) {
        const response = waitForResponse(alloc, response_path) catch |err| switch (err) {
            error.IPCFailed => {
                try stderr.print("No running Ghostty instance responded to +list-surfaces.\n", .{});
                return 1;
            },
            else => {
                try stderr.print("Failed to read the +list-surfaces response: {}\n", .{err});
                return 1;
            },
        };
        defer alloc.free(response);

        var stdout: std.Io.File = .stdout();
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer = stdout.writer(global.io(), &stdout_buffer);
        try stdout_writer.interface.writeAll(response);
        try stdout_writer.interface.writeByte('\n');
        try stdout_writer.interface.flush();
        return 0;
    }

    try stderr.print("+list-surfaces is not supported on this platform.\n", .{});
    return 1;
}

fn waitForResponse(
    alloc: Allocator,
    response_path: []const u8,
) ![]u8 {
    const attempts = 50;
    const sleep_ns = 100 * std.time.ns_per_ms;

    for (0..attempts) |_| {
        const file = std.Io.Dir.openFileAbsolute(global.io(), response_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try std.Io.sleep(global.io(), .fromNanoseconds(sleep_ns), .awake);
                continue;
            },
            else => return err,
        };
        defer file.close(global.io());

        const stat = try file.stat(global.io());
        if (stat.size == 0) {
            try std.Io.sleep(global.io(), .fromNanoseconds(sleep_ns), .awake);
            continue;
        }

        var reader = file.reader(global.io(), &.{});
        return try reader.interface.allocRemaining(alloc, .limited64(stat.size));
    }

    return error.IPCFailed;
}
