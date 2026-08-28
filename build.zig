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

    const bin = b.addWriteFiles();
    _ = bin.addCopyFile(make.artifact("make").getEmittedBin(), "make");
    for (@import("tools/binutils.zig").tools) |name| {
        _ = bin.addCopyFile(binutils.artifact(name).getEmittedBin(), name);
    }
    for (generators) |generator| {
        _ = bin.addCopyFile(generator[1].artifact(generator[0]).getEmittedBin(), generator[0]);
    }

    // busybox dispatches on argv[0], and it is the one that knows which names it
    // answers to. Copied and linked to relatively, so the directory relocates.
    const link = b.addRunArtifact(busybox.artifact("busybox"));
    link.addArgs(&.{
        "sh",
        "-c",
        \\"$1" cp "$1" "$2/busybox"
        \\for applet in $("$1" --list); do "$1" ln -sf busybox "$2/$applet"; done
        ,
        "--",
    });
    link.addArtifactArg(busybox.artifact("busybox"));
    const applets = link.addOutputDirectoryArg("applets");

    const perl = b.dependency("perl", .{}).namedLazyPath("perl");
    b.step("perl", "build the perl kbuild runs").dependOn(&b.addInstallDirectory(.{
        .source_dir = perl,
        .install_dir = .prefix,
        .install_subdir = "perl",
    }).step);

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
    kernel.addDirectoryArg(perl);
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
