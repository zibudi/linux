const std = @import("std");

const zig = @import("options").zig;
const subcommand = std.StaticStringMap([]const u8).initComptime(@import("llvm.zig").tools);

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const tool = subcommand.get(std.fs.path.basename(argv[0])) orelse return error.UnknownTool;

    var cc: std.ArrayList([]const u8) = .empty;
    try cc.appendSlice(arena, &.{ zig, tool });
    if (compiles(tool)) try cc.append(arena, "-fno-sanitize=undefined");

    const args = try adapt(arena, argv[1..]);
    if (!has(args, "-S")) return std.process.replace(init.io, .{ .argv = try join(arena, cc.items, args) });

    try preprocess(init.io, try join(arena, cc.items, try deps(arena, args)));
    return std.process.replace(init.io, .{ .argv = try join(arena, cc.items, try assembly(arena, args)) });
}

fn adapt(arena: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var kernel = false;
    var bits: []const u8 = "x86_64";
    var tables: ?bool = null;

    for (args) |arg| {
        if (unmappable(arg)) continue;
        if (std.mem.startsWith(u8, arg, "--target=")) {
            kernel = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-m16") or std.mem.eql(u8, arg, "-m32")) {
            kernel = true;
            bits = "x86";
        }
        if (std.mem.eql(u8, arg, "-fasynchronous-unwind-tables")) tables = true;
        if (std.mem.eql(u8, arg, "-fno-asynchronous-unwind-tables")) tables = false;
        try out.append(arena, arg);
    }

    if (kernel) try out.appendSlice(arena, &.{
        "-target",
        try std.fmt.allocPrint(arena, "{s}-linux-none", .{bits}),
    });
    if (tables == false) try out.append(arena, "-fno-unwind-tables");
    return out.items;
}

fn deps(arena: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var discard = false;
    for (args) |arg| {
        if (discard) {
            discard = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "-o")) {
            discard = true;
            continue;
        }
        try out.append(arena, if (std.mem.eql(u8, arg, "-S")) "-E" else arg);
    }
    return out.items;
}

fn assembly(arena: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (args) |arg| if (!depfile(arg)) try out.append(arena, arg);
    try out.append(arena, "-Wno-unused-command-line-argument");
    return out.items;
}

fn compiles(tool: []const u8) bool {
    return std.mem.eql(u8, tool, "cc") or std.mem.eql(u8, tool, "c++");
}

fn unmappable(arg: []const u8) bool {
    for ([_][]const u8{ "-mtune=generic", "-march=i386" }) |flag| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

fn depfile(arg: []const u8) bool {
    for ([_][]const u8{ "-Wp,-MD,", "-Wp,-MMD," }) |prefix| {
        if (std.mem.startsWith(u8, arg, prefix)) return true;
    }
    return std.mem.eql(u8, arg, "-MD") or std.mem.eql(u8, arg, "-MMD");
}

fn has(args: []const []const u8, flag: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, flag)) return true;
    return false;
}

fn join(arena: std.mem.Allocator, cc: []const []const u8, args: []const []const u8) ![]const []const u8 {
    return std.mem.concat(arena, []const u8, &.{ cc, args });
}

fn preprocess(io: std.Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{ .argv = argv, .stdout = .ignore });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.PreprocessFailed,
        else => return error.PreprocessFailed,
    }
}
