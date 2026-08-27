const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 5) return error.Usage;
    const make, const tarball, const fragment, const out = .{ argv[1], argv[2], argv[3], argv[4] };

    const cwd = std.Io.Dir.cwd();
    const src = try std.fmt.allocPrint(arena, "{s}/src", .{out});
    const staged = try std.fmt.allocPrint(arena, "{s}/staged", .{out});
    try cwd.createDirPath(io, src);

    try run(io, &.{ "tar", "-xJf", tarball, "-C", src, "--strip-components=1" });
    try run(io, &.{ make, "-C", src, "defconfig" });

    const dotconfig = try std.fmt.allocPrint(arena, "{s}/.config", .{src});
    try cwd.writeFile(io, .{
        .sub_path = dotconfig,
        .data = try std.mem.concat(arena, u8, &.{
            try cwd.readFileAlloc(io, dotconfig, arena, .unlimited),
            try cwd.readFileAlloc(io, fragment, arena, .unlimited),
        }),
    });
    try run(io, &.{ make, "-C", src, "olddefconfig" });

    const jobs = try std.fmt.allocPrint(arena, "-j{d}", .{try std.Thread.getCpuCount()});
    try run(io, &.{ make, "-C", src, jobs, "bzImage", "modules" });
    const mod_path = try std.fmt.allocPrint(arena, "INSTALL_MOD_PATH={s}", .{staged});
    try run(io, &.{ make, "-C", src, mod_path, "INSTALL_MOD_STRIP=1", "modules_install" });

    const bzimage = try std.fmt.allocPrint(arena, "{s}/arch/x86/boot/bzImage", .{src});
    try cwd.copyFile(bzimage, cwd, try std.fmt.allocPrint(arena, "{s}/vmlinuz", .{out}), io, .{});
    try cwd.copyFile(dotconfig, cwd, try std.fmt.allocPrint(arena, "{s}/config", .{out}), io, .{});

    const lib = try std.fmt.allocPrint(arena, "{s}/lib/modules", .{staged});
    var dir = try cwd.openDir(io, lib, .{ .iterate = true });
    var it = dir.iterate();
    const release = while (try it.next(io)) |entry| {
        if (entry.kind == .directory) break try arena.dupe(u8, entry.name);
    } else return error.NoModules;
    dir.close(io);

    const modules = try std.fmt.allocPrint(arena, "{s}/modules", .{out});
    try cwd.rename(try std.fmt.allocPrint(arena, "{s}/{s}", .{ lib, release }), cwd, modules, io);
    for ([_][]const u8{ "build", "source" }) |link| {
        cwd.deleteFile(io, try std.fmt.allocPrint(arena, "{s}/{s}", .{ modules, link })) catch {};
    }

    try cwd.deleteTree(io, src);
    try cwd.deleteTree(io, staged);
}

fn run(io: std.Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{ .argv = argv });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}
