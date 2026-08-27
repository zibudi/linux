const std = @import("std");

pub fn build(b: *std.Build) void {
    const host = b.graph.host;

    const source = b.dependency("linux_source", .{});
    const make = b.dependency("gnumake", .{ .target = host, .optimize = .ReleaseFast });

    const options = b.addOptions();
    options.addOption([]const u8, "zig", b.graph.zig_exe);
    const shim = tool(b, host, "shim");
    shim.root_module.addOptions("options", options);

    const bin = b.addWriteFiles();
    _ = bin.addCopyFile(make.artifact("make").getEmittedBin(), "make");
    inline for (@import("tools/llvm.zig").tools) |named| {
        _ = bin.addCopyFile(shim.getEmittedBin(), named[0]);
    }

    const kernel = b.addRunArtifact(tool(b, host, "kernel"));
    kernel.addDirectoryArg(bin.getDirectory());
    kernel.addDirectoryArg(source.path("."));
    kernel.addFileArg(b.path("config/x86_64.config"));
    const out = kernel.addOutputDirectoryArg("linux");

    b.addNamedLazyPath("vmlinuz", out.path(b, "vmlinuz"));
    b.addNamedLazyPath("modules", out.path(b, "modules"));
    b.addNamedLazyPath("config", out.path(b, "config"));

    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = out,
        .install_dir = .prefix,
        .install_subdir = ".",
    }).step);
}

fn tool(b: *std.Build, host: std.Build.ResolvedTarget, name: []const u8) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("tools/{s}.zig", .{name})),
            .target = host,
            .optimize = .ReleaseFast,
        }),
    });
}
