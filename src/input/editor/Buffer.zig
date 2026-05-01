//! The text buffer for the prompt editor.
//!
//! For Phase 1 this is a flat UTF-8 buffer backed by an ArrayList. The
//! interface (`insertAt`, `deleteRange`, `text`) is identical to what a
//! tree-backed buffer would expose, so swapping the substrate later is
//! a single-file change.
const Buffer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

alloc: Allocator,
bytes: std.ArrayListUnmanaged(u8) = .{},

pub fn init(alloc: Allocator) Buffer {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *Buffer) void {
    self.bytes.deinit(self.alloc);
}

/// Number of bytes currently in the buffer.
pub fn len(self: *const Buffer) usize {
    return self.bytes.items.len;
}

/// Read-only view of the buffer contents.
pub fn text(self: *const Buffer) []const u8 {
    return self.bytes.items;
}

/// Insert bytes at the given byte offset. Caller is responsible for
/// ensuring `byte_offset` falls on a UTF-8 codepoint boundary.
pub fn insertAt(
    self: *Buffer,
    byte_offset: usize,
    slice: []const u8,
) Allocator.Error!void {
    std.debug.assert(byte_offset <= self.bytes.items.len);
    try self.bytes.insertSlice(self.alloc, byte_offset, slice);
}

/// Delete `byte_count` bytes starting at `byte_offset`. Caller is
/// responsible for ensuring both endpoints fall on UTF-8 codepoint
/// boundaries.
pub fn deleteRange(
    self: *Buffer,
    byte_offset: usize,
    byte_count: usize,
) void {
    std.debug.assert(byte_offset + byte_count <= self.bytes.items.len);
    self.bytes.replaceRangeAssumeCapacity(byte_offset, byte_count, &.{});
}

/// Reset the buffer to empty. Capacity is retained.
pub fn clear(self: *Buffer) void {
    self.bytes.clearRetainingCapacity();
}

test "Buffer: insert and read" {
    const testing = std.testing;
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    try buf.insertAt(0, "hello");
    try testing.expectEqualStrings("hello", buf.text());

    try buf.insertAt(5, " world");
    try testing.expectEqualStrings("hello world", buf.text());

    try buf.insertAt(5, ",");
    try testing.expectEqualStrings("hello, world", buf.text());
}

test "Buffer: delete" {
    const testing = std.testing;
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    try buf.insertAt(0, "hello, world");
    buf.deleteRange(5, 2);
    try testing.expectEqualStrings("helloworld", buf.text());
}

test "Buffer: clear" {
    const testing = std.testing;
    var buf: Buffer = .init(testing.allocator);
    defer buf.deinit();

    try buf.insertAt(0, "abc");
    buf.clear();
    try testing.expectEqual(@as(usize, 0), buf.len());
    try testing.expectEqualStrings("", buf.text());
}
