const std = @import("std");

// Alpine's kernel package: one versioned artifact carrying the image and the
// 920 modules built alongside it, so the two can never disagree about
// vermagic. The netboot vmlinuz this replaced had no version in its URL.
const url = "https://dl-cdn.alpinelinux.org/alpine/v3.22/main/x86_64/linux-virt-6.12.103-r0.apk";
const sha256 = "9f1adbcdc3abc8071257f5e47a59acffe923a0b35fda61d23a2b3f869dd764b3";

pub fn build(b: *std.Build) void {
    const host = b.graph.host;

    const curl = b.addSystemCommand(&.{ "curl", "-fsSL", "-o" });
    const downloaded = curl.addOutputFileArg("linux-virt.apk");
    curl.addArg(url);

    const verify = b.addSystemCommand(&.{ "sh", "-c", verify_script, "verify", sha256 });
    verify.addFileArg(downloaded);
    const apk = verify.addOutputFileArg("linux-virt.apk");

    const libarchive = b.dependency("libarchive", .{ .target = host, .optimize = .ReleaseSafe });
    const unpack_mod = b.createModule(.{
        .root_source_file = b.path("tools/unpack.zig"),
        .target = host,
        .optimize = .ReleaseSafe,
    });
    unpack_mod.linkLibrary(libarchive.artifact("archive"));
    const unpack = b.addExecutable(.{ .name = "unpack", .root_module = unpack_mod });

    const run = b.addRunArtifact(unpack);
    run.addFileArg(apk);
    const out = run.addOutputDirectoryArg("linux");

    // The public surface: an image, and the modules that match it.
    b.addNamedLazyPath("vmlinuz", out.path(b, "vmlinuz"));
    b.addNamedLazyPath("modules", out.path(b, "modules"));

    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = out,
        .install_dir = .prefix,
        .install_subdir = ".",
    }).step);
}

const verify_script =
    \\set -eu
    \\if command -v sha256sum >/dev/null 2>&1; then
    \\    actual=$(sha256sum "$2" | cut -d' ' -f1)
    \\else
    \\    actual=$(shasum -a 256 "$2" | cut -d' ' -f1)
    \\fi
    \\if [ "$actual" != "$1" ]; then
    \\    echo "linux-virt.apk digest changed" >&2
    \\    echo "  expected $1" >&2
    \\    echo "  got      $actual" >&2
    \\    exit 1
    \\fi
    \\cp "$2" "$3"
;
