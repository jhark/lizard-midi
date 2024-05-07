//! Definitions for, and encoding and decoding of MIDI messages.
//!
//! References:
//!
//! https://midi.org/summary-of-midi-1-0-messages
//! https://michd.me/jottings/midi-message-format-reference/
//! https://web.archive.org/web/20150506105425/http://www.midi.org/techspecs/midimessages.php
//! https://en.wikipedia.org/wiki/MIDI_timecode

const std = @import("std");

pub const Controller = @import("controller.zig").Controller;
pub const DeviceState = @import("DeviceState.zig");

pub const pitch_bend_center = 8192;

/// The type of a MIDI message, as stored in the 'status' byte.
pub const MessageType = enum(u8) {
    // MSB always set.

    // Channel voice messages.
    //
    // When packed into the status byte, the lower 4 bits represent the channel.
    note_off = 0b10000000,
    note_on = 0b10010000,
    polyphonic_key_pressure = 0b10100000,
    control_change = 0b10110000,
    program_change = 0b11000000,
    channel_pressure = 0b11010000,
    pitch_bend = 0b11100000,

    // System common messages.
    //
    // 0b11110xxx
    system_exclusive = 0b11110000,
    time_code_quarter_frame = 0b11110001,
    song_position_pointer = 0b11110010,
    song_select = 0b11110011,
    reserved_syscommon_0 = 0b11110100,
    reserved_syscommon_1 = 0b11110101,
    tune_request = 0b11110110,
    end_of_exclusive = 0b11110111,

    // System Real-Time Messages
    //
    // 0b11111xxx (120-127)
    timing_clock = 0b11111000,
    reserved_sysrt_0 = 0b11111001,
    start_sequence = 0b11111010,
    continue_sequence = 0b11111011,
    stop_sequence = 0b11111100,
    reserved_sysrt_1 = 0b11111101,
    active_sensing = 0b11111110,
    reset = 0b11111111,

    _,
};

fn statusToType(status: u8) MessageType {
    const sysRtMask = 0b11111000;
    if (status & sysRtMask == sysRtMask) {
        return @enumFromInt(status);
    }

    const sysCommonMask = 0b11110000;
    if (status & sysCommonMask == sysCommonMask) {
        return @enumFromInt(status);
    }

    return @enumFromInt(status & 0xf0);
}

pub const Message = union(MessageType) {
    // Channel voice,
    note_off: NoteOff,
    note_on: NoteOn,
    polyphonic_key_pressure: PolyphonicKeyPressure,
    control_change: ControlChange,
    program_change: ProgramChange,
    channel_pressure: ChannelPressure,
    pitch_bend: PitchBend,

    // System common.
    system_exclusive: SystemExclusive,
    time_code_quarter_frame: TimeCodeQuarterFrame,
    song_position_pointer: SongPositionPointer,
    song_select: SongSelect,
    reserved_syscommon_0,
    reserved_syscommon_1,
    tune_request,
    end_of_exclusive,

    // System real-time.
    timing_clock,
    reserved_sysrt_0,
    start_sequence,
    continue_sequence,
    stop_sequence,
    reserved_sysrt_1,
    active_sensing,
    reset,
};

pub const NoteOff = struct {
    channel: u4,
    key: u7,
    velocity: u7,
};

/// Note that 'note on' message with a velocity of zero is commonly used instead
/// of an explicit 'note off' message.
pub const NoteOn = struct {
    channel: u4,
    key: u7,
    velocity: u7,
};

/// Per-note aftertouch.
pub const PolyphonicKeyPressure = struct {
    channel: u4,
    key: u7,
    pressure: u7,
};

pub const ControlChange = struct {
    channel: u4,
    controller: Controller,
    value: u7,
};

pub const ProgramChange = struct {
    channel: u4,
    program: u7,
};

/// Per-channel aftertouch.
pub const ChannelPressure = struct {
    channel: u4,
    pressure: u7,
};

pub const PitchBend = struct {
    channel: u4,
    bend: u14,
};

pub const SystemExclusive = struct {
    data1: u7,
    data2: u7,
};

/// The sub-type of a time-code-quarter-frame message.
pub const TcqfType = enum(u3) {
    frame_number_lo = 0b000, // ffff
    frame_number_hi = 0b001, // 000f
    second_lo = 0b010, // ssss
    second_hi = 0b011, // 00ss
    minute_lo = 0b100, // mmmm
    minute_hi = 0b101, // 00mm
    hour_lo = 0b110, // hhhh
    rate_and_hour_hi = 0b111, // 0rrh
};

pub const TimeCodeQuarterFrame = union(TcqfType) {
    frame_number_lo: TcqfFrameNumberLo,
    frame_number_hi: TcqfFrameNumberHi,
    second_lo: TcqfSecondLo,
    second_hi: TcqfSecondHi,
    minute_lo: TcqfMinuteLo,
    minute_hi: TcqfMinuteHi,
    hour_lo: TcqfHourLo,
    rate_and_hour_hi: TcqfRateAndHourHi,
};

pub const TcqfFrameNumberLo = packed struct(u4) {
    frame_number_lo: u4,
};

pub const TcqfFrameNumberHi = packed struct(u4) {
    frame_number_hi: u1,
    _: u3 = 0,
};

pub const TcqfSecondLo = packed struct(u4) {
    second_lo: u4,
};

pub const TcqfSecondHi = packed struct(u4) {
    second_lo: u2,
    _: u2 = 0,
};

pub const TcqfMinuteLo = packed struct(u4) {
    minute_lo: u4,
};

pub const TcqfMinuteHi = packed struct(u4) {
    minute_hi: u2,
    _: u2 = 0,
};

pub const TcqfHourLo = packed struct(u4) {
    hour_lo: u4,
};

pub const TcqfRateAndHourHi = packed struct(u4) {
    hour_hi: u1,
    rate: u2,
    _: u1 = 0,
};

pub const SongPositionPointer = struct {
    /// Number of beats since start of song(/sequence). 1 beat = six MIDI clocks.
    beats: u14,
};

pub const SongSelect = struct {
    /// (or sequence)
    song: u7,
};

pub fn unpackMessage(status: u8, data1: u8, data2: u8) !Message {
    const msgType = statusToType(status);
    switch (msgType) {
        .note_off => {
            const ch = getChannel(status);
            const key = get7(data1);
            const velocity = get7(data2);
            return Message{
                .note_off = .{
                    .channel = ch,
                    .key = key,
                    .velocity = velocity,
                },
            };
        },
        .note_on => {
            const ch = getChannel(status);
            const key = get7(data1);
            const velocity = get7(data2);
            return Message{
                .note_on = .{
                    .channel = ch,
                    .key = key,
                    .velocity = velocity,
                },
            };
        },
        .polyphonic_key_pressure => {
            const ch = getChannel(status);
            const key = get7(data1);
            const pressure = get7(data2);
            return Message{
                .polyphonic_key_pressure = .{
                    .channel = ch,
                    .key = key,
                    .pressure = pressure,
                },
            };
        },
        .control_change => {
            const ch = getChannel(status);
            const controller = get7(data1);
            const value = get7(data2);
            return Message{
                .control_change = .{
                    .channel = ch,
                    .controller = @enumFromInt(controller),
                    .value = value,
                },
            };
        },
        .program_change => {
            const ch = getChannel(status);
            const program = get7(data1);
            return Message{
                .program_change = .{
                    .channel = ch,
                    .program = program,
                },
            };
        },
        .channel_pressure => {
            const ch = getChannel(status);
            const pressure = get7(data1);
            return Message{
                .channel_pressure = .{
                    .channel = ch,
                    .pressure = pressure,
                },
            };
        },
        .pitch_bend => {
            const ch = getChannel(status);
            const bend: u14 = get14(data1, data2);
            return Message{
                .pitch_bend = .{
                    .channel = ch,
                    .bend = bend,
                },
            };
        },
        .system_exclusive => {
            return Message{
                .system_exclusive = .{
                    .data1 = get7(data1),
                    .data2 = get7(data2),
                },
            };
        },
        .time_code_quarter_frame => {
            return Message{
                .time_code_quarter_frame = unpackTcqf(@bitCast(data1)),
            };
        },
        .song_position_pointer => {
            return Message{
                .song_position_pointer = .{
                    .beats = get14(data1, data2),
                },
            };
        },
        .song_select => {
            return Message{
                .song_select = .{
                    .song = get7(data1),
                },
            };
        },
        .reserved_syscommon_0 => {
            return Message{
                .reserved_syscommon_0 = void{},
            };
        },
        .reserved_syscommon_1 => {
            return Message{
                .reserved_syscommon_1 = void{},
            };
        },
        .tune_request => {
            return Message{
                .tune_request = void{},
            };
        },
        .end_of_exclusive => {
            return Message{
                .end_of_exclusive = void{},
            };
        },
        .timing_clock => {
            return Message{
                .timing_clock = void{},
            };
        },
        .reserved_sysrt_0 => {
            return Message{
                .reserved_sysrt_0 = void{},
            };
        },
        .start_sequence => {
            return Message{
                .start_sequence = void{},
            };
        },
        .continue_sequence => {
            return Message{
                .continue_sequence = void{},
            };
        },
        .stop_sequence => {
            return Message{
                .stop_sequence = void{},
            };
        },
        .reserved_sysrt_1 => {
            return Message{
                .reserved_sysrt_1 = void{},
            };
        },
        .active_sensing => {
            return Message{
                .active_sensing = void{},
            };
        },
        .reset => {
            return Message{
                .reserved_syscommon_0 = void{},
            };
        },
        _ => {
            return error.UnrecognisedMidiMessage;
        },
    }
}

pub const PackedMessage = struct {
    status: u8 = 0,
    data1: u8 = 0,
    data2: u8 = 0,
};

pub fn packMessage(message: Message) PackedMessage {
    const messageType: MessageType = message;
    const messageTypeU: u8 = @intFromEnum(messageType);
    switch (message) {
        .note_off => |v| {
            return PackedMessage{
                .status = messageTypeU | v.channel,
                .data1 = v.key,
                .data2 = v.velocity,
            };
        },
        .note_on => |v| {
            return PackedMessage{
                .status = messageTypeU | v.channel,
                .data1 = v.key,
                .data2 = v.velocity,
            };
        },
        .polyphonic_key_pressure => |v| {
            return PackedMessage{
                .status = messageTypeU | v.channel,
                .data1 = v.key,
                .data2 = v.pressure,
            };
        },
        .control_change => |v| {
            return PackedMessage{
                .status = messageTypeU | v.channel,
                .data1 = @intFromEnum(v.controller),
                .data2 = v.value,
            };
        },
        .program_change => |v| {
            return PackedMessage{
                .status = messageTypeU | v.channel,
                .data1 = v.program,
            };
        },
        .channel_pressure => |v| {
            return PackedMessage{
                .status = messageTypeU | v.channel,
                .data1 = v.pressure,
            };
        },
        .pitch_bend => |v| {
            const pu14: PackedU14 = @bitCast(v.bend);
            return PackedMessage{
                .status = messageTypeU | v.channel,
                .data1 = pu14.lo,
                .data2 = pu14.hi,
            };
        },
        .system_exclusive => |v| {
            return PackedMessage{
                .status = messageTypeU,
                .data1 = v.data1,
                .data2 = v.data2,
            };
        },
        .time_code_quarter_frame => |v| {
            return packTcqf(v);
        },
        .song_position_pointer => |v| {
            const pu14: PackedU14 = @bitCast(v.beats);
            return PackedMessage{
                .status = messageTypeU,
                .data1 = pu14.lo,
                .data2 = pu14.hi,
            };
        },
        .song_select => |v| {
            return PackedMessage{
                .status = messageTypeU,
                .data1 = v.song,
            };
        },
        .reserved_syscommon_0,
        .reserved_syscommon_1,
        .tune_request,
        .end_of_exclusive,
        .timing_clock,
        .reserved_sysrt_0,
        .start_sequence,
        .continue_sequence,
        .stop_sequence,
        .reserved_sysrt_1,
        .active_sensing,
        .reset,
        => {
            return PackedMessage{
                .status = messageTypeU,
            };
        },
    }
}

const Tcqf = packed struct(u8) {
    data: u4,
    type: u3,
    _: u1 = 0,
};

fn packTcqf(message: TimeCodeQuarterFrame) PackedMessage {
    const t: TcqfType = message;
    const tu: u3 = @intFromEnum(t);
    const data: u4 = switch (message) {
        .frame_number_lo => |v| @bitCast(v),
        .frame_number_hi => |v| @bitCast(v),
        .second_lo => |v| @bitCast(v),
        .second_hi => |v| @bitCast(v),
        .minute_lo => |v| @bitCast(v),
        .minute_hi => |v| @bitCast(v),
        .hour_lo => |v| @bitCast(v),
        .rate_and_hour_hi => |v| @bitCast(v),
    };

    return PackedMessage{
        .status = @intFromEnum(MessageType.time_code_quarter_frame),
        .data1 = @bitCast(Tcqf{ .type = tu, .data = @bitCast(data) }),
    };
}

fn unpackTcqf(tcqf: Tcqf) TimeCodeQuarterFrame {
    const t: TcqfType = @enumFromInt(tcqf.type);
    return switch (t) {
        .frame_number_lo => TimeCodeQuarterFrame{
            .frame_number_lo = @bitCast(tcqf.data),
        },
        .frame_number_hi => TimeCodeQuarterFrame{
            .frame_number_hi = @bitCast(tcqf.data),
        },
        .second_lo => TimeCodeQuarterFrame{
            .second_lo = @bitCast(tcqf.data),
        },
        .second_hi => TimeCodeQuarterFrame{
            .second_hi = @bitCast(tcqf.data),
        },
        .minute_lo => TimeCodeQuarterFrame{
            .minute_lo = @bitCast(tcqf.data),
        },
        .minute_hi => TimeCodeQuarterFrame{
            .minute_hi = @bitCast(tcqf.data),
        },
        .hour_lo => TimeCodeQuarterFrame{
            .hour_lo = @bitCast(tcqf.data),
        },
        .rate_and_hour_hi => TimeCodeQuarterFrame{
            .rate_and_hour_hi = @bitCast(tcqf.data),
        },
    };
}

fn getChannel(status: u8) u4 {
    return @intCast(status & 0b1111);
}

fn get7(data: u8) u7 {
    return @intCast(data & 0b01111111);
}

const PackedU14 = packed struct(u14) {
    lo: u7,
    hi: u7,
};

fn get14(data1: u8, data2: u8) u14 {
    const lo: u14 = get7(data1);
    const hi: u14 = get7(data2);
    return @intCast((hi << 7) | lo);
}

test "message packing" {
    const Local = struct {
        fn testPackUnpack(msg: Message) !void {
            const msg_packed = packMessage(msg);
            const msg_unpacked = try unpackMessage(
                msg_packed.status,
                msg_packed.data1,
                msg_packed.data2,
            );
            try std.testing.expectEqualDeep(msg, msg_unpacked);
        }
    };

    try Local.testPackUnpack(
        Message{
            .note_off = .{
                .channel = 0,
                .key = 32,
                .velocity = 0,
            },
        },
    );

    try Local.testPackUnpack(
        Message{
            .time_code_quarter_frame = .{
                .rate_and_hour_hi = .{
                    .hour_hi = 1,
                    .rate = 2,
                },
            },
        },
    );

    {
        const tcData: u8 = 0b0111_0101; // 0b0111_0rrh
        const msg = try unpackMessage(
            @intFromEnum(MessageType.time_code_quarter_frame),
            tcData,
            0,
        );
        try std.testing.expectEqualDeep(
            msg,
            Message{
                .time_code_quarter_frame = .{
                    .rate_and_hour_hi = .{
                        .hour_hi = 0b1,
                        .rate = 0b10,
                    },
                },
            },
        );
    }
}
