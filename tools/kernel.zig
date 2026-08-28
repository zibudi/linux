const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 6) return error.Usage;

    const cwd = std.Io.Dir.cwd();
    const bin = try cwd.realPathFileAlloc(io, argv[1], arena);
    const applets = try cwd.realPathFileAlloc(io, argv[2], arena);
    const source, const fragment, const out = .{ argv[3], argv[4], argv[5] };

    const tree = try std.fmt.allocPrint(arena, "{s}/build", .{out});
    try cwd.createDirPath(io, tree);

    const merge = try std.fmt.allocPrint(arena, "{s}/scripts/kconfig/merge_config.sh", .{source});
    const config = try std.fmt.allocPrint(arena, "{s}/.config", .{tree});
    const jobs = try std.fmt.allocPrint(arena, "-j{d}", .{try std.Thread.getCpuCount()});

    const env = init.environ_map;
    try env.put("PATH", try std.fmt.allocPrint(arena, "{s}:{s}:{s}", .{ bin, applets, env.get("PATH") orelse "" }));

    const make = [_][]const u8{
        try std.fmt.allocPrint(arena, "{s}/make", .{bin}),
        "-C",
        source,
        try std.fmt.allocPrint(arena, "O={s}", .{tree}),
        try std.fmt.allocPrint(arena, "CC=gcc -B{s}/", .{bin}),
        try std.fmt.allocPrint(arena, "HOSTCC=gcc -B{s}/", .{bin}),
        try std.fmt.allocPrint(arena, "PERL={s}/oid", .{bin}),
        try std.fmt.allocPrint(arena, "SHELL={s}/sh", .{applets}),
    };

    try run(io, arena, env, &make, &.{"defconfig"});
    try run(io, arena, env, &.{try std.fmt.allocPrint(arena, "{s}/sh", .{applets})}, &.{ merge, "-m", "-O", tree, config, fragment });
    try run(io, arena, env, &make, &.{"olddefconfig"});
    try run(io, arena, env, &make, &.{ jobs, "bzImage", "modules" });
    try run(io, arena, env, &make, &.{ "INSTALL_MOD_PATH=dest", "INSTALL_MOD_STRIP=1", "modules_install" });

    try move(io, arena, tree, "arch/x86/boot/bzImage", out, "vmlinuz");
    try move(io, arena, tree, ".config", out, "config");
    try move(io, arena, tree, try modules(io, arena, tree), out, "modules");
    for ([_][]const u8{ "build", "source" }) |link| {
        cwd.deleteFile(io, try std.fmt.allocPrint(arena, "{s}/modules/{s}", .{ out, link })) catch {};
    }
    try cwd.deleteTree(io, tree);
}

fn run(
    io: std.Io,
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    command: []const []const u8,
    args: []const []const u8,
) !void {
    const argv = try std.mem.concat(arena, []const u8, &.{ command, args });
    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = env });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.MakeFailed,
        else => return error.MakeFailed,
    }
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
