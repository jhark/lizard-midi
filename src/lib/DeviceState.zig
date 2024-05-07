///! A snapshot of a device's state.
///!
///! This exists to be useful to applications that wish to poll the current
///! state of a MIDI input device rather than deal with callbacks or event
///! queues.
///!
///! This does not encapsulate all possible state, and does not respond
///! correctly to every type of message.
const std = @import("std");
const midi = @import("midi.zig");

const DeviceState = @This();

pub const channel_count = 16;

channels: [channel_count]Channel = std.mem.zeroes([channel_count]Channel),

pub const Channel = struct {
    pub const controller_count = 120;
    pub const key_count = std.math.maxInt(u7);

    program: u7 = 0,
    pressure: u7 = 0,
    pitch_bend: i15 = 0, // [-8192, 8191]
    keys: [key_count]Key = std.mem.zeroes([key_count]Key),
    controllers: [controller_count]Controller = std.mem.zeroes([controller_count]Controller),

    pub fn allNotesOff(self: *Channel) void {
        for (&self.keys) |*key| {
            key.velocity = 0;
        }
    }

    /// Returns pitch bend normalised into the range [-1.0, 1.0].
    pub fn normalisedPitchBend(self: *const Channel) f32 {
        const pb = @as(f32, @floatFromInt(self.pitch_bend));
        if (self.pitch_bend > 0) return pb / 8191;
        return pb / 8192;
    }

    /// Returns channel pressure (channel aftertouch) normalised into the range [-1.0, 1.0].
    pub fn normalisedPressure(self: *const Channel) f32 {
        return normalise(u7, self.pressure);
    }

    pub fn controllerValue(self: *const Channel, controller: midi.Controller) u7 {
        const i = @intFromEnum(controller);
        if (i >= self.controllers.len) return 0;
        return self.controllers[i].value;
    }

    /// Returns a controller value normalised into the range [0.0, 1.0].
    pub fn normalisedControllerValue(self: *const Channel, controller: midi.Controller) f32 {
        const i = @intFromEnum(controller);
        if (i >= self.controllers.len) return 0;

        return normalise(u7, self.controllers[i].value);
    }

    /// Returns a controller value normalised into the range [0.0, 1.0].
    ///
    /// Takes into account controllers < 32, which may use two 7-bit values to
    /// represent a 14-bit range.
    pub fn normalisedControllerValue14b(self: *const Channel, controller: midi.Controller) f32 {
        const i = @intFromEnum(controller);
        if (i >= 32) return 0;

        const hi: u14 = self.controllers[i].value;
        const lo: u14 = self.controllers[i + 32].value;
        const v: u14 = (hi << 7) | lo;
        return normalise(u14, v);
    }

    inline fn normalise(comptime T: type, value: T) f32 {
        const vf: f32 = @as(f32, @floatFromInt(value)) / std.math.maxInt(T);
        return vf;
    }

    pub fn resetAllControllers(self: *Channel) void {
        @memset(&self.controllers, Controller{});
        self.controllers[@intFromEnum(midi.Controller.expression_controller)].value = 127;
        self.controllers[@intFromEnum(midi.Controller.non_registered_parameter_number_lsb)].value = 127;
        self.controllers[@intFromEnum(midi.Controller.non_registered_parameter_number_msb)].value = 127;
        self.controllers[@intFromEnum(midi.Controller.registered_parameter_number_lsb)].value = 127;
        self.controllers[@intFromEnum(midi.Controller.registered_parameter_number_msb)].value = 127;
        self.pressure = 0;
        self.pitch_bend = 0;
        for (&self.keys) |*key| {
            key.pressure = 0;
        }
    }
};

pub const Key = struct {
    velocity: u7 = 0,

    /// AKA aftertouch.
    pressure: u7 = 0,
};

pub const Controller = struct {
    value: u7 = 0,
};

pub fn init(self: *DeviceState) void {
    self.reset();
}

pub fn reset(self: *DeviceState) void {
    for (&self.channels) |*ch| {
        ch.allNotesOff();
        ch.resetAllControllers();
    }
}

pub fn update(self: *DeviceState, msg: midi.Message) void {
    switch (msg) {
        .note_off => |v| {
            // Release velocity does technically exist as its own thing, but
            // it is 'normally ignored'.
            self.channels[v.channel].keys[v.key].velocity = 0;
        },
        .note_on => |v| {
            self.channels[v.channel].keys[v.key].velocity = v.velocity;
        },
        .polyphonic_key_pressure => |v| {
            self.channels[v.channel].keys[v.key].pressure = v.pressure;
        },
        .control_change => |v| {
            switch (v.controller) {
                .all_sound_off,
                .all_notes_off,
                .all_notes_off_omni_mode_off,
                .all_notes_off_omni_mode_on,
                .all_notes_off_mono_mode_on,
                .all_notes_off_poly_mode_on,
                => {
                    // const keys: []Key = self.channels[v.channel].keys;
                    @memset(&self.channels[v.channel].keys, Key{});
                },
                .reset_all_controllers => {
                    self.channels[v.channel].resetAllControllers();
                },
                .local_control_on_off => {},
                else => {
                    self.channels[v.channel].controllers[@intFromEnum(v.controller)].value = v.value;
                },
            }
        },
        .program_change => |v| {
            self.channels[v.channel].program = v.program;
        },
        .channel_pressure => |v| {
            self.channels[v.channel].pressure = v.pressure;
        },
        .pitch_bend => |v| {
            var bend: i15 = v.bend;
            bend -= midi.pitch_bend_center;
            self.channels[v.channel].pitch_bend = bend;
        },
        .reset => {
            self.reset();
        },
        else => {},
    }
}
