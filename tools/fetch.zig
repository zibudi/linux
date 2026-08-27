const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 4) return error.Usage;
    const url, const want, const out = .{ argv[1], argv[2], argv[3] };

    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, out, .{});
    var buffer: [64 << 10]u8 = undefined;
    var writer: std.Io.File.Writer = .initStreaming(file, io, &buffer);

    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer.interface,
    });
    if (response.status != .ok) return error.HttpFailed;
    try writer.interface.flush();
    file.close(io);

    var sum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(try cwd.readFileAlloc(io, out, arena, .unlimited), &sum, .{});
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(sum, .lower), want)) return error.DigestMismatch;
}
