const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 4) return error.Usage;
    const url, const want, const out = .{ argv[1], argv[2], argv[3] };

    var body: std.Io.Writer.Allocating = .init(arena);
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    });
    if (response.status != .ok) return error.HttpFailed;

    var sum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body.written(), &sum, .{});
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(sum, .lower), want)) return error.DigestMismatch;

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = body.written() });
}
