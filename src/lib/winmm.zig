//! Wrappers for the Windows Multimedia (winmm) MIDI API.
//!
//! References:
//!
//! * https://learn.microsoft.com/en-us/windows/win32/multimedia/musical-instrument-digital-interface--midi
//! * https://learn.microsoft.com/en-gb/windows/win32/multimedia/midi-reference
//! * https://learn.microsoft.com/en-gb/windows/win32/multimedia/midi-functions

const std = @import("std");
const win32 = @cImport(@cInclude("Windows.h"));
const midi = @import("midi.zig");
const log = @import("log.zig").log;

pub const InputDeviceHandle = win32.HMIDIIN;
pub const OutputDeviceHandle = win32.HMIDIOUT;

pub const MidiMessageEvent = struct {
    timestamp: u64, // Milliseconds since 'start'.
    payload: midi.Message,
};

const MmSysErr = enum(c_int) {
    no_error = win32.MMSYSERR_NOERROR,
    @"error" = win32.MMSYSERR_ERROR,
    bad_device_id = win32.MMSYSERR_BADDEVICEID,
    not_enabled = win32.MMSYSERR_NOTENABLED,
    allocated = win32.MMSYSERR_ALLOCATED,
    inval_handle = win32.MMSYSERR_INVALHANDLE,
    no_driver = win32.MMSYSERR_NODRIVER,
    no_mem = win32.MMSYSERR_NOMEM,
    not_supported = win32.MMSYSERR_NOTSUPPORTED,
    bad_err_num = win32.MMSYSERR_BADERRNUM,
    inval_flag = win32.MMSYSERR_INVALFLAG,
    inval_param = win32.MMSYSERR_INVALPARAM,
    handle_busy = win32.MMSYSERR_HANDLEBUSY,
    invalid_alias = win32.MMSYSERR_INVALIDALIAS,
    bad_db = win32.MMSYSERR_BADDB,
    key_not_found = win32.MMSYSERR_KEYNOTFOUND,
    read_error = win32.MMSYSERR_READERROR,
    write_error = win32.MMSYSERR_WRITEERROR,
    delete_error = win32.MMSYSERR_DELETEERROR,
    val_not_found = win32.MMSYSERR_VALNOTFOUND,
    no_driver_cb = win32.MMSYSERR_NODRIVERCB,
    more_data = win32.MMSYSERR_MOREDATA,
    unprepared = win32.MIDIERR_UNPREPARED,
    still_playing = win32.MIDIERR_STILLPLAYING,
    no_map = win32.MIDIERR_NOMAP,
    not_ready = win32.MIDIERR_NOTREADY,
    no_device = win32.MIDIERR_NODEVICE,
    invalid_setup = win32.MIDIERR_INVALIDSETUP,
    bad_open_mode = win32.MIDIERR_BADOPENMODE,
    dont_continue = win32.MIDIERR_DONT_CONTINUE,
    _,
};

pub const SysErr = error{
    UnknownError,
    Error,
    BadDeviceId,
    NotEnabled,
    Allocated,
    InvalHandle,
    NoDriver,
    NoMem,
    NotSupported,
    BadErrNum,
    InvalFlag,
    InvalParam,
    HandleBusy,
    InvalidAlias,
    BadDb,
    KeyNotFound,
    ReadError,
    WriteError,
    DeleteError,
    ValNotFound,
    NoDriverCb,
    MoreData,
    Unprepared,
    StillPlaying,
    NoMap,
    NotReady,
    NoDevice,
    InvalidSetup,
    BadOpenMode,
    DontContinue,
};

pub const Technology = enum(c_int) {
    midi_port = win32.MOD_MIDIPORT, // MIDI hardware port.
    synth = win32.MOD_SYNTH, // Synthesizer.
    sq_synth = win32.MOD_SQSYNTH, // Square wave synthesizer.
    fm_synth = win32.MOD_FMSYNTH, // FM synthesizer.
    mapper = win32.MOD_MAPPER, // Microsoft MIDI mapper.
    wavetable = win32.MOD_WAVETABLE, // Hardware wavetable synthesizer.
    sw_synth = win32.MOD_SWSYNTH, // Software synthesizer.
    _,
};

pub const Capabilities = packed struct(u32) {
    patch_caching: bool = false,
    lr_volume: bool = false,
    stream: bool = false,
    volume: bool = false,
    _: u28 = 0,
};

const InputCallbackEventType = enum(win32.DWORD_PTR) {
    open = win32.MIM_OPEN,
    close = win32.MIM_CLOSE,
    data = win32.MIM_DATA,
    long_data = win32.MIM_LONGDATA,
    more_data = win32.MIM_MOREDATA,
    @"error" = win32.MIM_ERROR,
    long_error = win32.MIM_LONGERROR,
    _,
};

const OutputCallbackMessageType = enum(win32.UINT) {
    open = win32.MOM_OPEN,
    close = win32.MOM_CLOSE,
    done = win32.MOM_DONE,
    _,
};

//
// Input.
//

pub const InputEvent = union(InputCallbackEventType) {
    open,
    close,
    data: ShortMessage,
    long_data: LongMessage,
    more_data: ShortMessage,
    @"error": ShortMessage,
    long_error: LongMessage,

    /// Milliseconds since `start` was called on the device.
    const Timestamp = u64;

    pub const ShortMessage = struct {
        msg: midi.Message,
        timestamp: Timestamp,
    };

    pub const LongMessage = struct {
        midiMessage: *win32.MIDIHDR,
        timestamp: Timestamp,
    };
};

const InputCallbackTypeTrampoline = fn (
    ctx: usize,
    device_handle: InputDeviceHandle,
    event: InputEvent,
) void;

/// Example:
///
/// ```
/// const Handler = struct {
///     fn handleEvent(
///         self: *@This(),
///         device_handle: winmm.InputDeviceHandle,
///         event: winmm.InputEvent,
///     ) void {
///         _ = device_handle;
///         self.count += 1;
///         std.debug.print("{} {}\n", .{ self.count, event });
///     }
///
///     count: u64 = 0,
/// };
///
/// var handler = Handler{};
/// const device_handle = try winmm.inputOpen(0, &handler, Handler.handleEvent);
/// try winmm.inputStart(handle);
/// ...
/// ```
pub inline fn inputOpen(
    device_index: u32,
    ctx: anytype,
    comptime callback: fn (
        ctx: @TypeOf(ctx),
        device_handle: InputDeviceHandle,
        event: InputEvent,
    ) void,
) SysErr!InputDeviceHandle {
    deadlock_detector.checkNotCallbackThread();

    const Context = @TypeOf(ctx);

    const Local = struct {
        // Drops C calling convention and injects another per-type trampoline to
        // convert the context type.
        fn trampoline1(
            device_handle: win32.HMIDIIN,
            event_type: win32.DWORD_PTR,
            ctx1: win32.DWORD_PTR,
            param1: win32.DWORD_PTR,
            param2: win32.DWORD_PTR,
        ) callconv(.C) void {
            inputCallback(device_handle, event_type, ctx1, param1, param2, trampoline2);
        }

        // Per-context-type trampoline to convert from opaque context.
        fn trampoline2(
            ctxo: usize,
            device_handle: InputDeviceHandle,
            event: InputEvent,
        ) void {
            const ctxT: Context = switch (@typeInfo(Context)) {
                .pointer => @ptrFromInt(ctxo),
                else => @intCast(ctxo),
            };
            callback(ctxT, device_handle, event);
        }
    };

    const instance: win32.DWORD_PTR = switch (@typeInfo(Context)) {
        .pointer => @intFromPtr(ctx),
        else => @intCast(ctx),
    };

    var device_handle: InputDeviceHandle = undefined;
    const mmr = win32.midiInOpen(
        &device_handle,
        device_index,
        @intFromPtr(&Local.trampoline1),
        instance,
        win32.CALLBACK_FUNCTION | win32.MIDI_IO_STATUS,
    );
    try checkInputMmResult(mmr);
    return device_handle;
}

pub fn inputStart(device_handle: InputDeviceHandle) SysErr!void {
    deadlock_detector.checkNotCallbackThread();

    const mmr = win32.midiInStart(device_handle);
    try checkInputMmResult(mmr);
}

pub fn inputStop(device_handle: InputDeviceHandle) SysErr!void {
    deadlock_detector.checkNotCallbackThread();

    const mmr = win32.midiInStop(device_handle);
    try checkInputMmResult(mmr);
}

pub fn inputClose(device_handle: InputDeviceHandle) SysErr!void {
    deadlock_detector.checkNotCallbackThread();

    const mmr = win32.midiInClose(device_handle);
    try checkInputMmResult(mmr);
}

pub fn inputDeviceCount() u32 {
    deadlock_detector.checkNotCallbackThread();

    return win32.midiInGetNumDevs();
}

pub const InputDeviceInfo = struct {
    index: u32 = 0,
    manufacturer_id: u16 = 0,
    product_id: u16 = 0,
    driver_version: u32 = 0,
    capabilities: Capabilities = Capabilities{},
    name: []u8 = &.{},

    _name_buf: [name_buf_size]u8 = undefined,
    const name_buf_size = 32 * @sizeOf(u16) * 2; // Length of win32.MIDIINCAPSW.szPname is 32.
};

pub fn inputDeviceInfo(device_index: usize, info: *InputDeviceInfo) !void {
    deadlock_detector.checkNotCallbackThread();
    if (device_index > std.math.maxInt(u32)) return SysErr.BadDeviceId;

    var caps = win32.MIDIINCAPSW{};
    const mmr = win32.midiInGetDevCapsW(@intCast(device_index), &caps, @intCast(@sizeOf(win32.MIDIINCAPSW)));
    try checkInputMmResult(mmr);

    const name_len = try std.unicode.utf16LeToUtf8(&info._name_buf, nullTerminated(&caps.szPname));
    info.name = info._name_buf[0..name_len];
    info.capabilities = @bitCast(caps.dwSupport);
    info.driver_version = caps.vDriverVersion;
    info.manufacturer_id = caps.wMid;
    info.product_id = caps.wPid;
}

fn mmrInputErrorMessage(allocator: std.mem.Allocator, mmr: win32.MMRESULT) ![:0]u8 {
    deadlock_detector.checkNotCallbackThread();

    return getErrorMessage(win32.midiInGetErrorTextW, allocator, mmr);
}

pub fn inputErrorMessage(allocator: std.mem.Allocator, err: anyerror) ![:0]u8 {
    deadlock_detector.checkNotCallbackThread();

    const mmr: win32.MMRESULT = @bitCast(@intFromEnum(try sysErrToMmr(err)));
    return getErrorMessage(win32.midiInGetErrorTextW, allocator, mmr);
}

const PackedMidiMessage64 = packed struct(u64) {
    status: u8,
    data1: u8,
    data2: u8,
    _: u40 = 0,
};

const PackedMidiMessage32 = packed struct(u32) {
    status: u8,
    data1: u8,
    data2: u8,
    _: u8 = 0,
};

// MidiInProc
//
// https://learn.microsoft.com/en-us/previous-versions/dd798460(v=vs.85)
//
// > Applications should not call any multimedia functions from inside the
// > callback function, as doing so can cause a deadlock. Other system functions
// > can safely be called from the callback.
fn inputCallback(
    device_handle: win32.HMIDIIN,
    event_type: win32.DWORD_PTR,
    ctx: win32.DWORD_PTR,
    param1: win32.DWORD_PTR,
    param2: win32.DWORD_PTR,
    trampoline: InputCallbackTypeTrampoline,
) void {
    deadlock_detector.markCallbackThread();
    defer deadlock_detector.unmarkCallbackThread();

    const cbMessageType: InputCallbackEventType = @enumFromInt(event_type);

    switch (cbMessageType) {
        .open => {
            // Input device opened, i.e. successful call to midiInOpen.
            //
            // No extra data.
            log.debug("opened input device: {*}", .{device_handle});
            trampoline(ctx, device_handle, InputEvent{ .open = void{} });
        },
        .close => {
            // Input device closed, i.e. successful call to midiInClose.
            //
            // No extra data.
            log.debug("closed input device: {*}", .{device_handle});
            trampoline(ctx, device_handle, InputEvent{ .close = void{} });
        },
        .data => {
            // Received a midi message.
            const packedMidiMessage: PackedMidiMessage64 = @bitCast(param1);
            const timestamp = param2;
            const msg = midi.unpackMessage(
                packedMidiMessage.status,
                packedMidiMessage.data1,
                packedMidiMessage.data2,
            ) catch |err| {
                log.err("failed to unpack midi message `{}`: {}", .{ packedMidiMessage, err });
                return;
            };
            trampoline(ctx, device_handle, InputEvent{
                .data = InputEvent.ShortMessage{
                    .msg = msg,
                    .timestamp = timestamp,
                },
            });
        },
        .long_data => {
            // Received a full sysex message.
            const header: *win32.MIDIHDR = @ptrFromInt(param1);
            const timestamp = param2;
            trampoline(ctx, device_handle, InputEvent{
                .long_data = InputEvent.LongMessage{
                    .midiMessage = header,
                    .timestamp = timestamp,
                },
            });
        },
        .more_data => {
            // Data loss, input callback isn't processing messages fast enough.
            const packedMidiMessage: PackedMidiMessage64 = @bitCast(param1);
            const timestamp = param2;
            const msg = midi.unpackMessage(
                packedMidiMessage.status,
                packedMidiMessage.data1,
                packedMidiMessage.data2,
            ) catch |err| {
                log.err("failed to unpack midi message `{}`: {}", .{ packedMidiMessage, err });
                return;
            };
            trampoline(ctx, device_handle, InputEvent{
                .more_data = InputEvent.ShortMessage{
                    .msg = msg,
                    .timestamp = timestamp,
                },
            });
        },
        .@"error" => {
            // Driver detected an invalid midi message.
            const packedMidiMessage: PackedMidiMessage64 = @bitCast(param1);
            const timestamp = param2;
            const msg = midi.unpackMessage(
                packedMidiMessage.status,
                packedMidiMessage.data1,
                packedMidiMessage.data2,
            ) catch |err| {
                log.err("failed to unpack midi message `{}`: {}", .{ packedMidiMessage, err });
                return;
            };
            trampoline(ctx, device_handle, InputEvent{
                .@"error" = InputEvent.ShortMessage{
                    .msg = msg,
                    .timestamp = timestamp,
                },
            });
        },
        .long_error => {
            // Driver detected an invalid or incomplete sysex message.
            const header: *win32.MIDIHDR = @ptrFromInt(param1);
            const timestamp = param2;
            trampoline(ctx, device_handle, InputEvent{
                .long_error = InputEvent.LongMessage{
                    .midiMessage = header,
                    .timestamp = timestamp,
                },
            });
        },
        _ => {},
    }
}

//
// Output.
//

pub fn outputOpen(device_index: u32) SysErr!OutputDeviceHandle {
    deadlock_detector.checkNotCallbackThread();

    var device_handle: win32.HMIDIOUT = undefined;
    const mmr = win32.midiOutOpen(
        &device_handle,
        device_index,
        @intFromPtr(&outputCallback),
        0,
        win32.CALLBACK_FUNCTION,
    );
    try checkOutputMmResult(mmr);
    return device_handle;
}

pub fn outputClose(device_handle: OutputDeviceHandle) SysErr!void {
    deadlock_detector.checkNotCallbackThread();

    const mmr = win32.midiOutClose(device_handle);
    try checkOutputMmResult(mmr);
}

pub const Volume = packed struct(u32) {
    left: u16,
    right: u16,
};

pub fn outputGetVolume(device_handle: OutputDeviceHandle) SysErr!Volume {
    deadlock_detector.checkNotCallbackThread();

    var volume: u32 = 0;
    const mmr = win32.midiOutGetVolume(device_handle, &volume);
    try checkOutputMmResult(mmr);
    return @bitCast(volume);
}

pub fn outputSetVolumeMono(device_handle: OutputDeviceHandle, volume: u16) SysErr!void {
    deadlock_detector.checkNotCallbackThread();

    outputSetVolumeStereo(device_handle, volume, 0);
}

pub fn outputSetVolumeStereo(device_handle: OutputDeviceHandle, left_volume: u16, right_volume: u16) SysErr!void {
    deadlock_detector.checkNotCallbackThread();

    const mmr = win32.midiOutSetVolume(
        device_handle,
        @bitCast(
            Volume{
                .left_volume = left_volume,
                .right_volume = right_volume,
            },
        ),
    );
    try checkOutputMmResult(mmr);
}

pub fn outputDeviceCount() u32 {
    deadlock_detector.checkNotCallbackThread();

    return win32.midiOutGetNumDevs();
}

pub const OutputDeviceInfo = struct {
    index: u32 = 0,
    manufacturer_id: u16 = 0,
    product_id: u16 = 0,
    driver_version: u32 = 0,
    capabilities: Capabilities = Capabilities{},
    technology: Technology = Technology.midi_port,
    voice_count: u16 = 0,
    note_count: u16 = 0,
    channel_mask: u16 = 0,
    name: []u8 = &[0]u8{},

    _name_buf: [name_buf_size]u8 = undefined,
    const name_buf_size = 32 * @sizeOf(u16) * 2; // Length of win32.MIDIINCAPSW.szPname is 32.
};

pub fn outputDeviceInfo(device_index: usize, info: *OutputDeviceInfo) !void {
    deadlock_detector.checkNotCallbackThread();
    if (device_index > std.math.maxInt(u32)) return SysErr.BadDeviceId;

    var caps = win32.MIDIOUTCAPSW{};
    // var caps_size: c_uint = 0;
    const mmr = win32.midiOutGetDevCapsW(@intCast(device_index), &caps, @intCast(@sizeOf(win32.MIDIOUTCAPSW)));
    try checkOutputMmResult(mmr);

    const name_len = try std.unicode.utf16LeToUtf8(&info._name_buf, nullTerminated(&caps.szPname));
    info.name = info._name_buf[0..name_len];
    info.capabilities = @bitCast(caps.dwSupport);
    info.driver_version = caps.vDriverVersion;
    info.manufacturer_id = caps.wMid;
    info.product_id = caps.wPid;
    info.technology = @enumFromInt(caps.wTechnology);
    info.voice_count = caps.wVoices;
    info.note_count = caps.wNotes;
    info.channel_mask = caps.wChannelMask;
}

fn mmrOutputErrorMessage(allocator: std.mem.Allocator, mmr: win32.MMRESULT) ![:0]u8 {
    deadlock_detector.checkNotCallbackThread();

    return getErrorMessage(win32.midiOutGetErrorTextW, allocator, mmr);
}

pub fn outputErrorMessage(allocator: std.mem.Allocator, err: anyerror) ![:0]u8 {
    deadlock_detector.checkNotCallbackThread();

    const mmr: win32.MMRESULT = @bitCast(@intFromEnum(try sysErrToMmr(err)));
    return getErrorMessage(win32.midiOutGetErrorTextW, allocator, mmr);
}

pub fn outputSendMessage(device_handle: OutputDeviceHandle, msg: midi.Message) SysErr!void {
    deadlock_detector.checkNotCallbackThread();

    const smsg = midi.packMessage(msg);
    const pmsg = PackedMidiMessage32{
        .status = smsg.status,
        .data1 = smsg.data1,
        .data2 = smsg.data2,
    };
    const mmr = win32.midiOutShortMsg(device_handle, @bitCast(pmsg));
    try checkOutputMmResult(mmr);
}

// MidiOutProc
//
// https://learn.microsoft.com/en-us/previous-versions/dd798478(v=vs.85)
//
// > Applications should not call any multimedia functions from inside the
// > callback function, as doing so can cause a deadlock. Other system functions
// > can safely be called from the callback.
fn outputCallback(
    device_handle: win32.HMIDIOUT,
    event_type: win32.UINT,
    ctx: win32.DWORD_PTR,
    param1: win32.DWORD_PTR,
    param2: win32.DWORD_PTR,
) callconv(.C) void {
    deadlock_detector.markCallbackThread();
    defer deadlock_detector.unmarkCallbackThread();

    _ = ctx;
    _ = param2;
    const cbMessageType: OutputCallbackMessageType = @enumFromInt(event_type);

    switch (cbMessageType) {
        .open => {
            // Output device opened, i.e. successful call to midiOutOpen.
            //
            // No extra data.
            log.debug("opened output device: {*}", .{device_handle});
        },
        .close => {
            // Output device closed, i.e. successful call to midiOutClose.
            //
            // No extra data.
            log.debug("closed output device: {*}", .{device_handle});
        },
        .done => {
            // The given sysex message or stream buffer has been sent.
            const header: *win32.MIDIHDR = @ptrFromInt(param1);
            _ = header;
        },
        _ => {},
    }
}

//
// Routing.
//

pub fn connect(input_device_handle: win32.HMIDIIN, output_device_handle: win32.HMIDIOUT) SysErr!void {
    deadlock_detector.checkNotCallbackThread();

    const generic_handle: win32.HMIDI = @ptrCast(input_device_handle);
    const mmr = win32.midiConnect(generic_handle, output_device_handle, null);
    try checkInputMmResult(mmr);
}

pub fn disconnect(input_device_handle: win32.HMIDIIN, output_device_handle: win32.HMIDIOUT) SysErr!void {
    deadlock_detector.checkNotCallbackThread();

    const generic_handle: win32.HMIDI = @ptrCast(input_device_handle);
    const mmr = win32.midiDisconnect(generic_handle, output_device_handle, null);
    try checkInputMmResult(mmr);
}

//
// Util.
//

// Some devices place garbage in the name buffer after a null terminator.
pub fn nullTerminated(buf: []win32.wchar_t) []win32.wchar_t {
    for (buf, 0..) |char, i| {
        if (char == 0) {
            return buf[0..i];
        }
    }
    return buf;
}

const ErrTextFn = fn (mmrError: win32.MMRESULT, pszText: win32.LPWSTR, cchText: win32.UINT) callconv(.C) win32.MMRESULT;

fn getErrorMessage(err_text_fn: ErrTextFn, allocator: std.mem.Allocator, mmr: win32.MMRESULT) ![:0]u8 {
    var buf: [win32.MAXERRORLENGTH]u16 = std.mem.zeroes([win32.MAXERRORLENGTH]u16);
    const textMmr = err_text_fn(mmr, &buf, buf.len);
    try maybeRaiseSysErrMm(textMmr);
    return std.unicode.utf16LeToUtf8AllocZ(allocator, &buf);
}

fn getErrorMessageFixed(err_text_fn: ErrTextFn, buf: []u8, mmr: win32.MMRESULT) ![]u8 {
    var buf16: [win32.MAXERRORLENGTH]u16 = std.mem.zeroes([win32.MAXERRORLENGTH]u16);
    const textMmr = err_text_fn(mmr, &buf16, buf16.len);
    try maybeRaiseSysErrMm(textMmr);
    const len = try std.unicode.utf16LeToUtf8(buf, &buf16);
    return buf[0..len];
}

inline fn checkInputMmResult(mmr: win32.MMRESULT) SysErr!void {
    debugLogMmr(@src().fn_name, mmr, win32.midiInGetErrorTextW);
    try maybeRaiseSysErrMm(mmr);
}

inline fn checkOutputMmResult(mmr: win32.MMRESULT) SysErr!void {
    debugLogMmr(@src().fn_name, mmr, win32.midiOutGetErrorTextW);
    try maybeRaiseSysErrMm(mmr);
}

inline fn debugLogMmr(fn_name: []const u8, mmr: win32.MMRESULT, err_text_fn: ErrTextFn) void {
    if (mmr == win32.MMSYSERR_NOERROR) return;

    var buf: [win32.MAXERRORLENGTH * 2]u8 = undefined;
    const err_text = getErrorMessageFixed(err_text_fn, &buf, mmr) catch "<failed to get error message>";
    log.debug(fn_name ++ ": \"{s}\" ({})", .{ err_text, @as(MmSysErr, @enumFromInt(mmr)) });
}

fn maybeRaiseSysErrMm(mmr: c_uint) SysErr!void {
    const sysErr: MmSysErr = @enumFromInt(mmr);
    try maybeRaiseSysErr(sysErr);
}

fn maybeRaiseSysErr(err: MmSysErr) SysErr!void {
    switch (err) {
        .no_error => return,
        .@"error" => return SysErr.Error,
        .bad_device_id => return SysErr.BadDeviceId,
        .not_enabled => return SysErr.NotEnabled,
        .allocated => return SysErr.Allocated,
        .inval_handle => return SysErr.InvalHandle,
        .no_driver => return SysErr.NoDriver,
        .no_mem => return SysErr.NoMem,
        .not_supported => return SysErr.NotSupported,
        .bad_err_num => return SysErr.BadErrNum,
        .inval_flag => return SysErr.InvalFlag,
        .inval_param => return SysErr.InvalParam,
        .handle_busy => return SysErr.HandleBusy,
        .invalid_alias => return SysErr.InvalidAlias,
        .bad_db => return SysErr.BadDb,
        .key_not_found => return SysErr.KeyNotFound,
        .read_error => return SysErr.ReadError,
        .write_error => return SysErr.WriteError,
        .delete_error => return SysErr.DeleteError,
        .val_not_found => return SysErr.ValNotFound,
        .no_driver_cb => return SysErr.NoDriverCb,
        .more_data => return SysErr.MoreData,
        .unprepared => return SysErr.Unprepared,
        .still_playing => return SysErr.StillPlaying,
        .no_map => return SysErr.NoMap,
        .not_ready => return SysErr.NotReady,
        .no_device => return SysErr.NoDevice,
        .invalid_setup => return SysErr.InvalidSetup,
        .bad_open_mode => return SysErr.BadOpenMode,
        .dont_continue => return SysErr.DontContinue,
        _ => return SysErr.UnknownError,
    }
}

fn sysErrToMmr(err: anyerror) !MmSysErr {
    return switch (err) {
        // .no_error => return,
        SysErr.Error => .@"error",
        SysErr.BadDeviceId => .bad_device_id,
        SysErr.NotEnabled => .not_enabled,
        SysErr.Allocated => .allocated,
        SysErr.InvalHandle => .inval_handle,
        SysErr.NoDriver => .no_driver,
        SysErr.NoMem => .no_mem,
        SysErr.NotSupported => .not_supported,
        SysErr.BadErrNum => .bad_err_num,
        SysErr.InvalFlag => .inval_flag,
        SysErr.InvalParam => .inval_param,
        SysErr.HandleBusy => .handle_busy,
        SysErr.InvalidAlias => .invalid_alias,
        SysErr.BadDb => .bad_db,
        SysErr.KeyNotFound => .key_not_found,
        SysErr.ReadError => .read_error,
        SysErr.WriteError => .write_error,
        SysErr.DeleteError => .delete_error,
        SysErr.ValNotFound => .val_not_found,
        SysErr.NoDriverCb => .no_driver_cb,
        SysErr.MoreData => .more_data,
        SysErr.Unprepared => .unprepared,
        SysErr.StillPlaying => .still_playing,
        SysErr.NoMap => .no_map,
        SysErr.NotReady => .not_ready,
        SysErr.NoDevice => .no_device,
        SysErr.InvalidSetup => .invalid_setup,
        SysErr.BadOpenMode => .bad_open_mode,
        SysErr.DontContinue => .dont_continue,
        else => return error.NotSysErr,
    };
}

/// Helpers to detect code that may deadlock, and cause a panic instead.
const deadlock_detector = struct {
    const enable_checks = true;
    threadlocal var is_callback_thread: bool = false;

    fn markCallbackThread() void {
        if (!enable_checks) return;

        is_callback_thread = true;
    }

    fn unmarkCallbackThread() void {
        if (!enable_checks) return;

        is_callback_thread = false;
    }

    fn checkNotCallbackThread() void {
        if (!enable_checks) return;
        if (!is_callback_thread) return;

        @panic("debug check failed: attempt to call winmm function from " ++
            "inside midi callback, this is not allowed since it may deadlock");
    }
};
