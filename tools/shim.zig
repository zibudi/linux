const std = @import("std");

const zig = @import("options").zig;
const subcommand = std.StaticStringMap([]const u8).initComptime(@import("llvm.zig").tools);

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const name = std.fs.path.basename(argv[0]);

    var call: std.ArrayList([]const u8) = .empty;
    try call.appendSlice(arena, &.{ zig, subcommand.get(name) orelse return error.UnknownTool });
    try call.appendSlice(arena, argv[1..]);
    return std.process.replace(init.io, .{ .argv = call.items });
}
