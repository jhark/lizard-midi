const std = @import("std");
const lizard_midi = @import("lizard-midi");
const winmm = lizard_midi.winmm;

var g_exe_name: []const u8 = "lizard-midi";
var g_allocator: std.mem.Allocator = undefined;
var g_ctrl_c_event = std.Thread.ResetEvent{};

const Command = enum {
    devices,
    connect,
    monitor,
    arp,
    help,

    const count = std.meta.tags(Command).len;
    const max_name_len: usize = maxCommandNameLen();
    const Handler = *const fn (args: [][]const u8) anyerror!void;

    const handlers = [count]Handler{
        devices,
        connect,
        monitor,
        arp,
        help,
    };

    fn run(cmd: Command, args: [][]const u8) !void {
        return handlers[@intFromEnum(cmd)](args);
    }

    fn argHelp(cmd: Command) []const u8 {
        const strs = [count][]const u8{
            "",
            "SOURCE_DEVICE DESTINATION_DEVICE",
            "DEVICE",
            "DEVICE NOTE_LENGTH NOTE_DELAY NOTES...",
            "COMMAND",
        };

        return strs[@intFromEnum(cmd)];
    }

    fn shortHelp(cmd: Command) []const u8 {
        const short_help = [count][]const u8{
            "List connected MIDI devices.",
            "Connect one MIDI device to another.",
            "Print received MIDI messages to stdout.",
            "Play a looping sequence of notes.",
            "Print help for a command.",
        };

        return short_help[@intFromEnum(cmd)];
    }

    fn toString(cmd: Command) []const u8 {
        return @tagName(cmd);
    }

    fn toStringPadded(comptime cmd: Command) []const u8 {
        comptime var s: []const u8 = @tagName(cmd);
        const name_len = s.len;
        inline for (max_name_len - name_len) |_| {
            s = s ++ " ";
        }
        return s;
    }

    fn fromString(s: []const u8) !Command {
        return std.meta.stringToEnum(Command, s) orelse
            return error.BadCommand;
    }

    inline fn list() []const u8 {
        const fields = std.meta.fields(Command);
        comptime var s: []const u8 = fields[0].name;
        inline for (fields[1..]) |f| {
            s = s ++ ", " ++ f.name;
        }
        return s;
    }

    fn maxCommandNameLen() usize {
        const fields = std.meta.fields(Command);
        comptime var max: usize = 0;
        inline for (fields) |f| {
            const len = f.name.len;
            if (len > max) max = len;
        }
        return max;
    }

    fn namePadding() []const u8 {
        comptime var s: []const u8 = "";
        inline for (max_name_len) |_| {
            s = s ++ " ";
        }
        return s;
    }
};

fn devices(args: [][]const u8) !void {
    _ = args;

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();
    defer bw.flush() catch {};

    {
        const device_count = lizard_midi.InputDevice.count();
        try stdout.print("Detected {} MIDI input device{s}\n", .{ device_count, plural(device_count) });

        for (0..device_count) |device_index| {
            var device_info = lizard_midi.InputDevice.Info{};
            lizard_midi.InputDevice.info(device_index, &device_info) catch |err| {
                try stdout.print(
                    "{}: <Error retrieving device capabilities: {s}>\n",
                    .{
                        device_index,
                        try winmm.inputErrorMessage(g_allocator, err),
                    },
                );
                continue;
            };

            try stdout.print(
                "{}: name: \"{s}\"\n   driver version: 0x{X}, manufacturer ID: {}, product ID: {}, capabilities: {}\n",
                .{
                    device_index,
                    device_info.name,
                    device_info.driver_version,
                    device_info.manufacturer_id,
                    device_info.product_id,
                    device_info.capabilities,
                },
            );
        }

        try stdout.print("\n", .{});
    }
    {
        const device_count = lizard_midi.OutputDevice.count();
        try stdout.print("Detected {} MIDI input device{s}\n", .{ device_count, plural(device_count) });

        for (0..device_count) |device_index| {
            var device_info = lizard_midi.OutputDevice.Info{};
            lizard_midi.OutputDevice.info(device_index, &device_info) catch |err| {
                try stdout.print(
                    "{}: <Error retrieving device capabilities: {s}>\n",
                    .{
                        device_index,
                        try winmm.outputErrorMessage(g_allocator, err),
                    },
                );
                continue;
            };

            try stdout.print(
                "{}: name: \"{s}\"\n   driver version: 0x{X}, manufacturer ID: {}, product ID: {}, technology: {s}, voices: {}, polyphony: {}, channel mask: 0x{X}, capabilities: {}\n",
                .{
                    device_index,
                    device_info.name,
                    device_info.driver_version,
                    device_info.manufacturer_id,
                    device_info.product_id,
                    @tagName(device_info.technology),
                    device_info.voice_count,
                    device_info.note_count,
                    device_info.channel_mask,
                    device_info.capabilities,
                },
            );
        }

        try stdout.print("\n", .{});
    }
}

fn connect(args: [][]const u8) !void {
    if (args.len != 2) {
        return error.BadArgs;
    }
    const input_device_id = try findInputDevice(args[0]);
    const output_device_id = try findOutputDevice(args[1]);

    var input_device = lizard_midi.InputDevice{};
    var output_device = lizard_midi.OutputDevice{};
    try input_device.open(input_device_id, null);
    defer input_device.close() catch {};

    try output_device.open(output_device_id);
    defer output_device.close() catch {};

    try lizard_midi.connect(&input_device, &output_device);
    try input_device.start();
    g_ctrl_c_event.wait();
    try lizard_midi.disconnect(&input_device, &output_device);
}

fn monitor(args: [][]const u8) !void {
    if (args.len != 1) {
        return error.BadArgs;
    }

    const device_id = try findInputDevice(args[0]);

    const EventHandler = struct {
        pub fn handleEvent(
            self: *@This(),
            device_handle: lizard_midi.InputDevice.Handle,
            event: lizard_midi.InputDevice.Event,
        ) void {
            _ = device_handle;

            switch (event) {
                .data => |e| {
                    self.stdout.writer().print("{}\n", .{e.msg}) catch {};
                },
                else => {},
            }
        }

        stdout: std.fs.File,
    };

    var input_device = lizard_midi.InputDevice{};
    var event_handler = EventHandler{ .stdout = std.io.getStdOut() };
    try input_device.open(device_id, &event_handler);
    defer input_device.close() catch {};
    try input_device.start();
    g_ctrl_c_event.wait();
    try input_device.stop();
}

fn arp(args: [][]const u8) !void {
    const device_index = try findOutputDevice(args[0]);
    const length = try std.fmt.parseUnsigned(u32, args[1], 10);
    const delay = try std.fmt.parseUnsigned(u32, args[2], 10);
    const note_args = args[3..];

    const max_notes = 256;
    const Note = u7;
    if (note_args.len == 0) {
        std.debug.print("Must specify at least one note.\n", .{});
        std.process.exit(1);
    }
    if (note_args.len > max_notes) {
        std.debug.print("Too many notes specified. Maximum notes: {}.\n", .{max_notes});
        std.process.exit(1);
    }

    var notes = std.BoundedArray(Note, max_notes){};
    for (note_args) |arg| {
        const note = std.fmt.parseUnsigned(Note, arg, 10) catch |err| {
            switch (err) {
                error.Overflow => {
                    std.debug.print("Note `{s}` out of range. Valid range is 0-{}.\n", .{ arg, std.math.maxInt(Note) });
                },
                else => {
                    std.debug.print("Failed to parse note `{s}`: {}\n", .{ arg, err });
                },
            }
            std.process.exit(1);
        };
        try notes.append(note);
    }

    var device = lizard_midi.OutputDevice{};
    try device.open(device_index);

    while (true) {
        for (notes.slice()) |note| {
            try device.send(lizard_midi.Message{
                .note_on = .{
                    .channel = 0,
                    .key = note,
                    .velocity = 100,
                },
            });
            std.time.sleep(length * std.time.ns_per_ms);
            try device.send(lizard_midi.Message{
                .note_on = .{
                    .channel = 0,
                    .key = note,
                    .velocity = 0,
                },
            });
            std.time.sleep(delay * std.time.ns_per_ms);
            if (g_ctrl_c_event.isSet()) break;
        }

        if (g_ctrl_c_event.isSet()) break;
    }

    try device.close();
}

fn help(args: [][]const u8) !void {
    const Local = struct {
        fn badArgs() !void {
            std.debug.print("Expected a single argument, one of: {s}\n", .{Command.list()});
            return error.BadArgs;
        }
    };

    if (args.len == 0) {
        usage();
    }

    if (args.len != 1) {
        return Local.badArgs();
    }

    const cmd = Command.fromString(args[0]) catch {
        return Local.badArgs();
    };

    const stdout = std.io.getStdOut().writer();

    try stdout.print("{s} {s}\n\n{s}\n", .{
        cmd.toString(),
        cmd.argHelp(),
        cmd.shortHelp(),
    });
}

pub fn main() !void {
    std.debug.print("\n", .{}); // Workaround `zig build run` leaving text in terminal.

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    g_allocator = gpa.allocator();

    var args = try std.process.argsAlloc(g_allocator);
    const allocd = args;
    defer std.process.argsFree(g_allocator, allocd);

    if (args.len < 2) {
        std.log.err("expected a command\n", .{});
        usage();
    }
    g_exe_name = args[0];
    const commandStr = args[1];
    args = args[2..];

    const command = Command.fromString(commandStr) catch {
        std.log.err("unknown command `{s}`", .{commandStr});
        std.log.err("expected first argument to be one of: {s}", .{Command.list()});
        usage();
    };

    try std.os.windows.SetConsoleCtrlHandler(&consoleCtrlHandler, true);

    command.run(args) catch |err| switch (err) {
        error.BadArgs => usage(),
        else => return err,
    };
}

fn usage() noreturn {
    const preamble =
        \\Usage:
        \\
        \\  {s} COMMAND ARGS...
        \\
        \\Available commands:
        \\
        \\
    ;
    const epilogue =
        \\Notes:
        \\
        \\  DEVICE arguments may be a device name or number, see the output of
        \\  the `devices` command.
        \\
        \\  Times are given in milliseconds (and are not fully reliable since
        \\  the current implementation simply sleeps the thread to achieve this).
        \\
        \\  NOTES are MIDI note numbers in the range [0-127]. Middle C (C4) is 60.
        \\
    ;

    std.debug.print(preamble, .{g_exe_name});

    inline for (std.meta.fields(Command)) |field| {
        comptime var cmd: Command = @enumFromInt(field.value);
        std.debug.print("  {s}  {s}\n", .{ cmd.toStringPadded(), cmd.argHelp() });
        std.debug.print("  {s}  {s}\n", .{ Command.namePadding(), cmd.shortHelp() });
        std.debug.print("\n", .{});
    }
    std.debug.print("{s}", .{epilogue});
    std.debug.print("\n", .{});
    std.process.exit(1);
}

fn consoleCtrlHandler(dwCtrlType: std.os.windows.DWORD) callconv(std.os.windows.WINAPI) std.os.windows.BOOL {
    if (dwCtrlType == std.os.windows.CTRL_C_EVENT) {
        g_ctrl_c_event.set();
    }

    return 1;
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

fn findInputDevice(s: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, s, 10) catch
        return lizard_midi.InputDevice.find(s) orelse
        error.DeviceNotFound;
}

fn findOutputDevice(s: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, s, 10) catch
        return lizard_midi.OutputDevice.find(s) orelse
        error.DeviceNotFound;
}
