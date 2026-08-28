const std = @import("std");

pub fn build(b: *std.Build) void {
    const host = b.graph.host;

    const source = b.dependency("linux_source", .{});
    const make = b.dependency("gnumake", .{ .target = host, .optimize = .ReleaseFast });
    const binutils = b.dependency("binutils", .{ .target = host, .optimize = .ReleaseFast });
    const busybox = b.dependency("busybox", .{ .target = host, .optimize = .ReleaseSmall });

    const oid = tool(b, host, "oid");

    const bin = b.addWriteFiles();
    _ = bin.addCopyFile(make.artifact("make").getEmittedBin(), "make");
    _ = bin.addCopyFile(oid.getEmittedBin(), "oid");
    for (@import("tools/binutils.zig").tools) |name| {
        _ = bin.addCopyFile(binutils.artifact(name).getEmittedBin(), name);
    }

    b.step("oid", "build the OID registry generator on its own").dependOn(
        &b.addInstallArtifact(oid, .{}).step,
    );

    const link = b.addRunArtifact(tool(b, host, "applets"));
    link.addArtifactArg(busybox.artifact("busybox"));
    const applets = link.addOutputDirectoryArg("applets");

    const tools = b.step("tools", "build every tool the kernel build runs");
    for ([_]std.Build.LazyPath{ bin.getDirectory(), applets }) |directory| {
        tools.dependOn(&b.addInstallDirectory(.{
            .source_dir = directory,
            .install_dir = .prefix,
            .install_subdir = "tools",
        }).step);
    }

    const kernel = b.addRunArtifact(tool(b, host, "kernel"));
    kernel.addDirectoryArg(bin.getDirectory());
    kernel.addDirectoryArg(applets);
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
