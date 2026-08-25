const std = @import("std");

// Alpine's 6.12.94-0-virt build, borrowed whole. The URL is unversioned --
// Alpine overwrites it every stable release -- so the digest below is the only
// thing keeping this reproducible. When it stops matching, that is Alpine
// moving, not corruption: check what changed, then bump both lines together.
const url = "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/netboot/vmlinuz-virt";
const sha256 = "12eb24189f3eb30bd0dcd919248caaa054ed4e87b799a53fdcc3999f157933e4";

pub fn build(b: *std.Build) void {
    const curl = b.addSystemCommand(&.{ "curl", "-fsSL", "-o" });
    const downloaded = curl.addOutputFileArg("vmlinuz");
    curl.addArg(url);

    const verify = b.addSystemCommand(&.{ "sh", "-c", verify_script, "verify", sha256 });
    verify.addFileArg(downloaded);
    const vmlinuz = verify.addOutputFileArg("vmlinuz");

    // The whole public surface: consumers ask for "vmlinuz" and never learn
    // where it came from.
    b.addNamedLazyPath("vmlinuz", vmlinuz);

    b.getInstallStep().dependOn(&b.addInstallFile(vmlinuz, "vmlinuz").step);
}

const verify_script =
    \\set -eu
    \\if command -v sha256sum >/dev/null 2>&1; then
    \\    actual=$(sha256sum "$2" | cut -d' ' -f1)
    \\else
    \\    actual=$(shasum -a 256 "$2" | cut -d' ' -f1)
    \\fi
    \\if [ "$actual" != "$1" ]; then
    \\    echo "vmlinuz digest changed" >&2
    \\    echo "  expected $1" >&2
    \\    echo "  got      $actual" >&2
    \\    exit 1
    \\fi
    \\cp "$2" "$3"
;
