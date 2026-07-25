#!/usr/bin/env python3
"""
scripts/build_realgz_img.py — build the virtio-blk ext4 disk image
that scripts/test_inflate_realgz.sh attaches to QEMU.

The image contains exactly one file, /Packages.gz, which is the
genuine Debian `stable main` binary-amd64 index fetched from
deb.debian.org. The Hamnix kernel auto-mounts any ext4 virtio-blk
disk at /ext, so the file is readable from userland as
/ext/Packages.gz.

Why a disk image (and not the cpio initramfs or a baked-in blob):
a real Packages.gz is ~13 MB compressed; baking that into the
kernel/initramfs would bloat both. A virtio-blk -drive image holds
tens of MB at zero kernel cost — same mechanism scripts/test_ext4.sh
uses for build/ext4.img.

The real file is fetched once, then cached at
build/cache/Packages.gz so repeat runs are offline + deterministic.

Usage:
    python3 scripts/build_realgz_img.py [--url URL] [--max-bytes N]

Exits non-zero (with a clear message) if the file cannot be fetched
and is not cached — the test script treats that as SKIP, not FAIL,
so an offline CI box does not spuriously fail.
"""

import os
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

DEFAULT_URL = (
    "https://deb.debian.org/debian/dists/stable/"
    "main/binary-amd64/Packages.gz"
)

HERE      = Path(__file__).resolve().parent.parent
BUILD     = HERE / "build"
CACHE     = BUILD / "cache"
CACHED_GZ = CACHE / "Packages.gz"
OUT_IMG   = BUILD / "realgz.img"


def _which(name: str) -> str:
    found = shutil.which(name)
    if found:
        return found
    for prefix in ("/sbin", "/usr/sbin", "/usr/local/sbin"):
        cand = Path(prefix) / name
        if cand.exists():
            return str(cand)
    raise SystemExit(f"required tool '{name}' not found")


def fetch_packages_gz(url: str) -> bytes:
    """Fetch Packages.gz, using build/cache/ as an offline cache."""
    if CACHED_GZ.exists() and CACHED_GZ.stat().st_size > 0:
        print(f"[build_realgz_img] using cached {CACHED_GZ} "
              f"({CACHED_GZ.stat().st_size} bytes)")
        return CACHED_GZ.read_bytes()
    print(f"[build_realgz_img] fetching {url}")
    CACHE.mkdir(parents=True, exist_ok=True)
    try:
        req = urllib.request.Request(
            url, headers={"User-Agent": "hamnix-inflate-repro/1"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = resp.read()
    except Exception as e:                       # noqa: BLE001
        raise SystemExit(
            f"[build_realgz_img] could not fetch {url}: {e}\n"
            f"[build_realgz_img] (and no cache at {CACHED_GZ}) — "
            f"SKIP")
    if len(data) < 16 or data[0] != 0x1F or data[1] != 0x8B:
        raise SystemExit(
            f"[build_realgz_img] fetched data is not gzip "
            f"(got {len(data)} bytes, magic "
            f"{data[:2].hex() if data else 'empty'})")
    CACHED_GZ.write_bytes(data)
    print(f"[build_realgz_img] cached {len(data)} bytes -> {CACHED_GZ}")
    return data


def build_ext4_with_file(out_path: Path, name: str, body: bytes):
    """Create a raw ext4 image holding one file `name` = `body`.

    Sized to comfortably hold the file: file size rounded up + 4 MiB
    of slack for the filesystem metadata, 4 KiB blocks.
    """
    mkfs    = _which("mkfs.ext4")
    debugfs = _which("debugfs")

    # 4 MiB metadata slack, rounded up to a MiB boundary.
    img_bytes = ((len(body) + 4 * 1024 * 1024) // (1024 * 1024) + 1)
    img_bytes *= 1024 * 1024

    out_path.parent.mkdir(parents=True, exist_ok=True)
    # ALWAYS-OVERWRITE CONTRACT (scripts/_fresh_artifact.py): unlink rather
    # than truncate over the previous image, so a mkfs/debugfs failure below
    # cannot leave a half-updated ext4 that still carries a valid superblock.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from _fresh_artifact import fresh_artifact
    fresh_artifact("[build_realgz_img]", out_path)
    with open(out_path, "wb") as f:
        f.truncate(img_bytes)

    # 4 KiB blocks: a contiguous multi-MB file then fits in a single
    # depth-0 extent (each ext4 extent covers up to 32768 blocks =
    # 128 MiB at 4 KiB blocks). No journal — read path only.
    subprocess.run(
        [mkfs, "-F", "-q", "-b", "4096", "-t", "ext4",
         "-L", "HAMNIX_EXT", "-O", "^has_journal",
         str(out_path)],
        check=True, capture_output=True,
    )

    tmp = out_path.with_suffix(".payload.tmp")
    tmp.write_bytes(body)
    try:
        subprocess.run(
            [debugfs, "-w", "-f", "/dev/stdin", str(out_path)],
            input=f"write {tmp} {name}\n",
            text=True, check=True, capture_output=True,
        )
    finally:
        tmp.unlink(missing_ok=True)
    print(f"[build_realgz_img] wrote {out_path} "
          f"({img_bytes} bytes image, /{name} = {len(body)} bytes)")


def main() -> int:
    url = DEFAULT_URL
    max_bytes = 0
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--url" and i + 1 < len(args):
            url = args[i + 1]; i += 2
        elif args[i] == "--max-bytes" and i + 1 < len(args):
            max_bytes = int(args[i + 1]); i += 2
        else:
            print(f"[build_realgz_img] unknown arg: {args[i]}",
                  file=sys.stderr)
            return 2

    data = fetch_packages_gz(url)
    if max_bytes and len(data) > max_bytes:
        # Not used by default — the repro wants the WHOLE real file.
        data = data[:max_bytes]
        print(f"[build_realgz_img] truncated to {max_bytes} bytes")

    build_ext4_with_file(OUT_IMG, "Packages.gz", data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
