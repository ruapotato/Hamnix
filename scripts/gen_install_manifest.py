#!/usr/bin/env python3
"""
scripts/gen_install_manifest.py — emit etc/install/rootfs.manifest.

The installer (etc/install.hamsh) reads this manifest at install time
and pipes each (target_path, source_path) pair through the userland
`install_rootfs_from_manifest` tool, which delivers each file onto the
freshly-formatted target ext4 via the kernel's install_file ctl verb.
This is the per-file replacement for the old `dd_blk /dev/blk/vdap4
/dev/blk/vdbp2` partition-clobber: each file is created independently
with proper ext4 metadata (inode, extent, dirent) so the install path
no longer assumes byte-equivalent source and target.

The file list mirrors scripts/build_rootfs_img.py:
  * .hamnix-roots                        (the sentinel — required first)
  * REAL_DEBIAN_FILES                    (curated apt/dpkg closure)
  * USRMERGE_ALIASES duplicates          (legacy /bin/, /lib/, /lib64/)
  * bin/busybox (+ applet symlinks)      (Linux ns shell — skipped if
                                          the host's musl-busybox isn't
                                          pre-built; install_rootfs_from_
                                          manifest tolerates missing
                                          source paths)

Source paths point at /n/distros/<rel>: at install time the live ISO
has the source rootfs partition mounted there. The installer
(etc/install.hamsh) binds '#distro' /n/distros ITSELF at startup —
NOT the boot rc, which deliberately keeps the distro tree out of the
ambient namespace for isolation (see etc/rc.boot.full). So the
installer reads bytes from the live mount rather than re-extracting a
SLIM-mode package payload.

Manifest format (one entry per line; '#' comments allowed):

    <target_path>     <source_path>

Both paths are whitespace-free. The kernel-side install_file ctl
walks <target_path>'s parent dirs mkdir-p style, so the manifest can
include arbitrary depths without pre-creating intermediates.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent

# Mirror REAL_DEBIAN_FILES from scripts/build_rootfs_img.py. Keep this
# list in sync: if a file is added to the curated closure there, add
# it here so it lands on the installed target.
REAL_DEBIAN_FILES = [
    # Genuine Debian shells (real /bin/sh -> dash, plus bash).
    "usr/bin/dash",
    "usr/bin/bash",
    # Package managers proper.
    "usr/bin/apt",
    "usr/bin/apt-get",
    "usr/bin/apt-cache",
    "usr/bin/apt-config",
    "usr/bin/apt-mark",
    "usr/bin/dpkg",
    "usr/bin/dpkg-deb",
    "usr/bin/dpkg-query",
    "usr/bin/dpkg-split",
    # Dynamic linker + libc.
    "usr/lib64/ld-linux-x86-64.so.2",
    "usr/lib/x86_64-linux-gnu/libc.so.6",
    "usr/lib/x86_64-linux-gnu/libm.so.6",
    "usr/lib/x86_64-linux-gnu/libpthread.so.0",
    "usr/lib/x86_64-linux-gnu/libdl.so.2",
    "usr/lib/x86_64-linux-gnu/libresolv.so.2",
    "usr/lib/x86_64-linux-gnu/librt.so.1",
    # apt's .so closure.
    "usr/lib/x86_64-linux-gnu/libapt-pkg.so.7.0",
    "usr/lib/x86_64-linux-gnu/libapt-pkg.so.7.0.0",
    "usr/lib/x86_64-linux-gnu/libapt-private.so.0.0",
    "usr/lib/x86_64-linux-gnu/libapt-private.so.0.0.0",
    "usr/lib/x86_64-linux-gnu/libstdc++.so.6",
    "usr/lib/x86_64-linux-gnu/libstdc++.so.6.0.33",
    "usr/lib/x86_64-linux-gnu/libgcc_s.so.1",
    "usr/lib/x86_64-linux-gnu/libz.so.1",
    "usr/lib/x86_64-linux-gnu/libz.so.1.3.1",
    "usr/lib/x86_64-linux-gnu/libbz2.so.1.0",
    "usr/lib/x86_64-linux-gnu/libbz2.so.1.0.4",
    "usr/lib/x86_64-linux-gnu/liblzma.so.5",
    "usr/lib/x86_64-linux-gnu/liblzma.so.5.8.1",
    "usr/lib/x86_64-linux-gnu/liblz4.so.1",
    "usr/lib/x86_64-linux-gnu/liblz4.so.1.10.0",
    "usr/lib/x86_64-linux-gnu/libzstd.so.1",
    "usr/lib/x86_64-linux-gnu/libzstd.so.1.5.7",
    "usr/lib/x86_64-linux-gnu/libudev.so.1",
    "usr/lib/x86_64-linux-gnu/libudev.so.1.7.10",
    "usr/lib/x86_64-linux-gnu/libsystemd.so.0",
    "usr/lib/x86_64-linux-gnu/libsystemd.so.0.40.0",
    "usr/lib/x86_64-linux-gnu/libcrypto.so.3",
    "usr/lib/x86_64-linux-gnu/libxxhash.so.0",
    "usr/lib/x86_64-linux-gnu/libxxhash.so.0.8.3",
    "usr/lib/x86_64-linux-gnu/libcap.so.2",
    "usr/lib/x86_64-linux-gnu/libcap.so.2.75",
    # dpkg's .so closure.
    "usr/lib/x86_64-linux-gnu/libmd.so.0",
    "usr/lib/x86_64-linux-gnu/libmd.so.0.1.0",
    "usr/lib/x86_64-linux-gnu/libselinux.so.1",
    "usr/lib/x86_64-linux-gnu/libpcre2-8.so.0",
    "usr/lib/x86_64-linux-gnu/libpcre2-8.so.0.14.0",
    # bash's extra .so dep (terminal handling).
    "usr/lib/x86_64-linux-gnu/libtinfo.so.6",
    # /etc essentials.
    "etc/debian_version",
    "etc/os-release",
    "etc/passwd",
    "etc/group",
    "etc/hostname",
    "etc/apt/sources.list",
    "etc/apt/apt.conf",
    # dpkg's admindir scaffolding.
    "var/lib/dpkg/status",
    "var/lib/dpkg/available",
    "var/lib/dpkg/diversions",
    "var/lib/dpkg/statoverride",
    # Trusted GPG keyring.
    "usr/share/keyrings/debian-archive-keyring.gpg",
    "etc/apt/trusted.gpg.d/debian-archive-keyring.gpg",
]

USRMERGE_ALIASES = {
    "usr/bin/":   "bin/",
    "usr/sbin/":  "sbin/",
    "usr/lib/":   "lib/",
    "usr/lib64/": "lib64/",
}

# Busybox + applet names. The applets are symlinks on the source FS;
# we re-create them as plain files (each pointing to the busybox bytes)
# because the installer's install_file_to_slot path doesn't synthesize
# symlinks yet. install_rootfs_from_manifest tolerates missing source
# paths so a host without u_busybox_musl will skip these entries
# without failing the install.
# Kept in lockstep with _stage_busybox()'s bb_applets in
# scripts/build_rootfs_img.py — the installer copies busybox bytes to
# each of these applet paths off the source rootfs, so the installed
# disk mirrors the live root's working set. Every name is confirmed
# present in the staged musl busybox's applet table (busybox --list);
# absent applets (mount/awk/sed/tar/vi/ip/ping ...) are omitted.
BUSYBOX_APPLETS = [
    "sh", "ash",
    "ls", "cat", "echo", "cp", "mv", "rm", "mkdir", "rmdir",
    "ln", "touch", "chmod", "chown", "chgrp", "stat", "readlink",
    "pwd", "grep", "head", "tail", "wc", "sort", "cut", "tr",
    "uniq", "find", "which",
    "du", "df", "sync",
    "true", "false", "env", "printf", "date", "sleep", "usleep",
    "basename", "dirname", "mktemp",
    "uname", "id", "whoami", "hostname", "groups", "who", "users",
    "ps", "kill", "free", "uptime",
]


def _write(out_path: Path, lines: list[str]) -> None:
    """Write only if the CONTENT changed — never just bump the mtime.

    These manifests live under etc/, which scripts/_installer_img.sh scans by
    MTIME to decide whether build/hamnix-installer.img is stale
    (_HAMNIX_IMG_INPUT_DIRS includes "etc"). Rewriting byte-identical content
    with a fresh mtime pushed "newest tracked build input" past any artifact
    built earlier in the same session, so test_artifact_freshness.sh reported
    STALE for images that were in fact current — a false red on the one guard
    whose job is telling us when an artifact is genuinely out of date.
    A guard that cries wolf gets disabled, so fix the generator, not the guard.
    """
    out_path.parent.mkdir(parents=True, exist_ok=True)
    text = "\n".join(lines) + "\n"
    n = sum(1 for ln in lines if ln and not ln.startswith("#"))
    try:
        if out_path.read_text(encoding="utf-8") == text:
            print(f"[gen_install_manifest] {out_path} unchanged "
                  f"({n} entries) — mtime left alone", flush=True)
            return
    except (OSError, UnicodeDecodeError):
        pass
    out_path.write_text(text, encoding="utf-8")
    print(f"[gen_install_manifest] wrote {out_path} ({n} entries)",
          flush=True)


def gen_distro_manifest(src_root: str, out_path: Path) -> None:
    """Emit etc/install/distro.manifest — the LINUX-NAMESPACE tree.

    WHY THIS EXISTS (the `enter linux { sh }` post-install regression).
    On the LIVE medium `#distro` is served out of RAM: rc.boot runs
    `live_distro_up /rootfs.sqfs /live-distro.ext4`, the kernel
    decompresses that ext4 into a RAM block device and posts its
    `distro .` sentinel, and `enter linux { ... }` resolves against it.
    The INSTALLED system took the other rc.boot branch — it never ran
    live_distro_up — and `user/install.ad` wrote a one-line
    `.hamnix-roots` (`sysroot .`), so `#distro` did not exist at all and
    `enter linux { sh }` reported "sh not found".

    A second ext4 partition is NOT an option: fs/ext4.ad is a SINGLE
    global mount ("last one wins" in mount_rootfs_partition), so two
    live ext4 partitions would cross-resolve. The supported shape is the
    documented multiroot one — ONE partition, several named-root
    SUBTREES named by `.hamnix-roots` (docs/rootfs_partition.md):

        sysroot .
        distro  distro

    So the Debian/Linux userland is installed as FILES under `distro/`
    on the same target partition. Sources are read off the live medium's
    `#distro` (bound at /n/distros by the installer), which is exactly
    the tree the live desktop's `enter linux` uses — installed system ==
    faithful superset of the live one.
    """
    lines: list[str] = [
        "# /etc/install/distro.manifest — generated by",
        "# scripts/gen_install_manifest.py at image build time.",
        "#",
        "# Target paths are prefixed `distro/` so they land in the",
        "# partition's `distro` named-root SUBTREE (declared by the",
        "# installer's two-line .hamnix-roots). Source paths are on the",
        "# live medium's #distro, bound at /n/distros by the installer.",
        "",
    ]
    for rel in REAL_DEBIAN_FILES:
        lines.append(f"distro/{rel}    {src_root}/{rel}")
        for prefix, alias_prefix in USRMERGE_ALIASES.items():
            if rel.startswith(prefix):
                alias_rel = alias_prefix + rel[len(prefix):]
                lines.append(f"distro/{alias_rel}    {src_root}/{alias_rel}")
                break

    lines.append("")
    lines.append("# --- busybox + applets (the Linux-ns shell) ---")
    lines.append("# `/bin/sh` inside `enter linux { ... }` resolves HERE on")
    lines.append("# a host without the debootstrap fixture, so these rows")
    lines.append("# are what makes `enter linux { sh }` work post-install.")
    lines.append(f"distro/bin/busybox    {src_root}/bin/busybox")
    for applet in BUSYBOX_APPLETS:
        lines.append(f"distro/bin/{applet}    {src_root}/bin/{applet}")

    lines.append("")
    lines.append("# Provenance marker — proves the tree came off the real")
    lines.append("# Debian/live distro root and not the native sysroot.")
    lines.append(f"distro/PROVENANCE    {src_root}/PROVENANCE")
    _write(out_path, lines)


def gen_live_manifest(out_path: Path) -> None:
    """Emit etc/install/live.manifest — everything sourced from the live cpio.

    `user/install.ad::provision_target` created ~/Desktop, ~/Documents,
    ~/Downloads and ~/Pictures but left Desktop EMPTY. On the live image
    /home/live/Desktop carries the ~20 `.desktop` launchers that
    build_initramfs.py stages from etc/skel/Desktop. With an empty
    Desktop, /bin/hamdesktop falls back to the generic /etc/desktop.icons
    set — whose `Home` row pointed at `/` — which is exactly the
    "home folder icon opens the file browser at / " report.

    Target paths carry the `%USER%` token; the installer passes the
    wizard-collected login name to install_rootfs_from_manifest, which
    substitutes it. /etc/skel itself is installed too so a later
    `useradd` on the installed system has the same template.
    """
    lines: list[str] = [
        "# /etc/install/live.manifest — generated by",
        "# scripts/gen_install_manifest.py at image build time.",
        "#",
        "# `%USER%` in a TARGET path is replaced by the install user's",
        "# login name (install_rootfs_from_manifest argv[3]).",
        "# Sources are read off the live medium's cpio /etc/skel.",
        "",
    ]
    skel_dir = HERE / "etc" / "skel"
    if skel_dir.is_dir():
        for sp in sorted(skel_dir.rglob("*")):
            if not sp.is_file():
                continue
            rel = sp.relative_to(skel_dir).as_posix()      # Desktop/x.desktop
            # The user's own home copy...
            lines.append(f"home/%USER%/{rel}    /etc/skel/{rel}")
            # ...and /etc/skel on the installed system for future useradd.
            lines.append(f"etc/skel/{rel}    /etc/skel/{rel}")

    lines.append("")
    lines.append("# --- man pages (the discovery system) ---")
    lines.append("# etc/man/*.md is staged into the live cpio at")
    lines.append("# /usr/share/man/ (scripts/build_initramfs.py). No hpm")
    lines.append("# package carries them, so before this the installed")
    lines.append("# system had NO man pages at all while the live one had")
    lines.append("# every topic — `man <topic>` silently died on install.")
    man_dir = HERE / "etc" / "man"
    if man_dir.is_dir():
        for mp in sorted(man_dir.iterdir()):
            if mp.is_file() and mp.suffix == ".md":
                lines.append(
                    f"usr/share/man/{mp.name}    /usr/share/man/{mp.name}")
    _write(out_path, lines)


def main() -> int:
    # Source root the installer reads from. The installer
    # (etc/install.hamsh) binds '#distro' /n/distros itself at startup
    # (the boot rc no longer does — isolation invariant). Manifests
    # reference absolute paths under that mount.
    src_root = os.environ.get("HAMNIX_MANIFEST_SRC_ROOT", "/n/distros")

    # Target output (defaults to etc/install/rootfs.manifest under the
    # project root). build_initramfs.py picks up etc/install/* into
    # the cpio at /etc/install/* via its etc-walker.
    out_default = HERE / "etc" / "install" / "rootfs.manifest"
    out_path = Path(os.environ.get("HAMNIX_MANIFEST_OUT",
                                   str(out_default)))
    out_path.parent.mkdir(parents=True, exist_ok=True)

    lines: list[str] = []
    lines.append("# /etc/install/rootfs.manifest — generated by")
    lines.append("# scripts/gen_install_manifest.py at ISO build time.")
    lines.append("#")
    lines.append("# Format: <target_path> <source_path>")
    lines.append("# Comments + blank lines ignored.")
    lines.append("#")
    lines.append("# Read by /bin/install_rootfs_from_manifest, which")
    lines.append("# routes each entry through the kernel's install_file")
    lines.append("# ctl verb on the target /dev/blk/<dev>/ctl.")
    lines.append("")

    # Always plant .hamnix-roots first — without this sentinel,
    # init/main.ad::mount_rootfs_partition can't register #distro on
    # the installed boot.
    lines.append("# Plan 9 sentinel (mount_rootfs_partition reads this)")
    lines.append(f".hamnix-roots    {src_root}/.hamnix-roots")
    lines.append("")

    lines.append("# --- curated apt/dpkg closure (mirrors")
    lines.append("# scripts/build_rootfs_img.py::REAL_DEBIAN_FILES) ---")
    for rel in REAL_DEBIAN_FILES:
        lines.append(f"{rel}    {src_root}/{rel}")
        # usrmerge aliases: same bytes, also planted at the legacy
        # short-prefix path.
        for prefix, alias_prefix in USRMERGE_ALIASES.items():
            if rel.startswith(prefix):
                alias_rel = alias_prefix + rel[len(prefix):]
                # Source is the alias path on the live mount — the
                # rootfs build already plants both copies.
                lines.append(
                    f"{alias_rel}    {src_root}/{alias_rel}")
                break

    lines.append("")
    lines.append("# --- man pages (discovery system) ---")
    lines.append("# Source bytes live in etc/man/ in the Hamnix tree;")
    lines.append("# scripts/build_initramfs.py stages them into the cpio")
    lines.append("# at /usr/share/man/. The live ISO therefore exposes")
    lines.append("# every page at that path (the kernel cpio is mounted")
    lines.append("# as the root tmpfs name lookup), so the manifest can")
    lines.append("# source them from /usr/share/man/<topic>.<N>.md and")
    lines.append("# write them to the target ext4 at the same path.")
    man_dir = HERE / "etc" / "man"
    if man_dir.is_dir():
        for mp in sorted(man_dir.iterdir()):
            if mp.is_file() and mp.suffix == ".md":
                rel = f"usr/share/man/{mp.name}"
                # Source: live-cpio path (not /n/distros — man pages
                # are in the cpio, not the rootfs partition).
                lines.append(f"{rel}    /usr/share/man/{mp.name}")

    lines.append("")
    lines.append("# --- /etc/skel home skeleton ---")
    lines.append("# The standard per-user home template. Source bytes")
    lines.append("# live at etc/skel/ in the Hamnix tree; build_initramfs.py")
    lines.append("# stages them into the cpio at /etc/skel/*, so we source")
    lines.append("# from the live cpio (like the man pages above), not the")
    lines.append("# rootfs partition. This puts /etc/skel on the installed")
    lines.append("# system for any FUTURE useradd/adduser; the wizard's own")
    lines.append("# install user gets its home populated directly by")
    lines.append("# user/install.ad::provision_target.")
    skel_dir = HERE / "etc" / "skel"
    if skel_dir.is_dir():
        for sp in sorted(skel_dir.rglob("*")):
            if sp.is_file():
                rel = sp.relative_to(HERE).as_posix()      # etc/skel/...
                lines.append(f"{rel}    /{rel}")

    lines.append("")
    lines.append("# --- busybox + applets (the Linux-ns shell) ---")
    lines.append("# Source paths under /n/distros/bin/. Applet entries")
    lines.append("# install the busybox binary at each applet name.")
    lines.append("# install_rootfs_from_manifest silently skips missing")
    lines.append("# sources, so a host without u_busybox_musl is fine.")
    lines.append(f"bin/busybox    {src_root}/bin/busybox")
    # On the source rootfs each applet is a symlink → busybox. We
    # install the underlying busybox bytes at each applet name on the
    # target (the kernel-side install_file path doesn't write symlinks
    # yet). The source is the live applet path so the install reads
    # whatever the symlink points at.
    for applet in BUSYBOX_APPLETS:
        lines.append(f"bin/{applet}    {src_root}/bin/{applet}")

    # Same content-compare discipline as _write(): see its docstring for why a
    # no-op mtime bump on a tracked etc/ file makes the freshness guard lie.
    _write(out_path, lines)

    # The two manifests the PACKAGE-driven installer (user/install.ad,
    # the path the desktop "Install Hamnix" icon drives) consumes. They
    # live beside rootfs.manifest so build_initramfs.py's one-level etc/
    # walker stages all three into the cpio at /etc/install/*.
    gen_distro_manifest(src_root, out_path.parent / "distro.manifest")
    gen_live_manifest(out_path.parent / "live.manifest")
    return 0


if __name__ == "__main__":
    sys.exit(main())
