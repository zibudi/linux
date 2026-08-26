//! Unpacks Alpine's kernel package.
//!
//!     unpack <linux-virt.apk> <outdir>
//!
//! An apk is a gzipped tar, so libarchive reads it directly. Out of it come
//! the kernel image and every module, decompressed and flattened -- the .ko
//! files are individually gzipped inside the tar, which is a second layer
//! libarchive also handles.
//!
//! Only the modules named in `wanted` come out. Extracting all 920 would also
//! work on Linux and silently lose four of them on macOS, where xt_DSCP.ko and
//! xt_dscp.ko are the same filename -- the netfilter pairs that make the kernel
//! tree itself un-checkoutable on a case-insensitive filesystem.

const std = @import("std");
const c = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
});

/// The virtio core is builtin, so virtio_blk has no dependencies of its own.
const wanted = [_][]const u8{
    "virtio_blk.ko",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 3) return error.Usage;

    const out = std.Io.Dir.cwd();
    try out.createDirPath(io, argv[2]);
    const mods = try std.fmt.allocPrint(arena, "{s}/modules", .{argv[2]});
    try out.createDirPath(io, mods);

    const a = c.archive_read_new() orelse return error.ArchiveInit;
    defer _ = c.archive_read_free(a);
    _ = c.archive_read_support_format_tar(a);
    _ = c.archive_read_support_filter_gzip(a);
    if (c.archive_read_open_filename(a, argv[1].ptr, 64 * 1024) != c.ARCHIVE_OK) return fail(a);

    var kernels: usize = 0;
    var modules: usize = 0;
    while (true) {
        var entry: ?*c.archive_entry = null;
        const r = c.archive_read_next_header(a, &entry);
        if (r == c.ARCHIVE_EOF) break;
        if (r != c.ARCHIVE_OK) return fail(a);
        const path = std.mem.span(c.archive_entry_pathname(entry) orelse continue);

        if (std.mem.eql(u8, path, "boot/vmlinuz-virt")) {
            try drain(a, io, arena, out, try std.fmt.allocPrint(arena, "{s}/vmlinuz", .{argv[2]}), false);
            kernels += 1;
        } else if (std.mem.endsWith(u8, path, ".ko.gz")) {
            const base = std.fs.path.basename(path);
            const name = base[0 .. base.len - ".gz".len];
            for (wanted) |w| {
                if (!std.mem.eql(u8, w, name)) continue;
                try drain(a, io, arena, out, try std.fmt.allocPrint(arena, "{s}/{s}", .{ mods, name }), true);
                modules += 1;
            }
        } else if (std.mem.endsWith(u8, path, "/modules.dep") or std.mem.endsWith(u8, path, "/modules.alias")) {
            const base = std.fs.path.basename(path);
            try drain(a, io, arena, out, try std.fmt.allocPrint(arena, "{s}/{s}", .{ mods, base }), false);
        }
    }
    if (kernels != 1) return error.KernelNotFound;
    if (modules != wanted.len) return error.ModuleNotFound;
}

/// Writes the current entry out, optionally undoing a second layer of gzip.
fn drain(
    a: *c.archive,
    io: std.Io,
    arena: std.mem.Allocator,
    dir: std.Io.Dir,
    dest: []const u8,
    gz: bool,
) !void {
    var body: std.ArrayList(u8) = .empty;
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.archive_read_data(a, &chunk, chunk.len);
        if (n == 0) break;
        if (n < 0) return fail(a);
        try body.appendSlice(arena, chunk[0..@intCast(n)]);
    }

    const bytes = if (gz) try gunzip(arena, body.items) else body.items;
    const f = try dir.createFile(io, dest, .{});
    defer f.close(io);
    var wbuf: [64 * 1024]u8 = undefined;
    var w = f.writer(io, &wbuf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn gunzip(arena: std.mem.Allocator, data: []const u8) ![]u8 {
    const a = c.archive_read_new() orelse return error.ArchiveInit;
    defer _ = c.archive_read_free(a);
    _ = c.archive_read_support_filter_gzip(a);
    _ = c.archive_read_support_format_raw(a);
    if (c.archive_read_open_memory(a, data.ptr, data.len) != c.ARCHIVE_OK) return fail(a);
    var entry: ?*c.archive_entry = null;
    if (c.archive_read_next_header(a, &entry) != c.ARCHIVE_OK) return fail(a);

    var out: std.ArrayList(u8) = .empty;
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.archive_read_data(a, &chunk, chunk.len);
        if (n == 0) break;
        if (n < 0) return fail(a);
        try out.appendSlice(arena, chunk[0..@intCast(n)]);
    }
    return out.items;
}

fn fail(a: *c.archive) anyerror {
    if (c.archive_error_string(a)) |msg| {
        std.debug.print("unpack: {s}\n", .{std.mem.span(msg)});
    }
    return error.ArchiveFailed;
}
