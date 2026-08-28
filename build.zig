const std = @import("std");

pub fn build(b: *std.Build) void {
    const host = b.graph.host;

    const source = b.dependency("linux_source", .{});
    const make = b.dependency("gnumake", .{ .target = host, .optimize = .ReleaseFast });
    const binutils = b.dependency("binutils", .{ .target = host, .optimize = .ReleaseFast });
    const busybox = b.dependency("busybox", .{ .target = host, .optimize = .ReleaseSmall });
    const generators = [_]struct { []const u8, *std.Build.Dependency }{
        .{ "flex", b.dependency("flex", .{ .target = host, .optimize = .ReleaseFast }) },
        .{ "byacc", b.dependency("byacc", .{ .target = host, .optimize = .ReleaseFast }) },
        .{ "m4", b.dependency("m4", .{ .target = host, .optimize = .ReleaseFast }) },
    };

    const oid = tool(b, host, "oid");

    const bin = b.addWriteFiles();
    _ = bin.addCopyFile(make.artifact("make").getEmittedBin(), "make");
    // lib/Makefile spells out perl rather than $(PERL), so the stand-in has to
    // answer to that name. It refuses any script but build_OID_registry.
    _ = bin.addCopyFile(oid.getEmittedBin(), "perl");
    for (@import("tools/binutils.zig").tools) |name| {
        _ = bin.addCopyFile(binutils.artifact(name).getEmittedBin(), name);
    }
    for (generators) |generator| {
        _ = bin.addCopyFile(generator[1].artifact(generator[0]).getEmittedBin(), generator[0]);
    }

    b.step("oid", "build the OID registry generator on its own").dependOn(
        &b.addInstallArtifact(oid, .{}).step,
    );

    const link = b.addRunArtifact(tool(b, host, "applets"));
    link.addArtifactArg(busybox.artifact("busybox"));
    const applets = link.addOutputDirectoryArg("applets");

    // objtool links libelf and certs/extract-cert links libcrypto. They are
    // libraries rather than programs, which is why scrubbing PATH never caught them.
    // libelf includes zlib.h unconditionally, so zlib comes along; zstd is
    // genuinely optional and the kernel has nothing compressed for it to read.
    const elfutils = b.dependency("elfutils", .{
        .target = host,
        .optimize = .ReleaseFast,
        .zstd = false,
    });
    const zlib = b.dependency("zlib", .{ .target = host, .optimize = .ReleaseFast });
    const openssl = b.dependency("openssl", .{ .target = host, .optimize = .ReleaseFast });

    const libs = b.addWriteFiles();
    _ = libs.addCopyFile(elfutils.artifact("elf").getEmittedBin(), "lib/libelf.a");
    _ = libs.addCopyFile(elfutils.artifact("eu").getEmittedBin(), "lib/libeu.a");
    _ = libs.addCopyFile(zlib.artifact("z").getEmittedBin(), "lib/libz.a");
    // Upstream ships crypto and ssl separately; this port merges them, and
    // -lcrypto is the name the kernel asks for.
    _ = libs.addCopyFile(openssl.artifact("openssl").getEmittedBin(), "lib/libcrypto.a");
    _ = libs.addCopyDirectory(elfutils.artifact("elf").getEmittedIncludeTree(), "include", .{});
    _ = libs.addCopyDirectory(openssl.artifact("openssl").getEmittedIncludeTree(), "include", .{});

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
    kernel.addDirectoryArg(libs.getDirectory());
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
