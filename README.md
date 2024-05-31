# lizard-midi

* `lizard-midi` is a MIDI (1.0) library for Zig.
* It has no dependencies other than the underlying platform API.
* It currently only supports Windows, wrapping the Windows Multimedia APIs.
    * See: https://learn.microsoft.com/en-gb/windows/win32/multimedia/midi-reference
* It doesn't support every feature provided by the OS.
* It *does* support sending and receiving MIDI note and CC messages.
* It doesn't support SysEx messages.
* The API is not stable and will likely change if I add support for other OSs.

## CLI application

`lizard-midi` comes with a basic CLI application, which also serves as a usage sample.

```
> lizard-midi-tool help

Usage:

  lizard-midi-tool COMMAND ARGS...

Available commands:

  devices
           List connected MIDI devices.

  connect  SOURCE_DEVICE DESTINATION_DEVICE
           Connect one MIDI device to another.

  monitor  DEVICE
           Print received MIDI messages to stdout.

  arp      DEVICE NOTE_LENGTH NOTE_DELAY NOTES...
           Play a looping sequence of notes.

  help     COMMAND
           Print help for a command.

Notes:

  DEVICE arguments may be a device name or number, see the output of
  the `devices` command.

  Times are given in milliseconds (and are not fully reliable since
  the current implementation simply sleeps the thread to achieve this).

  NOTES are MIDI note numbers in the range [0-127]. Middle C (C4) is 60.
```

# Usage

## Build system

`build.zig.zon`:
```
.dependencies = .{
    .@"lizard-midi" = .{
        .path = "path/to/lizard-midi",
    },
},
```

`build.zig`:
```
const lizard_midi_dep = b.dependency("lizard-midi", .{
    .target = target,
    .optimize = optimize,
});

const lizard_midi_module = b.addModule("lizard-midi", .{
    .root_source_file = lizard_midi_dep.path("src/lib/root.zig"),
});

// ...

your_exe.root_module.addImport("lizard-midi", lizard_midi_module);
```

## Receiving messages

The most flexible way of handling incoming data is to define an event handler
with a `handleEvent` method, this will be used as a callback that is called by
another thread whenever data is received or other events occur.

```zig
const lizard_midi = @import("lizard-midi");

const EventHandler = struct {
    pub fn handleEvent(
        self: *@This(),
        device_handle: Handle,
        event: Event,
    ) void {
        _ = self;
        _ = device_handle;
        switch (event) {
            .data => |e| {
                std.log.info("{}", .{e.msg});
            },
            else => {},
        }
    }
};

var input_device = lizard_midi.InputDevice{};
var event_handler = EventHandler{};
try input_device.open(0, &event_handler);
try input_device.start();
```

If you do not wish to deal with a callback and synchronisation, the library
provides some of its own event handlers: `InputDevice.StateEventHandler` and
`InputDevice.QueueEventHandler`. If you are writing an application that is
frame-based, one of these may be convenient.

### StateEventHandler

This handler exposes a snapshot of MIDI device state (`DeviceState`) that can be
sampled by your application as needed. For example, you could sample it once per
frame and render it. Using this event handler you will only observe the latest
state of the device when you sample it, and may lose intermediate states that
occur in between samples.

```zig
var event_handler = InputDevice.StateEventHandler{};
try input_device.open(0, &event_handler);
try input_device.start();
```
..later..
```zig
event_handler.mutex.lock();
defer event_handler.mutex.unlock();
const channel = &event_handler.state.channels[0];
const pitch_bend = channel.normalisedPitchBend();
const aftertouch = channel.normalisedPressure();
// ...
```

### QueueEventHandler

This handler simply puts events into a fixed-sized queue when they are received.
The queue can be read by the application when convenient (e.g. at the start of a
frame).

As long as the application processes events fast enough, and the queue is large
enough to accommodate any spikes, no events will be missed.

```zig
var event_handler = InputDevice.QueueEventHandler{};
try event_handler.init(allocator, 5);
defer event_handler.deinit(allocator);
try input_device.open(0, &event_handler);
try input_device.start();
```
..later..
```zig
while (event_handler.pop()) |msg| {
    std.log.info("{}", .{msg});
}
```

Note that there is some inefficiency here as a mutex is locked for each call
to `pop()`.

## Sending messages

Simply create a `Message` and pass it to `OutputDevice.send`.

```zig
var device = OutputDevice{};
try device.open(device_index);
try device.send(lizard_midi.Message{
    .note_on = .{
        .channel = 0,
        .key = 60,
        .velocity = 100,
    },
});
```

There is currently no way to queue multiple messages and send them with reliable
timing intervals.
