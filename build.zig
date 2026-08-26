const std = @import("std");

/// Where the kernel comes from. Alpine's package is what boots today; building
/// it ourselves is what lets us decide the =y/=m split, which is the only way
/// dynamic module loading is ever interesting.
const Source = enum { alpine, source };

pub fn build(b: *std.Build) void {
    const source = b.option(Source, "source", "alpine (default) or source") orelse .alpine;

    const out = switch (source) {
        .alpine => fromAlpine(b),
        .source => fromSource(b),
    };

    // The public surface: an image, and the modules that match it.
    b.addNamedLazyPath("vmlinuz", out.path(b, "vmlinuz"));
    b.addNamedLazyPath("modules", out.path(b, "modules"));

    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = out,
        .install_dir = .prefix,
        .install_subdir = ".",
    }).step);
}

// Alpine's kernel package: one versioned artifact carrying the image and the
// 920 modules built alongside it, so the two can never disagree about
// vermagic. The netboot vmlinuz this replaced had no version in its URL.
const alpine_url = "https://dl-cdn.alpinelinux.org/alpine/v3.22/main/x86_64/linux-virt-6.12.103-r0.apk";
const alpine_sha256 = "9f1adbcdc3abc8071257f5e47a59acffe923a0b35fda61d23a2b3f869dd764b3";

fn fromAlpine(b: *std.Build) std.Build.LazyPath {
    const host = b.graph.host;
    const apk = fetch(b, "linux-virt.apk", alpine_url, alpine_sha256);

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
    return run.addOutputDirectoryArg("linux");
}

// The same 6.12.103, from upstream. Matching Alpine's version on purpose: the
// only difference between the two outputs should be the config, so the two
// paths stay comparable while this one grows up.
const source_url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.103.tar.xz";
const source_sha256 = "f143aaade8877ba5616e788b4482576db28481bcf557ef537f4fcc3938fc3176";

fn fromSource(b: *std.Build) std.Build.LazyPath {
    // A borrowed toolchain, not zig's: the kernel wants gcc, GNU make, bison,
    // flex and depmod, and libarchive has no lzma so tar unpacks the tarball.
    // Owning all of that is a later argument than owning the config.
    //
    // Linux only, twice over. macOS ships GNU Make 3.81 and the kernel wants
    // 4.0, which stops the build outright; and 13 of the tree's 86,669 files
    // differ from another only by case (xt_DSCP.c, xt_dscp.c -- netfilter,
    // all of them), so tar quietly drops them first without saying so.
    const run = b.addSystemCommand(&.{ "sh", "-c", kernel_script, "kernel" });
    run.addFileArg(fetch(b, "linux.tar.xz", source_url, source_sha256));
    run.addFileArg(b.path("config/x86_64.config"));
    return run.addOutputDirectoryArg("linux");
}

/// Download and check a digest. Not `zig fetch`, which refuses anything that
/// isn't a zig package.
fn fetch(b: *std.Build, name: []const u8, url: []const u8, sha256: []const u8) std.Build.LazyPath {
    const curl = b.addSystemCommand(&.{ "curl", "-fsSL", "-o" });
    const downloaded = curl.addOutputFileArg(name);
    curl.addArg(url);

    const verify = b.addSystemCommand(&.{ "sh", "-c", verify_script, "verify", name, sha256 });
    verify.addFileArg(downloaded);
    return verify.addOutputFileArg(name);
}

const verify_script =
    \\set -eu
    \\if command -v sha256sum >/dev/null 2>&1; then
    \\    actual=$(sha256sum "$3" | cut -d' ' -f1)
    \\else
    \\    actual=$(shasum -a 256 "$3" | cut -d' ' -f1)
    \\fi
    \\if [ "$actual" != "$2" ]; then
    \\    echo "$1 digest changed" >&2
    \\    echo "  expected $2" >&2
    \\    echo "  got      $actual" >&2
    \\    exit 1
    \\fi
    \\cp "$3" "$4"
;

const kernel_script =
    \\set -eu
    \\tarball=$1
    \\fragment=$2
    \\out=$3
    \\
    \\src=$(mktemp -d)
    \\trap 'rm -rf "$src"' EXIT
    \\
    \\# GNU tar will not sniff xz for itself here, so name the filter.
    \\tar -xJf "$tarball" -C "$src" --strip-components=1
    \\cd "$src"
    \\
    \\# defconfig is a known-good x86_64 kernel and the fragment says only what
    \\# we want different. Starting from something smaller is a separate
    \\# argument, and a much longer one.
    \\make defconfig
    \\./scripts/kconfig/merge_config.sh -m .config "$fragment"
    \\make olddefconfig
    \\make -j"$(nproc)" bzImage modules
    \\make modules_install INSTALL_MOD_PATH="$src/dest" INSTALL_MOD_STRIP=1
    \\
    \\mkdir -p "$out"
    \\cp arch/x86/boot/bzImage "$out/vmlinuz"
    \\
    \\# depmod's own layout, kept intact: modules.dep names every module by its
    \\# path under this directory, so flattening the tree would make that file
    \\# a lie. The alpine path flattens instead, and will have to stop.
    \\mv "$src/dest/lib/modules/"*/ "$out/modules"
    \\
    \\# Symlinks back into the tree we are about to delete.
    \\rm -f "$out/modules/build" "$out/modules/source"
;
