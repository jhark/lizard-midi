//! High level wrapper around winmm input device functions that provides some
//! additional conveniences.

const std = @import("std");
const midi = @import("midi.zig");
const winmm = @import("winmm.zig");
const log = @import("log.zig").log;
const ring_buffer = @import("ring_buffer.zig");

const InputDevice = @This();

pub const Handle = winmm.InputDeviceHandle;
pub const Error = winmm.SysErr;
pub const Info = winmm.InputDeviceInfo;
pub const Event = winmm.InputEvent;

handle: Handle = null,

/// Gets the number of input devices currently available.
pub fn count() usize {
    return winmm.inputDeviceCount();
}

/// Retrieves information about a device.
pub fn info(device_index: usize, o_info: *Info) !void {
    if (device_index > std.math.maxInt(u32)) return Error.BadDeviceId;
    const device_index32: u32 = @intCast(device_index);

    return winmm.inputDeviceInfo(device_index32, o_info);
}

/// Finds the first device with the given name.
pub fn find(name: []const u8) ?usize {
    const device_count = winmm.inputDeviceCount();
    for (0..device_count) |device_index| {
        const device_index32: u32 = @intCast(device_index);
        var device_info = Info{};
        winmm.inputDeviceInfo(device_index32, &device_info) catch continue;
        if (std.mem.eql(u8, name, device_info.name)) {
            return device_index;
        }
    }

    return null;
}

/// Opens a MIDI device and sets up a handler to receive device and MIDI events.
///
/// You may use one of the pre-made handlers, i.e. QueueEventHandler or
/// StateEventHandler, define your own, or pass `null`.
///
/// Example:
///
/// ```
/// const EventHandler = struct {
///     pub fn handleEvent(
///         self: *@This(),
///         device_handle: Handle,
///         event: Event,
///     ) void {
///         _ = self;
///         _ = device_handle;
///
///         switch (event) {
///             .data => |e| {
///                 std.log.info("{}", .{e.msg});
///             },
///             else => {},
///         }
///     }
/// };
///
/// var input_device = InputDevice{};
/// var event_handler = EventHandler{};
/// try input_device.open(0, &event_handler);
/// try input_device.start();
/// ```
pub fn open(self: *InputDevice, device_index: usize, event_handler: anytype) Error!void {
    if (self.handle != null) {
        std.debug.panic("midi device {*} already open", .{self.handle});
    }
    if (device_index > std.math.maxInt(u32)) return Error.BadDeviceId;
    const device_index32: u32 = @intCast(device_index);

    const DummyEventHandler = struct {
        fn handleEvent(
            ctx: usize,
            device_handle: Handle,
            event: Event,
        ) void {
            _ = ctx;
            _ = device_handle;
            _ = event;
        }
    };

    const EventHandlerParam = @TypeOf(event_handler);

    switch (@typeInfo(EventHandlerParam)) {
        .null => {
            self.handle = try winmm.inputOpen(
                device_index32,
                @as(usize, 0),
                DummyEventHandler.handleEvent,
            );
        },
        .pointer => |ti| {
            const EventHandler = ti.child;
            self.handle = try winmm.inputOpen(
                device_index32,
                event_handler,
                EventHandler.handleEvent,
            );
        },
        else => {
            @compileError("event_handler parameter must be a pointer to a struct with a handleEvent method, or null");
        },
    }
}

/// Closes a MIDI device and releases associated resources.
pub fn close(self: *InputDevice) Error!void {
    if (self.handle != null) {
        try winmm.inputClose(self.handle);
    }

    self.* = .{};
}

/// Start receiving data from the device.
pub fn start(self: *InputDevice) Error!void {
    return winmm.inputStart(self.handle);
}

/// Stop receiving data from the device.
pub fn stop(self: *InputDevice) Error!void {
    return winmm.inputStop(self.handle);
}

/// Handles MIDI events by queuing them up to be processed by the application
/// when convenient.
///
/// Useful if the application wants to respond to each event individually, but
/// doesn't want to deal with the synchronisation issues etc. arising from using
/// a callback.
///
/// If the application doesn't process events at the rate at which they come in,
/// then events will be lost.
///
/// Example:
///
/// ```
/// var event_handler = InputDevice.QueueEventHandler{};
/// try event_handler.init(allocator, 5);
/// defer event_handler.deinit(allocator);
/// try input_device.open(0, &event_handler);
/// try input_device.start();
/// ```
/// ..later..
/// ```
/// while (event_handler.pop()) |msg| {
///     std.log.info("{}", .{msg});
/// }
/// ```
pub const QueueEventHandler = struct {
    const RingBuffer = ring_buffer.RingBuffer(midi.Message);

    ring_buffer: RingBuffer = .{},
    mutex: std.Thread.Mutex = .{},
    dropped_messages: bool = false,

    pub fn init(self: *QueueEventHandler, allocator: std.mem.Allocator, capacity: usize) !void {
        return self.ring_buffer.init(allocator, capacity);
    }

    pub fn deinit(self: *QueueEventHandler, allocator: std.mem.Allocator) void {
        return self.ring_buffer.deinit(allocator);
    }

    pub fn push(self: *QueueEventHandler, msg: midi.Message) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.ring_buffer.push(msg) catch {
            self.dropped_messages = true;
        };
    }

    pub fn pop(self: *QueueEventHandler) ?midi.Message {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.ring_buffer.pop() catch null;
    }

    /// Whether or not any messages were dropped since the last call to this
    /// function.
    pub fn dropped(self: *QueueEventHandler) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        defer self.dropped_messages = false;
        return self.dropped_messages;
    }

    fn handleEvent(
        self: *QueueEventHandler,
        device_handle: Handle,
        event: Event,
    ) void {
        _ = device_handle;

        switch (event) {
            .data => |e| {
                self.push(e.msg);
            },
            .more_data => {
                self.dropped_messages = true;
            },
            .open,
            .close,
            .@"error",
            .long_error,
            .long_data,
            => {},
        }
    }
};

/// Handles MIDI events by updating a device state.
///
/// Useful if the application only cares about the current state at a given
/// point in time rather responding to each event.
///
/// Example:
///
/// ```
/// var event_handler = InputDevice.StateEventHandler{};
/// try input_device.open(0, &event_handler);
/// try input_device.start();
/// ```
/// ..later..
/// ```
/// event_handler.mutex.lock();
/// defer event_handler.mutex.unlock();
/// const channel = &event_handler.state.channels[0];
/// const pitch_bend = channel.normalisedPitchBend();
/// const aftertouch = channel.normalisedPressure();
/// ...
/// ```
pub const StateEventHandler = struct {
    mutex: std.Thread.Mutex = .{},
    state: midi.DeviceState = .{},

    fn handleEvent(
        self: *StateEventHandler,
        device_handle: Handle,
        event: Event,
    ) void {
        _ = device_handle;

        switch (event) {
            .data => |e| {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.state.update(e.msg);
            },
            .open,
            .close,
            .@"error",
            .long_error,
            .long_data,
            .more_data,
            => {},
        }
    }
};
