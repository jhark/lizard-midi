const std = @import("std");

/// A ring buffer of elements of type T.
///
/// The buffer does not change size after being allocated.
pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        values: []T = &.{},
        write_count: usize = 0,
        read_count: usize = 0,

        pub const Error = error{ Full, Empty };

        pub fn init(self: *Self, allocator: std.mem.Allocator, capacity: usize) !void {
            std.debug.assert(self.values.len == 0);
            const buf = try allocator.alloc(T, capacity);
            self.values = buf;
            self.write_count = 0;
            self.read_count = 0;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.values);
            self.* = .{};
        }

        pub fn push(self: *Self, value: T) Error!void {
            if (self.isFull()) return Error.Full;
            const i = self.getIndex(self.write_count);
            self.write_count += 1;
            self.values[i] = value;
        }

        pub fn pop(self: *Self) Error!T {
            if (self.isEmpty()) return Error.Empty;
            const i = self.getIndex(self.read_count);
            self.read_count += 1;
            return self.values[i];
        }

        pub fn isEmpty(self: *Self) bool {
            return self.write_count == self.read_count;
        }

        pub fn isFull(self: *Self) bool {
            return (self.write_count - self.read_count) == self.values.len;
        }

        fn getIndex(self: *Self, count: usize) usize {
            return count % self.values.len;
        }
    };
}

test "RingBuffer" {
    const allocator = std.testing.allocator;

    const T = u32;
    const RB = RingBuffer(T);
    const t = struct {
        fn expectFull(actual: anytype) !void {
            try std.testing.expectError(RB.Error.Full, actual);
        }
        fn expectEmpty(actual: anytype) !void {
            try std.testing.expectError(RB.Error.Empty, actual);
        }
        fn expectValue(expected: T, actual: anytype) !void {
            try std.testing.expectEqual(expected, actual);
        }
    };

    {
        var ring_buffer = RB{};
        try t.expectFull(ring_buffer.push(1));
        try t.expectEmpty(ring_buffer.pop());
    }

    {
        var ring_buffer = RB{};
        try ring_buffer.init(allocator, 4);
        defer ring_buffer.deinit(allocator);

        try ring_buffer.push(1);
        try ring_buffer.push(2);
        try ring_buffer.push(3);
        try ring_buffer.push(4);
        try t.expectFull(ring_buffer.push(5));
        try t.expectFull(ring_buffer.push(6));
        try t.expectValue(1, try ring_buffer.pop());
        try t.expectValue(2, try ring_buffer.pop());
        try t.expectValue(3, try ring_buffer.pop());
        try t.expectValue(4, try ring_buffer.pop());
        try t.expectEmpty(ring_buffer.pop());
        try t.expectEmpty(ring_buffer.pop());
    }
}
