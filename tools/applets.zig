//! Fills a directory with the names busybox answers to, since it dispatches on
//! argv[0].

const std = @import("std");

pub const names = [_][]const u8{
    "sh",       "sed",       "grep",   "awk",    "find",   "xargs",    "diff",     "bc",
    "cat",      "cp",        "mv",     "rm",     "mkdir",  "rmdir",    "ln",       "touch",
    "basename", "dirname",   "head",   "tail",   "wc",     "tr",       "cut",      "uniq",
    "sort",     "env",       "uname",  "whoami", "mktemp", "readlink", "expr",     "install",
    "sha1sum",  "sha256sum", "md5sum", "printf", "echo",   "test",     "true",     "false",
    "ls",       "chmod",     "sleep",  "date",   "seq",    "stat",     "realpath", "cmp",
    "tee",      "nl",        "paste",  "od",     "yes",    "nproc",    "id",       "du",
    "df",       "sync",      "pwd",    "tac",    "split",  "printenv",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len != 3) return error.Usage;

    const cwd = std.Io.Dir.cwd();
    const out = argv[2];
    try cwd.createDirPath(io, out);

    // Copied rather than referenced, and linked to by a relative name, so the
    // directory can be installed somewhere else and still work.
    const binary = try std.fmt.allocPrint(arena, "{s}/busybox", .{out});
    cwd.deleteFile(io, binary) catch {};
    try cwd.copyFile(argv[1], cwd, binary, io, .{});

    for (names) |name| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out, name });
        cwd.deleteFile(io, path) catch {};
        try cwd.symLink(io, "busybox", path, .{});
    }
}
