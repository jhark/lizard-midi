pub const InputDevice = @import("InputDevice.zig");
pub const OutputDevice = @import("OutputDevice.zig");
pub const DeviceState = @import("DeviceState.zig");

pub const log = @import("log.zig").log;
pub const winmm = @import("winmm.zig");

pub usingnamespace @import("midi.zig");

/// Routes MIDI messages from one device to another.
pub fn connect(input: *InputDevice, output: *OutputDevice) winmm.SysErr!void {
    try winmm.connect(input.handle, output.handle);
}

pub fn disconnect(input: *InputDevice, output: *OutputDevice) winmm.SysErr!void {
    try winmm.disconnect(input.handle, output.handle);
}
