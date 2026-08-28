//! Builds perl by running its own Configure and make. kbuild runs perl: the OID
//! registry today, and arch/x86/crypto's cryptogams assembly generators as soon
//! as the config asks for them. Neither is ours to rewrite.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len != 6) return error.Usage;

    const cwd = std.Io.Dir.cwd();
    const bin = try cwd.realPathFileAlloc(io, argv[1], arena);
    const applets = try cwd.realPathFileAlloc(io, argv[2], arena);
    const source = try cwd.realPathFileAlloc(io, argv[3], arena);
    const zig, const out = .{ argv[4], try cwd.realPathFileAlloc(io, argv[5], arena) };

    const env = init.environ_map;
    // Configure looks its tools up on the path, and everything it needs is here:
    // busybox answers for all sixteen it insists on, binutils for nm.
    try env.put("PATH", try std.fmt.allocPrint(arena, "{s}:{s}", .{ bin, applets }));

    // Configure writes into the tree it runs in, and a fetched package is not
    // ours to write to.
    const tree = try std.fmt.allocPrint(arena, "{s}/build", .{out});
    try run(io, env, null, &.{ try path(arena, applets, "cp"), "-a", source, tree });

    try run(io, env, tree, &.{
        try path(arena, applets, "sh"),
        "./Configure",
        "-des",
        try std.fmt.allocPrint(arena, "-Dcc={s} cc", .{zig}),
        try std.fmt.allocPrint(arena, "-Dprefix={s}", .{out}),
        // Nothing here loads an XS module, and a static perl is one file to place.
        "-Dusedl=n",
        "-Uuseshrplib",
        // perl stamps its build date into its banner; zig cc calls that an error.
        "-Accflags=-Wno-error=date-time",
    });

    const make = try path(arena, bin, "make");
    try run(io, env, tree, &.{ make, try std.fmt.allocPrint(arena, "-j{d}", .{try std.Thread.getCpuCount()}) });
    // install.perl is the interpreter and its modules, without the manual pages.
    try run(io, env, tree, &.{ make, "install.perl" });

    try cwd.deleteTree(io, tree);
}

fn path(arena: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
}

fn run(
    io: std.Io,
    env: *const std.process.Environ.Map,
    dir: ?[]const u8,
    argv: []const []const u8,
) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = env,
        .cwd = if (dir) |d| .{ .path = d } else .inherit,
    });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.PerlFailed,
        else => return error.PerlFailed,
    }
}
