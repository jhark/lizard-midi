const std = @import("std");
const midi = @import("midi.zig");
const winmm = @import("winmm.zig");

const OutputDevice = @This();

pub const Handle = winmm.OutputDeviceHandle;
pub const Error = winmm.SysErr;
pub const Info = winmm.OutputDeviceInfo;

handle: Handle = null,

/// Gets the number of input devices currently available.
pub fn count() usize {
    return winmm.outputDeviceCount();
}

/// Retrieves information about a device.
pub fn info(device_index: usize, o_info: *Info) !void {
    if (device_index > std.math.maxInt(u32)) return Error.BadDeviceId;
    const device_index32: u32 = @intCast(device_index);

    return winmm.outputDeviceInfo(device_index32, o_info);
}

/// Finds the first device with the given name.
pub fn find(name: []const u8) ?usize {
    const device_count = winmm.outputDeviceCount();
    for (0..device_count) |device_index| {
        var device_info = Info{};
        winmm.outputDeviceInfo(device_index, &device_info) catch continue;
        if (std.mem.eql(u8, name, device_info.name)) {
            return device_index;
        }
    }

    return null;
}

pub fn open(self: *OutputDevice, device_index: usize) winmm.SysErr!void {
    if (self.handle != null) {
        std.debug.panic("midi device {*} already open", .{self.handle});
    }
    if (device_index > std.math.maxInt(u32)) return Error.BadDeviceId;
    const device_index32: u32 = @intCast(device_index);

    self.handle = try winmm.outputOpen(device_index32);
}

pub fn close(self: *OutputDevice) winmm.SysErr!void {
    if (self.handle != null) {
        try winmm.outputClose(self.handle);
    }

    self.* = .{};
}

pub fn send(self: *OutputDevice, msg: midi.Message) winmm.SysErr!void {
    return winmm.outputSendMessage(self.handle, msg);
}
