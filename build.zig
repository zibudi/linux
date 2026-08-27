const std = @import("std");

const url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.103.tar.xz";
const sha256 = "f143aaade8877ba5616e788b4482576db28481bcf557ef537f4fcc3938fc3176";

pub fn build(b: *std.Build) void {
    const host = b.graph.host;

    const fetch = b.addRunArtifact(tool(b, host, "fetch"));
    fetch.addArgs(&.{ url, sha256 });
    const tarball = fetch.addOutputFileArg("linux.tar.xz");

    const make = b.dependency("gnumake", .{ .target = host, .optimize = .ReleaseFast });
    const kernel = b.addRunArtifact(tool(b, host, "kernel"));
    kernel.addArtifactArg(make.artifact("make"));
    kernel.addFileArg(tarball);
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
