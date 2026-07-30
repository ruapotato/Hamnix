#!/usr/bin/env bash
# scripts/test_installed_pkg_repo.sh — the INSTALLED system must ship a
# working package repository, so the package manager can offer the repo-ONLY
# apps (starting with the audiobook player).
#
# WHY THIS GATE EXISTS. A user on a real installed system reported that the
# package manager "offers no extra packages (the audiobook player)". The
# audiobook player was not missing from packaging and the Software GUI was
# not broken — both were fine. What was missing was the REPOSITORY on the
# installed root:
#
#   * the live/installer medium carries the whole native repo in RAM at
#     /iso-packages/, and hpm's default-repo probe finds it, so on the LIVE
#     image `hpm search` lists everything;
#   * user/install.ad installed hamnix-base FROM that repo onto the target
#     and then walked away. The installed root got no /iso-packages, no
#     /etc/hpm/repo and no cached index, so hpm fell back to the network
#     default https://255.one/ — nothing to list without networking;
#   * and the repo-only apps (hamnix-hamaudiobook, hamnix-hampaint,
#     hamnix-hamclock, hamnix-hammark, hamnix-hamangrybirds) are
#     DELIBERATELY excluded from the hamnix-base closure, so "no repo" means
#     "those apps are unreachable", exactly as reported.
#
# This is the same shape as the `enter linux { sh }` -> "sh not found"
# report: content the live medium has that the install never copied.
#
# WHAT THIS GATE ASSERTS (host-side, no QEMU — it is the cheap always-runs
# half; scripts/test_installed_system_parity.sh drives the same capability
# on a REAL installed disk under `pkgrepo`):
#
#   1. Building an install medium emits /etc/install/packages.manifest.
#   2. Every SOURCE path that manifest names is really present on the
#      medium — a row pointing at a path the cpio does not carry would
#      silently install nothing (install_rootfs_from_manifest skips missing
#      sources by design).
#   3. The manifest lands the repo at usr/share/hpm/repo/ AND carries the
#      audiobook player's tarball + the channel index.
#   4. It writes the target's /etc/hpm/repo, whose body is the file:// URL
#      of that mirror.
#   5. linux-debian-12 is NOT mirrored (install_distro_tree already lays
#      that payload down file-by-file; mirroring it would duplicate 100+
#      MiB on the target).
#   6. The CONSUMERS are compiled in, not just present in source: the
#      shipped build/user/install.elf references the manifest path and the
#      shipped build/user/hpm.elf carries the on-disk mirror URL its
#      default-repo precedence falls back to.
#
# Exit codes: 0 PASS, 1 FAIL, 125 INCONCLUSIVE (a build input is missing —
# never a soft green).

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

say()  { echo "[installed-pkg-repo] $*"; }
fails=0
ok()   { say "OK: $*"; }
miss() { say "MISS: $*"; fails=$((fails + 1)); }

# MUTATE=<label>[,<label>...] blinds the named assertion(s) so this gate can
# be mutation-tested without editing it. Labels:
#   manifest | sources | audiobook | repocfg | dircap | mansize | nodebian |
#   installer | hpm
mutated=",${MUTATE:-},"
blinded() {
    [ -n "$1" ] && [ "${mutated#*,${1},}" != "$mutated" ]
}

WORK="$(mktemp -d /tmp/test-installed-pkg-repo.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

say "(1/4) Build userland"
if ! bash scripts/build_user.sh > "$WORK/build_user.log" 2>&1; then
    say "INCONCLUSIVE: scripts/build_user.sh failed"
    tail -40 "$WORK/build_user.log" >&2
    exit 125
fi
for elf in build/user/install.elf build/user/hpm.elf; do
    if [ ! -f "$elf" ]; then
        say "INCONCLUSIVE: $elf missing after build_user.sh"
        exit 125
    fi
done

say "(2/4) Build the native package repo (SLIM boot/debian)"
if ! HAMNIX_BOOTLOADER_SLIM=1 HAMNIX_LINUX_DEBIAN_SLIM=1 \
        python3 scripts/build_packages.py > "$WORK/build_packages.log" 2>&1; then
    say "INCONCLUSIVE: scripts/build_packages.py failed"
    tail -40 "$WORK/build_packages.log" >&2
    exit 125
fi
if [ ! -f build/packages/main/index.json ]; then
    say "INCONCLUSIVE: build/packages/main/index.json missing"
    exit 125
fi

say "(3/4) Stage an install medium carrying that repo (HAMNIX_ISO_PACKAGES)"
# HAMNIX_BUILD_DIR keeps the blob out of the shared fs/initramfs_blob.S so a
# concurrent build in this checkout is not clobbered.
if ! HAMNIX_BUILD_DIR="$WORK/blob" \
     HAMNIX_ISO_PACKAGES="$PROJ_ROOT/build/packages" \
        python3 scripts/build_initramfs.py > "$WORK/build_initramfs.log" 2>&1; then
    say "INCONCLUSIVE: scripts/build_initramfs.py failed"
    tail -40 "$WORK/build_initramfs.log" >&2
    exit 125
fi
BLOB="$WORK/blob/initramfs_blob.S.bin"
if [ ! -f "$BLOB" ]; then
    say "INCONCLUSIVE: cpio blob $BLOB not produced (archive under the incbin"
    say "              threshold?) — cannot inspect the staged medium"
    exit 125
fi

say "(4/4) Assertions on the staged medium"
# Walk the newc cpio and drop every entry into $WORK/cpio/<path>.
python3 - "$BLOB" "$WORK/cpio" <<'PY' || { say "INCONCLUSIVE: cpio walk failed"; exit 125; }
import os, sys
blob = open(sys.argv[1], "rb").read()
out = sys.argv[2]
off = 0
n = 0
while True:
    if blob[off:off + 6] != b"070701":
        break
    fields = [int(blob[off + 6 + i * 8: off + 14 + i * 8], 16) for i in range(13)]
    fsize, nsize = fields[6], fields[11]
    name = blob[off + 110: off + 110 + nsize - 1].decode()
    hdr = off + 110 + nsize
    hdr += (-hdr) % 4
    data = blob[hdr: hdr + fsize]
    off = hdr + fsize
    off += (-off) % 4
    if name == "TRAILER!!!":
        break
    p = os.path.join(out, name.lstrip("/"))
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as fh:
        fh.write(data)
    n += 1
print(f"[installed-pkg-repo] walked {n} cpio entries")
PY

MAN="$WORK/cpio/etc/install/packages.manifest"
if blinded manifest || [ ! -f "$MAN" ]; then
    miss "the install medium carries NO /etc/install/packages.manifest — the"
    miss "  installed root will have no package repo (hpm falls back to the"
    miss "  network and the Software app lists nothing to install)"
    say "FAILED ($fails)"; exit 1
fi
ok "/etc/install/packages.manifest is staged on the medium"

# Every source path a row names must exist on the medium. A row whose source
# is absent is silently skipped by install_rootfs_from_manifest, so a typo'd
# prefix would install an EMPTY repo and still look green.
bad_src=0
rows=0
while read -r tgt src; do
    case "$tgt" in ''|'#'*) continue;; esac
    rows=$((rows + 1))
    [ -f "$WORK/cpio/${src#/}" ] || { bad_src=$((bad_src + 1));
        [ "$bad_src" -le 5 ] && say "    unresolved source: $src"; }
done < "$MAN"
if blinded sources || [ "$bad_src" -ne 0 ]; then
    miss "$bad_src of $rows manifest source paths are absent from the medium"
else
    ok "all $rows manifest source paths resolve on the medium"
fi

# The mirror target + the audiobook player + the channel index.
if blinded audiobook \
   || ! grep -Eq '^usr/share/hpm/repo/main/packages/hamnix-hamaudiobook-[^ ]*\.tar\.gz[ \t]' "$MAN"; then
    miss "no row mirrors hamnix-hamaudiobook's tarball to usr/share/hpm/repo/ —"
    miss "  the audiobook player stays uninstallable on the installed system"
else
    ok "the audiobook player's tarball is mirrored to usr/share/hpm/repo/"
fi
if ! grep -Eq '^usr/share/hpm/repo/main/index\.json[ \t]' "$MAN"; then
    miss "no row mirrors the main-channel index.json (hpm has nothing to list)"
else
    ok "the main-channel index.json is mirrored"
fi

# The installed system's hpm default-repo config.
CFGSRC=$(awk '$1 == "etc/hpm/repo" { print $2 }' "$MAN" | head -1)
if blinded repocfg || [ -z "$CFGSRC" ]; then
    miss "the manifest writes no etc/hpm/repo on the target — hpm there would"
    miss "  still default to https://255.one/"
elif ! grep -q '^file:///usr/share/hpm/repo/$' "$WORK/cpio/${CFGSRC#/}"; then
    miss "$CFGSRC does not name the on-disk mirror as hpm's default repo"
    say "    body: $(grep -v '^#' "$WORK/cpio/${CFGSRC#/}" | tr '\n' ' ')"
else
    ok "the target's /etc/hpm/repo points at file:///usr/share/hpm/repo/"
fi

# THE TWO MEASURED CEILINGS. Both were found by running the first version of
# this feature through a real install, and both fail SILENTLY at install time
# (install_rootfs_from_manifest skips an unreadable/oversized source and
# ext4_dir_insert's overflow is a kernel printk, not a tool exit code), so
# they have to be caught here.
#   * fs/ext4.ad::ext4_dir_insert cannot grow a directory past its first
#     4 KiB block ("M16.63 does NOT grow the directory by allocating a new
#     block"), which measured out at ~114 entries. Mirroring all 199
#     packages lost the last 88 to `blob_save_at_path FAIL (dir_insert)`.
#   * install_rootfs_from_manifest's MANIFEST_MAX is 65536 bytes.
worst_dir=$(awk '$1 !~ /^#/ && NF == 2 { sub(/\/[^/]*$/, "", $1); print $1 }' "$MAN" \
            | sort | uniq -c | sort -rn | head -1)
worst_n=$(echo "$worst_dir" | awk '{print $1}')
worst_p=$(echo "$worst_dir" | awk '{print $2}')
if blinded dircap || [ "${worst_n:-0}" -gt 100 ]; then
    miss "$worst_n files land in $worst_p/ — over the ~114-entry ext4"
    miss "  single-block directory ceiling; the overflow would be dropped"
else
    ok "densest mirror directory is $worst_p/ with $worst_n files (ext4 ceiling ok)"
fi
man_bytes=$(wc -c < "$MAN")
if blinded mansize || [ "$man_bytes" -gt 60000 ]; then
    miss "the manifest is $man_bytes bytes — over install_rootfs_from_manifest's"
    miss "  65536-byte MANIFEST_MAX"
else
    ok "manifest is $man_bytes bytes (under the 65536-byte MANIFEST_MAX)"
fi

# Deliberate exclusion: the Debian payload is installed as files by
# install_distro_tree; mirroring its tarball too would double it on disk.
if blinded nodebian || grep -q 'linux-debian-12' "$MAN"; then
    miss "linux-debian-12 is mirrored onto the target — install_distro_tree"
    miss "  already lays that payload down, this duplicates 100+ MiB"
else
    ok "linux-debian-12 is excluded from the mirror (no duplicate payload)"
fi

# The CONSUMERS, asserted on the SHIPPED binaries rather than the sources —
# a source-only grep would stay green if the build never picked the change up.
if blinded installer \
   || ! grep -aq '/etc/install/packages.manifest' build/user/install.elf; then
    miss "build/user/install.elf does not reference the packages manifest —"
    miss "  the installer never mirrors the repo onto the target"
else
    ok "the shipped installer consumes /etc/install/packages.manifest"
fi
if blinded hpm \
   || ! grep -aq 'file:///usr/share/hpm/repo/' build/user/hpm.elf; then
    miss "build/user/hpm.elf has no on-disk-mirror fallback in its"
    miss "  default-repo precedence"
else
    ok "the shipped hpm falls back to the on-disk mirror at /usr/share/hpm/repo/"
fi

if [ "$fails" -ne 0 ]; then
    say "RESULT: FAIL ($fails assertion(s))"
    exit 1
fi
say "RESULT: PASS — an installed root gets a working offline hpm repository,"
say "  so the package manager can offer the audiobook player"
exit 0
