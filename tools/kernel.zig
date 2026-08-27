const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 5) return error.Usage;
    const make, const source, const fragment, const out = .{ argv[1], argv[2], argv[3], argv[4] };

    const cwd = std.Io.Dir.cwd();
    const tree = try std.fmt.allocPrint(arena, "{s}/build", .{out});
    try cwd.createDirPath(io, tree);

    const O = try std.fmt.allocPrint(arena, "O={s}", .{tree});
    const jobs = try std.fmt.allocPrint(arena, "-j{d}", .{try std.Thread.getCpuCount()});

    try run(io, &.{ make, "-C", source, O, "defconfig" });
    try append(io, arena, try std.fmt.allocPrint(arena, "{s}/.config", .{tree}), fragment);
    try run(io, &.{ make, "-C", source, O, "olddefconfig" });
    try run(io, &.{ make, "-C", source, O, jobs, "bzImage", "modules" });
    try run(io, &.{ make, "-C", source, O, "INSTALL_MOD_PATH=dest", "INSTALL_MOD_STRIP=1", "modules_install" });

    try move(io, arena, tree, "arch/x86/boot/bzImage", out, "vmlinuz");
    try move(io, arena, tree, ".config", out, "config");
    try move(io, arena, tree, try modules(io, arena, tree), out, "modules");
    for ([_][]const u8{ "build", "source" }) |link| {
        cwd.deleteFile(io, try std.fmt.allocPrint(arena, "{s}/modules/{s}", .{ out, link })) catch {};
    }
    try cwd.deleteTree(io, tree);
}

fn run(io: std.Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{ .argv = argv });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.MakeFailed,
        else => return error.MakeFailed,
    }
}

fn append(io: std.Io, arena: std.mem.Allocator, path: []const u8, extra: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = path, .data = try std.mem.concat(arena, u8, &.{
        try cwd.readFileAlloc(io, path, arena, .unlimited),
        try cwd.readFileAlloc(io, extra, arena, .unlimited),
    }) });
}

fn modules(io: std.Io, arena: std.mem.Allocator, tree: []const u8) ![]const u8 {
    const lib = try std.fmt.allocPrint(arena, "{s}/dest/lib/modules", .{tree});
    var dir = try std.Io.Dir.cwd().openDir(io, lib, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| if (entry.kind == .directory)
        return std.fmt.allocPrint(arena, "dest/lib/modules/{s}", .{entry.name});
    return error.NoModules;
}

fn move(io: std.Io, arena: std.mem.Allocator, from: []const u8, name: []const u8, to: []const u8, as: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ from, name }),
        cwd,
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ to, as }),
        io,
    );
}
