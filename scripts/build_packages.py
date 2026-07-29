#!/usr/bin/env python3
"""
scripts/build_packages.py — build the v1 Hamnix package tarballs.

The Debian-installer-shape pivot: each install step is a `hpm install
<pkg>`. To make that scale beyond the monolithic v1 set, this script
emits one package PER command-line app plus a handful of
component/driver packages, and two metapackages (`hamnix-coreutils`
and `hamnix-base`) that pull groups of them in via `depends:`. A
future install can pick a subset (e.g. `{ hamnix-init, hamnix-hamsh,
hpm, hamnix-cat, hamnix-ls, hamnix-drivers-net-e1000e, hamnix-fs-ext4
}` for an embedded build) and skip everything else.

Per-command split (2026-05-28): each `user/<cmd>.ad` ships as its own
`hamnix-<cmd>` package (one binary, minimal `depends:`). Underscored
command stems map to hyphenated package names (the PKGINFO `name`
grammar is `[a-z][a-z0-9-]*` — NO underscores), while the installed
BINARY keeps its underscored filename. E.g. `env_show` →
package `hamnix-env-show`, binary `bin/env_show`. `hamnix-coreutils`
is now a METAPACKAGE depending on every `hamnix-<cmd>`, so anything
that pulled `hamnix-coreutils` still gets the whole command set.

Channel layout (2026-05-27 pivot, per memory/project_nonfree_repo.md):
top-level directories under build/packages/ are *channels* mirroring
Debian's main / contrib / non-free / non-free-firmware split. Today
this script writes every package into `main/` (free + first-party
software). Placeholder `non-free/` and `non-free-firmware/` channels
exist as empty channels with a `{schema:1, packages:[]}` index so a
fresh `hpm refresh` against an enabled channel returns cleanly
instead of 404. The contrib channel is reserved (not auto-created).

Outputs (under build/packages/):

  * main/index.json                    — main-channel index. Each
                                          entry carries `channel: "main"`.
  * main/packages/hamnix-base-<v>.tar.gz   — metapackage (zero files,
                                          depends on all component pkgs).
                                          target: #hamnix-system
  * hamnix-init-<v>.tar.gz             — /init + /etc/rc.boot etc.
  * hamnix-hamsh-<v>.tar.gz            — /bin/hamsh + /etc/profile etc.
  * hamnix-<cmd>-<v>.tar.gz            — one package PER command
                                          (~83: cat, ls, echo, ps, ...)
  * hamnix-coreutils-<v>.tar.gz        — METAPACKAGE depending on every
                                          hamnix-<cmd> (preserves the
                                          old "install all utils" path)
  * hamnix-net-<v>.tar.gz              — ifconfig, ping, route, httpd
  * hamnix-svc-sshd-<v>.tar.gz         — sshd + /etc/svc/sshd.hamsh
  * hpm-<v>.tar.gz                     — /bin/hpm + var dirs
  * hamnix-fs-ext4-<v>.tar.gz          — mkfs_ext4 + install_file_to_slot
  * hamnix-fs-fat-<v>.tar.gz           — mkfs_fat
  * hamnix-drivers-net-e1000e-<v>.tar.gz — e1000e.ko
  * hamnix-drivers-block-ahci-<v>.tar.gz — ahci + libata + scsi_mod + ...
  * hamnix-drivers-block-nvme-<v>.tar.gz — nvme + nvme_core
  * hamnix-drivers-usb-xhci-<v>.tar.gz   — xhci_pci + xhci_hcd + usbcore
  * hamnix-drivers-snd-hda-<v>.tar.gz    — snd_hda_intel + ALSA stack
  * hamnix-installer-tools-<v>.tar.gz  — hamnix_partition + dd_blk
  * hamnix-bootloader-<v>.tar.gz       — BOOTX64.EFI + kernel ELF
  * linux-debian-12-<v>.tar.gz         — Debian 12 rootfs
  * index.json                         — repo index (docs/packages.md)

Cleavage principle: every reusable subsystem is its own package so a
shrink-wrapped install can pick exactly what it needs. A NUC with only
USB+NVMe doesn't need ahci/snd-hda; an embedded headless build doesn't
need linux-debian-12; a kiosk box might want only hamnix-{kernel,init,
hamsh}.

After this script runs the ISO builder stages build/packages/main/ at
/iso-packages/ on the cpio (build_initramfs.py) and the installer
runs

    hpm --repo=file:///iso-packages --target-prefix=/tmp/newroot \\
        install hamnix-base

The ISO mini-repo only carries the `main` channel — the installer
default subscribes to `main` only, and an ISO-time install never
needs non-free firmware (that's an opt-in `hpm enable
non-free-firmware` post-install).

which (per docs/packages.md and the hpm v3 dep solver) pulls the
entire closure transitively. Alternatively install.hamsh can name
individual components for a slimmer build.

DESIGN — file→package mapping. The mapping lives in this file under
PACKAGE_SPECS (a list of dicts). Each entry declares:
  * name, version, arch, description, target
  * depends/conflicts/provides (PKGINFO + index.json fields)
  * a `files` list of (src_path, target_path) tuples that the staging
    helper copies into <pkg>-<v>/files/<target_path>
  * an optional `extra_files` callable for packages with non-trivial
    layout (linux-debian-12's usrmerge; hamnix-bootloader's SLIM mode)

A future package = one new dict added to PACKAGE_SPECS. The
file-mapping is the source of truth; gen_install_manifest.py can be
extended later to read this same table if the brief's option-1 (per-
package manifest fragments) becomes preferable.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
import tarfile
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
BUILD = HERE / "build"
USER_DIR = BUILD / "user"
MOD_DIR = BUILD / "mod"
# Output channel tree. Defaults to build/packages/ (a throwaway build
# artifact) but is overridable via HAMNIX_PACKAGES_OUT so the canonical
# package tree can be regenerated directly into the HamnixOS/packages
# submodule (the source of truth served at 255.one, and the tree the
# ISO build embeds as its installer mirror). main() only unlinks stale
# *.tar.gz / index.json — it never rm -rf's this dir, so a submodule's
# .git is safe.
PACKAGES_OUT = Path(os.environ.get("HAMNIX_PACKAGES_OUT", str(BUILD / "packages")))
ETC_DIR = HERE / "etc"
MAN_DIR = ETC_DIR / "man"
KMODS_DIR = HERE / "kernel-modules"
KERNEL_ELF = BUILD / "hamnix-kernel.elf"
EFI_STUB = BUILD / "hamnix-bootx64.efi"
DEBIAN_MINBASE = HERE / "tests" / "distros" / "debian-minbase" / "rootfs"

# v1: every package shares one atomic release version. You don't ship
# a bootloader newer than the base it boots into.
PKG_VERSION = os.environ.get("HAMNIX_PKG_VERSION", "1.0.0")


# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

def _say(msg: str) -> None:
    print(f"[build_packages] {msg}", flush=True)


# --- Index signing (trust root) --------------------------------------
# hpm treats index.json as the root of trust (it records every
# package's sha256). To stop a MITM / compromised mirror serving a
# malicious index with matching hashes, we emit a DETACHED Ed25519
# signature index.json.sig that hpm verifies against etc/hpm/trusted.pub
# before trusting any hash inside. Signing needs the repo SECRET key,
# which is held out of band (never committed) and passed via the
# HPM_REPO_SECKEY env var (path to a 32-byte hex seed). When it is
# unset — the common local/dev case, exactly like building an apt repo
# without the archive key — we skip signing and print a note; hpm will
# then require `refresh --allow-unsigned` for that repo.
# The committed LOCAL signing key. It stamps every index with a valid
# signature even when HPM_REPO_SECKEY (the out-of-band PRODUCTION archive
# secret) is unset — the common local / offline / on-image build. hpm trusts
# this key ONLY for file:// (on-image) repos (etc/hpm/local-trusted.pub,
# compiled in), which are trusted-by-construction, so committing its secret
# grants no MITM power over the remote 255.one path. When HPM_REPO_SECKEY IS
# set (CI / production publish), that key signs instead and hpm verifies it
# against the compiled-in PRODUCTION root (etc/hpm/trusted.pub).
LOCAL_SECKEY = HERE / "scripts" / "hpm_local_key.seed"


def _sign_index(index_path: Path) -> None:
    seckey_path = os.environ.get("HPM_REPO_SECKEY")
    sig_path = index_path.with_name(index_path.name + ".sig")
    if sig_path.exists():
        sig_path.unlink()
    sys.path.insert(0, str(HERE / "scripts"))
    import hpm_sign
    if seckey_path:
        seed_hex = Path(seckey_path).read_text()
        which = "production (HPM_REPO_SECKEY)"
    elif LOCAL_SECKEY.is_file():
        seed_hex = LOCAL_SECKEY.read_text()
        which = "local on-image key"
    else:
        _say(f"NOT signing {index_path} (HPM_REPO_SECKEY unset AND "
             f"{LOCAL_SECKEY} missing) — hpm will need "
             f"`refresh --allow-unsigned` for this repo")
        return
    sig = hpm_sign.sign_bytes(index_path.read_bytes(), seed_hex)
    sig_path.write_text(sig + "\n")
    _say(f"signed {index_path} -> {sig_path.name} "
         f"(Ed25519, {which}, pub {hpm_sign.pub_of(seed_hex)[:16]}…)")


def _stage_dir(staging: Path) -> Path:
    """Create a clean staging dir and return its path."""
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    return staging


def _copy_file(src: Path, dst: Path, mode: int | None = None) -> int:
    """Copy `src` to `dst` (creating parents). Returns size in bytes."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    data = src.read_bytes()
    dst.write_bytes(data)
    if mode is not None:
        dst.chmod(mode)
    else:
        if src.stat().st_mode & 0o111:
            dst.chmod(0o755)
        else:
            dst.chmod(0o644)
    return len(data)


def _write_pkginfo(pkg_root: Path, fields: dict[str, str]) -> None:
    """Emit a PKGINFO file at <pkg_root>/PKGINFO."""
    lines = []
    for key, val in fields.items():
        lines.append(f"{key}: {val}")
    pkg_root.joinpath("PKGINFO").write_text("\n".join(lines) + "\n",
                                            encoding="utf-8")


def _tar_gz(pkg_root: Path, out_path: Path) -> tuple[str, int]:
    """Make a deterministic gzipped tar of pkg_root.

    Returns (sha256_hex, size_bytes).
    """
    if out_path.exists():
        out_path.unlink()
    pkg_dirname = pkg_root.name
    entries: list[Path] = sorted(pkg_root.rglob("*"))
    with tarfile.open(out_path, mode="w:gz", format=tarfile.GNU_FORMAT,
                      compresslevel=9) as tar:
        ti = tarfile.TarInfo(name=pkg_dirname)
        ti.type = tarfile.DIRTYPE
        ti.mode = 0o755
        ti.mtime = 0
        ti.uid = 0
        ti.gid = 0
        ti.uname = "root"
        ti.gname = "root"
        tar.addfile(ti)
        for p in entries:
            rel = p.relative_to(pkg_root)
            arcname = f"{pkg_dirname}/{rel.as_posix()}"
            ti = tar.gettarinfo(name=str(p), arcname=arcname)
            if ti is None:
                continue
            ti.mtime = 0
            ti.uid = 0
            ti.gid = 0
            ti.uname = "root"
            ti.gname = "root"
            if ti.isdir():
                ti.mode = 0o755
                tar.addfile(ti)
            elif ti.isreg():
                ti.mode = 0o755 if (p.stat().st_mode & 0o111) else 0o644
                with p.open("rb") as f:
                    tar.addfile(ti, f)
            elif ti.issym():
                tar.addfile(ti)
            else:
                tar.addfile(ti)
    data = out_path.read_bytes()
    sha = hashlib.sha256(data).hexdigest()
    return sha, len(data)


# ---------------------------------------------------------------------
# File mappings — per-package
# ---------------------------------------------------------------------
# Each spec resolves to a `files/` layout. Sources are project-relative;
# missing sources are reported via _say and skipped (the package still
# emits — useful for slim/CI builds where e.g. busybox isn't compiled).

def _add_user_bin(file_map: list[tuple[Path, str]], stem: str,
                  target_subpath: str = "bin") -> None:
    """Add build/user/<stem>.elf at files/<target_subpath>/<stem>."""
    src = USER_DIR / f"{stem}.elf"
    rel = f"{target_subpath}/{stem}"
    file_map.append((src, rel))


def _add_etc_file(file_map: list[tuple[Path, str]], name: str,
                  subdir: str = "") -> None:
    """Add etc/<subdir>/<name> at files/etc/<subdir>/<name>."""
    if subdir:
        src = ETC_DIR / subdir / name
        rel = f"etc/{subdir}/{name}"
    else:
        src = ETC_DIR / name
        rel = f"etc/{name}"
    file_map.append((src, rel))


def _add_ko(file_map: list[tuple[Path, str]], modname: str,
            ko_basename: str | None = None) -> None:
    """Add kernel-modules/<modname>/<modname>.ko at files/lib/modules/.

    Some modules ship under a different ko basename (nvme_core →
    nvme-core.ko). Pass ko_basename to override.
    """
    if ko_basename is None:
        ko_basename = modname
    src = KMODS_DIR / modname / f"{ko_basename}.ko"
    rel = f"lib/modules/{ko_basename}.ko"
    file_map.append((src, rel))


# ---- hamnix-init ----------------------------------------------------
# /init shim + the rc.boot + inittab + etc identity files. Without
# this package there's no PID 1, no boot rc — nothing comes up.

def _files_init() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    # /init shim (special: not under /bin).
    f.append((USER_DIR / "init.elf", "init"))
    # etc boot config + identity.
    # rc.boot.full is the full boot rc that enters runlevel 5 (graphical);
    # it's a base boot file and was previously unpackaged (base drift).
    for name in ("rc.boot", "rc.boot.full", "inittab", "fstab", "hostname",
                 "host.conf", "hosts", "issue", "issue.net",
                 "login.defs", "lsb-release", "networks",
                 "os-release", "passwd", "group", "shadow",
                 "shells", "profile", "protocols",
                 "resolv.conf", "services", "timezone",
                 "debian_version"):
        _add_etc_file(f, name)
    # Per-user namespace recipes. etc/users/ is a DIRECTORY (not a single
    # file), so it can't ride the flat list above (it was previously
    # listed as "users" and silently skipped as a missing file — which
    # meant /etc/users/ never landed on the installed disk, so the login
    # path had no default.ns to source AND `useradd` could not write
    # /etc/users/<name>.ns, leaving every new user's #<name> home unbound
    # in their session). Ship every recipe so the directory exists and
    # the regular-user restricted view + per-user home bind resolve.
    users_dir = ETC_DIR / "users"
    if users_dir.is_dir():
        for ns in sorted(users_dir.glob("*.ns")):
            f.append((ns, f"etc/users/{ns.name}"))
    # /etc/hpm/channels — channel-subscription file. Default contents
    # subscribe to `main` only (the free / first-party channel).
    # `hpm enable non-free-firmware` appends entries post-install.
    _add_etc_file(f, "channels", subdir="hpm")
    # /etc/hpm/{trusted.pub,local-trusted.pub} — the PRODUCTION (remote
    # 255.one) and LOCAL (file:// / on-image) repo trust roots, shipped for
    # inspection/tooling (hpm also has both compiled in).
    _add_etc_file(f, "trusted.pub", subdir="hpm")
    _add_etc_file(f, "local-trusted.pub", subdir="hpm")
    # Runlevel operator hooks for the non-graphical base: rc.3 is
    # multi-user (non-graphical), rc.0/rc.6 are halt/reboot. rc.5
    # (graphical) ships in hamnix-desktop-config instead, since it's the
    # DE entry point. These were previously unpackaged (base drift).
    for rc in ("rc.0", "rc.3", "rc.6"):
        _add_etc_file(f, rc, subdir="rc.d")
    return f


# ---- hamnix-hamsh ---------------------------------------------------
# The shell. Pulls in /bin/hamsh + the issue/motd assets that hamsh
# prints on session entry. /etc/profile is in hamnix-init (read by
# every shell at startup, not just hamsh).

def _files_hamsh() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "hamsh")
    _add_etc_file(f, "motd")
    # banner is a userland binary (user/banner.ad) — its assets are
    # baked in. The motd file in /etc is the actual greeting.
    _add_user_bin(f, "banner")
    return f


# ---- per-command packages (was: hamnix-coreutils) ------------------
# Every small command the shell expects ships as its OWN package
# (`hamnix-<cmd>`), generated programmatically from COREUTILS_BINS
# below. `hamnix-coreutils` is now a METAPACKAGE that depends on every
# one of them, so anything that pulled `hamnix-coreutils` still gets
# the whole set. Each leaf depends only on the init runtime
# (`hamnix-init`) — a standalone binary needs the ELF loader + PID-1
# runtime, not the shell.

COREUTILS_BINS = (
    "ascii", "awk", "base64", "basename", "cal", "cat", "clear", "cmp",
    "cp", "crond", "crontab", "csplit", "cut", "date", "df", "diff",
    "dircolors", "dirname",
    "distrofs", "dmesg",
    "du", "echo", "ed", "env_show", "expr", "false", "find", "free",
    "getty", "grep", "halt", "hamwd", "head", "hostname", "id",
    "insmod", "kill", "less", "ln", "login", "ls", "lsblk", "lsmod",
    "md5sum", "memhog",
    "mkdir", "more", "motd", "mv", "nsbindprobe", "nsrun", "numfmt", "od",
    "p9srv_demo", "passwd", "patch", "pgrep", "poweroff", "pr", "preempt_demo",
    "preempt_hog", "printf", "ps", "pwd", "reboot", "rev", "rm",
    "rmmod", "sed", "seq", "sleep", "sort", "strings", "su", "tail",
    "tee", "test", "top", "touch", "tr", "true", "tsort", "uname", "uptime",
    "u_server", "u_tlstest", "vi", "watch", "wc", "whatis", "which",
    "whoami", "xargs", "yes",
    # --- drift sweep (2026-06-19): real CLI tools that build into
    # build/user/*.elf but were never in any package. The live rootfs
    # globbed them in (build_rootfs_img.py) so the from-packages base
    # silently lacked them. Net-facing tools (curl/wget/ssh/host/ntpd/
    # httpd_worker) live in hamnix-net instead; pure demos/selftests
    # (hello, *_demo, *_selftest, x11test, scenetest, ...) are
    # intentionally NOT packaged. See test_package_de_coverage.sh.
    "aplay", "cgi_echo", "chvt", "cksum", "column", "comm", "expand",
    "factor", "fold", "gunzip", "gzip", "hdu", "help", "hfw", "hlog",
    "hxd", "initctl", "join", "loadkeys", "losetup", "man", "mktemp",
    "modprobe", "nl", "nproc", "oopsread", "paste", "printenv",
    "realpath", "service", "shuf", "split", "stat", "tac", "tar",
    "tree", "truncate", "tty", "unexpand", "uniq", "useradd",
    # --- drift sweep (2026-07-12, #115 granular-packaging pass): real
    # shippable CLIs that build into build/user/*.elf but were in NO
    # package (caught red by test_package_de_coverage.sh). bc = infix
    # calculator; fmt = text reflow; sha256sum = FIPS-180-4 digest; js =
    # the native JavaScript engine CLI. (spawnfdprobe = a #28 spawn-FD
    # fixture and umdf_host = the Track-4 .ko host slice stay UNpackaged
    # — allowlisted as dev/fixture binaries in the coverage gate.)
    "bc", "fmt", "sha256sum", "js",
    # --- coreutils gap-fill (2026-07-12, #143 native-userland batch):
    # standard file/text CLIs that were absent as native Adder binaries.
    # sum = BSD/SysV checksum; sha1sum = SHA-1 digest; arch = uname -m;
    # unlink/link = the thin one-shot unlink(2)/link(2) front ends;
    # pathchk = portable-pathname validator.
    "sum", "sha1sum", "arch", "unlink", "link", "pathchk",
)


def _cmd_pkg_name(stem: str) -> str:
    """Map a command stem to its package name.

    PKGINFO `name` grammar is `[a-z][a-z0-9-]*` (lowercase, hyphens OK,
    NO underscores), so underscored stems get their underscores
    rewritten to hyphens. The installed binary keeps the underscored
    stem; only the PACKAGE name is hyphenated.

        cat       -> hamnix-cat
        env_show  -> hamnix-env-show
        u_server  -> hamnix-u-server
    """
    return "hamnix-" + stem.replace("_", "-")


def _man_one_liner(stem: str) -> str | None:
    """Pull a one-line description from etc/man/<stem>.1.md if present.

    Man pages are markdown. The H1 title line is `# <cmd> - <summary>`
    and the NAME section repeats `<cmd> - <summary>`. Prefer the NAME
    section (canonical whatis source); fall back to the H1. Returns the
    `<summary>` portion, or None if no man page / no parseable line.
    """
    man = MAN_DIR / f"{stem}.1.md"
    if not man.is_file():
        return None
    try:
        lines = man.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None

    def _summary(line: str) -> str | None:
        # Accept `cmd - summary` or `cmd — summary`.
        for sep in (" - ", " — "):
            if sep in line:
                return line.split(sep, 1)[1].strip()
        return None

    # NAME section: the first non-blank line after a `## NAME` header.
    for i, raw in enumerate(lines):
        if raw.strip().lower() == "## name":
            for follow in lines[i + 1:]:
                if follow.strip():
                    s = _summary(follow.strip())
                    if s:
                        return s
                    break
            break
    # Fall back to the H1 title (`# cmd - summary`).
    for raw in lines:
        stripped = raw.strip()
        if stripped.startswith("# "):
            return _summary(stripped[2:].strip())
    return None


def _cmd_description(stem: str) -> str:
    """One-line package description for command `stem`.

    Pulls the real summary from etc/man/<stem>.1.md when available;
    otherwise a sensible default. Don't over-invest — the default is
    fine for the long tail of demo/utility commands.
    """
    man = _man_one_liner(stem)
    if man:
        return f"Hamnix {stem} — {man}"
    return f"Hamnix {stem} command"


def _make_cmd_files_fn(stem: str):
    """Return a files_fn that stages just `build/user/<stem>.elf`."""
    def _files() -> list[tuple[Path, str]]:
        f: list[tuple[Path, str]] = []
        _add_user_bin(f, stem)
        return f
    return _files


def _cmd_specs() -> list[dict]:
    """Generate one PACKAGE_SPEC per command in COREUTILS_BINS."""
    specs: list[dict] = []
    for stem in COREUTILS_BINS:
        specs.append({
            "name": _cmd_pkg_name(stem),
            "files_fn": _make_cmd_files_fn(stem),
            "depends": ["hamnix-init>=1"],
            "description": _cmd_description(stem),
            "target": "#hamnix-system",
        })
    return specs


# ---- hamnix-net -----------------------------------------------------
# Network userland: ifconfig (boot-rc dump), ping, route, httpd. The
# kernel does the actual IP stack; these are the operator-facing tools.

def _files_net() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "ifconfig")
    _add_user_bin(f, "ping")
    _add_user_bin(f, "route")
    _add_user_bin(f, "httpd")
    # Drift sweep (2026-06-19): network client/server tools that built
    # but were never packaged. curl/wget = HTTP clients; ssh = the SSH-2
    # client; host = DNS lookup; ntpd = SNTP time sync; httpd_worker =
    # the per-connection CGI worker httpd spawns.
    _add_user_bin(f, "curl")
    _add_user_bin(f, "wget")
    _add_user_bin(f, "ssh")
    _add_user_bin(f, "host")
    _add_user_bin(f, "ntpd")
    _add_user_bin(f, "httpd_worker")
    return f


# ---- hamnix-svc-sshd ------------------------------------------------
# In-tree SSH server. Decoupled from the base because a headless
# embedded board can opt out of remote login.

def _files_svc_sshd() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "sshd")
    _add_etc_file(f, "sshd.hamsh", subdir="svc")
    return f


# ---- hpm ------------------------------------------------------------
# The package manager itself. Split out because a locked-down embedded
# system might ship a frozen image without runtime package mgmt.

def _files_hpm() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "hpm")
    return f


# ---- hamnix-fs-ext4 -------------------------------------------------
# Ext4 toolchain: format + per-file install. install_rootfs_from_manifest
# also lives here because it drives the kernel-side install_file ctl.

def _files_fs_ext4() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "mkfs_ext4")
    _add_user_bin(f, "install_file_to_slot")
    _add_user_bin(f, "mkdir_at_slot")
    _add_user_bin(f, "install_rootfs_from_manifest")
    return f


# ---- hamnix-fs-fat --------------------------------------------------

def _files_fs_fat() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "mkfs_fat")
    return f


# ---- hamnix-drivers-net-e1000e --------------------------------------
# Intel e1000e family (I219 PHY/MAC on most NUCs and laptops).

def _files_drv_e1000e() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_ko(f, "e1000e")
    return f


# ---- hamnix-drivers-block-ahci --------------------------------------
# AHCI SATA stack. libata + libahci are framework deps; scsi_mod +
# scsi_common are the SCSI mid/lower layer the ATA-on-SCSI translator
# pulls in.

def _files_drv_ahci() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_ko(f, "ahci")
    _add_ko(f, "libahci")
    _add_ko(f, "libata")
    _add_ko(f, "scsi_mod")
    _add_ko(f, "scsi_common")
    return f


# ---- hamnix-drivers-block-nvme --------------------------------------

def _files_drv_nvme() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_ko(f, "nvme")
    _add_ko(f, "nvme_core", ko_basename="nvme-core")
    return f


# ---- hamnix-drivers-usb-xhci ----------------------------------------

def _files_drv_xhci() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_ko(f, "xhci_pci")
    _add_ko(f, "xhci_hcd")
    _add_ko(f, "usbcore")
    return f


# ---- hamnix-drivers-snd-hda -----------------------------------------

def _files_drv_snd_hda() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_ko(f, "snd_hda_intel")
    _add_ko(f, "snd_hda_codec")
    _add_ko(f, "snd_hda_core")
    _add_ko(f, "snd_pcm")
    _add_ko(f, "snd")
    return f


# ---- hamnix-installer-tools ----------------------------------------
# The partitioner + dd_blk + sqfs_to_blk + the `install` front-end. mkfs_*
# moved to hamnix-fs-*; hpm is its own package; hpm's solver pulls them in
# via the metapackage. `install` is the interactive/auto Debian-style
# installer command, and sqfs_to_blk is the ESP byte-streamer it spawns;
# shipping both means the installed system can itself reinstall onto a new
# disk.

def _files_installer_tools() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "hamnix_partition")
    _add_user_bin(f, "dd_blk")
    _add_user_bin(f, "sqfs_to_blk")
    _add_user_bin(f, "install")
    # haminstall = the headless on-target installer (lay down a fresh
    # Hamnix from a running system); the GUI front-end haminstallui
    # ships in hamnix-desktop-apps.
    _add_user_bin(f, "haminstall")
    return f


# ---- the scene-file Desktop Environment: GRANULAR packaging ---------
# A REAL distro ships every application as its OWN package (#115: "make
# it a real distro — everything individually packaged"). The DE therefore
# splits into:
#
#   * hamnix-desktop-core — the compositor / window-system daemon
#     (hamUId), the DE session manager (hamde/hamsession/hamsessui), the
#     panel + menus + tray + OSD + notification/toast/lock/screensaver
#     infrastructure. This is the "you must have it for a desktop at all"
#     substrate; the app packages Depend on it.
#
#   * one hamnix-<app> package PER application (hamnix-ham2048,
#     hamnix-hamterm, hamnix-hamfiles, hamnix-hamcalc, hamnix-hamedit,
#     hamnix-hammon, hamnix-hamview, hamnix-hambrowse, hamnix-haminbox,
#     hamnix-hamsettings, hamnix-haminstallui). Each is
#     independently installable/removable and carries its own version +
#     depends (>= hamnix-desktop-core). An app that comes as a
#     logic-binary + a scene front-end (hamterm + hamtermscene, hamfm +
#     hamfmscene, ...) ships BOTH in its package.
#
#   * hamnix-desktop-apps — now a METAPACKAGE (zero files) depending on
#     every hamnix-<app> package, mirroring the hamnix-coreutils pattern.
#     Anything that pulled the old bundled hamnix-desktop-apps still gets
#     the whole app set transitively.
#
#   * hamnix-desktop — the top METAPACKAGE: Depends on hamnix-desktop-core
#     + hamnix-desktop-apps + hamnix-desktop-config + the shell.
#
# Verified present in build/user/*.elf after scripts/build_user.sh: all
# binaries below build. None dropped.

DESKTOP_CORE_BINS = (
    "hamUId", "hamde", "hamdesktop", "hampanelscene", "hamctl",
    "hamnotify", "hamshot", "hamshotui", "hamtray", "hamappmenu", "hamctxmenu",
    "hamosd", "hamlock", "hamscreensaver", "hamsession", "hamsessui",
    "hamrband", "hamresize", "hamtoast",
)

# One package per DE application. `bins` is the binary set the package
# stages; `summary` is the human one-liner; `images` flags the hamview
# sample-image fixtures.
DESKTOP_APP_PACKAGES: list[dict] = [
    {"name": "hamnix-ham2048", "bins": ("ham2048scene",),
     "summary": "2048 sliding-tile puzzle game"},
    {"name": "hamnix-hamsnake", "bins": ("hamsnakescene",),
     "summary": "Snake arcade game"},
    {"name": "hamnix-hamchess", "bins": ("hamchessscene",),
     "summary": "two-player hot-seat chess"},
    {"name": "hamnix-hamtetris", "bins": ("hamtetrisscene",),
     "summary": "Tetris falling-blocks game"},
    {"name": "hamnix-hammine", "bins": ("hamminescene",),
     "summary": "Minesweeper logic puzzle game"},
    {"name": "hamnix-hamgamedemo", "bins": ("hamgamedemo",),
     "summary": "Coin Dash (hamGame demo game)"},
    {"name": "hamnix-hamgamesnake", "bins": ("hamgamesnake",),
     "summary": "Snake (hamGame arcade game)"},
    # hamnix-hamgamechess retired — the inferior hamgamechess build was removed
    # in favour of hamchessscene (full legal moves + check/mate). Its binary is
    # no longer built, so the metapackage entry is gone to keep the build sound.
    {"name": "hamnix-hamterm", "bins": ("hamterm", "hamtermscene"),
     "summary": "terminal emulator"},
    {"name": "hamnix-hamfiles", "bins": ("hamfm", "hamfmscene"),
     "summary": "file manager"},
    {"name": "hamnix-hamcalc", "bins": ("hamcalc", "hamcalcscene"),
     "summary": "calculator"},
    {"name": "hamnix-hamedit", "bins": ("hamedit", "hameditscene"),
     "summary": "text editor"},
    {"name": "hamnix-hammon", "bins": ("hammon", "hammonscene"),
     "summary": "system / resource monitor"},
    {"name": "hamnix-hamview", "bins": ("hamview",),
     "summary": "image viewer", "images": True},
    {"name": "hamnix-hambrowse", "bins": ("hambrowse",),
     "summary": "native web browser"},
    {"name": "hamnix-haminbox", "bins": ("haminbox",),
     "summary": "mail inbox"},
    {"name": "hamnix-hamcalendar", "bins": ("hamcalscene",),
     "summary": "monthly calendar"},
    {"name": "hamnix-hamnotes", "bins": ("hamnotesscene",),
     "summary": "sticky-note scratchpad"},
    {"name": "hamnix-hampkg", "bins": ("hampkgscene", "hamsoftware"),
     "summary": "graphical package manager / Software app (hpm front-end)"},
    {"name": "hamnix-hamlog", "bins": ("hamlogscene",),
     "summary": "kernel log viewer"},
    # ---- the OFFICE SUITE (pre-installed, first-class DE apps) -------------
    # HamWrite / HamSheet / HamSlides were repo-ONLY leaves (built + published
    # but excluded from the hamnix-base closure, .desktop parked in
    # etc/hamde/apps-optional/) so the panel never listed them and a fresh
    # install never carried them. They are now ordinary DE app packages: pulled
    # in by hamnix-desktop-apps -> hamnix-desktop -> hamnix-base, with their
    # .desktop launchers moved into etc/hamde/apps/ (globbed wholesale by
    # hamnix-desktop-config) so the Applications menu shows them out of the box.
    {"name": "hamnix-hamwrite", "bins": ("hamwrite",),
     "summary": "word processor (HamWrite — rich text, headings, save/load)"},
    {"name": "hamnix-hamsheet", "bins": ("hamsheet",),
     "summary": "spreadsheet (HamSheet — recalculating formula engine)"},
    {"name": "hamnix-hamslides", "bins": ("hamslides",),
     "summary": "presentation editor (HamSlides — edit + present a deck)"},
    {"name": "hamnix-hamaudio", "bins": ("hamaudioscene",),
     "summary": "audio player (.wav playback through the HDA sink)",
     "sounds": True},
    {"name": "hamnix-hamvideo", "bins": ("hamvideoscene",),
     "summary": "video player (Motion-JPEG .hmjv playback to the window)",
     "videos": True},
    {"name": "hamnix-hamsettings", "bins": ("hamsettings", "hamabout"),
     "summary": "settings + about dialog"},
    {"name": "hamnix-haminstallui", "bins": ("haminstallui",),
     "summary": "graphical installer front-end"},
]

# Flat set of every app-package name — used to keep hamnix-base's direct
# depends list to the metapackage (hamnix-desktop) rather than every leaf.
DESKTOP_APP_PKG_NAMES = {d["name"] for d in DESKTOP_APP_PACKAGES}


def _files_desktop_core() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    for stem in DESKTOP_CORE_BINS:
        _add_user_bin(f, stem)
    return f


def _make_desktop_app_files_fn(bins: tuple, with_images: bool,
                               with_sounds: bool = False,
                               with_videos: bool = False):
    """Return a files_fn staging `bins` (+ hamview sample images / the
    hamaudio royalty-free test clip / the hamvideo royalty-free test clip)."""
    def _files() -> list[tuple[Path, str]]:
        f: list[tuple[Path, str]] = []
        for stem in bins:
            _add_user_bin(f, stem)
        if with_videos:
            # The royalty-free (CC0) Motion-JPEG test clip the player opens out
            # of the box: `hamvideoscene` defaults to /usr/share/videos/
            # test.hmjv. Generated deterministically by scripts/gen_test_video.py
            # (synthesized animation — no third-party footage), an original
            # public-domain work.
            vid = HERE / "tests" / "fixtures" / "videos" / "test.hmjv"
            f.append((vid, "usr/share/videos/test.hmjv"))
        if with_sounds:
            # The royalty-free (CC0) audio test clip. `aplay` defaults to
            # /usr/share/sounds/test.wav, and it is one of the playlist rows
            # the DE audio player seeds on a bare launch (whose DEFAULT open is
            # now the Hamnix Music Demo mp3 below, not test.wav). Generated
            # deterministically by scripts/gen_test_wav.py (synthesized arpeggio
            # — no third-party recording), so it is an original public-domain
            # work.
            wav = HERE / "tests" / "fixtures" / "sounds" / "test.wav"
            f.append((wav, "usr/share/sounds/test.wav"))
            # The same clip as CBR MPEG-1 Layer III, so `hamaudioscene
            # /usr/share/sounds/test.mp3` exercises the native MP3 decoder
            # (lib/mp3decode) end-to-end through the HDA sink. Generated by
            # scripts/gen_test_mp3.py (also public-domain / CC0).
            mp3 = HERE / "tests" / "fixtures" / "sounds" / "test.mp3"
            f.append((mp3, "usr/share/sounds/test.mp3"))
            # The DE login/loading jingle (48 kHz WAV) that user/login.ad
            # streams to the HDA sink (non-blocking) when the desktop comes
            # up, plus a longer music demo (clean MPEG-1 Layer III, 128k /
            # 48 kHz) preloaded so `hamaudioscene` opens real music out of
            # the box. Original assets shipped with Hamnix.
            jingle = HERE / "tests" / "fixtures" / "sounds" / "boot-jingle.wav"
            f.append((jingle, "usr/share/sounds/boot-jingle.wav"))
            music = HERE / "tests" / "fixtures" / "sounds" / "hamnix-music-demo.mp3"
            f.append((music, "usr/share/music/hamnix-music-demo.mp3"))
        if with_images:
            # Sample images for the hamview image viewer: a PNG and a
            # baseline JPEG so `hamview /share/hamview/test.png|test.jpg`
            # opens a real compressed image out of the box (and
            # scripts/test_hamview_png_jpeg.sh has fixed on-device targets
            # to decode + screendump).
            fixtures = HERE / "tests" / "fixtures" / "hamview"
            for img in ("test.png", "test.jpg"):
                f.append((fixtures / img, f"share/hamview/{img}"))
        return f
    return _files


def _desktop_app_specs() -> list[dict]:
    """Generate one PACKAGE_SPEC per DE application package."""
    specs: list[dict] = []
    for app in DESKTOP_APP_PACKAGES:
        specs.append({
            "name": app["name"],
            "files_fn": _make_desktop_app_files_fn(
                app["bins"], app.get("images", False),
                app.get("sounds", False), app.get("videos", False)),
            "depends": [f"hamnix-desktop-core>={PKG_VERSION}"],
            "description": f"Hamnix desktop app — {app['summary']}",
            "target": "#hamnix-system",
        })
    return specs


# ---- hamnix-desktop-config ------------------------------------------
# The DE autostart + config files. WITHOUT these nothing launches the
# DE even with the app binaries present: rc.5 (runlevel-5 graphical
# hook) flips the kernel scene compositor and launches the panel/term;
# services.d/hamuid.svc declaratively auto-starts hamUId at runlevel 5;
# rc.de-user / rc.de-hostowner are the per-session DE rc bodies;
# desktop.icons + panel.conf are the launcher layout. (There is NO
# etc/wallpaper.ppm — the backdrop is generated at runtime.)

def _files_desktop_config() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    # Runlevel-5 (graphical) operator hook — the DE entry point.
    _add_etc_file(f, "rc.5", subdir="rc.d")
    # Boot-time DE self-test + demo-app launches (rc.5 `source`s this). It is
    # packaged ONLY when a DE render gate builds the image with
    # HAMNIX_DE_SELFTEST=1, so a NORMAL user boot comes up CLEAN (wallpaper +
    # panel + taskbar + one welcome terminal) while the render gates
    # (test_de_visual_gate.sh / test_de_mem_gate.sh) still trigger the app
    # launches + [visual_gate] markers + window maps. On a normal build the
    # fragment is ABSENT, rc.5's `source` no-ops, and no demo windows open.
    if os.environ.get("HAMNIX_DE_SELFTEST") == "1":
        _add_etc_file(f, "rc.5.selftest", subdir="rc.d")
    # Declarative service definitions discovered by PID-1's supervisor.
    _add_etc_file(f, "hamde.svc", subdir="services.d")
    _add_etc_file(f, "hamuid.svc", subdir="services.d")
    _add_etc_file(f, "hamnotify-welcome.svc", subdir="services.d")
    # Per-session DE rc bodies (user + hostowner-elevated).
    _add_etc_file(f, "rc.de-user")
    _add_etc_file(f, "rc.de-hostowner")
    # Linux-namespace Wayland-client launcher (Applications ->
    # "Linux Namespace" -> "Wayland Terminal"). Sourced by
    # /bin/hamsh from hamUId's daemon_launch_wayland_ns().
    _add_etc_file(f, "rc.de-wayland")
    # Launcher layout.
    _add_etc_file(f, "desktop.icons")
    _add_etc_file(f, "panel.conf")
    # DATA-DRIVEN Applications menu: one .desktop per app under
    # /etc/hamde/apps. The scene panel scans this dir at startup, so
    # adding an app is dropping a file here — no code edit. Ship every
    # entry the tree carries.
    apps_dir = ETC_DIR / "hamde" / "apps"
    if apps_dir.is_dir():
        for entry in sorted(apps_dir.glob("*.desktop")):
            f.append((entry, f"etc/hamde/apps/{entry.name}"))
    return f


# ---- hamnix-hamaudiobook — the FIRST repo-ONLY, NOT-preinstalled app ------
# This package establishes the "installs from 255.one, absent from the base
# image" pattern the user asked for. Unlike every DE app above (which rides the
# hamnix-desktop-apps metapackage that hamnix-base depends on), this spec is
# DELIBERATELY excluded from the hamnix-base dependency closure (see
# build_hamnix_base()'s leaf_names) so a fresh install does NOT carry it — it is
# reachable ONLY via `hpm install hamnix-hamaudiobook` or the Software app. Its
# payload carries the binary, its .desktop launcher (staged into
# /etc/hamde/apps so INSTALLING the package adds the Applications entry — the
# base etc/hamde/apps dir never contains it), and a sample book so the default
# launch plays out of the box.

HAMAUDIOBOOK_PKG = "hamnix-hamaudiobook"


def _files_hamaudiobook() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "hamaudiobook")
    # Launcher lives in etc/hamde/apps-optional/ (NOT etc/hamde/apps/, which the
    # base hamnix-desktop-config package globs wholesale) and is staged into the
    # live /etc/hamde/apps ONLY when this package is installed.
    f.append((ETC_DIR / "hamde" / "apps-optional" / "hamaudiobook.desktop",
              "etc/hamde/apps/hamaudiobook.desktop"))
    # A royalty-free (CC0) sample book so a bare `hamaudiobook` launch plays and
    # exercises the MP3 decoder + HDA sink end-to-end (default book path is
    # /usr/share/sounds/test.mp3). Reuses the deterministic test fixture.
    mp3 = HERE / "tests" / "fixtures" / "sounds" / "test.mp3"
    f.append((mp3, "usr/share/sounds/test.mp3"))
    return f


# ---- hamnix-hampaint — the raster drawing app, ALSO repo-ONLY -------------
# HamPaint is the MS-Paint / Tux-Paint equivalent: a native raster editor with a
# canvas, tools (pencil/eraser/line/rect/filled-rect/ellipse/flood-fill), a
# brush-size control, a colour palette, Clear (new) and save-as-PNG. Same
# repo-ONLY pattern as the audiobook app — BUILT + published in the main channel
# (installable via hpm / the Software app), but excluded from the hamnix-base
# closure below so a fresh install does NOT carry it. Its payload is the binary +
# its .desktop launcher (staged into /etc/hamde/apps ONLY when installed).

HAMPAINT_PKG = "hamnix-hampaint"


def _files_hampaint() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "hampaint")
    # Launcher lives in etc/hamde/apps-optional/ (NOT etc/hamde/apps/, which the
    # base hamnix-desktop-config package globs wholesale) and is staged into the
    # live /etc/hamde/apps ONLY when this package is installed.
    f.append((ETC_DIR / "hamde" / "apps-optional" / "hampaint.desktop",
              "etc/hamde/apps/hampaint.desktop"))
    return f


# ---- hamnix-hamangrybirds — repo-ONLY, NOT-preinstalled game --------------
# Follows the hamnix-hamaudiobook pattern exactly: BUILT + published in the main
# channel (installable via `hpm install hamnix-hamangrybirds` or the Software
# app), but NOT named by any metapackage's depends AND excluded from the
# hamnix-base closure below, so it never lands in the pre-installed base image.
# Its .desktop lives in etc/hamde/apps-optional/ and is staged into the live
# /etc/hamde/apps ONLY when this package is installed (the base
# hamnix-desktop-config package globs etc/hamde/apps wholesale, so keeping the
# launcher OUT of apps/ until install is what keeps it off a bare desktop).

# ---- hamnix-hamclock — the clock / calendar / timer utility, repo-ONLY -----
# HamClock is a small desktop time utility: a large 7-segment digital HH:MM:SS
# read-out plus an analog clock face (clock view), a real month calendar with
# today highlighted and prev/next month paging (calendar view), and a start /
# stop / reset stopwatch (timer view). Same repo-ONLY pattern as
# the audiobook app / HamPaint — BUILT + published in the main channel
# (installable via hpm / the Software app), but excluded from the hamnix-base
# closure below so a fresh install does NOT carry it. Its payload is the binary +
# its .desktop launcher (staged into /etc/hamde/apps ONLY when installed).

HAMCLOCK_PKG = "hamnix-hamclock"


def _files_hamclock() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "hamclock")
    # Launcher lives in etc/hamde/apps-optional/ (NOT etc/hamde/apps/, which the
    # base hamnix-desktop-config package globs wholesale) and is staged into the
    # live /etc/hamde/apps ONLY when this package is installed.
    f.append((ETC_DIR / "hamde" / "apps-optional" / "hamclock.desktop",
              "etc/hamde/apps/hamclock.desktop"))
    return f


HAMMARK_PKG = "hamnix-hammark"


def _files_hammark() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "hammark")
    # Launcher lives in etc/hamde/apps-optional/ (NOT etc/hamde/apps/, which the
    # base hamnix-desktop-config package globs wholesale) and is staged into the
    # live /etc/hamde/apps ONLY when this package is installed.
    f.append((ETC_DIR / "hamde" / "apps-optional" / "hammark.desktop",
              "etc/hamde/apps/hammark.desktop"))
    return f


# The repo-ONLY unit converter. Same pattern: built + published in the main
# channel but kept out of the hamnix-base closure below, so `hpm install
# hamnix-hamconvert` / the Software app is the only way to get it. Eight
# categories (Length / Mass / Temperature / Volume / Area / Time / Data / Speed)
# with exact conversion factors and affine temperature. Depends only on the
# compositor (scene DE).
HAMCONVERT_PKG = "hamnix-hamconvert"


def _files_hamconvert() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "hamconvert")
    # Launcher lives in etc/hamde/apps-optional/ (NOT etc/hamde/apps/, which the
    # base hamnix-desktop-config package globs wholesale) and is staged into the
    # live /etc/hamde/apps ONLY when this package is installed.
    f.append((ETC_DIR / "hamde" / "apps-optional" / "hamconvert.desktop",
              "etc/hamde/apps/hamconvert.desktop"))
    return f


# The repo-ONLY EXPRESSION calculator. Same pattern: built + published in the
# main channel but kept out of the hamnix-base closure below, so `hpm install
# hamnix-hammath` / the Software app is the only way to get it. Unlike the
# pre-installed immediate calculator (hamnix-hamcalc), HamMath builds a whole
# expression on the LCD and evaluates it with correct operator precedence,
# parentheses and unary minus (2+3*4 = 14, (2+3)*4 = 20). Depends only on the
# compositor (scene DE).
HAMMATH_PKG = "hamnix-hammath"


def _files_hammath() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "hammath")
    # Launcher lives in etc/hamde/apps-optional/ (NOT etc/hamde/apps/, which the
    # base hamnix-desktop-config package globs wholesale) and is staged into the
    # live /etc/hamde/apps ONLY when this package is installed.
    f.append((ETC_DIR / "hamde" / "apps-optional" / "hammath.desktop",
              "etc/hamde/apps/hammath.desktop"))
    return f


HAMANGRYBIRDS_PKG = "hamnix-hamangrybirds"


def _files_hamangrybirds() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "hamangrybirds")
    f.append((ETC_DIR / "hamde" / "apps-optional" / "hamangrybirds.desktop",
              "etc/hamde/apps/hamangrybirds.desktop"))
    return f


# ---------------------------------------------------------------------
# Package spec table — the source of truth.
# ---------------------------------------------------------------------
#
# Each entry: {name, files_fn, depends, conflicts, provides, target,
# description}. files_fn returns the (src, target_rel) tuples.
# Packages with non-trivial layout (bootloader SLIM mode, linux-debian
# usrmerge) are handled by build_*() specials further below.

PACKAGE_SPECS: list[dict] = [
    {
        "name": "hamnix-init",
        "files_fn": _files_init,
        "depends": [],
        "description": "Hamnix init (PID 1 shim + /etc/rc.boot + identity)",
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-hamsh",
        "files_fn": _files_hamsh,
        "depends": ["hamnix-init>=1"],
        "description": "Hamnix shell — /bin/hamsh + motd/banner",
        "target": "#hamnix-system",
    },
    # hamnix-coreutils is now a METAPACKAGE: zero files, depends on
    # every per-command hamnix-<cmd> package. The per-command leaf
    # specs are spliced in below via _cmd_specs() (after this literal
    # list is defined), and this entry's depends is populated to name
    # all of them. Anything that pulled `hamnix-coreutils` before the
    # split still gets the full command set transitively.
    {
        "name": "hamnix-coreutils",
        "files_fn": lambda: [],
        # depends filled in below from COREUTILS_BINS.
        "depends": ["hamnix-hamsh>=1"]
                   + [f"{_cmd_pkg_name(s)}>={PKG_VERSION}"
                      for s in COREUTILS_BINS],
        "description": ("Hamnix core userland metapackage — pulls in "
                        "every per-command package (cat/ls/echo/ps/...)"),
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-net",
        "files_fn": _files_net,
        "depends": ["hamnix-hamsh>=1"],
        "description": "Hamnix networking userland — ifconfig, ping, route, httpd",
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-svc-sshd",
        "files_fn": _files_svc_sshd,
        "depends": ["hamnix-net>=1"],
        "description": "Hamnix in-tree SSH-2 server (sshd + svc definition)",
        "target": "#hamnix-system",
    },
    {
        "name": "hpm",
        "files_fn": _files_hpm,
        "depends": ["hamnix-net>=1"],
        "description": "Hamnix package manager (hpm)",
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-fs-ext4",
        "files_fn": _files_fs_ext4,
        "depends": ["hamnix-hamsh>=1"],
        "description": "Hamnix ext4 toolchain — mkfs_ext4 + install_file_to_slot",
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-fs-fat",
        "files_fn": _files_fs_fat,
        "depends": ["hamnix-hamsh>=1"],
        "description": "Hamnix FAT toolchain — mkfs_fat",
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-drivers-net-e1000e",
        "files_fn": _files_drv_e1000e,
        "depends": ["hamnix-init>=1"],
        "description": "Intel e1000e Ethernet driver (.ko)",
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-drivers-block-ahci",
        "files_fn": _files_drv_ahci,
        "depends": ["hamnix-init>=1"],
        "description": "AHCI SATA block stack (ahci + libata + scsi_mod + ...)",
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-drivers-block-nvme",
        "files_fn": _files_drv_nvme,
        "depends": ["hamnix-init>=1"],
        "description": "NVMe block driver (nvme + nvme-core)",
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-drivers-usb-xhci",
        "files_fn": _files_drv_xhci,
        "depends": ["hamnix-init>=1"],
        "description": "USB xHCI host controller stack (xhci_pci + xhci_hcd + usbcore)",
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-drivers-snd-hda",
        "files_fn": _files_drv_snd_hda,
        "depends": ["hamnix-init>=1"],
        "description": "Intel HDA audio stack (snd_hda_intel + ALSA core)",
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-installer-tools",
        "files_fn": _files_installer_tools,
        "depends": ["hamnix-fs-ext4>=1", "hamnix-fs-fat>=1"],
        "description": "Hamnix installer tools — partitioner + dd_blk",
        "target": "#hamnix-system",
    },
    # ---- the scene-file Desktop Environment -------------------------
    # GRANULAR (#115): hamnix-desktop-core stages the compositor/panel/
    # session substrate; one hamnix-<app> package per application stages
    # that app (spliced in below via _desktop_app_specs()); hamnix-desktop-
    # apps is a METAPACKAGE depending on every app package; hamnix-desktop-
    # config stages the autostart/config files; hamnix-desktop is the top
    # metapackage that pulls core + apps + config + shell. Before this,
    # `hpm install hamnix-base` yielded a booting CLI system with NO
    # desktop at all; before the granular split every app lived in one
    # bundled hamnix-desktop-apps package.
    {
        "name": "hamnix-desktop-core",
        "files_fn": _files_desktop_core,
        "depends": ["hamnix-hamsh>=1"],
        "description": ("Hamnix Desktop Environment CORE — compositor / "
                        "window-system daemon (hamUId), session manager, "
                        "panel, menus, tray, OSD, notifications, lock "
                        "(no apps)"),
        "target": "#hamnix-system",
    },
    # hamnix-desktop-apps is now a METAPACKAGE: zero files, depends on
    # every per-app hamnix-<app> package (filled in below from
    # DESKTOP_APP_PACKAGES). Anything that pulled the old bundled
    # hamnix-desktop-apps still gets the full app set transitively.
    {
        "name": "hamnix-desktop-apps",
        "files_fn": lambda: [],
        "depends": [f"hamnix-desktop-core>={PKG_VERSION}"]
                   + [f"{d['name']}>={PKG_VERSION}"
                      for d in DESKTOP_APP_PACKAGES],
        "description": ("Hamnix desktop applications metapackage — pulls "
                        "in every per-app package (ham2048/hamterm/"
                        "hamfiles/hamcalc/hamedit/hammon/hamview/"
                        "hambrowse/haminbox/hamsettings/...)"),
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-desktop-config",
        "files_fn": _files_desktop_config,
        "depends": ["hamnix-init>=1"],
        "description": ("Hamnix Desktop Environment autostart + config "
                        "(rc.d/rc.5 + services.d/*.svc + rc.de-* + "
                        "desktop.icons + panel.conf)"),
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-desktop",
        "files_fn": lambda: [],
        "depends": ["hamnix-hamsh>=1",
                    f"hamnix-desktop-core>={PKG_VERSION}",
                    f"hamnix-desktop-apps>={PKG_VERSION}",
                    f"hamnix-desktop-config>={PKG_VERSION}"],
        "description": ("Hamnix desktop metapackage — the scene-file DE "
                        "(core + apps + autostart config + shell)"),
        "target": "#hamnix-system",
    },
]

# Splice in one leaf package per DE application (hamnix-ham2048,
# hamnix-hamterm, ...). Generated from DESKTOP_APP_PACKAGES so the table
# stays maintainable. Each depends on hamnix-desktop-core.
PACKAGE_SPECS.extend(_desktop_app_specs())

# Splice in one leaf package per command. Generated programmatically
# from COREUTILS_BINS so the table stays maintainable (no hand-written
# 80-odd dict literals). Each leaf is `hamnix-<cmd>` (underscores→
# hyphens), stages just that one binary, and depends only on the init
# runtime. The hamnix-coreutils metapackage above already names them
# all in its depends.
PACKAGE_SPECS.extend(_cmd_specs())

# The repo-ONLY audiobook app. Appended to PACKAGE_SPECS so it is BUILT and
# published in the main channel (installable via hpm / the Software app), but it
# is NOT named by any metapackage's depends AND is explicitly excluded from the
# hamnix-base closure below, so it never lands in the pre-installed base image.
# Depends pull the compositor + HDA audio stack so `hpm install
# hamnix-hamaudiobook` yields a runnable app on a bare base.
PACKAGE_SPECS.append({
    "name": HAMAUDIOBOOK_PKG,
    "files_fn": _files_hamaudiobook,
    "depends": [f"hamnix-desktop-core>={PKG_VERSION}",
                f"hamnix-drivers-snd-hda>={PKG_VERSION}"],
    "description": ("Hamnix Audiobook player — MP3/WAV playback with "
                    "save/resume position per book + sleep timer (night "
                    "mode) + skip +-30s. Repo-only: install from 255.one, "
                    "not pre-installed."),
    "target": "#hamnix-system",
})

# The repo-ONLY Angry-Birds-style slingshot physics game. Same repo-only shape
# as hamnix-hamaudiobook: BUILT + published in the main channel but NOT named by
# any metapackage's depends AND excluded from the hamnix-base closure below, so
# it ships ONLY via 255.one / `hpm install`. Depends just the compositor so the
# window opens on a bare base.
PACKAGE_SPECS.append({
    "name": HAMANGRYBIRDS_PKG,
    "files_fn": _files_hamangrybirds,
    "depends": [f"hamnix-desktop-core>={PKG_VERSION}"],
    "description": ("Ham Angry Birds — slingshot physics game: gravity-arc "
                    "projectile, destructible wood/stone towers + pig "
                    "targets, aim by keys or on-screen controls, score, 3 "
                    "levels, win/lose/restart. Repo-only: install from "
                    "255.one, not pre-installed."),
    "target": "#hamnix-system",
})


# The repo-ONLY raster drawing app. Same pattern as the audiobook app: built +
# published in the main channel but kept out of the hamnix-base closure below, so
# `hpm install hamnix-hampaint` / the Software app is the only way to get it.
# Depends only on the compositor (scene-file DE) — no extra hardware stack.
PACKAGE_SPECS.append({
    "name": HAMPAINT_PKG,
    "files_fn": _files_hampaint,
    "depends": [f"hamnix-desktop-core>={PKG_VERSION}"],
    "description": ("HamPaint — Hamnix raster drawing app (MS-Paint / Tux-Paint "
                    "style): a canvas you paint with the mouse using pencil, "
                    "eraser, line, rectangle, filled-rectangle, ellipse and "
                    "flood-fill tools, a small/medium/large brush, a colour "
                    "palette, Clear/new, and save-as-PNG. Repo-only: install "
                    "from 255.one, not pre-installed."),
    "target": "#hamnix-system",
})


# The repo-ONLY clock / calendar / timer utility. Same pattern as the office
# apps: built + published in the main channel but kept out of the hamnix-base
# closure below, so `hpm install hamnix-hamclock` / the Software app is the only
# way to get it. Depends only on the compositor (scene-file DE).
PACKAGE_SPECS.append({
    "name": HAMCLOCK_PKG,
    "files_fn": _files_hamclock,
    "depends": [f"hamnix-desktop-core>={PKG_VERSION}"],
    "description": ("HamClock — Hamnix clock / calendar / timer utility: a large "
                    "7-segment digital HH:MM:SS read-out plus an analog clock "
                    "face, a month calendar with today highlighted and "
                    "prev/next month paging, and a start/stop/reset stopwatch. "
                    "Reads the wall clock from /proc/realtime. Repo-only: "
                    "install from 255.one, not pre-installed."),
    "target": "#hamnix-system",
})


# The repo-ONLY Markdown document viewer. Same pattern: built + published in the
# main channel but kept out of the hamnix-base closure below, so `hpm install
# hamnix-hammark` / the Software app is the only way to get it. Reads the OS's
# own on-device .md docs as a formatted, scrollable page. Depends only on the
# compositor (v2-blit DE).
PACKAGE_SPECS.append({
    "name": HAMMARK_PKG,
    "files_fn": _files_hammark,
    "depends": [f"hamnix-desktop-core>={PKG_VERSION}"],
    "description": ("HamMark — Hamnix Markdown document viewer: parses a useful "
                    "CommonMark subset (ATX headings, bold / italic / inline "
                    "code, links, fenced code blocks, unordered + ordered "
                    "lists, blockquotes, horizontal rules) and lays it out as a "
                    "scrollable formatted page — larger headings, wrapped "
                    "paragraphs, a monospace code slab, a blockquote accent bar "
                    "and a scrollbar. Arrow / PageUp-Down / mouse-wheel scroll. "
                    "Repo-only: install from 255.one, not pre-installed."),
    "target": "#hamnix-system",
})


# The repo-ONLY unit converter. Same pattern: built + published in the main
# channel but kept out of the hamnix-base closure below. Depends only on the
# compositor (scene DE).
PACKAGE_SPECS.append({
    "name": HAMCONVERT_PKG,
    "files_fn": _files_hamconvert,
    "depends": [f"hamnix-desktop-core>={PKG_VERSION}"],
    "description": ("HamConvert — Hamnix unit converter: eight categories "
                    "(Length, Mass, Temperature, Volume, Area, Time, Data, "
                    "Speed) with a category sidebar, FROM/TO unit lists, a live "
                    "result and a quick 1-to-many table. Exact conversion "
                    "factors, affine temperature (Celsius / Fahrenheit / "
                    "Kelvin) and decimal-SI data units (KB = 1000 bytes). "
                    "Repo-only: install from 255.one, not pre-installed."),
    "target": "#hamnix-system",
})


# The repo-ONLY expression calculator. Same pattern: built + published in the
# main channel but kept out of the hamnix-base closure below. Depends only on
# the compositor (scene DE).
PACKAGE_SPECS.append({
    "name": HAMMATH_PKG,
    "files_fn": _files_hammath,
    "depends": [f"hamnix-desktop-core>={PKG_VERSION}"],
    "description": ("HamMath — Hamnix expression calculator: build a whole "
                    "arithmetic expression on the LCD (2+3*4, (2+3)*4, -(3+2)) "
                    "and evaluate it with correct operator PRECEDENCE, "
                    "PARENTHESES, unary minus and decimals via a recursive-"
                    "descent, fixed-point (no-FPU) evaluator. A 5x4 keypad with "
                    "digits, + - * /, parentheses, backspace and =. Unlike the "
                    "pre-installed immediate calculator, it honours precedence. "
                    "Repo-only: install from 255.one, not pre-installed."),
    "target": "#hamnix-system",
})


# ---------------------------------------------------------------------
# Generic spec-driven package builder
# ---------------------------------------------------------------------

def _build_spec(spec: dict) -> dict | None:
    """Build the tarball for a PACKAGE_SPECS entry.

    Returns the index.json entry dict, or None if the package was
    skipped (no files staged AND it's not a metapackage).
    """
    pkg_name = spec["name"]
    pkg_dirname = f"{pkg_name}-{PKG_VERSION}"
    staging = _stage_dir(PACKAGES_OUT / "_stage" / pkg_dirname)
    files_root = staging / "files"
    files_root.mkdir()

    total_bytes = 0
    n_files = 0
    skipped: list[str] = []

    file_map = spec["files_fn"]()
    for src, rel in file_map:
        if not src.is_file():
            skipped.append(str(src.relative_to(HERE)) if src.is_relative_to(HERE) else str(src))
            continue
        total_bytes += _copy_file(src, files_root / rel)
        n_files += 1

    if skipped:
        _say(f"{pkg_name}: skipped {len(skipped)} missing source(s) "
             f"(first 3: {', '.join(skipped[:3])}"
             f"{'…' if len(skipped) > 3 else ''})")

    target = spec.get("target", "#hamnix-system")
    description = spec["description"]

    # PKGINFO assembly.
    pkginfo: dict[str, str] = {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "description": description,
        "target": target,
        "maintainer": "HamnixOS",
        "license": "ISC",
        "homepage": "https://255.one/",
    }
    if spec.get("depends"):
        # PKGINFO depends: comma-separated string per docs/packages.md.
        pkginfo["depends"] = ", ".join(spec["depends"])
    if spec.get("conflicts"):
        pkginfo["conflicts"] = ", ".join(spec["conflicts"])
    if spec.get("provides"):
        pkginfo["provides"] = ", ".join(spec["provides"])

    _write_pkginfo(staging, pkginfo)

    out_tar = PACKAGES_OUT / "main" / "packages" / f"{pkg_dirname}.tar.gz"
    sha, size = _tar_gz(staging, out_tar)
    _say(f"built {out_tar.name}: {n_files} files, "
         f"{total_bytes} src bytes, {size} tar bytes, sha={sha[:16]}…")

    entry: dict = {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "channel": "main",
        "url": f"packages/{pkg_dirname}.tar.gz",
        "sha256": sha,
        "size": size,
        "description": description,
        "depends": list(spec.get("depends", [])),
        "target": target,
    }
    if spec.get("conflicts"):
        entry["conflicts"] = list(spec["conflicts"])
    if spec.get("provides"):
        entry["provides"] = list(spec["provides"])
    return entry


# ---------------------------------------------------------------------
# hamnix-base — metapackage. Zero files; depends on every component.
# ---------------------------------------------------------------------

def build_hamnix_base() -> dict:
    pkg_name = "hamnix-base"
    pkg_dirname = f"{pkg_name}-{PKG_VERSION}"
    staging = _stage_dir(PACKAGES_OUT / "_stage" / pkg_dirname)
    files_root = staging / "files"
    files_root.mkdir()

    # Metapackage = `hamnix-base` pulls in every COMPONENT package via
    # depends; hpm's BFS solver pulls the rest transitively. We depend
    # on the hamnix-coreutils metapackage (which fans out to all ~83
    # per-command hamnix-<cmd> leaves) rather than naming every leaf
    # directly — that keeps hamnix-base's depends list to the dozen-ish
    # top-level components and avoids a 100-entry depends string while
    # still resolving the full closure.
    # hamnix-bootloader is also pulled in so a `hpm install hamnix-base`
    # against an ISO mini-repo gets the full OS shape on disk; the
    # installer copies BOOTX64.EFI separately because the ESP isn't a
    # Hamnix-file-server target.
    # Exclude the per-command coreutils leaves (reached via the
    # hamnix-coreutils metapackage) AND the per-app DE leaves + the DE
    # core (reached via the hamnix-desktop metapackage) so hamnix-base's
    # direct depends stays the dozen-ish top-level components instead of
    # ballooning with every leaf. The closure still resolves them all.
    leaf_names = {_cmd_pkg_name(s) for s in COREUTILS_BINS}
    leaf_names |= DESKTOP_APP_PKG_NAMES
    leaf_names.add("hamnix-desktop-core")
    # The repo-only audiobook app must NOT be pre-installed: keep it out of the
    # base closure so it ships ONLY via 255.one / `hpm install`.
    leaf_names.add(HAMAUDIOBOOK_PKG)
    # Likewise the repo-only Angry Birds game — 255.one / `hpm install` only.
    leaf_names.add(HAMANGRYBIRDS_PKG)
    # The repo-only raster drawing app is likewise NOT pre-installed.
    leaf_names.add(HAMPAINT_PKG)
    # NOTE: the OFFICE SUITE (hamnix-hamwrite / -hamsheet / -hamslides) is NOT
    # excluded here any more — it is now part of DESKTOP_APP_PKG_NAMES above, so
    # it is reached (and PRE-INSTALLED) through hamnix-desktop-apps.
    # The repo-only clock / calendar / timer utility is NOT pre-installed.
    leaf_names.add(HAMCLOCK_PKG)
    # The repo-only Markdown viewer is likewise NOT pre-installed.
    leaf_names.add(HAMMARK_PKG)
    # The repo-only unit converter is likewise NOT pre-installed.
    leaf_names.add(HAMCONVERT_PKG)
    # The repo-only expression calculator is likewise NOT pre-installed.
    leaf_names.add(HAMMATH_PKG)
    depends = [f"{s['name']}>={PKG_VERSION}" for s in PACKAGE_SPECS
               if s["name"] not in leaf_names]
    depends.append(f"hamnix-bootloader>={PKG_VERSION}")

    description = ("Hamnix base — metapackage pulling in every "
                   "component (init/hamsh/coreutils/net/sshd/hpm/fs/"
                   "drivers/installer/bootloader)")

    _write_pkginfo(staging, {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "description": description,
        "target": "#hamnix-system",
        "depends": ", ".join(depends),
        "maintainer": "HamnixOS",
        "license": "ISC",
        "homepage": "https://255.one/",
    })

    out_tar = PACKAGES_OUT / "main" / "packages" / f"{pkg_dirname}.tar.gz"
    sha, size = _tar_gz(staging, out_tar)
    _say(f"built {out_tar.name}: METAPACKAGE (0 files, "
         f"{len(depends)} depends), {size} tar bytes, sha={sha[:16]}…")
    return {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "channel": "main",
        "url": f"packages/{pkg_dirname}.tar.gz",
        "sha256": sha,
        "size": size,
        "description": description,
        "depends": depends,
        "target": "#hamnix-system",
    }


# ---------------------------------------------------------------------
# hamnix-bootloader — BOOTX64.EFI + kernel ELF. target=#esp.
# ---------------------------------------------------------------------

def build_hamnix_bootloader() -> dict:
    pkg_name = "hamnix-bootloader"
    pkg_dirname = f"{pkg_name}-{PKG_VERSION}"
    staging = _stage_dir(PACKAGES_OUT / "_stage" / pkg_dirname)
    files_root = staging / "files"
    files_root.mkdir()
    total_bytes = 0
    n_files = 0

    slim_early = os.environ.get("HAMNIX_BOOTLOADER_SLIM") == "1"
    if not slim_early:
        if not KERNEL_ELF.is_file():
            raise SystemExit(
                f"[build_packages] {KERNEL_ELF.relative_to(HERE)} missing — "
                f"run scripts/build_iso.sh first to produce the kernel ELF")
        if not EFI_STUB.is_file():
            raise SystemExit(
                f"[build_packages] {EFI_STUB.relative_to(HERE)} missing — "
                f"run scripts/build_iso.sh first to produce the EFI stub")

    # The ISO mini-repo emits a metadata-only bootloader package (the
    # full BOOTX64.EFI + kernel.elf payload lives in the live ISO's
    # source ESP partition and is copied onto the target ESP via dd_blk
    # by install.hamsh). On the upstream HamnixOS/packages build the
    # full payload IS embedded.
    slim = os.environ.get("HAMNIX_BOOTLOADER_SLIM") == "1"
    if not slim:
        total_bytes += _copy_file(EFI_STUB, files_root / "BOOTX64.EFI",
                                  mode=0o755)
        n_files += 1
        total_bytes += _copy_file(KERNEL_ELF,
                                  files_root / "hamnix-kernel.elf",
                                  mode=0o755)
        n_files += 1
    else:
        _say("hamnix-bootloader: HAMNIX_BOOTLOADER_SLIM=1 — emitting "
             "metadata-only package (no files/)")
        (files_root / "README").write_text(
            "ISO mini-repo slim build. BOOTX64.EFI + kernel.elf live in "
            "the live ISO's source ESP partition and are copied onto "
            "the target ESP by /etc/install.hamsh via dd_blk. The full "
            "payload is published at https://255.one/.\n",
            encoding="ascii")
        n_files += 1

    description = ("Hamnix UEFI bootloader stub + kernel ELF "
                   "(installs onto the ESP)")
    _write_pkginfo(staging, {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "description": description,
        "target": "#esp",
        "depends": "hamnix-init>=1",
        "maintainer": "HamnixOS",
        "license": "ISC",
        "homepage": "https://255.one/",
    })
    out_tar = PACKAGES_OUT / "main" / "packages" / f"{pkg_dirname}.tar.gz"
    sha, size = _tar_gz(staging, out_tar)
    _say(f"built {out_tar.name}: {n_files} files, "
         f"{total_bytes} src bytes, {size} tar bytes, sha={sha[:16]}…")
    return {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "channel": "main",
        "url": f"packages/{pkg_dirname}.tar.gz",
        "sha256": sha,
        "size": size,
        "description": description,
        "depends": ["hamnix-init>=1"],
        "target": "#esp",
    }


# ---------------------------------------------------------------------
# linux-debian-12 — Debian rootfs (unchanged from v1).
# ---------------------------------------------------------------------

LINUX_DEBIAN_FILES = [
    "usr/bin/apt", "usr/bin/apt-get", "usr/bin/apt-cache",
    "usr/bin/apt-config", "usr/bin/apt-mark", "usr/bin/dpkg",
    "usr/bin/dpkg-deb", "usr/bin/dpkg-query", "usr/bin/dpkg-split",
    "usr/lib64/ld-linux-x86-64.so.2",
    "usr/lib/x86_64-linux-gnu/libc.so.6",
    "usr/lib/x86_64-linux-gnu/libm.so.6",
    "usr/lib/x86_64-linux-gnu/libpthread.so.0",
    "usr/lib/x86_64-linux-gnu/libdl.so.2",
    "usr/lib/x86_64-linux-gnu/libresolv.so.2",
    "usr/lib/x86_64-linux-gnu/librt.so.1",
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
    "usr/lib/x86_64-linux-gnu/libmd.so.0",
    "usr/lib/x86_64-linux-gnu/libmd.so.0.1.0",
    "usr/lib/x86_64-linux-gnu/libselinux.so.1",
    "usr/lib/x86_64-linux-gnu/libpcre2-8.so.0",
    "usr/lib/x86_64-linux-gnu/libpcre2-8.so.0.14.0",
    "etc/debian_version", "etc/os-release", "etc/passwd", "etc/group",
    "etc/hostname", "etc/apt/sources.list", "etc/apt/apt.conf",
    "var/lib/dpkg/status", "var/lib/dpkg/available",
    "var/lib/dpkg/diversions", "var/lib/dpkg/statoverride",
    "usr/share/keyrings/debian-archive-keyring.gpg",
    "etc/apt/trusted.gpg.d/debian-archive-keyring.gpg",
]

LINUX_DEBIAN_USRMERGE = {
    "usr/bin/":   "bin/",
    "usr/sbin/":  "sbin/",
    "usr/lib/":   "lib/",
    "usr/lib64/": "lib64/",
}


def build_linux_debian_12() -> dict | None:
    pkg_name = "linux-debian-12"
    pkg_dirname = f"{pkg_name}-{PKG_VERSION}"
    staging = _stage_dir(PACKAGES_OUT / "_stage" / pkg_dirname)
    files_root = staging / "files"
    files_root.mkdir()
    total_bytes = 0
    n_files = 0

    slim = os.environ.get("HAMNIX_LINUX_DEBIAN_SLIM") == "1"

    if not DEBIAN_MINBASE.is_dir() and not slim:
        _say(f"WARN: {DEBIAN_MINBASE.relative_to(HERE)} absent — "
             f"linux-debian-12 will be SKIPPED. Run "
             f"tests/distros/debian-minbase/BUILD.sh first.")
        return None

    if slim:
        _say("linux-debian-12: HAMNIX_LINUX_DEBIAN_SLIM=1 — emitting "
             "metadata-only package (no files/)")
        (files_root / "README").write_text(
            "ISO mini-repo slim build of linux-debian-12. The real "
            "Debian closure lives in the live ISO's source rootfs "
            "partition and is copied onto the target rootfs by "
            "/etc/install.hamsh via the manifest installer. The full "
            "payload is at https://255.one/.\n", encoding="ascii")
        (files_root / ".hamnix-roots").write_text("distro    .\n",
                                                  encoding="ascii")
        n_files = 2
    else:
        missing: list[str] = []
        for rel in LINUX_DEBIAN_FILES:
            src = DEBIAN_MINBASE / rel
            if not src.is_file():
                missing.append(rel)
                continue
            try:
                data = src.read_bytes()
            except (OSError, PermissionError) as e:
                missing.append(f"{rel} ({e})")
                continue
            mode = 0o755 if (src.stat().st_mode & 0o111) else 0o644
            dst = files_root / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(data)
            dst.chmod(mode)
            total_bytes += len(data)
            n_files += 1
            for prefix, alias_prefix in LINUX_DEBIAN_USRMERGE.items():
                if rel.startswith(prefix):
                    alias_rel = alias_prefix + rel[len(prefix):]
                    adst = files_root / alias_rel
                    adst.parent.mkdir(parents=True, exist_ok=True)
                    adst.write_bytes(data)
                    adst.chmod(mode)
                    total_bytes += len(data)
                    n_files += 1
                    break
        if missing:
            _say(f"linux-debian-12: skipped {len(missing)} optional files "
                 f"(first 3: {', '.join(missing[:3])}{'…' if len(missing) > 3 else ''})")

        (files_root / ".hamnix-roots").write_text("distro    .\n",
                                                  encoding="ascii")
        n_files += 1

    description = "Debian 12 (bookworm) rootfs for the Linux namespace"
    _write_pkginfo(staging, {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "description": description,
        "target": "#distro",
        "depends": "hamnix-init>=1",
        "provides": "linux-distro",
        "maintainer": "HamnixOS",
        "license": "various (Debian)",
        "homepage": "https://debian.org/",
    })

    out_tar = PACKAGES_OUT / "main" / "packages" / f"{pkg_dirname}.tar.gz"
    sha, size = _tar_gz(staging, out_tar)
    _say(f"built {out_tar.name}: {n_files} files"
         f"{' (SLIM)' if slim else ''}, "
         f"{total_bytes} src bytes, {size} tar bytes, sha={sha[:16]}…")
    return {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "channel": "main",
        "url": f"packages/{pkg_dirname}.tar.gz",
        "sha256": sha,
        "size": size,
        "description": description,
        "depends": ["hamnix-init>=1"],
        "provides": ["linux-distro"],
        "target": "#distro",
    }


# ---------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------

def main() -> int:
    if not BUILD.is_dir():
        raise SystemExit(
            "[build_packages] build/ missing — run scripts/build_iso.sh "
            "first to produce the artifacts this script repackages.")
    PACKAGES_OUT.mkdir(parents=True, exist_ok=True)
    # Channel subdirs: main/ holds every first-party / free package;
    # non-free/ and non-free-firmware/ exist as placeholders so `hpm
    # refresh` against an opt-in enabled channel returns an empty list
    # cleanly (no 404 from GitHub Pages). The contrib channel is
    # reserved (created on-demand when a package needs it).
    main_dir = PACKAGES_OUT / "main"
    main_pkgs = main_dir / "packages"
    main_pkgs.mkdir(parents=True, exist_ok=True)
    (PACKAGES_OUT / "non-free").mkdir(parents=True, exist_ok=True)
    (PACKAGES_OUT / "non-free-firmware").mkdir(parents=True, exist_ok=True)

    # Clean stale outputs (both the old flat shape AND any prior
    # channel-dir build artefacts).
    for old in PACKAGES_OUT.glob("*.tar.gz"):
        old.unlink()
    if (PACKAGES_OUT / "packages").is_dir():
        # Legacy flat layout: remove the bare `packages/` dir if it
        # exists (we now write under main/packages/).
        for old in (PACKAGES_OUT / "packages").glob("*.tar.gz"):
            old.unlink()
    for old in main_pkgs.glob("*.tar.gz"):
        old.unlink()
    for stale in (PACKAGES_OUT / "index.json",
                  main_dir / "index.json",
                  PACKAGES_OUT / "non-free" / "index.json",
                  PACKAGES_OUT / "non-free-firmware" / "index.json"):
        if stale.exists():
            stale.unlink()
        stale_sig = stale.with_name(stale.name + ".sig")
        if stale_sig.exists():
            stale_sig.unlink()

    entries: list[dict] = []

    # Build the component packages first (per PACKAGE_SPECS order).
    for spec in PACKAGE_SPECS:
        entry = _build_spec(spec)
        if entry is not None:
            entries.append(entry)

    # Then the bootloader (target=#esp) and the Debian distro.
    entries.append(build_hamnix_bootloader())
    deb_entry = build_linux_debian_12()
    if deb_entry is not None:
        entries.append(deb_entry)

    # Finally hamnix-base (metapackage). It depends on the others, so
    # the index lists it last for human-eyeball reading order.
    entries.append(build_hamnix_base())

    # Cleanup staging area after a successful build.
    stage_root = PACKAGES_OUT / "_stage"
    if stage_root.is_dir() and os.environ.get("HAMNIX_KEEP_STAGE") != "1":
        shutil.rmtree(stage_root)

    updated = os.environ.get("HAMNIX_PKG_DATE", "2026-05-27")
    main_index = {
        "schema": 1,
        "repo": "HamnixOS/packages",
        "channel": "main",
        "url": "https://255.one/main/",
        "updated": updated,
        "description": ("Hamnix main channel — first-party free "
                        "software (hamnix-base + hamnix-coreutils "
                        "metapackages + one hamnix-<cmd> package per "
                        "command + components + bootloader + "
                        "linux-debian-12)"),
        "packages": entries,
    }
    (main_dir / "index.json").write_text(
        json.dumps(main_index, indent=2,
                   ensure_ascii=False) + "\n", encoding="utf-8")
    _say(f"wrote {main_dir / 'index.json'} "
         f"({len(entries)} package entries)")
    _sign_index(main_dir / "index.json")

    # Empty channel indexes. Each opt-in channel has a stub index so
    # `hpm refresh` returns `0 packages` cleanly when subscribed but
    # the channel has no contents yet. The day a non-free-firmware
    # package lands the build pipeline replaces this stub.
    for ch_name, ch_desc in (
        ("non-free",
         "Hamnix non-free channel — placeholder (no packages yet)"),
        ("non-free-firmware",
         "Hamnix non-free firmware channel — placeholder"),
    ):
        stub = {
            "schema": 1,
            "repo": "HamnixOS/packages",
            "channel": ch_name,
            "url": f"https://255.one/{ch_name}/",
            "updated": updated,
            "description": ch_desc,
            "packages": [],
        }
        (PACKAGES_OUT / ch_name / "index.json").write_text(
            json.dumps(stub, indent=2,
                   ensure_ascii=False) + "\n", encoding="utf-8")
        _say(f"wrote {PACKAGES_OUT / ch_name / 'index.json'} "
             f"(0 package entries — empty channel)")
        _sign_index(PACKAGES_OUT / ch_name / "index.json")

    return 0


if __name__ == "__main__":
    sys.exit(main())
