#!/usr/bin/env python3
"""
scripts/build_initramfs.py — generates a cpio "newc" archive for the
bare-metal Hamnix initramfs and emits it as a .S file of .byte
directives that the kernel image .incbin-includes.

cpio newc layout (per cpio(5)):
  Each entry: 110-byte ASCII header + name + pad-to-4 + data + pad-to-4
  Header fields (each 8 chars of uppercase hex, except magic which is 6):
    magic    "070701"
    ino, mode, uid, gid, nlink, mtime, filesize,
    devmajor, devminor, rdevmajor, rdevminor, namesize, check
  Padding is from the START of the entry; both name and data end
  4-byte aligned.

Final entry: a special "TRAILER!!!" file with size 0 marks end-of-
archive. Linux's init/initramfs.c looks for exactly this string.

Re-run this script after touching the FILES list to regenerate
fs/initramfs_blob.S (which is committed; assembly happens at build
time without re-running this script).
"""

import os
import sys
from pathlib import Path

# Autostub generator. Runs FIRST so any new bundled .ko's mechanical
# UND symbols (__SCK__*, __SCT__*, __tracepoint_*, retpoline thunks,
# ...) get a stub emitted into linux_abi/api_autostubs.ad BEFORE the
# kernel ELF compile step picks that file up. See
# scripts/gen_autostubs.py for the catalog. The generator is a no-op
# (writes nothing) when the file is already up to date, so this is
# cheap even on incremental builds. We tolerate failure (a corrupt
# .ko shouldn't sink the rest of the build), but a fresh checkout
# always has all the .ko's so the success path is the common one.
def _run_gen_autostubs() -> None:
    try:
        import subprocess
        here = Path(__file__).resolve().parent.parent
        gen = here / "scripts" / "gen_autostubs.py"
        if not gen.is_file():
            return
        # Inherit stdout so the build log shows the summary line.
        subprocess.run(
            ["python3", str(gen)],
            cwd=str(here),
            check=False,
        )
    except Exception as _exc:
        print(f"[build_initramfs] gen_autostubs.py failed: {_exc}")


_run_gen_autostubs()

FILES = [
    ("/motd",       b"Welcome to Hamnix from a real cpio initramfs!\n"
                    b"This file came out of a newc-formatted blob.\n"),
    ("/version",    b"Hamnix bare-metal kernel, M16.30 - ELF /init loader\n"),
]

# Classic per-user home subdirectories for the live/default user `live`
# (/etc/passwd: live:x:1:1::/home/live:/bin/hamsh). The cpio is a FLAT name
# table — directories are implicit, materialised by the files inside
# them — so we plant a `.keep` placeholder in each standard home subdir
# (Documents/Downloads/Pictures/Notes). This gives the live user a
# familiar home layout AND sensible default locations for the DE file
# manager / hameditscene file-picker (which defaults to
# /home/live/Documents). New ext4-backed users get the same subdirs from
# useradd's make_home_skel() (`#<name>/Desktop` ...). KISS: an empty
# `.keep` byte stream is enough to make the directory enumerable.
for _home_sub in ("Documents", "Downloads", "Pictures", "Notes"):
    FILES.append((f"/home/live/{_home_sub}/.keep", b""))
# The DESKTOP is now REAL, filesystem-backed: /bin/hamdesktop renders its
# icon grid from the CONTENTS of /home/live/Desktop (parsing `.desktop`
# launcher files for name/exec, and showing plain files/folders as
# file/folder icons), so `ls ~/Desktop` shows the launchers AND a folder
# created from the CLI appears on the desktop via hamdesktop's periodic
# re-scan. Plant the default launcher set from the /etc/skel/Desktop
# template (the single source of truth, also installed for future
# useradd) at /home/live/Desktop/*.desktop. If the template is absent the
# desktop dir is left implicit-empty and hamdesktop falls back to its
# built-in default icon set.
# The install manifests (etc/install/*.manifest) are GENERATED, and
# etc/install/ is gitignored — so regenerate them here, before the etc/
# walker below stages them into the cpio at /etc/install/*. Doing it in
# THIS script (rather than only in build_installer_img.sh) means every
# cpio build carries a manifest set that matches the tree it was built
# from: `install` reads /etc/install/distro.manifest + live.manifest at
# install time, and a stale or missing manifest silently degrades the
# installed system (no Linux namespace, no home skeleton, no man pages).
try:
    import gen_install_manifest as _gim           # same scripts/ dir
    _gim.main()
except Exception as _e:                           # never block a build
    print(f"  [install-manifest] WARN: could not regenerate "
          f"etc/install/*.manifest ({_e})")

_skel_desktop = Path(__file__).resolve().parent.parent / "etc" / "skel" / "Desktop"
_planted_desktop = 0
if _skel_desktop.is_dir():
    for _de in sorted(_skel_desktop.iterdir()):
        if _de.is_file() and _de.name.endswith(".desktop"):
            FILES.append((f"/home/live/Desktop/{_de.name}", _de.read_bytes()))
            _planted_desktop += 1
if _planted_desktop == 0:
    # No template shipped — keep the directory enumerable so hamdesktop can
    # still create folders in it.
    FILES.append(("/home/live/Desktop/.keep", b""))
# A friendly starter note so /home/live/Documents isn't bare on the live
# image (also gives the editor's Open picker something to load).
FILES.append((
    "/home/live/Documents/welcome.txt",
    b"Welcome to Hamnix!\n\n"
    b"This is your Documents folder. Try the text editor (hameditscene):\n"
    b"  Ctrl-O  open a file via the folder browser\n"
    b"  Ctrl-S  save (Save As opens the folder browser to pick a folder)\n"
    b"  Ctrl-W  Save As to a different folder\n",
))

# Default DE wallpaper. user/hamUId.ad's startup path calls
# wallpaper_load_path("/etc/wallpaper.ppm") best-effort; planting a real
# PPM here is what stops the DE booting onto a flat grey backdrop. The
# image is generated fresh per build by scripts/gen_default_wallpaper.py
# (a hand-coded midnight-blue gradient + soft vignette + low ridges) so
# we don't carry a ~900 KiB binary blob in git. Failure to generate is
# tolerated — the DE just falls back to the ROOT_R/G/B solid colour, the
# same behaviour as before this file shipped.
def _build_default_wallpaper_bytes() -> bytes:
    try:
        import sys as _wp_sys
        _wp_scripts_dir = str(Path(__file__).resolve().parent)
        if _wp_scripts_dir not in _wp_sys.path:
            _wp_sys.path.insert(0, _wp_scripts_dir)
        from gen_default_wallpaper import build_default_wallpaper
        return build_default_wallpaper()
    except Exception as _exc:
        print(f"[build_initramfs] gen_default_wallpaper failed: {_exc}")
        return b""


_wp_bytes = _build_default_wallpaper_bytes()
if _wp_bytes:
    FILES.append(("/etc/wallpaper.ppm", _wp_bytes))

# Sample images for the hamview image viewer. On the LIVE/installer medium the
# native userland rides in this cpio (there is no ext4 sysroot), so the sample
# PNG + baseline JPEG that `hamview /share/hamview/test.{png,jpg}` opens — and
# that scripts/test_hamview_png_jpeg.sh decodes + screendumps — must be planted
# here alongside /bin/hamview. (The installed-disk path gets the same files via
# the hamnix-desktop-apps package; see scripts/build_packages.py.)
_hv_fix_dir = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "hamview"
for _hv_img in ("test.png", "test.jpg"):
    _hv_src = _hv_fix_dir / _hv_img
    if _hv_src.is_file():
        FILES.append((f"/share/hamview/{_hv_img}", _hv_src.read_bytes()))
    else:
        print(f"[build_initramfs] WARN: hamview fixture {_hv_src} absent — "
              f"test_hamview_png_jpeg will not find /share/hamview/{_hv_img}")

# Royalty-free (CC0) audio test clip for the hamaudio player. On the LIVE/
# installer medium native userland rides in this cpio (no ext4 sysroot), so
# the clip `hamaudioscene`/`aplay` default to (/usr/share/sounds/test.wav) —
# and that scripts/test_hamaudio_playback.sh streams through the HDA sink —
# must be planted here. (The installed-disk path gets the same file via the
# hamnix-hamaudio package; see scripts/build_packages.py.) ~103 KiB.
_wav_src = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "sounds" / "test.wav"
if _wav_src.is_file():
    FILES.append(("/usr/share/sounds/test.wav", _wav_src.read_bytes()))
else:
    print(f"[build_initramfs] WARN: audio fixture {_wav_src} absent — "
          f"hamaudio has no default clip")

# The same clip as CBR MPEG-1 Layer III, decoded on-device by lib/mp3decode
# (`hamaudioscene /usr/share/sounds/test.mp3`). Generated by
# scripts/gen_test_mp3.py (public-domain / CC0). ~30 KiB.
_mp3_src = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "sounds" / "test.mp3"
if _mp3_src.is_file():
    FILES.append(("/usr/share/sounds/test.mp3", _mp3_src.read_bytes()))

# The DE login/loading jingle (48 kHz WAV) that user/hamdesktop.ad streams to
# the HDA sink (detached `aplay /usr/share/sounds/boot-jingle.wav`) when the
# desktop comes up, plus the longer "Hamnix Music Demo" (MPEG-1 Layer III,
# 128k / 48 kHz) that hamaudioscene DEFAULTS to on a bare launch
# (/usr/share/music/hamnix-music-demo.mp3, track 0 of the bare playlist).
# On the LIVE/installer medium native userland rides in THIS cpio (there is no
# ext4 sysroot yet, and DE apps resolve /usr/share against this boot file
# server), so BOTH assets MUST be planted here — the installed-disk path gets
# them via the hamnix-hamaudio package (scripts/build_packages.py). Without
# them the live desktop had no boot chime (aplay: `cannot open input`, exit 1)
# AND the audio player's default track failed to open ("(unreadable audio)").
_jingle_src = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "sounds" / "boot-jingle.wav"
if _jingle_src.is_file():
    FILES.append(("/usr/share/sounds/boot-jingle.wav", _jingle_src.read_bytes()))
else:
    print(f"[build_initramfs] WARN: jingle {_jingle_src} absent — no boot chime")
_music_src = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "sounds" / "hamnix-music-demo.mp3"
if _music_src.is_file():
    FILES.append(("/usr/share/music/hamnix-music-demo.mp3", _music_src.read_bytes()))
else:
    print(f"[build_initramfs] WARN: music demo {_music_src} absent — "
          f"hamaudioscene default track will not open")

# Royalty-free (CC0) Motion-JPEG test clip for the hamvideo player — same
# rationale as the .wav above: the live/installer cpio must carry the clip
# `hamvideoscene` (and scripts/test_hamvideo_playback.sh) default to at
# /usr/share/videos/test.hmjv. (Installed-disk path gets it via the
# hamnix-hamvideo package.) ~120 KiB. Generated by scripts/gen_test_video.py.
_vid_src = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "videos" / "test.hmjv"
if _vid_src.is_file():
    FILES.append(("/usr/share/videos/test.hmjv", _vid_src.read_bytes()))
else:
    print(f"[build_initramfs] WARN: video fixture {_vid_src} absent — "
          f"hamvideo has no default clip")

# --- PROVENANCE STAMP (always planted) --------------------------------
# /etc/hamnix-build carries "<git-sha12>[-dirty] <build UTC>" as a
# NUL-terminated string. init/main.ad prints it at boot:03 as
#     [boot] image built <sha> <time>
# so ANY serial log — a gate's, a screenshot's, a human's — names the build
# that actually ran. On 2026-07-24 three agents and the orchestrator each
# reported a different answer about whether the office suite shipped, because
# each was looking at a different artifact and none matched what booted. This
# one line makes that mistake impossible to make silently.
#
# fs/initramfs_blob.S is .gitignore'd, so the stamp costs no git churn.
# HAMNIX_BUILD_STAMP overrides it entirely.
#
# REPRODUCIBILITY (2026-07-28). This used to embed datetime.now(), which made
# the cpio — and therefore the kernel ELF that .incbin-s it — differ on every
# single run from identical sources. That one byte-per-second of drift was
# enough to defeat every content-addressed build cache in the tree
# (scripts/_kernel_image.sh saw a new key each time), and 178 CI gates each
# paid a full 101 s kernel compile as a result. The stamp is now a pure
# function of the tree:
#   * clean tree  -> "<sha12> <commit time UTC>"
#   * dirty tree  -> "<sha12>-dirty.<8 hex of the working diff> <commit time>"
# It still names exactly which build booted — better, in fact, because two
# different dirty states now get different stamps instead of merely different
# clocks. SOURCE_DATE_EPOCH is honoured for the timestamp when set.
def _provenance_stamp() -> bytes:
    override = os.environ.get("HAMNIX_BUILD_STAMP")
    if override:
        return override.encode()[:95] + b"\x00"
    import subprocess as _sp
    import datetime as _dt
    import hashlib as _hl
    root = Path(__file__).resolve().parent.parent
    def _git(*a):
        try:
            return _sp.check_output(["git", *a], cwd=str(root),
                                    stderr=_sp.DEVNULL).decode().strip()
        except Exception:
            return ""
    sha = _git("rev-parse", "--short=12", "HEAD") or "nogit"
    if _git("status", "--porcelain", "--untracked-files=no"):
        # Identify WHICH dirty state, deterministically, instead of stamping
        # the wall clock.
        diff = _git("diff", "HEAD") + "\n" + _git("status", "--porcelain",
                                                  "--untracked-files=no")
        sha += "-dirty." + _hl.sha256(diff.encode()).hexdigest()[:8]
    sde = os.environ.get("SOURCE_DATE_EPOCH")
    if sde and sde.isdigit():
        when = _dt.datetime.fromtimestamp(int(sde), _dt.timezone.utc)
    else:
        iso = _git("log", "-1", "--format=%cI")
        try:
            when = _dt.datetime.fromisoformat(iso).astimezone(_dt.timezone.utc)
        except Exception:
            when = _dt.datetime.fromtimestamp(0, _dt.timezone.utc)
    return (sha + " " + when.strftime("%Y-%m-%dT%H:%M:%SZ")).encode()[:95] + b"\x00"


FILES.append(("/etc/hamnix-build", _provenance_stamp()))

# Optional opt-in markers controlled by env vars. Used by per-test
# harness scripts to enable kernel-side smoke tests that would
# otherwise hang/regress unrelated test runs. See
# scripts/test_net_https.sh which sets ENABLE_TLS_SMOKE=1 to plant
# `/etc/tls-test`; init/main.ad gates `https_local_smoke_test()` on
# that file's presence.
if os.environ.get("ENABLE_TLS_SMOKE") == "1":
    FILES.append(("/etc/tls-test", b"1\n"))

# ENABLE_HAMSH_HEARTBEAT=1 plants /etc/hamsh-heartbeat. hamsh's main()
# (user/hamsh.ad) probes for this marker at startup and only then arms the
# periodic "[hamsh-alive] tick=N uptime=Ns" idle-loop heartbeat. That line
# is a dev/CI liveness canary — on a normal shipped boot it would spam the
# interactive serial/console prompt every ~3s, so it is OFF unless this
# marker is present. The three gates that assert on the heartbeat set this:
# scripts/test_hamsh_heartbeat.sh, scripts/test_suspend_resume.sh, and
# scripts/test_installer_boot_heartbeat.sh (via build_installer_img.sh).
if os.environ.get("ENABLE_HAMSH_HEARTBEAT") == "1":
    FILES.append(("/etc/hamsh-heartbeat", b"1\n"))

# ENABLE_SMAP_TEST=1 plants /etc/smap-test. init/main.ad gates
# smap_enforced_test() on this marker — a positive SMAP-active proof that
# does an un-stac'd CPL=0 read of a US=1 user page and asserts it #PF's
# under CR4.SMAP=1. scripts/test_smap_enforced.sh sets it and boots under
# KVM (TCG masks SMAP CPUID so the test would SKIP there).
if os.environ.get("ENABLE_SMAP_TEST") == "1":
    FILES.append(("/etc/smap-test", b"1\n"))

# ENABLE_MM_CORRUPT_TEST=1 plants /etc/mm-corrupt-test. init/main.ad gates
# page_alloc_corrupt_inject_test() (tests/mm_smoke.ad) on this marker. That
# injection deliberately scribbles a free-listed page and proves the buddy
# allocator's _pa_get_next() self-heal catches it — but it is DESTRUCTIVE
# (truncating the order-0 list strands the entries behind the scribbled
# node), so #104 gated it OFF for shipped/installer boots. scripts/
# test_mm_pa_corrupt.sh sets this to keep the self-heal path covered.
if os.environ.get("ENABLE_MM_CORRUPT_TEST") == "1":
    FILES.append(("/etc/mm-corrupt-test", b"1\n"))

# ENABLE_NVME_SELFTEST=1 plants /etc/nvme-selftest. init/main.ad's NVMe
# bring-up (nvme_init) gates its DESTRUCTIVE self-test battery
# (write-smoke/blk-smoke/PRP/multi-queue/health/AER — all WRITE to LBA
# 1/2/4 = the GPT region) on this marker. The nvme self-test scripts
# (test_nvme_write/multiq/health/aer/prp, test_block_layer_write) attach
# a SCRATCH NVMe disk and set ENABLE_NVME_SELFTEST=1 so the destructive
# markers print; the normal boot + the installer/installed NVMe paths
# leave the marker absent so the on-disk partition table is never
# clobbered.
if os.environ.get("ENABLE_NVME_SELFTEST") == "1":
    FILES.append(("/etc/nvme-selftest", b"1\n"))

# Chunked-transfer-encoding decoder smoke. See
# scripts/test_net_https_chunked.sh; the harness sets
# ENABLE_TLS_CHUNKED_SMOKE=1 to plant /etc/tls-chunked-test, and
# init/main.ad's https_chunked_smoke_test gates on that file.
if os.environ.get("ENABLE_TLS_CHUNKED_SMOKE") == "1":
    FILES.append(("/etc/tls-chunked-test", b"1\n"))

# Content-Encoding: gzip wireup smoke. See
# scripts/test_net_https_gzip.sh; the harness sets
# ENABLE_TLS_GZIP_SMOKE=1 to plant /etc/tls-gzip-test, and
# init/main.ad's https_gzip_smoke_test gates on that file. The
# fixture serves a chunked+gzip body and the kernel-side smoke
# verifies the inflated bytes match the expected plaintext.
# The same env var also plants /etc/skip-https-internet-smoke so
# the unconditional https://example.com leg in net_smoke_test
# doesn't fire (the current baseline traps mid-TLS-handshake on
# the AES-256-GCM record, a separate residual that would
# otherwise kill the kernel before reaching the gzip smoke).
if os.environ.get("ENABLE_TLS_GZIP_SMOKE") == "1":
    FILES.append(("/etc/tls-gzip-test", b"1\n"))
    FILES.append(("/etc/skip-https-internet-smoke", b"1\n"))

# Native tar/gzip/gunzip fixture. scripts/test_tar_gzip.sh sets
# ENABLE_TAR_GZIP_FIXTURE=1 to bake a REAL host-gzip-produced .gz (with
# known plaintext) into the cpio at /tests/realgz/. The .gz is produced
# by Python's gzip module over highly compressible text, so zlib emits
# dynamic-Huffman DEFLATE blocks — proving our `gunzip` INFLATE handles
# real Huffman streams, not merely our own stored-block output. The
# matching plaintext is staged alongside so the test can diff against it.
# Loop (file-backed block) device fixture. scripts/test_loop.sh sets
# ENABLE_LOOP_TEST=1 to bake a REAL FAT image FILE into the cpio at
# /tests/loop/disk.img plus the /etc/loop-test marker. init/main.ad's
# loop_e2e_selftest() attaches that image FILE as /dev/blk/loop0, mounts
# FAT off the loop slot, and reads HELLO.TXT back — proving an image file
# can be mounted like a real disk (Linux losetup + mount). The image is
# the very same FAT layout build_diskimg.py bakes into /dev/ram0, so its
# known file HELLO.TXT carries the FAT32_MARKER the self-test asserts.
if os.environ.get("ENABLE_LOOP_TEST") == "1":
    import sys as _loop_sys
    _loop_scripts_dir = str(Path(__file__).resolve().parent)
    if _loop_scripts_dir not in _loop_sys.path:
        _loop_sys.path.insert(0, _loop_scripts_dir)
    import build_diskimg as _diskimg_mod
    FILES.append(("/tests/loop/disk.img", _diskimg_mod.build_image()))
    FILES.append(("/etc/loop-test", b"1\n"))

# ENABLE_ISO9660_TEST=1 (via scripts/test_iso9660.sh) bakes a REAL Rock
# Ridge ISO9660 image FILE into the cpio at /tests/iso9660/test.iso plus
# the /etc/iso9660-test marker. init/main.ad's iso9660_e2e_selftest()
# loop-attaches that .iso as /dev/blk/loop1, parses the Primary Volume
# Descriptor, lists the root, reads a known file byte-exact, resolves a
# Rock Ridge long name, reads a >1-sector file, and resolves a nested
# file — proving the read-only ISO9660 reader (fs/iso9660.ad) end-to-end.
# The .iso is built at build time (genisoimage/xorriso) and kept OUT of
# git, exactly like the loop FAT fixture above.
if os.environ.get("ENABLE_ISO9660_TEST") == "1":
    import sys as _iso_sys
    _iso_scripts_dir = str(Path(__file__).resolve().parent)
    if _iso_scripts_dir not in _iso_sys.path:
        _iso_sys.path.insert(0, _iso_scripts_dir)
    import build_iso_fixture as _iso_mod
    FILES.append(("/tests/iso9660/test.iso", _iso_mod.build_iso_image()))
    FILES.append(("/etc/iso9660-test", b"1\n"))

# ENABLE_NTFS_TEST=1 (via scripts/test_ntfs.sh) bakes a REAL NTFS image
# FILE into the cpio at /tests/ntfs/test.img plus the /etc/ntfs-test
# marker. init/main.ad's ntfs_e2e_selftest() loop-attaches that image as
# /dev/blk/loopN, parses the boot sector/BPB, decodes the $MFT runlist,
# reads FILE records (USN fixup), enumerates the root directory (small
# INDEX_ROOT + non-resident INDEX_ALLOCATION INDX blocks), reads a
# resident file (HELLO.TXT) byte-exact, reads a non-resident multi-
# cluster file (BIG.DAT) byte-exact, and resolves a nested file —
# proving the read-only NTFS reader (fs/ntfs.ad) end-to-end. The image is
# built at build time (mkntfs/ntfs-3g) and kept OUT of git, exactly like
# the ISO9660 and loop FAT fixtures above.
if os.environ.get("ENABLE_NTFS_TEST") == "1":
    import sys as _ntfs_sys
    _ntfs_scripts_dir = str(Path(__file__).resolve().parent)
    if _ntfs_scripts_dir not in _ntfs_sys.path:
        _ntfs_sys.path.insert(0, _ntfs_scripts_dir)
    import build_ntfs_fixture as _ntfs_mod
    FILES.append(("/tests/ntfs/test.img", _ntfs_mod.build_ntfs_image()))
    FILES.append(("/etc/ntfs-test", b"1\n"))

# ENABLE_BTRFS_TEST=1 (via scripts/test_btrfs.sh) bakes a REAL btrfs image
# FILE into the cpio at /tests/btrfs/test.img plus the /etc/btrfs-test
# marker. init/main.ad's btrfs_e2e_selftest() loop-attaches that image as
# /dev/blk/loopN, verifies the superblock magic at 0x10000, seeds the
# chunk map from the bootstrap sys_chunk_array, reads the CHUNK + ROOT
# B-trees, descends the FS tree to enumerate the root directory, reads an
# INLINE-extent file (HELLO.TXT) byte-exact and a REGULAR-extent file
# bigger than one node (BIG.DAT) byte-exact through the chunk map, and
# resolves a nested file — proving the read-only btrfs reader
# (fs/btrfs.ad) end-to-end. The image is built at build time
# (mkfs.btrfs/btrfs-progs, --rootdir, no root needed) and kept OUT of
# git, exactly like the ISO9660 / NTFS / loop FAT fixtures above.
if os.environ.get("ENABLE_BTRFS_TEST") == "1":
    import sys as _btrfs_sys
    _btrfs_scripts_dir = str(Path(__file__).resolve().parent)
    if _btrfs_scripts_dir not in _btrfs_sys.path:
        _btrfs_sys.path.insert(0, _btrfs_scripts_dir)
    import build_btrfs_fixture as _btrfs_mod
    FILES.append(("/tests/btrfs/test.img", _btrfs_mod.build_btrfs_image()))
    FILES.append(("/etc/btrfs-test", b"1\n"))

if os.environ.get("ENABLE_TAR_GZIP_FIXTURE") == "1":
    import gzip as _gzip_mod
    # Repetitive, compressible plaintext: zlib chooses dynamic Huffman
    # (BTYPE=10) with LZ77 back-references for this, the exact path our
    # gunzip must decode (not the trivial stored path our gzip emits).
    _realgz_plain = (
        b"The quick brown fox jumps over the lazy dog.\n"
        b"Hamnix native gunzip decodes real-world gzip Huffman streams.\n"
    ) * 64
    _realgz_bytes = _gzip_mod.compress(_realgz_plain, compresslevel=9)
    FILES.append(("/tests/realgz/known.txt", _realgz_plain))
    FILES.append(("/tests/realgz/known.txt.gz", _realgz_bytes))

    # A REAL .tar.gz produced by Python's stdlib tar+gzip (POSIX/ustar
    # headers, dynamic-Huffman DEFLATE) — the differential-vs-standard-tar
    # artifact for the native `tar -tzf` / `-xzf` read path. Two files
    # under a subdir so extraction exercises mkdir + nested member paths.
    import io as _io_mod
    import tarfile as _tar_mod
    _tg_f1 = b"gz-member-one-payload\n"
    _tg_f2 = b"gz-member-two-payload\n"
    _tbuf = _io_mod.BytesIO()
    with _tar_mod.open(fileobj=_tbuf, mode="w", format=_tar_mod.USTAR_FORMAT) as _tf:
        for _nm, _data in (("tgtree/a.txt", _tg_f1), ("tgtree/sub/b.txt", _tg_f2)):
            _ti = _tar_mod.TarInfo(_nm)
            _ti.size = len(_data)
            _tf.addfile(_ti, _io_mod.BytesIO(_data))
    _realtar_gz = _gzip_mod.compress(_tbuf.getvalue(), compresslevel=9)
    FILES.append(("/tests/realgz/tree.tar.gz", _realtar_gz))

# M16.102 TCP three-way-handshake smoke (10.0.2.100:7 echo via
# SLIRP `guestfwd=tcp:10.0.2.100:7-cmd:cat`). Gated the same way as
# /etc/tcp-ring-test below: without the matching guestfwd the connect
# ARP-stalls and tcp_connect's jiffy deadline never expires (jiffies
# aren't ticking yet at net_smoke_test time — time_init runs later in
# start_kernel). Only scripts/test_net_tcp.sh sets this; the default
# vanilla boot does NOT include it, so production / demo boots skip
# the smoke and reach the interactive prompt cleanly.
if os.environ.get("ENABLE_TCP_SMOKE_TEST") == "1":
    FILES.append(("/etc/tcp-smoke-test", b"1\n"))

# V5.3 TCP RX-ring multi-segment smoke. Gated the same way as
# /etc/tls-test so the kernel doesn't try to ARP / SYN 10.0.2.201
# during boot when the test_tcp_ring.sh harness isn't running —
# without the marker, an unreachable peer would stall tcp_connect
# (jiffies aren't ticking yet at net_smoke_test time, so its
# polling-loop deadline never fires). See init/main.ad's
# tcp_ring_smoke_test gate.
if os.environ.get("ENABLE_TCP_RING_SMOKE") == "1":
    FILES.append(("/etc/tcp-ring-test", b"1\n"))

# /net 9P file-tree smoke (ARCH §10). scripts/test_net_devnet.sh sets
# ENABLE_DEVNET_SMOKE=1 to plant /etc/devnet-test; init/main.ad gates
# devnet_smoke_test() (the /net/tcp/clone open + ctl connect + data
# transfer round-trip) on it. Gated for the same reason as the TCP
# ring marker above: without a guestfwd echo target the `connect` ctl
# command stalls tcp_connect, so only that one harness plants it.
if os.environ.get("ENABLE_DEVNET_SMOKE") == "1":
    FILES.append(("/etc/devnet-test", b"1\n"))

# TCP FIN_WAIT_2 timeout smoke. Gated the same way as the TLS / TCP
# ring markers above. The fixture (scripts/test_tcp_fin_wait2.sh)
# stands up a Python server that ACKs our FIN but never sends its
# own — exercising the RFC 793 §3.5 / RFC 7414 §2.17 FIN_WAIT_2
# timeout path in drivers/net/tcp.ad. Only that one harness sets
# this; other tests run without the marker (and so without an
# ARP-stall on the unreachable 10.0.2.202).
# Same defence as the gzip smoke: also plant skip-https-internet-smoke
# so the unconditional https://example.com leg in net_smoke_test
# doesn't trap on the AES-256-GCM record (separate residual; would
# otherwise kill the kernel before reaching the FW2 gate).
if os.environ.get("ENABLE_TCP_FIN_WAIT2_SMOKE") == "1":
    FILES.append(("/etc/tcp-finwait2-test", b"1\n"))
    FILES.append(("/etc/skip-https-internet-smoke", b"1\n"))

# TCP back-to-back-connect regression. Gated the same way as the TCP
# ring / FIN_WAIT_2 markers above. The fixture (scripts/test_tcp_
# reconnect.sh) boots with a guestfwd to host `cat` at 10.0.2.100:7
# and the kernel's tcp_reconnect_smoke_test fires 6 back-to-back
# connect/echo/close cycles with NO delay between them — the
# regression for the ephemeral-source-port-rotation fix in
# drivers/net/tcp.ad. Only that one harness sets this; default boot
# and other tests run without the marker.
if os.environ.get("ENABLE_TCP_RECONNECT_SMOKE") == "1":
    FILES.append(("/etc/tcp-reconnect-test", b"1\n"))

# TCP bulk-download throughput smoke. Gated the same way as the TCP
# ring / reconnect markers above. The fixture (scripts/test_net_tcp_
# throughput.sh) boots with a guestfwd to a Python blob server at
# 10.0.2.203:9200; the kernel's tcp_throughput_smoke_test drains a
# 1 MiB blob and asserts the sustained rate clears a sane floor — a
# regression guard for the TCP receive path. Only that one harness
# sets this; default boot and other tests run without it.
if os.environ.get("ENABLE_TCP_THROUGHPUT_SMOKE") == "1":
    FILES.append(("/etc/tcp-throughput-test", b"1\n"))

# TCP loopback smoke: in-kernel single-process loopback round-trip.
# scripts/test_tcp_loopback.sh sets ENABLE_TCP_LOOPBACK_SMOKE=1 to plant
# /etc/tcp-loopback-test; init/main.ad gates tcp_loopback_smoke_test() on
# this marker. No SLIRP guestfwd is needed — 127.0.0.1 is handled purely
# in ip_send's loopback shortcut. Default boots skip this so net tests that
# don't need loopback aren't affected.
if os.environ.get("ENABLE_TCP_LOOPBACK_SMOKE") == "1":
    FILES.append(("/etc/tcp-loopback-test", b"1\n"))

# #166: TCP data-path maturity self-test (congestion control, window
# scaling, SACK, multi-listener accept backlog). scripts/test_tcp_maturity.sh
# sets ENABLE_TCP_TEST=1 to plant /etc/tcp-test; init/main.ad's boot:30.c
# gate calls tcp_maturity_selftest(), which asserts against crafted in-kernel
# state — no SLIRP / guestfwd needed. Default boots ship no marker so the
# self-test never fires unintentionally.
if os.environ.get("ENABLE_TCP_TEST") == "1":
    FILES.append(("/etc/tcp-test", b"1\n"))

# #173: ELF process core dumps. scripts/test_coredump.sh sets
# ENABLE_COREDUMP_TEST=1 to plant /etc/coredump-test; init/main.ad's
# boot:30.d gate confirms kernel/core/coredump.ad linked and announces
# the u_coredump fixture, which deliberately SIGSEGVs with no handler so
# the kernel writes /tmp/core, then re-reads + validates the ELF.
if os.environ.get("ENABLE_COREDUMP_TEST") == "1":
    FILES.append(("/etc/coredump-test", b"1\n"))

# DHCP renew/rebind/expiry smoke. Gated the same way as the TLS / TCP
# ring markers above. The renew smoke leaves DHCP state at IDLE on
# exit, which breaks any downstream test that requires state == BOUND
# (test_dns.sh checks `dhcp_state_get() == 3` before resolving). Only
# scripts/test_dhcp_renew.sh sets this; default boot keeps the BOUND
# lease intact. See init/main.ad's dhcp_renew_smoke_test gate.
if os.environ.get("ENABLE_DHCP_RENEW_SMOKE") == "1":
    FILES.append(("/etc/dhcp-renew-test", b"1\n"))

# SYS_NETCFG (`ifconfig`) network info + static-config smoke. Gated the
# same way as the markers above — see init/main.ad's nc_marker_found
# gate. The smoke pins a static IPv4 address / gateway / DNS, which
# stops DHCP from installing a lease, so it would break any downstream
# test that needs the DHCP-assigned 10.0.2.15. Only
# scripts/test_net_cfg.sh sets this; default boot keeps DHCP in charge.
if os.environ.get("ENABLE_NETCFG_SMOKE") == "1":
    FILES.append(("/etc/netcfg-test", b"1\n"))

# IPv6 link-local + ND + ICMPv6 echo self-test (task #156). Gated like
# the markers above so the vanilla boot stays quiet; only
# scripts/test_net_ipv6.sh plants the marker to run ipv6_selftest().
if os.environ.get("ENABLE_IPV6_SELFTEST") == "1":
    FILES.append(("/etc/ipv6-test", b"1\n"))

# §10 unicast ARP helper + ICMP time-exceeded + redirect selftest.
# scripts/test_net_arp_icmp_helpers.sh sets ENABLE_NAI_HELPERS_TEST=1
# to plant /etc/net-arp-icmp-helpers-test; tests/net_smoke.ad's
# _nai_marker_present() gate then calls net_arp_icmp_helpers_selftest()
# during net_smoke_test.
if os.environ.get("ENABLE_NAI_HELPERS_TEST") == "1":
    FILES.append(("/etc/net-arp-icmp-helpers-test", b"1\n"))

# xHCI V1/V2 synthetic transfer-engine selftests. Gated the same way as
# the markers above — see init/main.ad's xhci_marker_found gate. The
# selftests forge Event-Ring state that real silicon won't agree with
# when no USB keyboard is enumerated, so default boots skip them (which
# is what real Asus / ThinkPad laptops without a USB keyboard attached
# now do — pre-marker boots were hanging in xhci_poll's MMIO-poll path).
# scripts/test_usb_hid_v1.sh and scripts/test_usb_hid_v2.sh set this to
# force the synthetic selftests to run under QEMU.
if os.environ.get("ENABLE_XHCI_SELFTEST") == "1":
    FILES.append(("/etc/xhci-selftest", b"1\n"))

# Installer-medium HID-input regression aid. The REAL installer build
# (HAMNIX_INSTALLER_BLOB=1, scripts/build_installer_img.sh) plants
# /etc/installer-medium ALONGSIDE the multi-hundred-MiB squashfs + package
# payload. For a fast, focused VM regression of the installer-medium USB
# HID-INPUT bring-up path (init/main.ad calls xhci_init_force() under this
# marker so the USB-only NUC's mouse/keyboard come up for the DE), set
# ENABLE_INSTALLER_MEDIUM_MARKER=1 to plant ONLY the marker — no squashfs,
# no package repo. scripts/test_installer_usb_hid_input.sh uses this so the
# test boots in seconds instead of building the full installer image.
# Default boots ship no marker; the real installer build uses the BLOB path.
if os.environ.get("ENABLE_INSTALLER_MEDIUM_MARKER") == "1":
    FILES.append(("/etc/installer-medium", b"1\n"))

# F-oops capture self-test marker. OOPS_TEST=1 plants /etc/oops-test so
# init/main.ad fires a deterministic panic right after esp_log_init has
# armed OOPS.BIN's extent. scripts/test_kernel_oops_capture.sh boots
# with this set, reads OOPS.BIN off the FAT volume the kernel wrote to,
# and asserts the panic message + a backtrace addr persisted.
if os.environ.get("OOPS_TEST") == "1":
    FILES.append(("/etc/oops-test", b"1\n"))

# S3 suspend-to-RAM self-test marker. ENABLE_SUSPEND_TEST=1 plants
# /etc/suspend-test so init/main.ad (boot:13.S) drives a single S3
# round-trip through arch/x86/kernel/power.ad::power_suspend_s3().
# scripts/test_suspend_resume.sh boots with this set and asserts both
# the entering/back markers AND that the hamsh idle heartbeat ticks
# after the simulated resume.
if os.environ.get("ENABLE_SUSPEND_TEST") == "1":
    FILES.append(("/etc/suspend-test", b"1\n"))

# Framebuffer page-pause log-capture aid. Set ENABLE_LOG_SLOW=1 to plant
# /etc/log-slow; init/main.ad (boot:03) then makes the GOP text console
# pause ~1 s and stamp an OCR delimiter ("### HAMNIX-LOGPAGE NNNN ###")
# after every screenful of scrolled output, so a capture card can grab
# the fast-scrolling NUC boot log one page at a time. Off by default.
if os.environ.get("ENABLE_LOG_SLOW") == "1":
    FILES.append(("/etc/log-slow", b"1\n"))

# xHCI LIVE keyboard round-trip. Set ENABLE_XHCI_KBD_LIVE=1 to plant
# /etc/xhci-kbd-live; init/main.ad gates xhci_kbd_live_watch() on it.
# Unlike ENABLE_XHCI_SELFTEST (which drives the SYNTHETIC forged-event
# selftests), this opts into a GENUINE wire round-trip: the kernel
# blocks after enumerating a real usb-kbd, prints a READY banner, and
# waits for the controller to post a real interrupt-IN Transfer Event
# for a keypress the harness injects over the QEMU monitor `sendkey`.
# Only scripts/test_xhci_kbd_live.sh sets this (alongside
# ENABLE_XHCI_KO=0 so the hand-rolled drivers/usb/xhci.ad actually
# owns the controller). Default boots ship no marker, so a PS/2-only
# real laptop never enters the watch loop.
if os.environ.get("ENABLE_XHCI_KBD_LIVE") == "1":
    FILES.append(("/etc/xhci-kbd-live", b"1\n"))

# USB mass-storage (BOT/SCSI) exercise. Set ENABLE_USBMS_TEST=1 to
# plant /etc/usbms-test; init/main.ad gates usbms_exercise() on it,
# which enumerates an attached USB stick (boot QEMU with
# `-device qemu-xhci -device usb-storage,drive=...`), registers
# /dev/blk/sd0, and reads sector 0 back. Default boots ship no marker
# so the storage probe is a no-op when no stick is present.
if os.environ.get("ENABLE_USBMS_TEST") == "1":
    FILES.append(("/etc/usbms-test", b"1\n"))

# EHCI (USB 2.0) mass-storage bulk exercise. Set ENABLE_EHCI_MSC_TEST=1
# to plant /etc/ehci-msc-test; init/main.ad gates ehci_msc_selftest() on
# it, which enumerates a USB stick on an EHCI controller (boot QEMU with
# `-device usb-ehci -device usb-storage,bus=ehci.0,drive=...`), drives
# the new EHCI bulk path through Bulk-Only Transport + SCSI READ(10), and
# reads sector 0 back. Default boots ship no marker so the probe is a
# no-op when no stick is present.
if os.environ.get("ENABLE_EHCI_MSC_TEST") == "1":
    FILES.append(("/etc/ehci-msc-test", b"1\n"))

# §file-mmap: REAL file-backed mmap self-test. scripts/test_mmap_file.sh
# sets ENABLE_MMAP_FILE_TEST=1 to plant /etc/mmap-file-test. init/main.ad
# at boot:37 detects the marker and calls mmap_file_selftest(): it writes
# a known-content file, mmap()s it PROT_READ MAP_PRIVATE, faults several
# pages in, memcmp's the mapped bytes against the source (including an
# offset map and a sub-page EOF tail that must read as zero), and prints
# "[mmap-file] PASS" / "[mmap-file] FAIL". Default boots omit the marker.
if os.environ.get("ENABLE_MMAP_FILE_TEST") == "1":
    FILES.append(("/etc/mmap-file-test", b"1\n"))
    # Known-content backing file the self-test mmap()s and verifies. The
    # content is the deterministic byte formula (i*31 + 7) & 0xFF, which
    # mmap_file_selftest() regenerates to memcmp against the mapped bytes.
    # Length = 2 pages + 100 bytes (8292) so the test covers multi-page
    # fault-in, an in-file offset, AND a sub-page EOF tail (bytes past
    # EOF in the last mapped page must read as zero).
    _mmf_len = 2 * 4096 + 100
    _mmf_data = bytes(((i * 31 + 7) & 0xFF) for i in range(_mmf_len))
    FILES.append(("/etc/mmap-file-data", _mmf_data))

# §shared-mmap: MAP_SHARED writable file-backed mmap self-test.
# scripts/test_mmap_shared_file.sh sets ENABLE_MMAP_SHARED_TEST=1 to plant
# /etc/mmap-shared-test (the gate marker). init/main.ad at boot:37.mms
# detects it and calls mmap_shared_selftest(): it creates a known-content
# file on tmpfs (a WRITABLE backend), mmap()s it MAP_SHARED|PROT_WRITE,
# modifies bytes through the mapping, msync(MS_SYNC)s, then reads the
# backing file back via the normal read path (NOT the mapping) and a
# second fresh mmap, confirming the modifications landed in the file.
# Prints "[mmap-shared] PASS" / "[mmap-shared] FAIL". Default boots omit
# the marker so the self-test is a no-op everywhere else.
if os.environ.get("ENABLE_MMAP_SHARED_TEST") == "1":
    FILES.append(("/etc/mmap-shared-test", b"1\n"))

# /proc/cpuinfo real-CPUID self-test. scripts/test_cpuinfo.sh sets
# ENABLE_CPUINFO_TEST=1 to plant /etc/cpuinfo-test. init/main.ad at
# boot:37.cpi detects it and calls cpuinfo_selftest() (fs/procfs.ad),
# which renders /proc/cpuinfo into a scratch buffer and asserts the
# real CPUID vendor string is present (NOT the literal "Hamnix"), that
# "processor\t: 0" appears, and that the processor-line count equals
# the SMP online CPU count. Prints "[CPUINFO] PASS" / "[CPUINFO] FAIL".
# Default boots omit the marker so the self-test is a no-op elsewhere.
if os.environ.get("ENABLE_CPUINFO_TEST") == "1":
    FILES.append(("/etc/cpuinfo-test", b"1\n"))

# /proc/mounts real per-namespace mount-table self-test.
# scripts/test_procmounts.sh sets ENABLE_PROCMOUNTS_TEST=1 to plant
# /etc/procmounts-test. init/main.ad at boot:37.pmt detects the marker
# and calls procmounts_selftest() (fs/procfs.ad), which renders
# /proc/mounts into a scratch buffer and asserts the root-pinned base
# lines are present, then performs a runtime mnttab_bind and re-renders,
# asserting the new bind shows up as a 6-field /proc/mounts line. Prints
# "[PROCMOUNTS] PASS" / "[PROCMOUNTS] FAIL". Default boots omit the
# marker so the self-test is a no-op everywhere else.
if os.environ.get("ENABLE_PROCMOUNTS_TEST") == "1":
    FILES.append(("/etc/procmounts-test", b"1\n"))

# linux-abi U-ABI fills self-test. scripts/test_uabi_fills.sh sets
# ENABLE_UABI_FILLS_TEST=1 to plant /etc/uabi-fills-test. init/main.ad at
# boot:37.uaf detects the marker and calls uabi_fills_selftest()
# (linux_abi/u_syscalls.ad), which drives the newly-filled Linux-ABI
# syscalls (arch_prctl GET_FS, readlink, uname, newfstatat, pwrite64)
# through the real in-kernel dispatch entry and prints "[UABI_FILLS] PASS"
# / "[UABI_FILLS] FAIL ...". The marker doubles as the file newfstatat
# stat()s. Default boots omit the marker so the self-test never fires.
if os.environ.get("ENABLE_UABI_FILLS_TEST") == "1":
    FILES.append(("/etc/uabi-fills-test", b"1\n"))

# Kernel backtrace self-test. scripts/test_backtrace.sh sets
# ENABLE_BACKTRACE_TEST=1 to plant /etc/backtrace-test. init/main.ad at
# boot:37.bt detects the marker and calls backtrace_selftest(), which
# fires one WARN_ON(true); kernel/panic.ad's WARN_ON then runs
# dump_stack(), the frame-pointer backtrace walker, printing the
# "Call trace (kernel text base = 0x...)" header + "  [<0x...>] +0x..."
# frame lines. WARN_ON does not halt, so the box keeps booting. Default
# boots omit the marker so the self-test never fires.
if os.environ.get("ENABLE_BACKTRACE_TEST") == "1":
    FILES.append(("/etc/backtrace-test", b"1\n"))

# #165: linux-abi PTY (pseudo-terminal) self-test. scripts/test_pty.sh
# sets ENABLE_PTY_TEST=1 to plant /etc/pty-test (the gate marker).
# init/main.ad at boot:37.pty detects it and calls pty_selftest()
# (linux_abi/u_syscalls.ad), which drives the full ptmx/pts open+ioctl+
# read+write+close path through the real in-kernel dispatch and prints
# "[PTY] PASS" / "[PTY] FAIL ...". Default boots omit the marker.
if os.environ.get("ENABLE_PTY_TEST") == "1":
    FILES.append(("/etc/pty-test", b"1\n"))

# linux-abi msync(2) self-test. scripts/test_msync.sh sets
# ENABLE_MSYNC_TEST=1 to plant /etc/msync-test (the gate marker).
# init/main.ad at boot:37.msy detects it and calls msync_selftest()
# (linux_abi/u_syscalls.ad): it creates a known-content file on tmpfs (a
# WRITABLE backend), mmap()s it MAP_SHARED|PROT_WRITE, modifies bytes
# through the mapping, calls msync(MS_SYNC) via the REAL Linux-ABI
# dispatch, then reads the backing file back via the normal read path (NOT
# the mapping), confirming the flush landed. Prints "[MSYNC] PASS" /
# "[MSYNC] FAIL". Default boots omit the marker so the self-test never
# fires.
if os.environ.get("ENABLE_MSYNC_TEST") == "1":
    FILES.append(("/etc/msync-test", b"1\n"))

# Writable-/dev/mouse synthetic-event self-test. scripts/test_devmouse_write.sh
# sets ENABLE_DEVMOUSE_WRITE_TEST=1 to plant /etc/devmouse-write-test.
# init/main.ad at boot:37.dmw detects the marker and calls
# devmouse_write_selftest() (sys/src/9/port/devmouse.ad): it injects a known
# event via devmouse_write ("5 -3 1\n"), reads it back via devmouse_read,
# decodes the ASCII line, and asserts dx==5, dy==-3, buttons==1 (plus a
# malformed-input reject path). Prints "[DEVMOUSE_WRITE] PASS" /
# "[DEVMOUSE_WRITE] FAIL ...". Default boots omit the marker so the
# self-test never fires.
if os.environ.get("ENABLE_DEVMOUSE_WRITE_TEST") == "1":
    FILES.append(("/etc/devmouse-write-test", b"1\n"))

# SMP kthread-churn soak. scripts/test_smp_soak.sh sets ENABLE_SMP_SOAK=1
# to plant /etc/smp-soak in the initramfs. init/main.ad at boot:37 detects
# the marker and calls smp_kthread_soak_run() (kernel/sched/core.ad) which
# hammers kthread create/exit/reap cycles under -smp 2, stressing rq_lock
# contention, AP idle-loop dispatch, and per-CPU current_idx_pcpu mutations.
# Default boots omit the marker so the soak never fires unintentionally.
if os.environ.get("ENABLE_SMP_SOAK") == "1":
    FILES.append(("/etc/smp-soak", b"1\n"))

# #151: CFS-lite + SMP load-balance self-test. scripts/test_sched_fair.sh
# sets ENABLE_SCHED_FAIR=1 to plant /etc/sched-fair. init/main.ad at
# boot:37 detects the marker and calls sched_fair_smp_selftest()
# (kernel/sched/core.ad): it checks weight ordering / vruntime accrual and
# spawns CPU-bound kthreads to prove the AP work-steals (dispatch spread
# across >1 CPU under -smp 2). Default boots omit the marker.
if os.environ.get("ENABLE_SCHED_FAIR") == "1":
    FILES.append(("/etc/sched-fair", b"1\n"))

# scripts/test_fpu_ctxsw.sh sets ENABLE_FPU_TORTURE=1 to plant /etc/fpu-torture.
# init/main.ad at boot:37 detects the marker and calls
# fpu_ctxsw_torture_selftest() (kernel/sched/core.ad): two kthreads ping-pong
# distinct patterns across the xmm bank over many real context switches and
# assert ZERO cross-contamination — the direct proof that per-task FPU/SSE
# state is saved/restored on every switch. Default boots omit the marker.
if os.environ.get("ENABLE_FPU_TORTURE") == "1":
    FILES.append(("/etc/fpu-torture", b"1\n"))

# NTASKS-ceiling concurrency proof. scripts/test_ntasks_ceiling.sh sets
# ENABLE_NTASKS_TEST=1 to plant /etc/ntasks-test. init/main.ad at
# boot:37.ntasks_test detects the marker and calls ntasks_ceiling_test_run()
# (kernel/sched/core.ad): it holds >64 kthreads live SIMULTANEOUSLY to prove
# the NTASKS=256 lift actually took effect, then drains them. Default boots
# omit the marker.
if os.environ.get("ENABLE_NTASKS_TEST") == "1":
    FILES.append(("/etc/ntasks-test", b"1\n"))

# Stage-A per-CPU TSS proof. scripts/test_smp_user.sh sets ENABLE_SMP_USER=1
# to plant /etc/smp-user. init/main.ad at boot:37.smp_user detects the
# marker and calls smp_user_ap_selftest() (kernel/sched/core.ad): it spawns
# a CPL3 USER task and fences it onto the AP, proving a user task runs on a
# non-BSP CPU (cpu1) through that CPU's own per-CPU TSS. Default boots omit
# the marker.
if os.environ.get("ENABLE_SMP_USER") == "1":
    FILES.append(("/etc/smp-user", b"1\n"))

# task #112 SMP cross-CPU demand-fault race repro. scripts/test_pf_smp_race.sh
# sets ENABLE_PF_SMP_RACE=1 to plant /etc/pf-smp-race. init/main.ad at
# boot:37.pf_race detects the marker and calls pf_smp_race_selftest()
# (kernel/sched/core.ad): two ring-3 tasks sharing one address space sweep a
# shared demand-zero region concurrently, one per CPU, colliding their
# demand faults to exercise the SMP not-present fault path. Default boots
# omit the marker.
if os.environ.get("ENABLE_PF_SMP_RACE") == "1":
    FILES.append(("/etc/pf-smp-race", b"1\n"))

# Bottom-half stack proof. scripts/test_bh.sh sets ENABLE_BH_TEST=1 to plant
# /etc/bh-test. init/main.ad at boot:37.bh detects the marker and calls
# bh_selftest_run() (kernel/softirq.ad): proves softirq raise/run, tasklet
# run-once-coalesced, queue_work on a worker kthread + flush_work wait,
# delayed_work fires after its delay, and a threaded-IRQ thread_fn runs in
# thread context. Default boots omit the marker.
if os.environ.get("ENABLE_BH_TEST") == "1":
    FILES.append(("/etc/bh-test", b"1\n"))

# Write-through block buffer cache self-test. scripts/test_bcache.sh sets
# ENABLE_BCACHE_TEST=1 to plant /etc/bcache-test. init/main.ad at
# boot:37.bcache detects the marker and calls blk_bcache_selftest()
# (kernel/block/blk.ad): it writes/reads ram0 through blk_read_sectors /
# blk_write_sectors and asserts a warm re-read is served from the cache
# (device rd_ios FLAT, hit counter rises) and that a write keeps the cache
# coherent (no stale sector). Default boots omit the marker.
if os.environ.get("ENABLE_BCACHE_TEST") == "1":
    FILES.append(("/etc/bcache-test", b"1\n"))

# Linux-parity fs caching layer self-test. scripts/test_fcache.sh sets
# ENABLE_FCACHE_TEST=1 to plant /etc/fcache-test. init/main.ad at
# boot:37.fcache detects the marker and calls fcache_selftest() (fs/fcache.ad):
# it exercises the per-inode page cache (populate/hit/dirty/writeback +
# coherent reread), the dcache (positive/negative + per-Pgrp namespace
# isolation + generation invalidation) and the inode cache. Default boots
# omit the marker.
if os.environ.get("ENABLE_FCACHE_TEST") == "1":
    FILES.append(("/etc/fcache-test", b"1\n"))

# RCU grace-period engine self-test. scripts/test_rcu.sh sets ENABLE_RCU_TEST=1
# to plant /etc/rcu-test. init/main.ad at boot:37.rcu detects the marker and
# calls rcu_selftest() (kernel/rcu/rcu_selftest.ad): a reader defers a call_rcu
# callback until unlock + a GP; synchronize_rcu advances a GP; rcu_barrier
# drains callbacks; the task-list RCU traversal is correct under add/remove
# stress. Pure in-RAM, no disk. Default boots omit the marker.
if os.environ.get("ENABLE_RCU_TEST") == "1":
    FILES.append(("/etc/rcu-test", b"1\n"))

# ENABLE_RFORK_COW_TEST=1 to plant /etc/rfork-cow-test. init/main.ad at
# boot:37.rfcow detects the marker and calls elf32_wx_span_reset_selftest()
# (fs/elf.ad): it plants a bogus non-zero W^X RO-span count (as if an
# ELF64 binary loaded first), loads the native ELF32 /init image, and
# asserts the loader reset the spans to 0. Guards the PID-1 rfork-COW
# fatal #PF (a stale RO span flipped the ELF32 image's .data RO, so the
# first rfork child's write faulted verbatim-RO). Default boots omit it.
if os.environ.get("ENABLE_RFORK_COW_TEST") == "1":
    FILES.append(("/etc/rfork-cow-test", b"1\n"))

# GPU track #181 Phase 0: native Vulkan-shaped software-rasterizer spine
# self-test. scripts/test_vk_software_raster.sh sets ENABLE_VK_TEST=1 to
# plant /etc/vk-test. init/main.ad at boot:37.vk detects the marker and
# calls vk_software_raster_selftest() (lib/vk/vk_selftest.ad): it drives
# the whole Vulkan-shaped API through the software rasterizer to render a
# depth-tested two-triangle scene, asserts known pixel values + a
# deterministic checksum, and presents to /dev/fb. Default boots omit
# the marker so the spine self-test never fires unintentionally.
if os.environ.get("ENABLE_VK_TEST") == "1":
    FILES.append(("/etc/vk-test", b"1\n"))

# GPU track #182 Phase 1: native virtio-gpu 2D present self-test.
# scripts/test_virtio_gpu_present.sh sets ENABLE_VIRTIO_GPU_TEST=1 to
# plant /etc/virtio-gpu-test. init/main.ad at boot:37.vgpu detects the
# marker and calls virtio_gpu_present_test_pattern(): it paints the
# four-quadrant RED/GREEN/BLUE/WHITE pattern into the virtio-gpu backing
# buffer and runs TRANSFER_TO_HOST_2D + RESOURCE_FLUSH so the pixels land
# on the virtio-gpu scanout. Default boots omit the marker so the screen
# takeover never fires unintentionally.
if os.environ.get("ENABLE_VIRTIO_GPU_TEST") == "1":
    FILES.append(("/etc/virtio-gpu-test", b"1\n"))

# /proc/net renderer self-test. scripts/test_procnet.sh sets
# ENABLE_PROCNET_TEST=1 to plant /etc/procnet-test; init/main.ad at
# boot:37.pnt detects the marker and runs procnet_selftest().
if os.environ.get("ENABLE_PROCNET_TEST") == "1":
    FILES.append(("/etc/procnet-test", b"1\n"))

# #U52 System V IPC self-test. scripts/test_u52_sysvipc.sh sets
# ENABLE_SYSVIPC_TEST=1 to plant /etc/sysvipc-test; init/main.ad at
# boot:37.ipc detects the marker and runs sysvipc_selftest().
if os.environ.get("ENABLE_SYSVIPC_TEST") == "1":
    FILES.append(("/etc/sysvipc-test", b"1\n"))

# POSIX message queues (mq_*) self-test. scripts/test_mqueue.sh sets
# ENABLE_MQUEUE_TEST=1 to plant /etc/mqueue-test; init/main.ad at
# boot:37.mq detects the marker and runs posixmq_selftest().
if os.environ.get("ENABLE_MQUEUE_TEST") == "1":
    FILES.append(("/etc/mqueue-test", b"1\n"))

# AF_UNIX (local) domain socket self-test. scripts/test_afunix.sh sets
# ENABLE_AFUNIX_TEST=1 to plant /etc/afunix-test; init/main.ad at
# boot:37.afunix detects the marker and runs afunix_selftest().
if os.environ.get("ENABLE_AFUNIX_TEST") == "1":
    FILES.append(("/etc/afunix-test", b"1\n"))

# AF_NETLINK / NETLINK_ROUTE (rtnetlink) self-test. scripts/test_netlink.sh
# sets ENABLE_NETLINK_TEST=1 to plant /etc/netlink-test; init/main.ad at
# boot:37.netlink detects the marker and runs nl_selftest(), which frames +
# parses RTM_GETLINK / RTM_GETADDR / RTM_GETROUTE dumps.
if os.environ.get("ENABLE_NETLINK_TEST") == "1":
    FILES.append(("/etc/netlink-test", b"1\n"))

# pidfd process-management family (pidfd_open/pidfd_send_signal/waitid)
# self-test. scripts/test_pidfd.sh sets ENABLE_PIDFD_TEST=1 to plant
# /etc/pidfd-test; init/main.ad at boot:37.pidfd detects the marker and
# runs do_pidfd_selftest().
if os.environ.get("ENABLE_PIDFD_TEST") == "1":
    FILES.append(("/etc/pidfd-test", b"1\n"))

# memfd_create(2) + file-sealing self-test. scripts/test_memfd.sh sets
# ENABLE_MEMFD_TEST=1 to plant /etc/memfd-test; init/main.ad at
# boot:37.memfd detects the marker and runs memfd_selftest()
# (linux_abi/u_memfd.ad), which exercises create/write/read byte-exact +
# F_SEAL_WRITE/GROW/SEAL and the non-ALLOW_SEALING EPERM path.
if os.environ.get("ENABLE_MEMFD_TEST") == "1":
    FILES.append(("/etc/memfd-test", b"1\n"))

# Wayland-passthrough Phase-0 de-risk spike. scripts/test_wlspike_scm.sh sets
# ENABLE_WLSPIKE_TEST=1 to plant /etc/wlspike-test; init/main.ad at
# boot:37.wlspike detects the marker and runs wlspike_scm_selftest()
# (linux_abi/u_syscalls.ad), which passes a memfd fd over AF_UNIX SCM_RIGHTS
# via the real sendmsg/recvmsg dispatch and proves both ends map the SAME
# physical page (prints "[wlspike] SCM_RIGHTS memfd round-trip OK: WLSPIKE_OK").
if os.environ.get("ENABLE_WLSPIKE_TEST") == "1":
    FILES.append(("/etc/wlspike-test", b"1\n"))

# Wayland-passthrough Phase-1. scripts/test_wayland_phase1.sh sets
# ENABLE_WAYLAND_TEST=1 to plant /etc/wayland-test; init/main.ad at
# boot:38.wayland detects the marker and runs wayland_phase1_selftest()
# (linux_abi/u_syscalls.ad), which drives a real Wayland client
# (connect/sendmsg/recvmsg) against the native server, passes a wl_shm pool
# fd via SCM_RIGHTS, and asserts the committed ARGB8888 buffer reaches a
# window backbuffer + the compositor layer cache
# (prints "[wayland] shm buffer on screen OK: WLPHASE1_OK").
if os.environ.get("ENABLE_WAYLAND_TEST") == "1":
    FILES.append(("/etc/wayland-test", b"1\n"))

# io_uring_setup/enter/register self-test. scripts/test_iouring.sh sets
# ENABLE_IOURING_TEST=1 to plant /etc/iouring-test; init/main.ad at
# boot:37.iouring detects the marker and runs iouring_selftest()
# (linux_abi/u_iouring.ad), which sets up a ring, submits a NOP + asserts
# its CQE, WRITEVs/READVs a tmpfs file byte-exact via the ring, FSYNCs, and
# round-trips register/unregister buffers.
if os.environ.get("ENABLE_IOURING_TEST") == "1":
    FILES.append(("/etc/iouring-test", b"1\n"))

# Pipe zero-copy I/O family (splice/tee/vmsplice) self-test.
# scripts/test_splice.sh sets ENABLE_SPLICE_TEST=1 to plant
# /etc/splice-test; init/main.ad at boot:37.splice detects the marker
# and runs splice_selftest().
if os.environ.get("ENABLE_SPLICE_TEST") == "1":
    FILES.append(("/etc/splice-test", b"1\n"))

# /dev/fbctl dirty-rectangle RECT present hardening + fast-path self-test.
# scripts/test_fbctl_rect.sh sets ENABLE_FBRECT_TEST=1 to plant
# /etc/fbrect-test; init/main.ad at boot:37.fbrect detects the marker and
# runs fbctl_rect_selftest() (drivers/video/fb_cdev.ad). The self-test
# mutates the text-console geometry (it stands up a synthetic framebuffer),
# so it is opt-in — default boots ship no marker and are unaffected.
if os.environ.get("ENABLE_FBRECT_TEST") == "1":
    FILES.append(("/etc/fbrect-test", b"1\n"))

# /dev/fbpix framebuffer pixel READ-BACK (hamshot screenshot leaf)
# self-test. scripts/test_fbpix.sh sets ENABLE_FBPIX_TEST=1 to plant
# /etc/fbpix-test; init/main.ad at boot:37.fbpix detects the marker and
# runs fbpix_selftest() (drivers/video/fb_cdev.ad). The self-test stands
# up a synthetic framebuffer (mutates the text-console geometry) and
# leaves it live for the userland fixture, so it is opt-in — default
# boots ship no marker and are unaffected.
if os.environ.get("ENABLE_FBPIX_TEST") == "1":
    FILES.append(("/etc/fbpix-test", b"1\n"))

# close_range(2) + statx(2) self-test. scripts/test_close_range.sh sets
# ENABLE_CLOSERANGE_TEST=1 to plant /etc/closerange-test; init/main.ad at
# boot:37.closerange detects the marker and runs close_range_selftest().
if os.environ.get("ENABLE_CLOSERANGE_TEST") == "1":
    FILES.append(("/etc/closerange-test", b"1\n"))

# fanotify(7) self-test. scripts/test_fanotify.sh sets
# ENABLE_FANOTIFY_TEST=1 to plant /etc/fanotify-test; init/main.ad at
# boot:37.fanotify detects the marker and runs fanotify_selftest().
if os.environ.get("ENABLE_FANOTIFY_TEST") == "1":
    FILES.append(("/etc/fanotify-test", b"1\n"))

# init_module/finit_module/delete_module self-test. scripts/test_module_
# syscalls.sh sets ENABLE_KMODSYS_TEST=1 to plant /etc/kmodsys-test;
# init/main.ad at boot:37.kmodsys detects the marker and runs
# kmod_syscall_selftest().
if os.environ.get("ENABLE_KMODSYS_TEST") == "1":
    FILES.append(("/etc/kmodsys-test", b"1\n"))

# ext4 xattr + POSIX ACL self-test. scripts/test_ext4_xattr.sh sets
# ENABLE_EXT4XATTR_TEST=1 to plant /etc/ext4xattr-test; init/main.ad at
# boot:37.xat detects the marker and runs ext4_xattr_selftest().
if os.environ.get("ENABLE_EXT4XATTR_TEST") == "1":
    FILES.append(("/etc/ext4xattr-test", b"1\n"))

# FAT VFAT long-filename self-test. scripts/test_fat_lfn.sh sets
# ENABLE_FATLFN_TEST=1 to plant /etc/fatlfn-test; init/main.ad at
# boot:37.lfn detects the marker and runs fat_lfn_selftest().
if os.environ.get("ENABLE_FATLFN_TEST") == "1":
    FILES.append(("/etc/fatlfn-test", b"1\n"))

# Read-only exFAT reader self-test. scripts/test_exfat.sh sets
# ENABLE_EXFAT_TEST=1 to plant /etc/exfat-test; init/main.ad at
# boot:37.exfat detects the marker and runs exfat_selftest(), which
# mounts the exFAT image attached as sd0, lists the root, opens a known
# file and asserts its bytes.
if os.environ.get("ENABLE_EXFAT_TEST") == "1":
    FILES.append(("/etc/exfat-test", b"1\n"))

# exFAT WRITE self-test. scripts/test_exfat_write.sh sets
# ENABLE_EXFAT_WRITE_TEST=1 to plant /etc/exfat-write-test; init/main.ad
# at boot:37.exfatw detects the marker and runs exfat_write_selftest(),
# which mounts a writable exFAT image attached as sd0, CREATES a new
# file (bitmap alloc + FAT link + data write + dir entry-set append),
# and reads it back asserting the content.
if os.environ.get("ENABLE_EXFAT_WRITE_TEST") == "1":
    FILES.append(("/etc/exfat-write-test", b"1\n"))

# #168: REAL ACPI S5 poweroff + reboot self-test.
# scripts/test_acpi_poweroff.sh sets ENABLE_ACPI_TEST=1 to plant
# /etc/acpi-test. init/main.ad at boot:37.acpi detects the marker, logs
# the FADT PM1a_CNT_BLK + DSDT-decoded \_S5 SLP_TYPa that acpi_init()
# parsed, then triggers a real-only poweroff (PM1a S5 write, no emulator
# debug ports) so a clean VM exit proves the real FADT path. Default
# boots omit the marker so the self-test never powers a normal boot off.
if os.environ.get("ENABLE_ACPI_TEST") == "1":
    FILES.append(("/etc/acpi-test", b"1\n"))

# #167: memory-pressure subsystem (swap + page reclaim + OOM killer)
# self-test. scripts/test_mm_pressure.sh sets ENABLE_MM_TEST=1 to plant
# /etc/mm-test. init/main.ad at boot:37.mm detects the marker and calls
# mm_pressure_selftest() (mm/reclaim.ad): it builds a real demand-paged
# anon VMA, evicts every page to swap (asserting the PTE becomes a swap
# entry), faults each back in via the real swap-in path and re-checksums
# (proving the round-trip restores exact bytes), then drives the OOM
# killer against two victim tasks and asserts the largest-RSS one was
# killed while the system kept running. Default boots omit the marker.
if os.environ.get("ENABLE_MM_TEST") == "1":
    FILES.append(("/etc/mm-test", b"1\n"))

# task #178: selectable-keyboard-layout self-test. scripts/test_keymap.sh
# sets ENABLE_KEYMAP_TEST=1 to plant /etc/keymap-test. init/main.ad at
# boot:37.km detects the marker and calls keymap_selftest()
# (drivers/input/atkbd.ad): it feeds fixed Set-1 make-codes through the
# scancode->char translator under each of the US/DE/FR layouts and
# asserts per-layout characters (same key gives US 'y' but DE 'z';
# AltGr+Q='@' under DE; AZERTY 'a' under FR; shifted symbols), proving
# the runtime layout switch really re-routes translation. Default boots
# omit the marker so the self-test never fires unintentionally.
if os.environ.get("ENABLE_KEYMAP_TEST") == "1":
    FILES.append(("/etc/keymap-test", b"ENABLE_KEYMAP_TEST=1\n"))

# Cryptographic /dev/random CSPRNG self-test. scripts/test_random.sh sets
# ENABLE_RANDOM_TEST=1 to plant /etc/random-test. init/main.ad at
# boot:37.rnd detects the marker and calls devrandom_selftest()
# (sys/src/9/port/devrandom.ad): it checks the RFC 8439 §2.3.2 ChaCha20
# known-answer keystream EXACTLY, then proves the live pool's output is
# nonconstant, that successive reads differ (fast-key-erasure ratchet),
# and that two large reads differ (no short period). Prints its own
# EMERG-level [random] markers + a single [random] PASS. Default boots
# omit the marker so the self-test never fires unintentionally.
if os.environ.get("ENABLE_RANDOM_TEST") == "1":
    FILES.append(("/etc/random-test", b"ENABLE_RANDOM_TEST=1\n"))

# TLS handshake-entropy source self-test. scripts/test_tls_rng.sh sets
# ENABLE_TLS_RNG_TEST=1 to plant /etc/tls-rng-test. init/main.ad at
# boot:37.tlsrng detects the marker and calls tls_rng_selftest()
# (drivers/net/tls.ad): it proves TLS client_random + the X25519
# ephemeral private scalar now draw from the real kernel CSPRNG
# (devrandom_read) and not the old jiffies-seeded xorshift toy — two
# 64-byte draws differ, neither is all-zero, and the output is not a
# constant byte. Prints an EMERG-level [tls-rng] PASS / FAIL marker.
# Default boots omit the marker so the self-test never fires.
if os.environ.get("ENABLE_TLS_RNG_TEST") == "1":
    FILES.append(("/etc/tls-rng-test", b"1\n"))

# #171: EFI runtime services + Secure Boot image verification self-test.
# scripts/test_efi_secureboot.sh sets ENABLE_EFI_TEST=1 to plant
# /etc/efi-test plus the Secure Boot crypto fixtures. init/main.ad at
# boot:37.efi detects the marker and runs efi_runtime_selftest()
# (arch/x86/kernel/efi_runtime.ad — GetTime / GetVariable via the
# firmware RuntimeServices captured by the UEFI stub) and
# secureboot_selftest() (lib/secureboot/authenticode.ad — recomputes the
# Authenticode PE image hash and verifies a real RSASSA-PKCS1-v1.5-SHA256
# signature against the embedded trust anchor: it ACCEPTS the correctly
# signed blob and REJECTS a one-byte-tampered blob). The three fixture
# files are generated fresh per build by scripts/gen_secureboot_blob.py
# (no secrets committed; the verifier trusts only the embedded anchor).
# Default boots omit the marker so neither self-test ever fires.
if os.environ.get("ENABLE_EFI_TEST") == "1":
    FILES.append(("/etc/efi-test", b"ENABLE_EFI_TEST=1\n"))
    import sys as _sb_sys
    _sb_scripts_dir = str(Path(__file__).resolve().parent)
    if _sb_scripts_dir not in _sb_sys.path:
        _sb_sys.path.insert(0, _sb_scripts_dir)
    from gen_secureboot_blob import build_secureboot_fixtures
    _sb_fx = build_secureboot_fixtures()
    FILES.append(("/etc/secureboot-anchor", _sb_fx["secureboot-anchor"]))
    FILES.append(("/etc/secureboot-pe-good", _sb_fx["secureboot-pe-good"]))
    FILES.append(("/etc/secureboot-pe-bad", _sb_fx["secureboot-pe-bad"]))

# #174: per-namespace CPU + memory resource-cap self-test.
# scripts/test_nscap.sh sets ENABLE_NSCAP_TEST=1 to plant /etc/nscap-test.
# init/main.ad at boot:37.nsc detects the marker and calls nscap_selftest()
# (mm/nscap_test.ad): it builds two user tasks in SEPARATE namespaces,
# caps one's memory, and asserts that a demand-fault past the cap is
# DENIED in the capped namespace while the UNCAPPED namespace faults the
# same pages — plus the 25% CPU-cap vruntime-inflation factor. Default
# boots omit the marker so the self-test never fires unintentionally.
if os.environ.get("ENABLE_NSCAP_TEST") == "1":
    FILES.append(("/etc/nscap-test", b"ENABLE_NSCAP_TEST=1\n"))

# Native packet-filter firewall self-test. scripts/test_firewall.sh sets
# ENABLE_FIREWALL_TEST=1 to plant /etc/firewall-test. init/main.ad at
# boot:37.fw detects the marker and calls firewall_selftest()
# (drivers/net/firewall.ad): it drives the REAL _fw_evaluate verdict
# engine (the exact function the ip_rx/ip_send enforcement hooks call)
# to prove a DROP rule drops a matching tcp dport-23 packet (and bumps
# its hit counter) while a non-matching dport-80 packet is ACCEPTed, and
# to prove stateful conntrack lets an established reply (returning
# SYN-ACK) through a default-drop-inbound policy that would otherwise
# discard it. Default boots omit the marker so it never fires.
if os.environ.get("ENABLE_FIREWALL_TEST") == "1":
    FILES.append(("/etc/firewall-test", b"ENABLE_FIREWALL_TEST=1\n"))

# /net local-address renderer self-test. scripts/test_devnet_local.sh sets
# ENABLE_DEVNET_LOCAL_TEST=1 to plant /etc/devnet-local-test. init/main.ad at
# boot:37.dnl detects the marker and calls devnet_local_selftest()
# (drivers/net/devnet.ad): it sets a known host IP (10.0.2.15), clones a
# /net/tcp conn, renders its /local file via devnet_local_render, and asserts
# the output reports the REAL host IP ("10.0.2.15!") instead of the old
# 0.0.0.0 placeholder. Default boots omit the marker so it never fires.
if os.environ.get("ENABLE_DEVNET_LOCAL_TEST") == "1":
    FILES.append(("/etc/devnet-local-test", b"ENABLE_DEVNET_LOCAL_TEST=1\n"))

# §13: per-device block-I/O accounting self-test. scripts/test_diskstats.sh
# sets ENABLE_DISKSTATS_TEST=1 to plant /etc/diskstats-test. init/main.ad at
# boot:37.ds detects the marker and calls blk_diskstats_selftest()
# (kernel/block/blk.ad): it snapshots ram0's /dev/diskstats counters, drives
# a KNOWN amount of real block I/O through blk_read_sectors, and asserts the
# rd_ios / rd_sectors deltas EXACTLY match the I/O issued while an idle
# witness device's counters do not move — proving the /proc/diskstats
# numbers are fed by real I/O, not a fake parallel counter. Default boots
# omit the marker so it never fires.
if os.environ.get("ENABLE_DISKSTATS_TEST") == "1":
    FILES.append(("/etc/diskstats-test", b"ENABLE_DISKSTATS_TEST=1\n"))

# §sched: additive block I/O scheduler self-test. scripts/test_blk_sched.sh
# sets ENABLE_BLK_SCHED_TEST=1 to plant /etc/blk-sched-test. init/main.ad at
# boot:37.bsch detects the marker and calls blk_sched_selftest()
# (kernel/block/blk.ad): it seeds 4 adjacent sectors via the synchronous
# write path, plugs + submits 4 OUT-OF-ORDER adjacent reads into one
# contiguous buffer, and asserts the elevator+merger coalesced them to a
# single dispatched transfer (3 merge events), byte-compares the merged
# readback against an independent synchronous read AND the seed, and proves a
# non-adjacent batch stays 2 transfers (0 merges) — proving request merging +
# elevator ordering are real while the synchronous correctness path is
# byte-identical. Default boots omit the marker so it never fires.
if os.environ.get("ENABLE_BLK_SCHED_TEST") == "1":
    FILES.append(("/etc/blk-sched-test", b"1\n"))

# virtio-blk FLUSH / DISCARD / WRITE_ZEROES self-test.
# scripts/test_virtio_blk_dwz.sh sets ENABLE_VBLK_DWZ_TEST=1 to plant
# /etc/virtio-blk-dwz-test. init/main.ad at boot:37.vblkdwz detects the
# marker and calls virtio_blk_dwz_selftest() (drivers/block/virtio_blk.ad):
# it boots with a virtio-blk drive advertising discard/flush, then issues a
# REAL FLUSH (type 4), a REAL WRITE_ZEROES (type 13) + readback proving the
# region is zero, and a REAL DISCARD (type 11) — each with device status-byte
# checking. Default boots omit the marker so it never fires.
if os.environ.get("ENABLE_VBLK_DWZ_TEST") == "1":
    FILES.append(("/etc/virtio-blk-dwz-test", b"1\n"))

# Phase G: Plan 9 note-group WIDE delivery self-test. scripts/test_notepg.sh
# sets ENABLE_NOTEPG_TEST=1 to plant /etc/notepg-test. init/main.ad at
# boot:37.npg detects the marker and calls notegroup_selftest()
# (sys/src/9/port/sysnote.ad): it builds a controlled population of inert
# task slots (three live members in one note group, one member in a
# different group, one dead/STATE_EXITED member in the first group), runs
# the REAL post_note_to_group walk, and asserts the note was enqueued onto
# EXACTLY the three live group members while the cross-group witness and the
# dead member were skipped — proving the group fan-out + membership/liveness
# logic, which decides WHO receives a note posted to a note group. Default
# boots omit the marker so it never fires.
if os.environ.get("ENABLE_NOTEPG_TEST") == "1":
    FILES.append(("/etc/notepg-test", b"ENABLE_NOTEPG_TEST=1\n"))

# Plan 9 single-target (one pid) note delivery self-test.
# scripts/test_notepid.sh sets ENABLE_NOTEPID_TEST=1 to plant
# /etc/notepid-test. init/main.ad at boot:37.npid detects the marker and
# calls notepid_selftest() (sys/src/9/port/sysnote.ad): it claims two
# inert live task slots, stamps each a known distinct pid, posts a note to
# the FIRST pid via the REAL post_note_to_pid path (the same path
# /proc/<pid>/note cross-task writes now drive), and asserts the note was
# enqueued onto EXACTLY that one target while the non-target witness was
# skipped, the return value equals count, and a post to a non-existent pid
# honestly returns -ESRCH. Default boots omit the marker so it never fires.
if os.environ.get("ENABLE_NOTEPID_TEST") == "1":
    FILES.append(("/etc/notepid-test", b"1\n"))

# §3 deferred trap-return note drain self-test.
# scripts/test_notedrain.sh sets ENABLE_NOTEDRAIN_TEST=1 to plant
# /etc/notedrain-test. init/main.ad at boot:37.ndrain detects the marker
# and calls notedrain_selftest() (sys/src/9/port/sysnote.ad): it builds an
# RFNOTEG cohort (3 children in group A with installed handlers, 1
# witness in group B, 1 group-A child with no handler), runs the REAL
# post_note_to_group walker, then simulates each child's trap-return via
# the production _drain_slot primitive to PROVE the deferred-delivery hook
# fires correctly (saved-RIP retarget to handler; default-action arm
# returns NOTE_DRAIN_DEFAULT; cross-group witness is a NOP). Default
# boots omit the marker so it never fires.
if os.environ.get("ENABLE_NOTEDRAIN_TEST") == "1":
    FILES.append(("/etc/notedrain-test", b"1\n"))

# Real AHCI Native Command Queuing self-test. scripts/test_ahci_ncq.sh sets
# ENABLE_AHCI_NCQ_TEST=1 to plant /etc/ahci-ncq-test. init/main.ad at
# boot:37.ncq detects the marker and calls ahci_ncq_selftest()
# (drivers/ata/ahci.ad): it allocates a fresh command-list slot per read,
# submits SEVERAL reads of distinct LBAs back-to-back across INDEPENDENT CI
# bits without draining between them, watches the CI bits clear to detect
# which slots finished (recording the peak simultaneous in-flight count),
# and re-reads each LBA serially to verify the concurrently-fetched buffers
# hold the right sectors. Requires the test to attach a QEMU ich9-ahci disk.
# Default boots omit the marker so it never fires.
if os.environ.get("ENABLE_AHCI_NCQ_TEST") == "1":
    FILES.append(("/etc/ahci-ncq-test", b"ENABLE_AHCI_NCQ_TEST=1\n"))

# NCQ block-path self-test (this commit). scripts/test_ahci_ncq_blkpath.sh
# sets ENABLE_AHCI_NCQ_BLK_TEST=1 to plant /etc/ahci-ncq-blk-test.
# init/main.ad at boot:37.ncqb detects the marker and calls
# ahci_ncq_blkpath_selftest() (drivers/ata/ahci.ad): it proves the block-
# layer hot path routes through the new NCQ FPDMA QUEUED submit primitive
# + IRQ-driven completion + per-slot wait queues, and asserts multi-slot
# concurrency on a real SATA disk. Default boots omit the marker.
if os.environ.get("ENABLE_AHCI_NCQ_BLK_TEST") == "1":
    FILES.append(("/etc/ahci-ncq-blk-test", b"ENABLE_AHCI_NCQ_BLK_TEST=1\n"))

# AHCI generic block-layer round-trip self-test. scripts/test_ahci_blk.sh
# sets ENABLE_AHCI_BLK_TEST=1 to plant /etc/ahci-blk-test. init/main.ad at
# boot:37.ablk detects the marker and calls ahci_blk_selftest()
# (drivers/ata/ahci.ad): it resolves the AHCI port THROUGH the kernel block
# layer (find_blockdev("sd0")), writes a known pattern via the generic
# blk_write_sectors vtable dispatch (NOT ahci_write_sectors directly), reads
# it back via blk_read_sectors, and byte-compares — proving the AHCI port's
# register_blockdev() wiring lands ext4/fat-class block I/O on the real SATA
# disk. Requires the test to attach a QEMU ich9-ahci disk. Default boots omit
# the marker so it never fires.
if os.environ.get("ENABLE_AHCI_BLK_TEST") == "1":
    FILES.append(("/etc/ahci-blk-test", b"1\n"))

# virtio-9p (9P-over-virtio-PCI) end-to-end self-test. scripts/test_virtio9p.sh
# sets ENABLE_V9P_TEST=1 to plant /etc/v9p-test. init/main.ad at boot:37.v9p
# detects the marker and calls v9p_e2e_selftest(): it brings up the QEMU
# virtio-9p-pci device, runs the full 9P2000.u attach/walk/open/read handshake
# over the request virtqueue against a host-shared directory, enumerates the
# export root, and byte-compares a known hello.txt. Requires the test to attach
# a QEMU virtio-9p-pci device. Default boots omit the marker so it never fires.
if os.environ.get("ENABLE_V9P_TEST") == "1":
    FILES.append(("/etc/v9p-test", b"1\n"))

# AHCI TRIM + IDENTIFY/SMART maturity self-test. scripts/test_ahci_trim.sh
# sets ENABLE_AHCI_TRIM_TEST=1 to plant /etc/ahci-trim-test. init/main.ad at
# boot:37.atrim detects the marker and calls ahci_trim_selftest()
# (drivers/ata/ahci.ad): it issues IDENTIFY DEVICE (0xEC), decodes the
# 48-bit LBA capacity (words 100..103) + rotation rate (word 217 -> SSD
# detect), asserts the capacity matches the attached disk, then issues
# DATA SET MANAGEMENT / TRIM (0x06, feature 0x01) with a real LBA-range
# payload and verifies a correct completion-or-graceful-abort status (the
# driver reads the TFD.ERR bit if QEMU rejects TRIM/SMART). Requires the
# test to attach a QEMU ich9-ahci disk. Default boots omit the marker so it
# never fires.
if os.environ.get("ENABLE_AHCI_TRIM_TEST") == "1":
    FILES.append(("/etc/ahci-trim-test", b"1\n"))

# AHCI error-recovery + hot-plug + timeout maturity self-test.
# scripts/test_ahci_recovery.sh sets ENABLE_AHCI_RECOVERY_TEST=1 to plant
# /etc/ahci-recovery-test. init/main.ad at boot:37.arec detects the marker
# and calls ahci_recovery_selftest() (drivers/ata/ahci.ad): it drives the
# REAL port STOP -> error-register CLEAR -> COMRESET (PxSCTL.DET) -> RESTART
# error-recovery cycle, proves the disk is usable again via a post-recovery
# IDENTIFY + LBA read, and exercises the hot-plug-edge poll. Requires the
# test to attach a QEMU ich9-ahci disk. Default boots omit the marker so it
# never fires.
if os.environ.get("ENABLE_AHCI_RECOVERY_TEST") == "1":
    FILES.append(("/etc/ahci-recovery-test", b"1\n"))

# FAT12 mkfs formatter self-test. scripts/test_fat_mkfs.sh sets
# ENABLE_FAT_MKFS_TEST=1 to plant /etc/fat-mkfs-test. init/main.ad at
# boot:37.fmk detects the marker and calls fat_mkfs_selftest()
# (fs/fat_mkfs.ad): it formats the AHCI scratch disk registered as "sd0"
# with a fresh FAT12 volume via fat_mkfs(slot, 32), then reads the boot
# sector + first FAT sector back through the generic block layer and
# verifies the BPB fields (0x55AA signature, bytes/sector, sectors/
# cluster, FAT count, root entries, media byte, FS-type string) and the
# packed FAT[0]/FAT[1] seed bytes (0xF8 0xFF 0xFF). Requires the test to
# attach a QEMU ich9-ahci disk >= 32 MiB. Default boots omit the marker
# so it never fires.
if os.environ.get("ENABLE_FAT_MKFS_TEST") == "1":
    FILES.append(("/etc/fat-mkfs-test", b"1\n"))

# FAT16 mkfs formatter self-test. scripts/test_fat16_mkfs.sh sets
# ENABLE_FAT16_MKFS_TEST=1 to plant /etc/fat16-mkfs-test. init/main.ad at
# boot:37.fmk16 detects the marker and calls fat16_mkfs_selftest()
# (fs/fat_mkfs.ad): it formats the AHCI scratch disk registered as "sd0"
# with a 128 MiB volume (~8188 clusters -> FAT16) via fat_mkfs(slot, 128),
# then reads the boot sector + first FAT sector back through the generic
# block layer and verifies the BPB fields (0x55AA signature, bytes/sector,
# sectors/cluster, "FAT16   " FS-type string) and the 16-bit FAT[0]/FAT[1]
# seed (entry0 low byte 0xF8, entry1 0xFFFF). Requires the test to attach a
# QEMU ich9-ahci disk >= 128 MiB. Default boots omit the marker so it never
# fires.
if os.environ.get("ENABLE_FAT16_MKFS_TEST") == "1":
    FILES.append(("/etc/fat16-mkfs-test", b"1\n"))

# FAT32 mkfs formatter self-test. scripts/test_fat32_mkfs.sh sets
# ENABLE_FAT32_MKFS_TEST=1 to plant /etc/fat32-mkfs-test. init/main.ad at
# boot:37.fmk32 detects the marker and calls fat32_mkfs_selftest()
# (fs/fat_mkfs.ad): it formats the AHCI scratch disk registered as "sd0"
# with a 512 MiB volume (~131000 clusters at 4 KiB clusters -> FAT32) via
# fat_mkfs(slot, 512), then reads the boot sector + first FAT sector back
# through the generic block layer and verifies the FAT32 BPB fields
# (BPB_FATSz16==0, BPB_RootEntCnt==0, BPB_RootClus==2, "FAT32   " FS-type
# string) and the 32-bit FAT[0]/FAT[1]/FAT[2] seed (entry0 low byte 0xF8,
# entry1/entry2 low 28 bits all-ones). Requires the test to attach a QEMU
# ich9-ahci disk >= 512 MiB. Default boots omit the marker so it never
# fires.
if os.environ.get("ENABLE_FAT32_MKFS_TEST") == "1":
    FILES.append(("/etc/fat32-mkfs-test", b"1\n"))

# FAT directory cross-cluster growth self-test. scripts/test_fat_dirgrow.sh
# sets ENABLE_FAT_DIRGROW_TEST=1 to plant /etc/fat-dirgrow-test. init/main.ad
# at boot:37.dgr detects the marker and calls fat_dirgrow_selftest()
# (fs/fat.ad): it lays down a tiny FAT32 volume on the AHCI scratch disk
# registered as "sd0" with 512-byte clusters (16 dirents/cluster), creates
# 24 files in the root directory — forcing the root dirent region to grow
# past its first cluster into a freshly-allocated, chain-linked second
# cluster — then re-looks-up every file by name to prove entries in the
# grown cluster are reachable. Requires the test to attach a QEMU ich9-ahci
# disk. Default boots omit the marker so it never fires.
if os.environ.get("ENABLE_FAT_DIRGROW_TEST") == "1":
    FILES.append(("/etc/fat-dirgrow-test", b"1\n"))

# sysinfo(2) live-accounting self-test. scripts/test_sysinfo.sh sets
# ENABLE_SYSINFO_TEST=1 to plant /etc/sysinfo-test. init/main.ad at
# boot:37.sysi detects the marker and calls sysinfo_selftest()
# (linux_abi/u_syscalls.ad): it drives _u_sysinfo against a poisoned
# buffer and asserts mem_unit==1, totalram==page_alloc_total()*4096 (>0),
# 0 < freeram <= totalram, and procs>=1 — proving the struct sysinfo is
# filled from live kernel accounting, not hardcoded constants. Needs no
# block device. Default boots omit the marker so it never fires.
if os.environ.get("ENABLE_SYSINFO_TEST") == "1":
    FILES.append(("/etc/sysinfo-test", b"1\n"))

# Plan-9 namespace bind/mount/unmount self-test. scripts/test_bind.sh sets
# ENABLE_BIND_TEST=1 to plant /etc/bind-test plus two source directories
# of fixture files. init/main.ad at boot:37.bind detects the marker and
# calls bind_selftest() (sys/src/9/port/bind_test.ad): it binds one
# source dir onto a union name and resolves files THROUGH the name (proves
# the binding redirects the walk), unions a second dir over the first with
# MBEFORE (proves files from BOTH members are visible and the MBEFORE
# member shadows a shared name), unmounts (proves the binding reverts), and
# clones a fresh Pgrp to bind in isolation (proves a child-namespace bind
# is NOT visible in the parent's namespace). The two source trees:
#   /bind_src_a/onlyA.txt   = "AAA"      (only in A)
#   /bind_src_a/shared.txt  = "FROM-A"   (shared name, A copy)
#   /bind_src_b/onlyB.txt   = "BBB"      (only in B)
#   /bind_src_b/shared.txt  = "FROM-B"   (shared name, B copy)
# Default boots omit the marker so the self-test never fires.
if os.environ.get("ENABLE_BIND_TEST") == "1":
    FILES.append(("/etc/bind-test", b"ENABLE_BIND_TEST=1\n"))
    FILES.append(("/bind_src_a/onlyA.txt", b"AAA"))
    FILES.append(("/bind_src_a/shared.txt", b"FROM-A"))
    FILES.append(("/bind_src_b/onlyB.txt", b"BBB"))
    FILES.append(("/bind_src_b/shared.txt", b"FROM-B"))

# #149: ext4 JBD2 journal crash-consistency self-test. scripts/
# test_ext4_journal.sh sets ENABLE_EXT4_JOURNAL_TEST=1 to plant
# /etc/ext4-journal-test. init/main.ad detects the marker after the
# ext4 mount and calls ext4_journal_selftest() (fs/ext4.ad): it stages
# a metadata transaction, commits it to the journal, skips checkpoint
# to simulate a crash, replays, and asserts the committed change
# survives; then stages a torn (no-commit-block) transaction and
# asserts replay rolls it back. The self-test WRITES raw scratch fs
# blocks, so it must only run on the disposable journalled test image.
# Default boots omit the marker so it never fires unintentionally.
if os.environ.get("ENABLE_EXT4_JOURNAL_TEST") == "1":
    FILES.append(("/etc/ext4-journal-test", b"1\n"))

# Multi-block ext4 directory walk self-test. scripts/test_ext4dir.sh
# sets ENABLE_EXT4DIR_TEST=1 to plant /etc/ext4dir-test. init/main.ad
# detects the marker after the ext4 mount and calls ext4_dirmb_selftest()
# (fs/ext4.ad): it walks a host-minted /bigdir that spans several data
# blocks, asserting readdir enumerates EVERY block's entries (not just
# block 0) and that a file the host placed in the LAST block resolves by
# name and reads back correctly. Read-only, but it expects the special
# test image attached on virtio, so it is opt-in. Default boots omit the
# marker so it never fires unintentionally.
if os.environ.get("ENABLE_EXT4DIR_TEST") == "1":
    FILES.append(("/etc/ext4dir-test", b"1\n"))

# ext4 mkdir self-test. scripts/test_ext4_mkdir.sh sets
# ENABLE_EXT4_MKDIR_TEST=1 to plant /etc/ext4-mkdir-test. init/main.ad
# detects the marker after the ext4 mount and calls ext4_mkdir_selftest()
# (fs/ext4.ad): it mkdir's a real directory on the live ext4 mount via the
# wired vfs_mkdir -> ext4_mkdir_live path, then re-reads the parent dir to
# confirm the new entry exists DIR-typed. Writes to the mounted image, so
# it is opt-in. Default boots omit the marker so it never fires.
if os.environ.get("ENABLE_EXT4_MKDIR_TEST") == "1":
    FILES.append(("/etc/ext4-mkdir-test", b"1\n"))

# ext4 fs-verity (EXT4_VERITY_FL Merkle-tree authenticity) self-test.
# scripts/test_ext4_verity.sh sets ENABLE_EXT4_VERITY_TEST=1 to plant
# /etc/ext4-verity-test. init/main.ad detects the marker after the ext4
# mount and calls ext4_verity_selftest() (fs/ext4.ad): it builds a REAL
# multi-block file on the live ext4 mount, enables verity (salted SHA-256
# Merkle tree + trusted root), reads it back verified byte-identical, then
# proves tampering a data block AND a hash-tree node are both DETECTED
# (read fails EIO). Writes to the mounted image, so it is opt-in. Default
# boots omit the marker so it never fires.
if os.environ.get("ENABLE_EXT4_VERITY_TEST") == "1":
    FILES.append(("/etc/ext4-verity-test", b"1\n"))

# ext4 fscrypt (EXT4_ENCRYPT_FL per-file content encryption) self-test.
# scripts/test_ext4_fscrypt.sh sets ENABLE_EXT4_FSCRYPT_TEST=1 to plant
# /etc/ext4-fscrypt-test. init/main.ad detects the marker after the ext4
# mount and calls ext4_fscrypt_selftest() (fs/ext4.ad): it builds a REAL
# multi-block file on the live ext4 mount, sets an fscrypt policy (derives a
# per-file AES-256-XTS content key via HKDF-SHA256, sets EXT4_ENCRYPT_FL),
# writes a known plaintext ENCRYPTED to disk, then proves the file reads back
# byte-identical, the raw on-disk block is genuine ciphertext (not the
# plaintext), the XTS tweak (= logical block number) makes equal plaintext
# encrypt to different ciphertext, and the wrong key recovers only garbage.
# Writes to the mounted image, so it is opt-in. Default boots omit the marker
# so it never fires.
if os.environ.get("ENABLE_EXT4_FSCRYPT_TEST") == "1":
    FILES.append(("/etc/ext4-fscrypt-test", b"1\n"))

# ext4 fast_commit (COMPAT_FAST_COMMIT) self-test. scripts/
# test_ext4_fast_commit.sh sets ENABLE_EXT4_FC_TEST=1 to plant
# /etc/ext4-fc-test. init/main.ad detects the marker after the ext4
# mount and calls ext4_fast_commit_selftest() (fs/ext4.ad): it creates a
# file, records a NEW per-inode change (TAG_INODE + TAG_ADD_RANGE) into
# the journal's reserved fast-commit tail closed by a crc'd TAG_TAIL,
# proves the file still reads OLD (the fast path only wrote the fc log),
# replays the fc region to simulate crash recovery, and byte-compares
# the restored NEW body; it also proves a crc-corrupt fast-commit is
# rejected. WRITES the mounted image, so it must only run on the
# disposable fast_commit test image. Default boots omit the marker.
if os.environ.get("ENABLE_EXT4_FC_TEST") == "1":
    FILES.append(("/etc/ext4-fc-test", b"1\n"))

# ext4 cross-directory directory-rename self-test.
# scripts/test_ext4_dirrename.sh sets ENABLE_EXT4DIRRENAME_TEST=1 to plant
# /etc/ext4dirrename-test. init/main.ad detects the marker after the ext4
# mount and calls ext4_dirrename_selftest() (fs/ext4.ad): it moves a
# sub-directory to a different parent and asserts the moved dir's ".." is
# rewritten to the new parent inode AND both parents' i_links_count are
# rebalanced (old parent -1, new parent +1), while a same-parent rename
# leaves link counts and ".." untouched. Writes to the mounted image, so
# it is opt-in. Default boots omit the marker so it never fires.
if os.environ.get("ENABLE_EXT4DIRRENAME_TEST") == "1":
    FILES.append(("/etc/ext4dirrename-test", b"1\n"))

# ext4 slow-symlink self-test. scripts/test_ext4_symlink.sh sets
# ENABLE_EXT4_SYMLINK_TEST=1 to plant /etc/ext4-symlink-test. init/main.ad
# detects the marker after the ext4 mount and calls ext4_symlink_selftest()
# (fs/ext4.ad): it creates a symlink whose target exceeds 60 bytes (forcing
# the slow path: a data block recorded as a depth-0 extent) plus a short
# (<=60-byte) symlink (the fast inline path), then reads both targets back
# via _ext4_read_symlink_target and compares them byte-for-byte against
# what was written. Writes to the mounted image, so it is opt-in. Default
# boots omit the marker so it never fires.
if os.environ.get("ENABLE_EXT4_SYMLINK_TEST") == "1":
    FILES.append(("/etc/ext4-symlink-test", b"1\n"))

# Per-backend fstat metadata self-test. scripts/test_fstat_backend.sh sets
# ENABLE_FSTAT_BACKEND_TEST=1 to plant /etc/fstat-backend-test. init/main.ad
# detects the marker after the ext4 mount and calls fstat_backend_selftest()
# (sys/src/9/port/sysfile.ad): it writes a known-length file on tmpfs and on
# the live ext4 mount, fstat's each fd, and asserts the returned Dir-record
# length matches the bytes written — proving do_fstat now returns real
# per-backend metadata instead of "backend not supported". Writes to the
# mounted ext4 image, so it is opt-in. Default boots omit the marker.
if os.environ.get("ENABLE_FSTAT_BACKEND_TEST") == "1":
    FILES.append(("/etc/fstat-backend-test", b"1\n"))

# wstat chmod/truncate round-trip self-test. scripts/test_p9wstat_ext4.sh sets
# ENABLE_WSTAT_APPLY_TEST=1 to plant /etc/wstat-apply-test. init/main.ad detects
# the marker after the ext4 mount and calls wstat_apply_selftest()
# (sys/src/9/port/sysfile.ad): it creates an ext4 file, drives do_wstat with the
# mode (chmod) + length (truncate) legs, and asserts the inode mode and file
# size round-trip through wstat. Writes to the mounted ext4 image, so it is
# opt-in. Default boots omit the marker.
if os.environ.get("ENABLE_WSTAT_APPLY_TEST") == "1":
    FILES.append(("/etc/wstat-apply-test", b"1\n"))

# tmpfs symlink + hard-link self-test. scripts/test_tmpfs_link.sh sets
# ENABLE_TMPFS_LINK_TEST=1 to plant /etc/tmpfs-link-test. init/main.ad's
# boot:37.tln hook detects the marker and calls tmpfs_link_selftest()
# (fs/vfs.ad): it creates a tmpfs file with known contents, a tmpfs
# symlink to it (verifying open-follow reads the file), a tmpfs hard link
# (verifying both names read the same data), then unlinks names one at a
# time to prove the per-slot link count keeps the storage alive until the
# last name is gone. RAM-backed only — no disk, so it always runs once the
# marker is present. Default boots omit the marker.
if os.environ.get("ENABLE_TMPFS_LINK_TEST") == "1":
    FILES.append(("/etc/tmpfs-link-test", b"1\n"))

# cgroup v2 (/sys/fs/cgroup) end-to-end self-test. scripts/test_cgroup2.sh
# sets ENABLE_CGROUP2_TEST=1 to plant /etc/cgroup2-test. init/main.ad's
# boot:37.cg2 hook detects the marker and calls cgroup2_vfs_selftest()
# (fs/vfs.ad): it open()/read()s the Linux-namespace cgroup2 interface
# files (cgroup.controllers, cgroup.procs, memory.current, pids.max,
# cgroup.type) through the real VFS dispatch and asserts their structural
# shape. Render-on-open only — no disk — so it always runs once the marker
# is present. Default boots omit the marker.
if os.environ.get("ENABLE_CGROUP2_TEST") == "1":
    FILES.append(("/etc/cgroup2-test", b"1\n"))

# F11 (2026-06-13) cgroup v2 cpu.max ENFORCEMENT self-test.
# scripts/test_cgroup_cpu_max.sh sets ENABLE_CGROUP_CPU_TEST=1 to plant
# /etc/cgroup-cpu-max-test. init/main.ad's boot:37.cgcpu hook detects
# the marker and calls cgroup_cpu_selftest() (kernel/sched/cgroup_cpu.ad)
# which exercises the real enforcement path: mkdir g1, write
# cpu.max "50000 100000" (50% of one CPU), attach a task, and drive
# 200 simulated ring-3 timer ticks through the same refill+charge+
# should-throttle calls the timer ISR and _pick_next() use on a real
# running user task. Asserts the task got ~50% of CPU ticks (within
# ±10 of 100) — i.e. cpu.max actually gated CPU consumption, not just
# rendered a file. Default boots omit the marker.
if os.environ.get("ENABLE_CGROUP_CPU_TEST") == "1":
    FILES.append(("/etc/cgroup-cpu-max-test", b"1\n"))

# scripts/test_cgroup_v2_enforce.sh sets ENABLE_CGROUP_ENFORCE_TEST=1 to
# plant /etc/cgroup-enforce-test. init/main.ad's boot:37.cgenf hook runs
# cgroup_enforce_selftest() (pids.max rejects the 3rd fork; memory.max
# bounds memory.current) AND cgroup_mem_enforce_selftest() (an over-cap
# charge drives reclaim then the cgroup OOM path -> -ENOMEM). These drive
# the SAME accounting entry points do_clone/task_reap (pids) and the
# demand-fault memcg hook (memory) hit on real fork/exit/page-fault.
if os.environ.get("ENABLE_CGROUP_ENFORCE_TEST") == "1":
    FILES.append(("/etc/cgroup-enforce-test", b"1\n"))

# §fuse: /dev/fuse + FUSE wire-protocol READ round-trip. scripts/test_fuse.sh
# sets ENABLE_FUSE_TEST=1 to plant /etc/fuse-test. init/main.ad's boot:37.fuse
# hook detects the marker and calls fuse_selftest() (linux_abi/u_fuse.ad): it
# stands up an in-kernel FUSE daemon role serving one file "hello" ==
# "FUSE-OK\n", opens a /dev/fuse connection, runs the FUSE_INIT handshake,
# mounts at /fuse, then drives LOOKUP+GETATTR+OPEN+READ+RELEASE over the
# genuine fuse_in/fuse_out header protocol across the real cdev and asserts the
# bytes. No disk needed. Default boots omit the marker so the self-test never
# fires.
if os.environ.get("ENABLE_FUSE_TEST") == "1":
    FILES.append(("/etc/fuse-test", b"1\n"))

# statfs(2)/fstatfs(2) capacity self-test. scripts/test_statfs.sh sets
# ENABLE_STATFS_TEST=1 to plant /etc/statfs-test. init/main.ad at
# boot:37.sfs detects the marker after the ext4 mount and calls
# statfs_selftest() (linux_abi/u_syscalls.ad): it drives _u_statfs through
# the real Linux-ABI dispatch on the live ext4 mount (/ext) and on the
# synthetic root (/), asserting a non-zero block size + total-block count
# and the EXT4 magic (the REAL superblock geometry df reports), then drives
# _u_fstatfs on an open tmpfs fd (TMPFS magic) and a bad fd (-EBADF).
# Needs a real ext4 device attached, so it is opt-in; default boots omit
# the marker so the self-test never fires.
if os.environ.get("ENABLE_STATFS_TEST") == "1":
    FILES.append(("/etc/statfs-test", b"1\n"))

# getrusage(2) CPU-time self-test. scripts/test_rusage.sh sets
# ENABLE_RUSAGE_TEST=1 to plant /etc/rusage-test. init/main.ad at
# boot:37.ru detects the marker and calls rusage_selftest()
# (linux_abi/u_syscalls.ad): it lets the timer ISR accrue a few system
# ticks to the boot task, then drives _u_getrusage and asserts ru_stime
# advanced (real per-task CPU-time accounting) and the unsupported tail
# stayed zeroed. Needs no extra device; default boots omit the marker.
if os.environ.get("ENABLE_RUSAGE_TEST") == "1":
    FILES.append(("/etc/rusage-test", b"1\n"))

# /proc/<pid>/stat CPU-time self-test. scripts/test_procstat_cpu.sh sets
# ENABLE_PROCSTAT_CPU_TEST=1 to plant /etc/procstat-cpu-test. init/main.ad
# at boot:37.pscpu detects the marker and calls procstat_cpu_selftest()
# (sys/src/9/port/devproc.ad): it lets the timer ISR accrue a few system
# ticks to the boot task, renders _emit_linux_stat for the boot slot, and
# asserts /proc/<pid>/stat field 15 (stime) is the real tick count, not 0.
# Needs no extra device; default boots omit the marker.
if os.environ.get("ENABLE_PROCSTAT_CPU_TEST") == "1":
    FILES.append(("/etc/procstat-cpu-test", b"1\n"))

# /proc/stat per-IRQ-column self-test. scripts/test_procstat_intr.sh sets
# ENABLE_PROCSTAT_INTR_TEST=1 to plant /etc/procstat-intr-test. init/main.ad
# at boot:37.psintr detects the marker and calls procstat_intr_selftest()
# (sys/src/9/port/devstat.ad): it lets the timer ISR bump the IRQ0 (vector
# 32) per-vector count, renders /proc/stat into a local buffer, and asserts
# the first per-IRQ column (right after the total) is the real non-zero
# timer count, not the old hardcoded 0. Needs no extra device; default
# boots omit the marker.
if os.environ.get("ENABLE_PROCSTAT_INTR_TEST") == "1":
    FILES.append(("/etc/procstat-intr-test", b"1\n"))

# Per-task page-fault accounting self-test. scripts/test_pgfault.sh sets
# ENABLE_PGFAULT_TEST=1 to plant /etc/pgfault-test. init/main.ad at
# boot:37.pgf detects the marker and calls pgfault_selftest()
# (linux_abi/u_syscalls.ad): it charges 3 minor + 2 major faults via the
# same helpers the page-fault handler drives, asserts the read accessors
# and getrusage's ru_minflt (0x40) / ru_majflt (0x48) rose to match, then
# emits the [PGFAULT] PASS banner. Needs no extra device; default boots
# omit the marker.
if os.environ.get("ENABLE_PGFAULT_TEST") == "1":
    FILES.append(("/etc/pgfault-test", b"1\n"))

# Context-switch accounting self-test. scripts/test_ctxsw.sh sets
# ENABLE_CTXSW_TEST=1 to plant /etc/ctxsw-test. init/main.ad at
# boot:37.ctx detects the marker and calls ctxsw_selftest()
# (linux_abi/u_syscalls.ad): it charges 2 voluntary + 3 involuntary
# switches via the same slot-indexed helpers schedule() drives, asserts the
# read accessors and getrusage's ru_nvcsw (0x80) / ru_nivcsw (0x88) rose to
# match, then emits the [CTXSW] PASS banner. Needs no extra device; default
# boots omit the marker.
if os.environ.get("ENABLE_CTXSW_TEST") == "1":
    FILES.append(("/etc/ctxsw-test", b"1\n"))

# Block-I/O accounting self-test. scripts/test_blkio.sh sets
# ENABLE_BLKIO_TEST=1 to plant /etc/blkio-test. init/main.ad at
# boot:37.blkio detects the marker and calls blkio_selftest()
# (linux_abi/u_syscalls.ad): it charges 8 block reads + 4 block writes via
# the same helpers the block layer drives at the I/O completion site,
# asserts the read accessors and getrusage's ru_inblock (0x58) /
# ru_oublock (0x60) rose to match, then emits the [BLKIO] PASS banner.
# Needs no extra device; default boots omit the marker.
if os.environ.get("ENABLE_BLKIO_TEST") == "1":
    FILES.append(("/etc/blkio-test", b"1\n"))

# Signal-delivery accounting self-test. scripts/test_nsignals.sh sets
# ENABLE_NSIGNALS_TEST=1 to plant /etc/nsignals-test. init/main.ad at
# boot:37.nsignals detects the marker and calls nsignals_selftest()
# (linux_abi/u_syscalls.ad): it charges 5 delivered signals via the same
# slot-indexed helper signal_post drives at the latch site, asserts the
# read accessor and getrusage's ru_nsignals (0x78) rose to match, then
# emits the [NSIGNALS] PASS banner. Needs no extra device; default boots
# omit the marker.
if os.environ.get("ENABLE_NSIGNALS_TEST") == "1":
    FILES.append(("/etc/nsignals-test", b"1\n"))

# getrusage(2) RUSAGE_CHILDREN self-test. scripts/test_ruchild.sh sets
# ENABLE_RUCHILD_TEST=1 to plant /etc/ruchild-test. init/main.ad detects the
# marker and calls ruchild_selftest() (linux_abi/u_syscalls.ad): it seeds the
# boot task's child accumulators (cutime/cstime/cminflt/cmajflt) with known
# sentinels, calls _u_getrusage with who=RUSAGE_CHILDREN, asserts the child
# counters land in ru_utime/ru_stime/ru_minflt/ru_majflt, then emits the
# [RUCHILD] PASS banner. Default boots omit the marker.
if os.environ.get("ENABLE_RUCHILD_TEST"):
    FILES.append(("/etc/ruchild-test", b"1\n"))

# getrlimit/setrlimit/prlimit64 round-trip self-test. scripts/test_rlimit.sh
# sets ENABLE_RLIMIT_TEST=1 to plant /etc/rlimit-test. init/main.ad detects
# the marker and calls rlimit_selftest() (linux_abi/u_syscalls.ad): it SETs
# RLIMIT_NOFILE via prlimit64, GETs it back to prove the real per-task store
# persisted, verifies the seeded 8 MiB RLIMIT_STACK default, then emits the
# [RLIMIT] PASS banner. Default boots omit the marker.
if os.environ.get("ENABLE_RLIMIT_TEST"):
    FILES.append(("/etc/rlimit-test", b"1\n"))

# capget(2)/capset(2) round-trip self-test. scripts/test_caps.sh sets
# ENABLE_CAPS_TEST=1 to plant /etc/caps-test. init/main.ad detects the marker
# and calls caps_selftest() (linux_abi/u_caps.ad): it version-probes capget,
# reads the seeded full cap set, DROPs CAP_NET_RAW via capset and proves the
# real per-task cap store persisted it, then asserts re-adding a permitted bit
# is rejected with EPERM, and emits the [CAPS] PASS banner. Default boots omit
# the marker.
if os.environ.get("ENABLE_CAPS_TEST"):
    FILES.append(("/etc/caps-test", b"1\n"))

# perf_event_open(2) software-counter self-test. scripts/test_perf.sh sets
# ENABLE_PERF_TEST=1 to plant /etc/perf-test. init/main.ad at boot:37.perf
# detects the marker and calls do_perf_selftest() (linux_abi/u_perf.ad): it
# opens disabled PERF_COUNT_SW_TASK_CLOCK + PERF_COUNT_SW_CONTEXT_SWITCHES
# events backed by the REAL per-task accumulators (utime/stime ticks,
# nvcsw/nivcsw), ENABLEs them, does measurable work (touch fresh pages + a
# yield loop), reads them and asserts they advanced, then RESETs and asserts
# the next read dropped toward zero, and emits the [perf] PASS banner. Default
# boots omit the marker.
if os.environ.get("ENABLE_PERF_TEST"):
    FILES.append(("/etc/perf-test", b"1\n"))

# Kernel keyring round-trip self-test. scripts/test_keyring.sh sets
# ENABLE_KEYRING_TEST=1 to plant /etc/keyring-test. init/main.ad at
# boot:37.keyring detects the marker and calls keyring_selftest()
# (linux_abi/u_keyring.ad): it add_keys a "user" key with a known payload,
# KEYCTL_READs it back byte-for-byte, KEYCTL_UPDATEs and re-reads,
# request_key/KEYCTL_SEARCH finds it (a bogus description -> ENOKEY),
# LINK/UNLINKs across the per-user keyring, then KEYCTL_REVOKEs and asserts a
# later READ returns EKEYREVOKED, emitting the [keyring] PASS banner. Default
# boots omit the marker.
if os.environ.get("ENABLE_KEYRING_TEST"):
    FILES.append(("/etc/keyring-test", b"1\n"))

# futex_waitv(2) (nr 449) wait-on-vector self-test. scripts/test_futexv.sh sets
# ENABLE_FUTEXV_TEST=1 to plant /etc/futexv-test. init/main.ad at boot:37.futexv
# detects the marker and calls futexv_selftest() (linux_abi/u_futexv.ad): it
# builds a 2-element waiters array over two real futex words, asserts the
# enqueue value-mismatch fast path returns -EAGAIN, drives the multi-uaddr
# park/unwind path against the real futex wait table, and rejects bad
# flags/nr/size/reserved/null input with EINVAL, emitting the [futexv] PASS
# banner. Default boots omit the marker.
if os.environ.get("ENABLE_FUTEXV_TEST"):
    FILES.append(("/etc/futexv-test", b"1\n"))

# ENABLE_PIDFD_GETFD_TEST=1 to plant /etc/pidfd-getfd-test. init/main.ad at
# boot:37.pidfd_getfd detects the marker and calls pidfd_getfd_selftest()
# (linux_abi/u_pidfd_getfd.ad): it opens a real file fd, derives a pidfd to
# self, getfd's the fd into a new caller slot, asserts the two slots share one
# backing object (the cross-process dup is real — marker + fd_buf identical and
# the duplicate survives closing the source), then drives the
# flags!=0/non-pidfd/closed-targetfd error paths, emitting the [pidfd-getfd]
# PASS banner. Default boots omit the marker.
if os.environ.get("ENABLE_PIDFD_GETFD_TEST"):
    FILES.append(("/etc/pidfd-getfd-test", b"1\n"))

# cachestat(2) (nr 451) page-cache residency self-test. scripts/test_cachestat.sh
# sets ENABLE_CACHESTAT_TEST=1 to plant /etc/cachestat-test (the gate marker)
# AND /etc/cachestat-data (the backing file the test maps). init/main.ad at
# boot:37.cachestat detects the marker and calls cachestat_selftest()
# (linux_abi/u_cachestat.ad): it maps /etc/cachestat-data into a file-backed
# VMA, opens an fd to it, asserts cachestat's nr_cache is 0 before any page is
# faulted, equals the page count after the populator faults the pages in, and is
# clamped for a sub-range query, then drives the flags!=0/bad-pointer/closed-fd
# error paths, emitting the [cachestat] PASS banner. The 4-page data file lets
# the test cover multi-page residency and a sub-range query. Default boots omit
# both files.
if os.environ.get("ENABLE_CACHESTAT_TEST"):
    FILES.append(("/etc/cachestat-test", b"1\n"))
    _cs_len = 4 * 4096
    _cs_data = bytes(((i * 31 + 7) & 0xFF) for i in range(_cs_len))
    FILES.append(("/etc/cachestat-data", _cs_data))

# ENABLE_PROCESS_VM_TEST=1 to plant /etc/process-vm-test. init/main.ad at
# boot:37.process_vm detects the marker and calls process_vm_selftest()
# (linux_abi/u_process_vm.ad): it builds a real SECOND address space (a fresh
# task slot with a distinct PML4), stamps a known pattern into a remote page at
# a non-identity vaddr, then drives the REAL process_vm_readv/writev path
# (pid lookup -> remote page-table walk) and asserts the cross-address-space
# transfer is byte-exact in both directions, plus the short-read / -EFAULT /
# -ESRCH / -EINVAL / scatter-gather boundary behaviours, emitting the
# [process_vm] PASS banner. Default boots omit the marker.
if os.environ.get("ENABLE_PROCESS_VM_TEST"):
    FILES.append(("/etc/process-vm-test", b"1\n"))

# process_madvise(2) (nr 440) cross-process advice self-test.
# scripts/test_process_madvise.sh sets ENABLE_PROCESS_MADVISE_TEST=1 to plant
# /etc/process-madvise-test. init/main.ad at boot:37.process_madvise detects the
# marker and calls process_madvise_selftest() (linux_abi/u_process_madvise.ad):
# it builds a real SECOND task, maps a known page in it, stamps a non-zero
# pattern, then drives the REAL process_madvise(MADV_DONTNEED) path via a pidfd
# to the target and asserts the target's page reads back ALL ZERO — the
# observable cross-process effect — plus the -EINVAL / -EBADF / -ESRCH
# boundaries, emitting the [process_madvise] PASS banner. Default boots omit it.
if os.environ.get("ENABLE_PROCESS_MADVISE_TEST"):
    FILES.append(("/etc/process-madvise-test", b"1\n"))

# mseal(2) (nr 462) memory-seal self-test. scripts/test_mseal.sh sets
# ENABLE_MSEAL_TEST=1 to plant /etc/mseal-test. init/main.ad at boot:37.mseal
# detects the marker and calls umseal_selftest() (linux_abi/u_mseal.ad): it
# mmaps a sealed + an unsealed anonymous region, mseal()s the first, then
# asserts mprotect/munmap/mremap/madvise(DONTNEED) on the sealed region all
# return -EPERM while the unsealed region still allows them, emitting the
# [mseal] PASS banner. Default boots omit the marker.
if os.environ.get("ENABLE_MSEAL_TEST"):
    FILES.append(("/etc/mseal-test", b"1\n"))

# name_to_handle_at(2)/open_by_handle_at(2) (nr 303/304) round-trip self-test.
# scripts/test_fhandle.sh sets ENABLE_FHANDLE_TEST=1 to plant /etc/fhandle-test
# (the self-test opens THIS very file by handle). init/main.ad at
# boot:37.fhandle detects the marker and calls fhandle_selftest()
# (linux_abi/u_fhandle.ad): it opens the file the normal way + notes its inode
# and first bytes, name_to_handle_at()s it to an opaque struct file_handle,
# then open_by_handle_at()s that handle (no path) and asserts the new fd has
# the SAME inode and reads back identical bytes, emitting the [fhandle] PASS
# banner. Default boots omit the marker.
if os.environ.get("ENABLE_FHANDLE_TEST"):
    FILES.append(("/etc/fhandle-test", b"fhandle round-trip test fixture\n"))

# bpf(2) eBPF interpreter + map/prog self-test. scripts/test_bpf.sh sets
# ENABLE_BPF_TEST=1 to plant /etc/bpf-test. init/main.ad detects the marker and
# calls bpf_selftest() (linux_abi/u_bpf.ad): it creates real HASH + ARRAY maps
# and round-trips key->value bytes, PROG_LOADs + TEST_RUNs a real eBPF program
# computing ctx[0]+ctx[1] (asserting the exact sum 1337) plus a stack STX/LDX
# round-trip, and asserts three deliberately invalid programs are rejected
# (no-EXIT/bad-register -> EINVAL, OOB-stack store -> EACCES), emitting the
# [bpf] PASS banner. Default boots omit the marker.
if os.environ.get("ENABLE_BPF_TEST"):
    FILES.append(("/etc/bpf-test", b"1\n"))

# userfaultfd(2) demand-paging-in-userspace self-test. scripts/test_userfaultfd.sh
# sets ENABLE_USERFAULTFD_TEST=1 to plant /etc/userfaultfd-test. init/main.ad at
# boot:37.userfaultfd detects the marker and calls userfaultfd_selftest()
# (linux_abi/u_userfaultfd.ad): it creates a uffd, runs the UFFDIO_API handshake,
# mmaps an anonymous demand region and UFFDIO_REGISTERs it for missing faults,
# simulates a fault (the do_page_fault hook claims it and enqueues a
# UFFD_EVENT_PAGEFAULT uffd_msg, suppressing demand-zero), reads the uffd_msg,
# UFFDIO_COPYs known bytes into the faulted page through the real mm mapping path
# (elf_map_one_page) and reads the page back byte-exact, plus a UFFDIO_ZEROPAGE
# page that reads back all-zero, emitting the [userfaultfd] PASS banner. Default
# boots omit the marker.
if os.environ.get("ENABLE_USERFAULTFD_TEST"):
    FILES.append(("/etc/userfaultfd-test", b"1\n"))

# adjtimex(2)/clock_adjtime(2) NTP clock-discipline self-test.
# scripts/test_adjtimex.sh sets ENABLE_ADJTIMEX_TEST=1 to plant
# /etc/adjtimex-test. init/main.ad at boot:37.adjtimex detects the marker and
# calls adjtimex_selftest() (linux_abi/u_adjtimex.ad): it reads the nominal
# discipline state, rejects an out-of-range freq / unknown modes bit /
# non-realtime clock_adjtime with EINVAL, applies a +100 ppm frequency skew and
# proves a FIXED raw monotonic-ns comes out larger through the realtime read
# hook, applies a MOD_OFFSET single-shot and proves a CLOCK_REALTIME read moved
# by exactly the applied amount, and stores + bounds-checks a tick adjustment,
# emitting the [adjtimex] PASS banner. Default boots omit the marker.
if os.environ.get("ENABLE_ADJTIMEX_TEST"):
    FILES.append(("/etc/adjtimex-test", b"1\n"))
# Hi-res timer subsystem self-test. scripts/test_hrtimer.sh sets
# ENABLE_HRTIMER_TEST=1 to plant /etc/hrtimer-test. init/main.ad at
# boot:16.time detects the marker and calls hrtimer_selftest()
# (kernel/time/timer_selftest.ad): it proves a clocksource is selected +
# monotonic, a hrtimer fires sub-tick (<10 ms, not jiffies-quantized), a
# 1 ms sleep takes ~1 ms, NO_HZ stops the tick on idle + accounts skipped
# jiffies on wake, and a POSIX CLOCK_PROCESS_CPUTIME_ID timer fires at its
# CPU-time threshold. Default boots omit the marker.
if os.environ.get("ENABLE_HRTIMER_TEST"):
    FILES.append(("/etc/hrtimer-test", b"1\n"))
# Bounded-wait hrtimer-timeout self-test. scripts/test_wqtimeout.sh sets
# ENABLE_WQTIMEOUT_TEST=1 to plant /etc/wqtimeout-test. init/main.ad at
# boot:37 detects the marker and calls wq_timeout_hrtimer_selftest()
# (kernel/sched/core.ad): it proves the native bounded wait
# (wq_wait_commit_timeout) now times out on the ns clocksource with jiffies
# FROZEN — the class the old jiffies-poll deadline silently failed under
# NO_HZ idle / early boot. Default boots omit the marker.
if os.environ.get("ENABLE_WQTIMEOUT_TEST"):
    FILES.append(("/etc/wqtimeout-test", b"1\n"))
# NUMA mempolicy round-trip self-test. scripts/test_mempolicy.sh sets
# ENABLE_MEMPOLICY_TEST=1 to plant /etc/mempolicy-test. init/main.ad detects
# the marker and calls mempolicy_selftest() (linux_abi/u_mempolicy.ad): it
# round-trips BIND/INTERLEAVE through the per-task store, mmaps a real range
# and mbinds it, asserts a foreign-node mask is rejected EINVAL and that
# MPOL_F_MEMS_ALLOWED reflects node 0, then reads /sys/devices/system/node/
# online through the VFS path and asserts "0", emitting the [mempolicy] PASS
# banner. Default boots omit the marker.
if os.environ.get("ENABLE_MEMPOLICY_TEST"):
    FILES.append(("/etc/mempolicy-test", b"1\n"))
# quotactl(2) disk-quota round-trip self-test. scripts/test_quota.sh sets
# ENABLE_QUOTA_TEST=1 to plant /etc/quota-test. init/main.ad detects the marker
# and calls quota_selftest() (linux_abi/u_quota.ad): it Q_QUOTAONs a fs,
# Q_SETQUOTA/Q_GETQUOTA round-trips a dqblk byte-exact, Q_SETINFO/Q_GETINFO
# round-trips grace times, Q_QUOTAOFF makes a subsequent Q_GETQUOTA observe
# ESRCH, and a bad cmd/type/special is rejected EINVAL/ENODEV, emitting the
# [quota] PASS banner. Default boots omit the marker.
if os.environ.get("ENABLE_QUOTA_TEST"):
    FILES.append(("/etc/quota-test", b"1\n"))

# fchmodat2(2) (nr 452) self-test. scripts/test_fchmodat2.sh sets
# ENABLE_FCHMODAT2_TEST=1 to plant /etc/fchmodat2-test, which is BOTH the boot
# marker AND the real openable file fchmodat2_selftest() (linux_abi/u_fchmodat2.ad)
# chmods: it chmods the path with flags=0 and AT_SYMLINK_NOFOLLOW (both -> 0),
# a missing path -> ENOENT, an unsupported flag -> EINVAL, AT_EMPTY_PATH on the
# open fd -> 0, and off-fd AT_EMPTY_PATH -> EBADF, emitting [fchmodat2] PASS.
# Default boots omit the marker.
if os.environ.get("ENABLE_FCHMODAT2_TEST"):
    FILES.append(("/etc/fchmodat2-test", b"1\n"))

# Landlock LSM round-trip + open-enforcement self-test. scripts/test_landlock.sh
# sets ENABLE_LANDLOCK_TEST=1 to plant /etc/landlock-test plus two REAL files:
# /etc/landlock-allowed/data (under the allowed dir) and /etc/landlock-denied/
# data (exists, but NOT under the allowed dir). init/main.ad detects the marker
# and calls landlock_selftest() (linux_abi/u_syscalls.ad -> u_landlock.ad): it
# probes the ABI version, rejects a malformed create attr EINVAL, builds a
# ruleset allowing READ under /etc/landlock-allowed and restricts self, then
# drives REAL opens through the dispatch — an open under the allowed dir
# SUCCEEDS while an open of the existing /etc/landlock-denied/data is DENIED
# -EACCES, proving the per-task ruleset genuinely gates open(). The denied file
# really exists, so the EACCES is the ruleset, not ENOENT. Default boots omit
# all three.
if os.environ.get("ENABLE_LANDLOCK_TEST"):
    FILES.append(("/etc/landlock-test", b"1\n"))
    FILES.append(("/etc/landlock-allowed/data", b"allowed\n"))
    FILES.append(("/etc/landlock-denied/data", b"denied\n"))

# getpriority(2)/setpriority(2) round-trip self-test. scripts/test_priosys.sh
# sets ENABLE_PRIOSYS_TEST=1 to plant /etc/priosys-test. init/main.ad detects
# the marker and calls priority_syscall_selftest() (linux_abi/u_syscalls.ad):
# it SETs nice=5 via setpriority, asserts the real per-task nice store took
# it, GETs it back via getpriority (biased 20-nice ABI form == 15), restores
# the saved nice, then emits the [PRIOSYS] PASS banner. Default boots omit it.
if os.environ.get("ENABLE_PRIOSYS_TEST"):
    FILES.append(("/etc/priosys-test", b"1\n"))

# vsize/rss + ru_maxrss self-test. scripts/test_vmstat.sh sets
# ENABLE_VMSTAT_TEST=1 to plant /etc/vmstat-test. init/main.ad at
# boot:37.vmstat detects the marker and calls vmstat_selftest()
# (linux_abi/u_syscalls.ad): it walks the boot task's VMAs on demand to
# compute /proc/<pid>/stat field 23 (vsize, bytes) and field 24 (rss,
# pages), then drives getrusage and asserts ru_maxrss (0x20) is >= the
# current rss in KB, then emits the [VMSTAT] PASS banner. Needs no extra
# device; default boots omit the marker.
if os.environ.get("ENABLE_VMSTAT_TEST") == "1":
    FILES.append(("/etc/vmstat-test", b"1\n"))

# Page-allocator allocation tracking (--track-allocs) self-test.
# scripts/test_track_allocs.sh sets ENABLE_TRACK_ALLOCS_TEST=1 to plant
# /etc/trkalloc-test. init/main.ad at boot:37.trkalloc detects the marker
# and calls track_allocs_selftest() (sys/src/9/port/devmeminfo.ad): it
# arms the tracker through the real `echo 'track on' > /proc/meminfo` ctl
# path, proves per-site stamp/unstamp accounting, and proves the
# default-off guarantee (no tracker bytes in the blob, no counter
# movement). Emits the [TRKALLOC] PASS banner. Default boots omit it.
if os.environ.get("ENABLE_TRACK_ALLOCS_TEST") == "1":
    FILES.append(("/etc/trkalloc-test", b"1\n"))

# /proc/<pid>/statm self-test. scripts/test_statm.sh sets
# ENABLE_STATM_TEST=1 to plant /etc/statm-test. init/main.ad detects the
# marker and calls statm_selftest() (linux_abi/u_syscalls.ad): it builds
# a demand-paged anonymous VMA, faults its pages in, renders the statm
# line via the PUBLIC emit_statm, parses fields 1 (size = vsize/4096) and
# 2 (resident = present pages), cross-checks them against the on-demand
# VMA helpers, and emits the [STATM] PASS banner. Needs no extra device;
# default boots omit the marker.
if os.environ.get("ENABLE_STATM_TEST") == "1":
    FILES.append(("/etc/statm-test", b"1\n"))

# /proc/self/maps open self-test (Firefox blocker #2). scripts/test_maps.sh
# sets ENABLE_MAPS_TEST=1 to plant /etc/maps-test. init/main.ad detects the
# marker and calls maps_open_selftest() (linux_abi/u_syscalls.ad): it builds a
# demand-paged VMA + synthesizes a main-thread user-stack range, then drives
# the REAL userspace vfs_open("/proc/self/maps") path a Debian ELF's openat
# takes (resolve_path -> #p/self/maps -> devproc KIND_MAPS -> vma_maps_render),
# reads the map, and asserts it opened and carries an address-range line AND
# the [stack] line glibc's pthread_getattr_np needs. Default boots omit it.
if os.environ.get("ENABLE_MAPS_TEST") == "1":
    FILES.append(("/etc/maps-test", b"1\n"))

# /proc/<pid>/stat starttime (field 22) self-test. scripts/test_starttime.sh
# sets ENABLE_STARTTIME_TEST=1 to plant /etc/starttime-test. init/main.ad
# detects the marker and calls starttime_selftest() (devproc.ad): it stamps
# the boot slot's start_jiffies to a known sentinel, asserts the accessor
# reads it back, renders _emit_linux_stat for the boot slot, parses field 22
# and confirms it equals the sentinel, then emits the [STARTTIME] PASS
# banner. Needs no extra device; default boots omit the marker.
if os.environ.get("ENABLE_STARTTIME_TEST") == "1":
    FILES.append(("/etc/starttime-test", b"1\n"))

# /proc/<pid>/stat priority+nice (fields 18/19) self-test.
# scripts/test_prionice.sh sets ENABLE_PRIONICE_TEST=1 to plant
# /etc/prionice-test. init/main.ad detects the marker and calls
# prionice_selftest() (devproc.ad): it sets the boot slot's nice to a known
# negative value, asserts sched_get_nice reads it back, renders
# _emit_linux_stat for the boot slot, parses field 18 (priority = 20 + nice)
# and field 19 (nice, SIGNED), confirms priority==15 / nice==-5, then emits
# the [PRIONICE] PASS banner. Needs no extra device; default boots omit it.
if os.environ.get("ENABLE_PRIONICE_TEST") == "1":
    FILES.append(("/etc/prionice-test", b"1\n"))

# /proc/<pid>/stat pgrp (field 5) self-test.
# scripts/test_pgrp.sh sets ENABLE_PGRP_TEST=1 to plant /etc/pgrp-test.
# init/main.ad detects the marker and calls pgrp_selftest() (devproc.ad):
# it sets the boot slot's job_pgid to a known sentinel (4242), renders
# _emit_linux_stat for the boot slot, parses field 5 (pgrp), confirms it
# equals 4242, then emits the [PGRP] PASS banner. Needs no extra device;
# default boots omit it.
if os.environ.get("ENABLE_PGRP_TEST") == "1":
    FILES.append(("/etc/pgrp-test", b"1\n"))

# /proc/<pid>/stat flags (field 9) self-test. scripts/test_procflags.sh sets
# ENABLE_PROCFLAGS_TEST=1 to plant /etc/procflags-test. init/main.ad detects
# the marker and calls procflags_selftest() (devproc.ad): it renders
# _emit_linux_stat for the boot slot, parses field 9 (flags), and confirms it
# equals the real PF_KTHREAD bit (2097152) derived from the boot task's
# is_user, then emits the [PROCFLAGS] PASS banner. Needs no extra device;
# default boots omit it.
if os.environ.get("ENABLE_PROCFLAGS_TEST"):
    FILES.append(("/etc/procflags-test", b"1\n"))

# /proc/<pid>/io self-test. scripts/test_procio.sh sets ENABLE_PROCIO_TEST=1
# to plant /etc/procio-test. init/main.ad detects the marker and calls
# procio_selftest() (devproc.ad): it stamps the boot slot's rchar/wchar/
# syscr/syscw (+ inblock/oublock), renders emit_proc_io, parses the seven
# lines, and confirms the values, then emits the [PROCIO] PASS banner. Needs
# no extra device; default boots omit it.
if os.environ.get("ENABLE_PROCIO_TEST"):
    FILES.append(("/etc/procio-test", b"1\n"))

# /proc/<pid>/limits self-test. scripts/test_proclimits.sh sets
# ENABLE_PROCLIMITS_TEST=1 to plant /etc/proclimits-test. init/main.ad detects
# the marker and calls proclimits_selftest() (devproc.ad): it renders
# emit_proc_limits for the boot slot, parses the "Max open files"/"Max stack
# size" rows, and asserts nofile_soft=1024 nofile_hard=4096 stack_soft=8388608,
# then emits the [PROCLIMITS] PASS banner. Needs no extra device.
if os.environ.get("ENABLE_PROCLIMITS_TEST"):
    FILES.append(("/etc/proclimits-test", b"1\n"))

# /proc/<pid>/fd self-test. scripts/test_procfd.sh sets ENABLE_PROCFD_TEST=1 to
# plant /etc/procfd-test. init/main.ad detects the marker and calls
# procfd_selftest() (devproc.ad): it renders emit_proc_fd for the boot slot and
# asserts the standard descriptors 0/1/2 are listed with their target column
# reading "/dev/cons", then emits the [PROCFD] PASS banner. Needs no extra
# device.
if os.environ.get("ENABLE_PROCFD_TEST"):
    FILES.append(("/etc/procfd-test", b"1\n"))

# Phase 4c `#d/<N>` DEV_DEVFD inline-chan self-test. scripts/test_devfd_chan.sh
# sets ENABLE_DEVFDCHAN_TEST=1 to plant /etc/devfdchan-test. init/main.ad
# detects the marker and calls devfdchan_selftest() (devfd.ad): pipe binds at
# /fd/5 + /fd/6 opened as `#d/5` / `#d/6` chans, payload round-trip, waitfds
# probe 1 → 0 across the drain, lseek rejected; emits the [DEVFDCHAN] PASS
# banner. Needs no extra device.
if os.environ.get("ENABLE_DEVFDCHAN_TEST"):
    FILES.append(("/etc/devfdchan-test", b"1\n"))

# Phase 4c DEV_PIPE_R/DEV_PIPE_W pool-chan self-test. scripts/test_pipe_chan.sh
# sets ENABLE_PIPECHAN_TEST=1 to plant /etc/pipechan-test. init/main.ad detects
# the marker and calls pipechan_selftest() (fs/pipe.ad): vfs_pipe() over the
# pool-Chan representation, probe 0 -> 1 -> 0 across a payload round-trip,
# dup+close chan-refcount tripwire, EOF after writer close, EPIPE after reader
# close, 0x43-prefixed per-pipe inode identity, lseek rejected; emits the
# [PIPECHAN] PASS banner. Needs no extra device.
if os.environ.get("ENABLE_PIPECHAN_TEST"):
    FILES.append(("/etc/pipechan-test", b"1\n"))

# Phase 4c DEV_SOCKET/DEV_SOCKETPAIR pool-chan self-test.
# scripts/test_sock_chan.sh sets ENABLE_SOCKCHAN_TEST=1 to plant
# /etc/sockchan-test. init/main.ad detects the marker and calls
# sockchan_selftest() (fs/socketpair.ad): vfs_socketpair() over the
# pool-Chan representation, probe 2 -> 1 -> 2 across a payload round-trip,
# both directions, dup+close chan-refcount tripwire, EOF + EPIPE after peer
# close, 0x43-prefixed per-end inode identity, lseek rejected, plus the
# DEV_SOCKET record-encoding round trip; emits the [SOCKCHAN] PASS banner.
# Needs no extra device.
if os.environ.get("ENABLE_SOCKCHAN_TEST"):
    FILES.append(("/etc/sockchan-test", b"1\n"))

# /proc/<pid>/ctl write-surface self-test. scripts/test_procctl.sh sets
# ENABLE_PROCCTL_TEST=1 to plant /etc/procctl-test. init/main.ad detects the
# marker and calls procctl_selftest() (devproc.ad): it drives the real
# _ctl_parse_pri on a "pri -5" control message, applies it via sched_set_nice,
# and asserts sched_get_nice(boot_slot)==-5, then emits the [PROCCTL] PASS
# banner. Needs no extra device.
if os.environ.get("ENABLE_PROCCTL_TEST"):
    FILES.append(("/etc/procctl-test", b"1\n"))

# Per-task oom_score_adj store + OOM-killer exemption/clamp self-test.
# scripts/test_oomadj.sh sets ENABLE_OOMADJ_TEST=1 to plant /etc/oomadj-test.
# init/main.ad detects the marker and calls oomadj_selftest()
# (kernel/sched/core.ad): it drives the real oom_adj_set/get/is_exempt store,
# asserts exemption at -1000 and the upper clamp at 1000, then emits the
# [OOMADJ] PASS banner. Needs no extra device.
if os.environ.get("ENABLE_OOMADJ_TEST"):
    FILES.append(("/etc/oomadj-test", b"1\n"))

# F10-10 (#457): per-Pgrp oom_score_adj field + clone-independence self-test.
# scripts/test_pgrpoom.sh sets ENABLE_PGRPOOM_TEST=1 to plant /etc/pgrpoom-test.
# init/main.ad detects the marker and calls pgrp_oomadj_selftest()
# (sys/src/9/port/chan.ad): it round-trips a safe-range value through
# pgrp_oom_score_adj_set/get, confirms the upper +1000 and lower -1000 clamps,
# then exercises pgrp_clone INDEPENDENCE — set distinct values on parent and
# clone and confirm neither mutation perturbs the other. Emits the
# [PGRPOOM] PASS banner. Needs no extra device.
if os.environ.get("ENABLE_PGRPOOM_TEST"):
    FILES.append(("/etc/pgrpoom-test", b"1\n"))

# F10-8 / #457: NATIVE seccomp-lite per-task syscall-filter self-test.
# scripts/test_seccomp_native.sh sets ENABLE_SECCOMP_NATIVE_TEST=1 to
# plant /etc/seccomp-native-test. init/main.ad detects the marker and
# calls seccomp_native_selftest() (kernel/sched/core.ad): it arms a
# spare slot with an allow-only-SYS_GETPID(4) bitmap and asserts that
# the do_syscall-entry probe permits nr=4, blocks nr=0/8 and nr>=256,
# and refuses to disarm an armed filter (irrevocable). No extra device.
if os.environ.get("ENABLE_SECCOMP_NATIVE_TEST"):
    FILES.append(("/etc/seccomp-native-test", b"1\n"))

# SCHED_FIFO/SCHED_RR realtime scheduling-policy self-test.
# scripts/test_rtsched.sh sets ENABLE_RTSCHED_TEST=1 to plant /etc/rtsched-test.
# init/main.ad detects the marker and calls rtsched_selftest()
# (kernel/sched/core.ad): it drives the real sched_set_scheduler / _pick_next /
# RR-rotation mechanism over spare-slot fixtures, asserts a FIFO@50 task beats a
# SCHED_OTHER task, two equal-priority RR tasks alternate on rotation, a FIFO
# task is not preempted by a lower-priority RR task, and the priority-range
# queries return 99/1 (FIFO/RR) / 0 (OTHER), then emits the [rtsched] PASS
# banner. Needs no extra device. Uniquely-named gate so it never collides with
# a sibling kernel-scheduler agent's marker block.
if os.environ.get("ENABLE_RTSCHED_TEST"):
    FILES.append(("/etc/rtsched-test", b"1\n"))

# /proc/<pid>/stat child-resource accounting (fields 11/13/16/17) self-test.
# scripts/test_childacct.sh sets ENABLE_CHILDACCT_TEST=1 to plant
# /etc/childacct-test. init/main.ad detects the marker and calls
# childacct_selftest() (devproc.ad): it stamps the boot slot's four child
# accumulators (cutime/cstime/cminflt/cmajflt) with known sentinels, asserts
# the accessors read them back, renders _emit_linux_stat for the boot slot,
# parses fields 11/13/16/17, confirms they match, then emits the
# [CHILDACCT] PASS banner. Needs no extra device; default boots omit it.
if os.environ.get("ENABLE_CHILDACCT_TEST") == "1":
    FILES.append(("/etc/childacct-test", b"1\n"))

# times(2) CPU-time self-test. scripts/test_times.sh sets
# ENABLE_TIMES_TEST=1 to plant /etc/times-test. init/main.ad at
# boot:37.times detects the marker and calls times_selftest()
# (linux_abi/u_syscalls.ad): it lets the timer ISR accrue a few system
# ticks to the boot task, then drives _u_times and asserts tms_stime
# advanced (real per-task CPU-time accounting), cutime stayed zeroed,
# and the jiffies return is positive. Default boots omit the marker.
if os.environ.get("ENABLE_TIMES_TEST") == "1":
    FILES.append(("/etc/times-test", b"1\n"))

# /proc/stat CPU-split self-test. scripts/test_devstat_split.sh sets
# ENABLE_DEVSTAT_SPLIT_TEST=1 to plant /etc/devstat-split-test. init/main.ad
# at boot:37.dss detects the marker and calls devstat_split_selftest()
# (sys/src/9/port/devstat.ad): it lets the timer ISR accrue a few ticks to
# the boot task, then asserts the real three-way user/system/idle jiffie
# split (system advances, the three counters are independent, and every
# tick was charged to exactly one bucket). Needs no extra device; default
# boots omit the marker.
if os.environ.get("ENABLE_DEVSTAT_SPLIT_TEST") == "1":
    FILES.append(("/etc/devstat-split-test", b"1\n"))

# access(2) mode-bit self-test. scripts/test_access_mode.sh sets
# ENABLE_ACCESS_MODE_TEST=1 to plant /etc/access-mode-test. init/main.ad
# at boot:37.acc detects the marker after the ext4 mount and calls
# access_mode_selftest() (linux_abi/u_syscalls.ad): it stamps a few ext4
# files with known modes (0664/0755/0444) on the live /ext mount, then
# drives SYS_access through the real Linux-ABI dispatch asserting the
# R/W/X bit check against i_mode (X_OK on a no-x file is -EACCES, X_OK on
# an executable is 0, W_OK on a read-only file is -EACCES) plus -ENOENT
# for a missing path. Writes to the mounted ext4 image, so it is opt-in.
if os.environ.get("ENABLE_ACCESS_MODE_TEST") == "1":
    FILES.append(("/etc/access-mode-test", b"1\n"))

# Linux-NS per-file POSIX DAC self-test fixtures. scripts/
# test_linux_ns_dac.sh sets ENABLE_DAC_TEST=1 to plant two cpio files
# with KNOWN modes (root-owned by cpio convention, uid 0):
#   /etc/dac-world.txt   0644 — world-readable: a non-root Linux user
#                               (dave, uid 1000) CAN read it.
#   /etc/dac-root600.txt 0600 — root-only: dave is DENIED (EACCES) read
#                               AND write; hostowner (Linux root) reads OK.
# These ride the same kernel cpio perm-check (_perm_check_cpio) that
# /etc/shadow does, giving the test a deterministic positive (world)
# and negative (root600) alongside the headline /etc/shadow case.
if os.environ.get("ENABLE_DAC_TEST") == "1":
    FILES.append(("/etc/dac-world.txt", b"WORLD-READABLE\n", 0o100644))
    FILES.append(("/etc/dac-root600.txt", b"ROOT-SECRET\n", 0o100600))

# readlink(2)/readlinkat(2)-on-tmpfs-symlink self-test. scripts/
# test_tmpfs_readlink.sh sets ENABLE_TMPFS_READLINK_TEST=1 to plant
# /etc/tmpfs-readlink-test. init/main.ad at boot:37.trl detects the marker
# and calls tmpfs_readlink_selftest() (linux_abi/u_syscalls.ad): it creates
# a tmpfs file plus a tmpfs symlink with a known target string, then drives
# SYS_readlink and SYS_readlinkat through the real Linux-ABI dispatch on the
# symlink, asserting the returned byte count == the target length, the
# copied bytes == the target string, no trailing NUL, and that readlink on a
# non-symlink tmpfs file returns -EINVAL. Purely RAM-backed (tmpfs) so it
# needs no disk image; default boots omit the marker so it never fires.
if os.environ.get("ENABLE_TMPFS_READLINK_TEST") == "1":
    FILES.append(("/etc/tmpfs-readlink-test", b"1\n"))

# symlink(2)/link(2)/utimensat(2) Linux-ABI self-test. scripts/
# test_linkat.sh sets ENABLE_LINKAT_TEST=1 to plant /etc/linkat-test.
# init/main.ad at boot:37.lat detects the marker and calls
# linkat_selftest() (linux_abi/u_syscalls.ad): it drives the newly-wired
# SYS_symlink/SYS_symlinkat/SYS_link/SYS_utimensat family through the real
# Linux-ABI dispatch on the live tmpfs backend, asserting that a symlink's
# stored target round-trips via readlink, a hardlink aliases the same data
# byte, a cross-backend link returns -EXDEV (the Plan 9 file-server
# boundary), and utimensat returns 0 / -ENOENT / -EFAULT correctly.
# Purely RAM-backed (tmpfs) so it needs no disk image; default boots omit
# the marker so it never fires.
if os.environ.get("ENABLE_LINKAT_TEST") == "1":
    FILES.append(("/etc/linkat-test", b"1\n"))

# getrandom(2)/statx(2) direct-syscall Linux-ABI self-test. scripts/
# test_statx_getrandom.sh sets ENABLE_STATX_GETRANDOM_TEST=1 to plant
# /etc/statx-test. init/main.ad at boot:37.sxg detects the marker and calls
# statx_getrandom_selftest() (linux_abi/u_syscalls.ad): it drives the
# getrandom(318) + statx(332) direct top-level syscalls through the real
# Linux-ABI dispatch, asserting getrandom serves full-length differing
# entropy (and 0 for a zero-length request) and statx reports the directory
# type bit + nlink>=1 for /etc, the regular-file type bit + exact size for a
# planted /tmp file, and -ENOENT for a missing path. Purely RAM-backed
# (tmpfs) so it needs no disk image; default boots omit the marker.
if os.environ.get("ENABLE_STATX_GETRANDOM_TEST") == "1":
    FILES.append(("/etc/statx-test", b"1\n"))

# sched_setaffinity(2)/sched_getaffinity(2)/membarrier(2) Linux-ABI self-test.
# scripts/test_sched_affinity.sh sets ENABLE_SCHED_AFFINITY_TEST=1 to plant
# /etc/sched-affinity-test. init/main.ad at boot:37.aff detects the marker and
# calls sched_affinity_membarrier_selftest() (linux_abi/u_syscalls.ad): it
# drives the REAL per-task CPU-affinity store (cpu_affinity in the task struct)
# and its enforcement by the per-CPU-runqueue scheduler — a single-CPU mask
# round-trips through set/get, placement/migration only ever lands a task on an
# allowed CPU, and on an SMP boot a CPU1-pinned task is enqueued on CPU1's
# runqueue. It also drives the REAL membarrier dispatch (QUERY returns a nonzero
# supported mask; GLOBAL/PRIVATE_EXPEDITED issue a real barrier and return 0).
# Purely in-RAM (task_table + LAPIC) so it needs no disk image; default boots
# omit the marker so it never fires.
if os.environ.get("ENABLE_SCHED_AFFINITY_TEST") == "1":
    FILES.append(("/etc/sched-affinity-test", b"1\n"))

# MBR extended/logical-partition (EBR chain) self-test. scripts/
# test_partebr.sh sets ENABLE_PARTEBR_TEST=1 to plant /etc/partebr-test
# and attaches a raw "vda" disk carrying an MBR + extended container +
# a 3-EBR logical chain. init/main.ad at boot:37.ebr detects the marker
# and calls partition_ebr_selftest() (drivers/block/partition.ad): it
# re-scans vda and asserts the three LOGICAL partitions enumerate at
# their exact absolute LBA windows (proving the next-EBR pointer is
# anchored at the extended-partition base, not the current EBR — the
# classic offset gotcha). Read-only, opt-in; default boots omit the
# marker so it never fires.
if os.environ.get("ENABLE_PARTEBR_TEST") == "1":
    FILES.append(("/etc/partebr-test", b"1\n"))

# ext4 extent-index-node (eh_depth > 0) self-test. scripts/test_ext4idx.sh
# sets ENABLE_EXT4IDX_TEST=1 to plant /etc/ext4idx-test. init/main.ad
# detects the marker after the ext4 mount and calls
# ext4_extentidx_selftest() (fs/ext4.ad): it appends many deliberately
# non-contiguous one-block extents to a fresh file, overflowing the 4
# inline extent slots and forcing the inode into a depth-1 INDEX node;
# it then reads every block back through the index-tree walk (verifying
# a per-block pattern) and truncates the file to zero, asserting the
# index + leaf + data blocks are freed and the tree folds back to an
# inline depth-0 leaf. It WRITES to the mounted image, so it must only
# run on the disposable test image — opt-in via the marker. Default
# boots omit it so it never fires unintentionally.
if os.environ.get("ENABLE_EXT4IDX_TEST") == "1":
    FILES.append(("/etc/ext4idx-test", b"1\n"))

# ext4 DEPTH-2 extent-tree self-test. scripts/test_ext4d2.sh sets
# ENABLE_EXT4D2_TEST=1 to plant /etc/ext4d2-test. init/main.ad detects
# the marker after the ext4 mount and calls ext4_extentd2_selftest()
# (fs/ext4.ad): it appends enough deliberately non-contiguous one-block
# extents to overflow the depth-1 capacity (4 inode index slots × leaf
# records), forcing the inode into a DEPTH-2 index tree (idx → idx →
# leaf); it reads every block back through the two-level index walk,
# partially truncates (exercising depth-2 trim), then truncates to zero
# (folding the tree back to an inline depth-0 leaf). It WRITES to the
# mounted image, so it must only run on the disposable test image —
# opt-in via the marker. Default boots omit it so it never fires.
if os.environ.get("ENABLE_EXT4D2_TEST") == "1":
    FILES.append(("/etc/ext4d2-test", b"1\n"))

# ext4 htree (dir_index) hash-lookup self-test. scripts/test_ext4_htree.sh
# sets ENABLE_EXT4_HTREE_TEST=1 to plant /etc/ext4-htree-test. init/main.ad
# detects the marker after the ext4 mount and calls ext4_htree_selftest()
# (fs/ext4.ad): it first runs a directory-hash KAT (legacy/half_md4/tea)
# against values precomputed by Linux's debugfs `dx_hash`, proving the
# hash matches Linux bit-for-bit; then it resolves the on-disk "bigdir"
# htree directory (minted by the test script with enough entries to force
# >=1 dx index level), looks up several names through the dx_root/dx_node
# hash-descend path, cross-checks each against the linear all-block scan,
# and asserts the descend touched only a handful of leaf blocks (not every
# directory block). READ-only, so it is safe on any mounted image, but it
# only finds "bigdir" on the test script's image — opt-in via the marker.
if os.environ.get("ENABLE_EXT4_HTREE_TEST") == "1":
    FILES.append(("/etc/ext4-htree-test", b"1\n"))

# ext4 htree (dir_index) INSERT / leaf-split WRITE self-test.
# scripts/test_ext4_htree_insert.sh sets ENABLE_EXT4_HTINS_TEST=1 to plant
# /etc/ext4-htins-test. init/main.ad detects the marker after the ext4
# mount and calls ext4_htree_insert_selftest() (fs/ext4.ad): it resolves
# the on-disk "htdir" dir_index directory, inserts a batch of new names
# (forcing >= 1 leaf split and an index-level growth) through the full
# create -> ext4_dir_insert -> ext4_htree_dir_insert write path, then
# verifies every inserted name resolves via the hash-descend lookup to the
# inode created for it, the dir grew (real split), the pre-existing name
# survived, and the index stayed a valid htree. WRITES the mounted image,
# so opt-in via the marker; default boots omit it so it never fires.
if os.environ.get("ENABLE_EXT4_HTINS_TEST") == "1":
    FILES.append(("/etc/ext4-htins-test", b"1\n"))

# ext4 large_dir (3-level htree growth) WRITE self-test.
# scripts/test_ext4_largedir.sh sets ENABLE_EXT4_LARGEDIR_TEST=1 to plant
# /etc/ext4-largedir-test. init/main.ad detects the marker after the ext4
# mount and calls ext4_largedir_selftest() (fs/ext4.ad): it resolves the
# on-disk near-full 2-level "lgdir" dir_index directory and inserts new
# names until the dx_root overflows and the tree grows to 3 index levels
# (indirect_levels==2, gated on the superblock's INCOMPAT_LARGEDIR), then
# verifies every inserted name resolves via the 3-level hash descend. WRITES
# the mounted image, so opt-in via the marker; default boots omit it.
if os.environ.get("ENABLE_EXT4_LARGEDIR_TEST") == "1":
    FILES.append(("/etc/ext4-largedir-test", b"1\n"))

# ext4 extent-FREE / no-leak self-test. scripts/test_ext4_extent_free.sh
# sets ENABLE_EXT4EXTFREE_TEST=1 to plant /etc/ext4extfree-test.
# init/main.ad detects the marker after the ext4 mount and calls
# ext4_extentfree_selftest() (fs/ext4.ad): it records the free-block
# bitmap count, writes a multi-block fragmented file (spanning several
# extents), unlinks it, and asserts the free count returns to its pre-
# write value — proving ext4_unlink walks the extent tree and frees ALL
# data + index/leaf metadata blocks (no leak). It also round-trips a
# depth-3 extent tree byte-exact. WRITES the mounted image, so opt-in via
# the marker; default boots omit it so it never fires.
if os.environ.get("ENABLE_EXT4EXTFREE_TEST") == "1":
    FILES.append(("/etc/ext4extfree-test", b"1\n"))

# Partition write-smoke fixtures (mkpart MBR on sd0, gpt on nvme0n1).
# These WRITE a partition table onto a freshly-registered disk that has
# no MBR, so they must NEVER run on production media. Set
# ENABLE_MKPART_SMOKE=1 to plant /etc/mkpart-smoke; init/main.ad calls
# partition_enable_mkpart_smoke() when it sees the marker, before any
# disk registers. Only scripts/test_mkpart.sh / test_gpt_mkpart.sh set
# it; default boots leave the scan path strictly read-only.
if os.environ.get("ENABLE_MKPART_SMOKE") == "1":
    FILES.append(("/etc/mkpart-smoke", b"1\n"))

# ext4 mkfs self-test arming. The lazy ext4_mkfs_self_test (fs/ext4.ad)
# FORMATS sd0p1/nvme0n1p1, so it is a developer fixture that must NEVER
# run on real media (a shipped .img's sd0p1 is the live ESP). Setting
# ENABLE_MKFS_SELFTEST=1 plants /etc/mkfs-selftest; init/main.ad calls
# ext4_enable_mkfs_selftest() when it sees the marker. Only
# scripts/test_mkfs.sh sets it; default boots never format a disk.
if os.environ.get("ENABLE_MKFS_SELFTEST") == "1":
    FILES.append(("/etc/mkfs-selftest", b"1\n"))

# xHCI live-keyboard attach OPT-OUT. Mirrors ENABLE_XHCI_SELFTEST but
# in the opposite direction: setting ENABLE_XHCI_NO_ATTACH=1 plants
# /etc/xhci-no-attach so drivers/usb/xhci.ad's xhci_init() skips
# _xhci_v1_attach_keyboard() entirely — the controller is still
# brought up + reset + scanned, just no live SETUP / Address Device
# / GET_DESCRIPTOR / Configure Endpoint walk on the connected port.
# This is the real-hardware escape hatch for laptops where the live
# attach wedges inside an MMIO/command-ring poll (Intel Nook boot
# 2026-05 hung at [boot:01.f] xhci v1 transfer-engine bringup + attach).
# Boot then continues normally; the box just has no USB keyboard but
# the serial console / PS/2 keyboard / framebuffer prompt still work.
if os.environ.get("ENABLE_XHCI_NO_ATTACH") == "1":
    FILES.append(("/etc/xhci-no-attach", b"1\n"))

# xHCI full-skip OPT-OUT. The bigger sibling of ENABLE_XHCI_NO_ATTACH:
# setting ENABLE_XHCI_NO_INIT=1 plants /etc/xhci-no-init so
# drivers/usb/xhci.ad's xhci_init() returns immediately AFTER the
# safe PCI find/cap-read prints and BEFORE the first MMIO BAR access
# (halt/reset poll). Use this on real silicon where the MMIO load
# itself stalls the CPU — no software timeout helps because the load
# instruction never retires. Intel Nook boot 2026-05 wedged at
# [boot:01.c] xhci halt + reset; this marker lets the box boot past
# the xHCI block entirely and continue into ehci_init / start_kernel.
# Default boots do NOT ship the marker, so behavior is unchanged
# unless the user explicitly sets ENABLE_XHCI_NO_INIT=1.
if os.environ.get("ENABLE_XHCI_NO_INIT") == "1":
    FILES.append(("/etc/xhci-no-init", b"1\n"))

# xHCI live-init force-ENABLE opt-IN. The opposite of
# ENABLE_XHCI_NO_INIT: setting ENABLE_XHCI_FORCE_INIT=1 plants
# /etc/xhci-force-init so drivers/usb/xhci.ad's xhci_init() runs the
# live BAR-MMIO bringup path even on bare metal. Without this marker
# (and without /etc/xhci-no-init), bare-metal boots auto-skip the
# live path after CPUID leaf 0x40000000 returns EBX=0 (no hypervisor
# signature) — see drivers/usb/xhci.ad and docs/REAL_HARDWARE.md.
# Use this on real hardware where the user already knows the xHCI
# controller responds to the Hamnix bringup sequence; the user
# accepts the risk that an unresponsive controller will hang the
# halt+reset MMIO poll. QEMU CI never sets this — QEMU is detected
# as a hypervisor (TCG / KVM signature at CPUID 0x40000000) so the
# live xHCI path runs by default.
if os.environ.get("ENABLE_XHCI_FORCE_INIT") == "1":
    FILES.append(("/etc/xhci-force-init", b"1\n"))

# The /etc/e1000e-ko marker that used to gate the .ko-load path is
# gone — init/main.ad's boot:35.a now unconditionally kmod_linux_loads
# /lib/modules/e1000e.ko, which is the only path that drives Intel
# Gigabit silicon (the hand-rolled drivers/net/e1000e.ad has been
# retired). No env-var, no marker file, no conditional code path.

# Storage pivot (Agent D): ahci.ko (SATA AHCI controller — covers
# most stock desktop/laptop SATA silicon). scripts/test_ahci_ko.sh
# sets ENABLE_AHCI_KO=1 to plant /etc/ahci-ko in the initramfs. A
# kernel-side autoloader (Agent B's modprobe.ad / init/main.ad
# wiring) can gate on this marker. In the meantime the test
# exercises the load path via userspace `insmod /lib/modules/6.12/
# ahci.ko` (the L-track test pattern).
if os.environ.get("ENABLE_AHCI_KO") == "1":
    FILES.append(("/etc/ahci-ko", b"1\n"))

# libata.ko harvest (generic Linux ATA/SCSI layer). scripts/test_libata_ko.sh
# sets ENABLE_LIBATA_KO=1 to plant /etc/libata-ko. The kernel-side
# boot:35.LAT path (init/main.ad) gates on this marker and drives an
# explicit ordered load scsi_common -> scsi_mod -> libata so libata's
# scsi_* / sdev_* UND symbols resolve cross-module against scsi_mod's
# ksymtab. Load-only exercise: confirms the loader + linux_abi shims
# absorb the generic ATA/SCSI subsystem (links + init returns 0).
if os.environ.get("ENABLE_LIBATA_KO") == "1":
    FILES.append(("/etc/libata-ko", b"1\n"))

# DRM/KMS (graphics) core harvest. scripts/test_drm_ko.sh sets
# ENABLE_DRM_KO=1 to plant /etc/drm-ko. The kernel-side boot:35.DRM
# path (init/main.ad) gates on this marker and kmod_linux_loads the
# stock Debian drm.ko (the DRM core framework — drm_drv/drm_ioctl/
# drm_gem/atomic-modeset). Load-only exercise (the L-series coverage
# bar): under QEMU's emulated VGA there is no real GPU, so drm.ko's
# init registers its chrdev/debugfs scaffolding and returns — proving
# the loader + linux_abi shims absorb the DRM core (links skipped=0 +
# init_module returns), the last un-probed subsystem class.
if os.environ.get("ENABLE_DRM_KO") == "1":
    FILES.append(("/etc/drm-ko", b"1\n"))

# Storage pivot (Agent D): nvme.ko (PCIe NVM Express SSD driver —
# every modern NVMe device).
# scripts/test_nvme_ko.sh sets ENABLE_NVME_KO=1 to plant /etc/nvme-ko.
# Same userspace-insmod fallback as the ahci block above until a
# kernel-side autoloader honours the marker.
if os.environ.get("ENABLE_NVME_KO") == "1":
    FILES.append(("/etc/nvme-ko", b"1\n"))

# WiFi pivot: cfg80211 + mac80211 are the foundational 802.11
# framework modules. Neither carries a MODULE_DEVICE_TABLE PCI alias
# of its own, so the modprobe auto-loader's PCI-class match never
# fires for them — they must be loaded BEFORE any wifi driver
# (ath*, iwl*, brcmsmac, ...) is brought up. ENABLE_FRAMEWORK_MODULES=1
# plants /etc/framework-modules; init/main.ad reads the marker and
# directly insmods /lib/modules/cfg80211.ko + /lib/modules/mac80211.ko
# during the L-shim init phase. scripts/test_cfg80211_ko.sh and
# scripts/test_mac80211_ko.sh both set this env var.
if os.environ.get("ENABLE_FRAMEWORK_MODULES") == "1":
    FILES.append(("/etc/framework-modules", b"1\n"))

# iwlwifi.ko harvest marker. scripts/test_iwlwifi_ko.sh sets both
# ENABLE_FRAMEWORK_MODULES=1 (to pre-load cfg80211.ko + mac80211.ko)
# and ENABLE_IWLWIFI_KO=1 (to trigger the explicit iwlwifi.ko load
# in init/main.ad's boot:35.W block). Without ENABLE_FRAMEWORK_MODULES
# the iwlwifi load will fail with unresolved cfg80211_* symbols.
if os.environ.get("ENABLE_IWLWIFI_KO") == "1":
    FILES.append(("/etc/iwlwifi-ko", b"1\n"))

# modules.dep regression test marker. scripts/test_loader_modulesdep.sh
# sets this to exercise the in-kernel modules_dep parser: boot without
# the framework-modules pre-load, dispatch mac80211 directly, and let
# the dep walker auto-load cfg80211 first. Mutually exclusive with
# ENABLE_FRAMEWORK_MODULES (which would pre-load both, bypassing the
# dep walker).
if os.environ.get("ENABLE_MODULESDEP_TEST") == "1":
    FILES.append(("/etc/modulesdep-test", b"1\n"))

# Cross-module EXPORT_SYMBOL regression test marker. Loads cfg80211.ko
# then mac80211.ko; the loader's ksymtab fallback path resolves
# mac80211's cfg80211_* UND set against cfg80211's __ksymtab and emits
# a [ksymtab_hit] diag for each resolved name. scripts/
# test_loader_cross_module_export.sh sets this env var.
if os.environ.get("ENABLE_CROSS_MODULE_EXPORT_TEST") == "1":
    FILES.append(("/etc/cross-module-export-test", b"1\n"))

# Native `ping` smoke. scripts/test_ping.sh sets ENABLE_PING_SMOKE=1 to
# plant /etc/ping-smoke-test in the initramfs. The marker is consumed
# only by the test harness today (a future kernel-side autorun could
# gate on it the way ENABLE_NETCFG_SMOKE does for /etc/netcfg-test).
# Default boot omits the marker so unrelated test runs don't change
# shape.
if os.environ.get("ENABLE_PING_SMOKE") == "1":
    FILES.append(("/etc/ping-smoke-test", b"1\n"))

# HTTP 3xx redirect-follow smoke. Gated the same way as the markers
# above. scripts/test_net_http_redirect.sh stands up a Python HTTP
# server that 302s to a same-host /final endpoint serving "hello";
# init/main.ad's http_redirect_smoke_test exercises the kernel's
# redirect-follow loop end-to-end. Default boot omits the marker so
# unrelated test runs don't try to reach 10.0.2.200:80.
if os.environ.get("ENABLE_HTTP_REDIRECT_SMOKE") == "1":
    FILES.append(("/etc/http-redirect-test", b"1\n"))
    # The unconditional https://example.com leg in net_smoke_test
    # traps mid-handshake on the AES-256-GCM record (separate
    # residual; same defence the gzip/finwait2 markers apply); skip
    # it so the kernel reaches the redirect smoke below.
    FILES.append(("/etc/skip-https-internet-smoke", b"1\n"))

# HAMNIX_DEB_FIXTURE: RETIRED. Was used by the now-deleted
# scripts/test_dpkg_*.sh battery (Adder dpkg_deb tests) to plant a host-
# generated tiny .deb at /tests/sample.deb in the cpio. Real apt/dpkg
# now run inside `enter linux { ... }` against debian-minbase/rootfs/;
# no synthetic fixtures needed.

# httpd docroot staging: scripts/test_httpd.sh sets HAMNIX_HTTPD_DOCROOT=1
# to plant a tiny static-file tree at /var/www inside the cpio initramfs
# so the userland /bin/httpd daemon has something to serve under QEMU.
# The httpd test boots with httpd as /init, binds guest port 8080, and a
# host curl drives real HTTP GETs through the in-kernel TCP stack. The
# files land at fixed cpio paths (subdirs are flattened into the path
# string — fs/cpio.ad resolves "/var/www/index.html" by exact match).
# Off-default: an unset env var leaves the initramfs alone, exactly like
# every other gated marker above.
if os.environ.get("HAMNIX_HTTPD_DOCROOT") == "1":
    FILES.append(("/var/www/index.html",
                  b"<html><body><h1>Hamnix httpd</h1>"
                  b"<p>static-file HTTP/1.0 server</p></body></html>\n"))
    FILES.append(("/var/www/hello.txt",
                  b"hello from hamnix httpd\n"))

# httpd concurrent/vhost/CGI staging: scripts/test_httpd_concurrent.sh
# sets HAMNIX_HTTPD_VHOSTS=1 to plant a full web-server fixture in the
# cpio:
#   /etc/httpd.conf            — listen + cgi_dir + two vhost blocks
#   /var/www/index.html        — default vhost (server_name localhost)
#   /var/www/hello.txt         — a text/plain static file
#   /var/www/style.css         — exercises Content-Type by extension
#   /var/www/cgi-bin/echo      — the cgi_echo ELF (CGI dispatch target)
#   /var/www2/index.html       — second vhost (server_name v2.test)
# The cgi-bin binary is the freshly built build/user/cgi_echo.elf, the
# same bytes that land at /bin/cgi_echo, copied to the docroot CGI path
# so a "/cgi-bin/echo" URL resolves to an executable.
if os.environ.get("HAMNIX_HTTPD_VHOSTS") == "1":
    FILES.append(("/etc/httpd.conf",
                  b"# Hamnix httpd test config\n"
                  b"listen 8080\n"
                  b"cgi_dir /cgi-bin\n"
                  b"vhost {\n"
                  b"    server_name localhost\n"
                  b"    root /var/www\n"
                  b"}\n"
                  b"vhost {\n"
                  b"    server_name v2.test\n"
                  b"    root /var/www2\n"
                  b"}\n"))
    FILES.append(("/var/www/index.html",
                  b"<html><body><h1>VHOST_DEFAULT</h1>"
                  b"<p>default vhost (localhost)</p></body></html>\n"))
    FILES.append(("/var/www/hello.txt",
                  b"hello from hamnix httpd\n"))
    FILES.append(("/var/www/style.css",
                  b"body { color: rebeccapurple; }\n"))
    FILES.append(("/var/www2/index.html",
                  b"<html><body><h1>VHOST_SECOND</h1>"
                  b"<p>second vhost (v2.test)</p></body></html>\n"))
    _cgi_elf = Path(__file__).resolve().parent.parent / "build" / "user" / "cgi_echo.elf"
    if _cgi_elf.is_file():
        FILES.append(("/var/www/cgi-bin/echo", _cgi_elf.read_bytes()))
    else:
        print(f"[build_initramfs] WARNING: {_cgi_elf} missing; "
              f"CGI route will 404")

# sshd publickey auth: scripts/test_sshd_pubkey.sh generates a
# throwaway ECDSA-P256 keypair on the host, points HAMNIX_SSH_AUTHKEYS
# at the public-key file, and this block bakes it into the cpio
# initramfs at /var/lib/ssh/authorized_keys. user/sshd.ad reads that
# path (the daemon's /var/lib/ssh namespace dir) at startup and
# authenticates a client offering the matching private key. A /var
# path tmpfs does not itself hold falls through to this cpio-baked
# entry (see the fs/vfs.ad /var dispatch note). Off-default: an unset
# env var leaves the initramfs alone, like every other gated marker.
_SSH_AUTHKEYS = os.environ.get("HAMNIX_SSH_AUTHKEYS", "")
if _SSH_AUTHKEYS:
    try:
        with open(_SSH_AUTHKEYS, "rb") as _f:
            FILES.append(("/var/lib/ssh/authorized_keys", _f.read()))
    except OSError as _e:
        raise SystemExit(
            f"HAMNIX_SSH_AUTHKEYS={_SSH_AUTHKEYS}: unreadable ({_e})")

# V5 cert validation: bake the production ISRG Root X1 anchor into the
# initramfs at /etc/tls-ca-isrg-x1.der whenever the host has it
# installed. drivers/net/tls.ad's _tls_validation_init() walks the cpio
# table for this exact path and castore_add_root's the bytes. Without
# this, no anchor is loaded and every chain fails closed.
_ISRG_HOST_PEM = "/etc/ssl/certs/ISRG_Root_X1.pem"
if os.path.exists(_ISRG_HOST_PEM):
    import subprocess
    try:
        _isrg_der = subprocess.run(
            ["openssl", "x509", "-in", _ISRG_HOST_PEM, "-outform", "DER"],
            check=True, capture_output=True,
        ).stdout
        FILES.append(("/etc/tls-ca-isrg-x1.der", _isrg_der))
    except (FileNotFoundError, subprocess.CalledProcessError):
        # openssl absent or PEM unreadable — kernel will log
        # "CA anchor absent" and refuse every real chain, which is the
        # correct fail-closed behaviour.
        pass

# V8 cert validation: bake the production DigiCert Global Root G2 anchor
# (RSA-2048, sha256WithRSAEncryption) into the initramfs at
# /etc/tls-ca-digicert-g2.der. This root anchors a large share of the
# commercial (non-Let's-Encrypt) web — www.digicert.com and, via the
# cross-signed Microsoft TLS RSA Root G2, www.microsoft.com's SHA-384
# chain. We prefer the checked-in DER fixture (deterministic, host-store-
# independent) and fall back to the host trust store. The 914-byte DER is
# a public trust anchor; pinning it in-tree keeps the anchor identical on
# CI hosts that don't ship it.
_DG2_FIXTURE = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "tests", "fixtures", "digicert_global_root_g2.der")
_DG2_HOST_PEM = "/etc/ssl/certs/DigiCert_Global_Root_G2.pem"
if os.path.exists(_DG2_FIXTURE):
    with open(_DG2_FIXTURE, "rb") as _f:
        FILES.append(("/etc/tls-ca-digicert-g2.der", _f.read()))
elif os.path.exists(_DG2_HOST_PEM):
    import subprocess
    try:
        _dg2_der = subprocess.run(
            ["openssl", "x509", "-in", _DG2_HOST_PEM, "-outform", "DER"],
            check=True, capture_output=True,
        ).stdout
        FILES.append(("/etc/tls-ca-digicert-g2.der", _dg2_der))
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass

# BUG #127 cert validation: bake the production GTS Root R1 anchor
# (RSA-4096, sha256WithRSAEncryption chain) into the initramfs at
# /etc/tls-ca-gts-r1.der. This root (Google Trust Services) anchors
# *.google.com and the huge share of the web behind Google Trust
# Services — the presented chain is leaf(*.google.com, ECDSA-P256) ->
# WR2 (RSA-2048) -> GTS Root R1 (RSA-4096). Every signature in the
# chain is sha256WithRSAEncryption, so it reuses the same audited
# RSA PKCS#1 v1.5 + SHA-256 verify path as ISRG X1 / DigiCert G2 (the
# ECDSA-P256 leaf key is only used in the TLS CertificateVerify, which
# is already supported). Without this anchor, google.com fails X.509
# chain validation ("no trusted root") -> TLS handshake fails ->
# hambrowse shows "Fetch failed". We prefer the checked-in DER fixture
# (deterministic) and fall back to the host trust store.
_GTS_FIXTURE = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "tests", "fixtures", "gts_root_r1.der")
_GTS_HOST_PEM = "/etc/ssl/certs/GTS_Root_R1.pem"
if os.path.exists(_GTS_FIXTURE):
    with open(_GTS_FIXTURE, "rb") as _f:
        FILES.append(("/etc/tls-ca-gts-r1.der", _f.read()))
elif os.path.exists(_GTS_HOST_PEM):
    import subprocess
    try:
        _gts_der = subprocess.run(
            ["openssl", "x509", "-in", _GTS_HOST_PEM, "-outform", "DER"],
            check=True, capture_output=True,
        ).stdout
        FILES.append(("/etc/tls-ca-gts-r1.der", _gts_der))
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass

# Test-fixture anchor: scripts/test_net_https.sh writes a path to its
# generated Hamnix Test CA DER into TLS_CA_DER, and we plant it here.
# The kernel adds it to the CA store in addition to ISRG Root X1 so the
# fixture's server cert (signed by the test CA) validates without
# breaking real-world ISRG-signed chains.
_TLS_CA_DER_PATH = os.environ.get("TLS_CA_DER", "")
if _TLS_CA_DER_PATH:
    try:
        with open(_TLS_CA_DER_PATH, "rb") as _f:
            FILES.append(("/etc/tls-ca.der", _f.read()))
    except OSError as _e:
        raise SystemExit(
            f"TLS_CA_DER={_TLS_CA_DER_PATH}: unreadable ({_e})")

# APT_TRUSTED_GPG: RETIRED with the Adder apt. The real Debian apt-get
# (staged inside /var/lib/distros/default/ via HAMNIX_DEFAULT_REAL_DEBIAN)
# reads /etc/apt/trusted.gpg.d/debian-archive-keyring.gpg from its own
# tree — that file is part of the curated-real-debian stage list.

# cpio capacity stress fixture: scripts/test_cpio_capacity.sh sets
# HAMNIX_CPIO_STRESS_FILES=<N> to plant N tiny synthetic files at
# /cpio-stress/file<i> inside the initramfs. This exercises fs/cpio.ad's
# NR_FILES table past the historical 192-slot cap (the table is now
# 8192 entries). The last planted file carries a recognisable payload
# so the kernel-side check can assert a file PAST index 192 was
# registered and is readable. Off-default: an unset env var leaves the
# initramfs alone, exactly like every other gated marker above.
# hpm repo fixture: scripts/test_hpm.sh sets HAMNIX_HPM_TEST_REPO=<path>
# to plant the contents of <path> at /test-hpm-repo/ inside the cpio
# initramfs. The test boots vanilla Hamnix and runs
# `hpm --repo=file:///test-hpm-repo/ <cmd>` against the planted fixture
# (a tiny index.json + one packages/<name>-<ver>.tar.gz). A second var
# HAMNIX_HPM_TEST_REPO_CONFLICT=<path> plants a parallel
# /test-hpm-repo-conflict/ used for the negative conflict test.
_HPM_TEST_REPO = os.environ.get("HAMNIX_HPM_TEST_REPO", "")
if _HPM_TEST_REPO:
    _repo_root = Path(_HPM_TEST_REPO)
    if not _repo_root.is_dir():
        raise SystemExit(
            f"HAMNIX_HPM_TEST_REPO={_HPM_TEST_REPO!r}: not a directory")
    for _f in sorted(_repo_root.rglob("*")):
        if not _f.is_file():
            continue
        _rel = _f.relative_to(_repo_root)
        with _f.open("rb") as _fh:
            FILES.append((f"/test-hpm-repo/{_rel.as_posix()}",
                          _fh.read()))

_HPM_TEST_REPO_C = os.environ.get("HAMNIX_HPM_TEST_REPO_CONFLICT", "")
if _HPM_TEST_REPO_C:
    _repo_root_c = Path(_HPM_TEST_REPO_C)
    if not _repo_root_c.is_dir():
        raise SystemExit(
            f"HAMNIX_HPM_TEST_REPO_CONFLICT={_HPM_TEST_REPO_C!r}: not a directory")
    for _f in sorted(_repo_root_c.rglob("*")):
        if not _f.is_file():
            continue
        _rel = _f.relative_to(_repo_root_c)
        with _f.open("rb") as _fh:
            FILES.append((f"/test-hpm-repo-conflict/{_rel.as_posix()}",
                          _fh.read()))

# ISO mini-repo for the hpm-driven installer. scripts/build_iso.sh
# builds the v1 packages via scripts/build_packages.py (kernel ELF +
# userland are by then already current) and stages the resulting
# build/packages/ tree into the cpio at /mnt/iso-packages/. The
# installer then runs
#
#   hpm --repo=file:///mnt/iso-packages --target-prefix=/mnt/newroot \
#       install hamnix-base hamnix-installer-tools linux-debian-12
#
# to populate a freshly-formatted target rootfs WITHOUT a network
# round-trip and WITHOUT dd_blk'ing whole partitions. The mirror is
# the Debian-installer pattern.
#
# Off by default: every test that doesn't drive the installer skips
# the (~30 MB) staging cost. scripts/build_iso.sh sets the env var.
_HPM_ISO_PACKAGES = os.environ.get("HAMNIX_ISO_PACKAGES", "")
if _HPM_ISO_PACKAGES:
    _iso_pkgs_root = Path(_HPM_ISO_PACKAGES)
    if not _iso_pkgs_root.is_dir():
        raise SystemExit(
            f"HAMNIX_ISO_PACKAGES={_HPM_ISO_PACKAGES!r}: not a directory")
    _n_iso_pkg_files = 0
    _n_iso_pkg_bytes = 0
    for _f in sorted(_iso_pkgs_root.rglob("*")):
        if not _f.is_file():
            continue
        _rel = _f.relative_to(_iso_pkgs_root)
        with _f.open("rb") as _fh:
            _bytes = _fh.read()
        # NOTE: the brief specified /mnt/iso-packages/, but the kernel
        # auto-mounts vda's FAT volume at /mnt (init/main.ad:313 area)
        # which shadows cpio entries under /mnt/. Stage at
        # /iso-packages/ instead — install.hamsh + the
        # docs/packages.md "Bootstrap" example match this path.
        FILES.append((f"/iso-packages/{_rel.as_posix()}", _bytes))
        _n_iso_pkg_files += 1
        _n_iso_pkg_bytes += len(_bytes)
    print(f"  [iso-packages] staged {_n_iso_pkg_files} files "
          f"({_n_iso_pkg_bytes} bytes) at /iso-packages/ from "
          f"{_iso_pkgs_root}")
    # Point a bare `hpm refresh` (e.g. the Software app on the live image) at
    # the on-image repo, so it works OFFLINE with no network and no
    # --allow-unsigned dance (the file:// index is signed by the committed
    # local key + trusted-by-construction). The installer's own explicit
    # `hpm --repo=file:///iso-packages ...` flag still overrides this. An
    # INSTALLED root ships no /etc/hpm/repo, so it defaults to https://255.one/.
    FILES.append(("/etc/hpm/repo",
                  b"# hpm default repo base (first bare line). On the live /\n"
                  b"# installer image this points at the on-image offline repo;\n"
                  b"# override per-invocation with `hpm --repo=<url> ...`.\n"
                  b"file:///iso-packages/\n"))
    print("  [iso-packages] wrote /etc/hpm/repo -> file:///iso-packages/")

_CPIO_STRESS_RAW = os.environ.get("HAMNIX_CPIO_STRESS_FILES", "")
if _CPIO_STRESS_RAW:
    try:
        _cpio_stress_n = int(_CPIO_STRESS_RAW)
    except ValueError:
        raise SystemExit(
            f"HAMNIX_CPIO_STRESS_FILES={_CPIO_STRESS_RAW!r}: expected an "
            f"integer file count")
    if _cpio_stress_n < 1:
        raise SystemExit(
            f"HAMNIX_CPIO_STRESS_FILES={_cpio_stress_n}: must be >= 1")
    for _i in range(_cpio_stress_n):
        # All but the last file carry a trivial payload. The last one
        # carries a distinctive marker the kernel-side test greps for,
        # proving an entry beyond the old 192 cap was indexed.
        if _i == _cpio_stress_n - 1:
            _payload = b"CPIO_STRESS_LAST_FILE_OK\n"
        else:
            _payload = b"x\n"
        FILES.append((f"/cpio-stress/file{_i}", _payload))

# Generic single-file injection: HAMNIX_EXTRA_CPIO_FILE="<host_path>:<guest_path>[:mode]"
# stages one host file into the cpio at <guest_path>. Used by
# scripts/test_linux_apt_install_e2e.sh to drop an apt-driver wrapper
# script under the distro root (avoids hamsh tokenizing apt's `Dir::Etc::`
# option syntax on the `enter linux { ... }` command line). Mode is octal,
# default 0755.
_EXTRA_CPIO = os.environ.get("HAMNIX_EXTRA_CPIO_FILE", "")
if _EXTRA_CPIO:
    _parts = _EXTRA_CPIO.split(":")
    if len(_parts) < 2:
        raise SystemExit(
            f"HAMNIX_EXTRA_CPIO_FILE={_EXTRA_CPIO!r}: expected "
            f"host_path:guest_path[:octal_mode]")
    _host_p = _parts[0]
    _guest_p = _parts[1]
    with open(_host_p, "rb") as _f:
        _data = _f.read()
    # FILES entries are (name, data) 2-tuples (default mode 0644); the
    # wrapper is invoked via `dash <path>`, so no execute bit is needed.
    FILES.append((_guest_p, _data))
    print(f"[initramfs] staged extra cpio file {_host_p} -> {_guest_p}")

# hamnix-ac source injection: scripts/hamnix-ac stages a host-side Adder
# source FILE into the cpio at a known in-guest path so the on-device
# self-hosted compiler (codegen_ac_driver) can open()+read() it, lex it,
# parse it, codegen it, and elf_emit it. HAMNIX_AC_SRC names the host
# file; HAMNIX_AC_SRC_PATH (default /src/input.ad) is the in-guest path
# the driver opens. This is the file-read injection mechanism — it scales
# to arbitrarily large sources (subject only to the driver's read buffer
# and the compiler's CODE_CAP), unlike build-time string embedding.
_CC_SRC = os.environ.get("HAMNIX_AC_SRC", "")
if _CC_SRC:
    _cc_src_path = os.environ.get("HAMNIX_AC_SRC_PATH", "/src/input.ad")
    _cc_src_file = Path(_CC_SRC)
    if not _cc_src_file.is_file():
        raise SystemExit(
            f"HAMNIX_AC_SRC={_CC_SRC!r}: source file not found")
    _cc_src_bytes = _cc_src_file.read_bytes()
    FILES.append((_cc_src_path, _cc_src_bytes))
    print(f"  [hamnix-ac] staged {_cc_src_path} "
          f"({len(_cc_src_bytes)} bytes from {_CC_SRC})")

# Multi-NIC L-shim scale-out: r8169.ko (Realtek consumer GbE) and
# igb.ko (Intel server/workstation). scripts/test_r8169_ko.sh sets
# ENABLE_R8169_KO=1 to plant /etc/r8169-ko; scripts/test_igb_ko.sh
# sets ENABLE_IGB_KO=1 to plant /etc/igb-ko. init/main.ad reads each
# marker to (a) skip any hand-rolled driver that would conflict and
# (b) kmod_linux_load the matching /lib/modules/<name>.ko at boot.
# Default boot omits both markers so unrelated tests run against
# existing drivers.
#
# These env-var markers live at the BOTTOM of this gated-marker
# section by design: Agent B's auto-modules logic (when it lands) is
# expected to slot in higher up, keeping the rebase area conflict-
# free. The order in FILES doesn't affect cpio lookup semantics
# (fs/vfs.ad's _lookup_name returns the first exact-match path; each
# marker has a unique path).
if os.environ.get("ENABLE_R8169_KO") == "1":
    FILES.append(("/etc/r8169-ko", b"1\n"))

if os.environ.get("ENABLE_IGB_KO") == "1":
    FILES.append(("/etc/igb-ko", b"1\n"))

# Multi-NIC L-shim scale-out (round 2): atlantic (Aquantia 10G), alx
# (Qualcomm Atheros), sky2 (Marvell Yukon 2), tg3 (Broadcom NetXtreme).
# Same marker shape as the round-1 trio above. The per-NIC test
# scripts (scripts/test_<name>_ko.sh) flip the matching env var to
# plant the /etc/<name>-ko marker the init/main.ad framework-modules
# reader will eventually honor.
if os.environ.get("ENABLE_ATLANTIC_KO") == "1":
    FILES.append(("/etc/atlantic-ko", b"1\n"))

if os.environ.get("ENABLE_ALX_KO") == "1":
    FILES.append(("/etc/alx-ko", b"1\n"))

if os.environ.get("ENABLE_SKY2_KO") == "1":
    FILES.append(("/etc/sky2-ko", b"1\n"))

if os.environ.get("ENABLE_TG3_KO") == "1":
    FILES.append(("/etc/tg3-ko", b"1\n"))

# e1000e.ko traffic exercise (NIC subsystem proof-of-concept).
# scripts/test_e1000e_traffic.sh sets ENABLE_E1000E_TRAFFIC_TEST=1 to
# plant /etc/e1000e-traffic-test, which gates init/main.ad's boot:35.c
# call to e1000e_traffic_smoke_test (drivers/net/e1000e_traffic.ad).
# After the existing boot:35.b DHCP exchange establishes a lease via
# the .ko, the smoke runs three phases — ICMP ping, DNS UDP lookup,
# 320-packet UDP burst to force >256-entry TX-ring wraparound — to
# prove regular packet flow works, not just DHCP's ~4-packet happy
# path. Default boots omit the marker; only the dedicated test sets
# the env var.
if os.environ.get("ENABLE_E1000E_TRAFFIC_TEST") == "1":
    FILES.append(("/etc/e1000e-traffic-test", b"1\n"))


# Storage L-shim NVMe exercise: scripts/test_nvme_io.sh sets
# ENABLE_NVME_IO_TEST=1 to plant /etc/nvme-io-ko in the initramfs. This
# marker is consumed by init/main.ad in TWO places:
#   * Early (block_smoke_test sibling): SKIP the hand-rolled
#     drivers/nvme/nvme.ad smoke test so the NVMe controller is left
#     for Linux's stock nvme.ko to claim.
#   * Late (boot:35.N): kmod_linux_load /lib/modules/6.12/nvme.ko and
#     run nvme_io_exercise() — try to mount ext4 off the block device
#     the shim-driven path produces and read+write a known file.
# Distinct from ENABLE_NVME_KO (loader-only test): that one keeps the
# hand-rolled driver active and runs `insmod` from hamsh; this one
# forces the .ko shim to own the device end to end. Placed at the END
# of the FILES-append section (last gated marker before the helpers)
# to minimise merge cost with the in-flight SCSI mid-layer agent
# (a48f) which is touching the AHCI gating block above.
if os.environ.get("ENABLE_NVME_IO_TEST") == "1":
    FILES.append(("/etc/nvme-io-ko", b"1\n"))

# USB host-controller class L-shim exercise marker. scripts/test_xhci_io.sh
# sets ENABLE_XHCI_KO=1 to plant /etc/xhci-ko in the initramfs. This
# is the USB equivalent of the ahci-io / nvme-io markers: with the marker
# present init/main.ad SKIPs the hand-rolled drivers/usb/xhci.ad +
# drivers/usb/ehci.ad init paths and instead drives the controller via
# Linux's stock usbcore + xhci_pci + xhci_hcd .ko dep chain through
# kmod_linux_load + modules_dep_load_with_deps. The chain owns the
# controller end to end; the in-kernel xhci_io_exercise() then asserts
# we got at least to usb_add_hcd (root hub registration) before the
# follow-up URB-submission milestone takes over the actual key-event
# injection.
# ENABLE_XHCI_KO defaults to 1 (Linux USB stack ON, hand-rolled
# drivers/usb/{xhci,usb,hid}.ad SKIPPED at boot:01/02). User direction:
# the hand-rolled USB stack never fully worked; the whole point of the
# L-shim pivot is to use Linux's drivers. Set ENABLE_XHCI_KO=0 to opt
# back into the hand-rolled path (legacy only).
if os.environ.get("ENABLE_XHCI_KO", "1") == "1":
    FILES.append(("/etc/xhci-ko", b"1\n"))

# REAL Linux .ko xHCI bring-up marker (scripts/test_xhci_ko_enum.sh sets
# ENABLE_XHCI_KO_REAL=1). When present, /etc/xhci-ko is ALSO planted
# (so boot:01 skips the hand-rolled drivers/usb/xhci.ad and the .ko dep
# chain still loads) AND the usb_hcd_pci_probe native bridge is
# SUPPRESSED — the stock Linux xhci_hcd.ko drives the controller via
# api_xhci_real.ad::xhci_real_exercise(): it resolves the genuine
# EXPORT_SYMBOL'd xhci_init_driver / xhci_run / xhci_gen_setup and lets
# the Linux driver itself read/write the controller registers. Native
# USB is fully disabled in this mode. Default boots do NOT set this, so
# root-on-USB (native USB-MSC) is unaffected.
#   ENABLE_XHCI_KO_REAL_MMIO=1 additionally arms the deep (fault-prone)
#   real xhci_gen_setup call (stage 3).
if os.environ.get("ENABLE_XHCI_KO_REAL", "0") == "1":
    if not any(name == "/etc/xhci-ko" for name, _ in FILES):
        FILES.append(("/etc/xhci-ko", b"1\n"))
    FILES.append(("/etc/xhci-ko-real", b"1\n"))
    if os.environ.get("ENABLE_XHCI_KO_REAL_MMIO", "0") == "1":
        FILES.append(("/etc/xhci-ko-real-mmio", b"1\n"))

# IN-RAM INSTALLER MEDIUM. scripts/build_installer_img.sh sets
# HAMNIX_INSTALLER_BLOB=1 (and HAMNIX_INSTALLER_SQFS=<path>) to pack the
# installer payload into the firmware-loaded cpio. Two in-RAM sources:
#
#   /rootfs.sqfs        a squashfs holding the NVMe ESP FAT image
#                       (esp.img). The installer streams the ESP out via
#                       sqfs_to_blk -> the kernel loop_sqfs_extract path
#                       onto the target ESP partition (FAT byte-copy —
#                       there is no per-file FAT writer).
#   /iso-packages/main  the native package repo (index.json + *.tar.gz),
#                       packed below. The installer populates the target
#                       ext4 ROOT by `hpm --repo=file:///iso-packages
#                       install hamnix-base` — a real Debian-style package
#                       install, NOT a golden-image stream.
#
# Either way the installer NEVER reads the install media's own block
# device. The /etc/installer-medium marker tells init/main.ad to skip ALL
# media storage bring-up (native + .ko USB) so the installer is purely
# RAM-resident, which is the whole point (the native USB driver is broken
# on the real NUC target). Only the installer build sets this; normal/dev
# cpios are NOT bloated by the squashfs + package payload.
if os.environ.get("HAMNIX_INSTALLER_BLOB") == "1":
    _sqfs_path = os.environ.get("HAMNIX_INSTALLER_SQFS", "")
    if not _sqfs_path:
        raise SystemExit("[build_initramfs] HAMNIX_INSTALLER_BLOB=1 but "
                         "HAMNIX_INSTALLER_SQFS=<path> not set")
    _sqfs_p = Path(_sqfs_path)
    if not _sqfs_p.is_absolute():
        _sqfs_p = Path(__file__).resolve().parent.parent / _sqfs_p
    if not _sqfs_p.is_file():
        raise SystemExit(f"[build_initramfs] HAMNIX_INSTALLER_SQFS="
                         f"{_sqfs_path}: file not found")
    _sqfs_bytes = _sqfs_p.read_bytes()
    FILES.append(("/rootfs.sqfs", _sqfs_bytes))
    FILES.append(("/etc/installer-medium", b"1\n"))
    print(f"[build_initramfs] HAMNIX_INSTALLER_BLOB=1: packed in-RAM "
          f"squashfs payload /rootfs.sqfs "
          f"({len(_sqfs_bytes)/(1<<20):.1f} MiB) + /etc/installer-medium "
          f"marker.", flush=True)

    # UNATTENDED (auto-wipe) vs INTERACTIVE (default) install.
    # An installer that erases whatever disk it finds the moment you attach
    # one is a footgun — that is NOT the default. The default install medium
    # boots the LIVE environment; the user launches the installer explicitly
    # ("Install Hamnix" / `install` at a prompt), which prompts for the disk
    # and confirms the ERASE. rc.boot auto-runs the unattended installer ONLY
    # when the /etc/installer-autorun marker is present, which is planted ONLY
    # here under HAMNIX_INSTALLER_AUTORUN=1. Two legitimate consumers set it:
    #   * the keyboard-less NUC "appliance" image (no one to type the command)
    #   * the CI install regressions (test_installer_nvme_inram.sh et al.)
    # A normal desktop install image (the one a person boots) never sets it.
    if os.environ.get("HAMNIX_INSTALLER_AUTORUN") == "1":
        FILES.append(("/etc/installer-autorun", b"1\n"))
        print("[build_initramfs] HAMNIX_INSTALLER_AUTORUN=1: planted "
              "/etc/installer-autorun — this medium AUTO-INSTALLS onto the "
              "first blank target (unattended/appliance/CI build).", flush=True)

    # DEBIAN-STYLE PACKAGE INSTALL: ship the native package repo IN RAM so
    # the installer can `hpm --repo=file:///iso-packages install hamnix-base`
    # onto the freshly-mkfs'd target ext4 — a real package install (not a
    # golden-image stream). scripts/build_packages.py emits
    # build/packages/main/ (index.json + packages/*.tar.gz); we mirror that
    # tree into the cpio at /iso-packages/main/. The repo is firmware-loaded
    # into RAM with the rest of the cpio, so NO media read is needed (the
    # whole in-RAM model survives the broken-USB NUC target).
    _pkg_repo_env = os.environ.get("HAMNIX_INSTALLER_PKG_REPO", "")
    if _pkg_repo_env:
        _repo_root = Path(_pkg_repo_env)
    else:
        _repo_root = Path(__file__).resolve().parent.parent / "build" / "packages"
    _repo_main = _repo_root / "main"
    if not (_repo_main / "index.json").is_file():
        raise SystemExit(
            f"[build_initramfs] HAMNIX_INSTALLER_BLOB=1 but the package repo "
            f"{_repo_main}/index.json is missing — run "
            f"scripts/build_packages.py (build_installer_img.sh Stage 1 does "
            f"this).")
    _repo_count = 0
    _repo_bytes = 0
    for _root, _dirs, _names in os.walk(_repo_main):
        for _nm in _names:
            _abs = Path(_root) / _nm
            _rel = _abs.relative_to(_repo_main)
            _cpio_path = "/iso-packages/main/" + str(_rel).replace(os.sep, "/")
            _data = _abs.read_bytes()
            FILES.append((_cpio_path, _data))
            _repo_count += 1
            _repo_bytes += len(_data)
    print(f"[build_initramfs] HAMNIX_INSTALLER_BLOB=1: packed in-RAM package "
          f"repo /iso-packages/main/ ({_repo_count} files, "
          f"{_repo_bytes/(1<<20):.1f} MiB) for the Debian-style root "
          f"install.", flush=True)

# Native Intel HDA audio self-test. scripts/test_hda_audio.sh sets
# ENABLE_AUDIO_TEST=1 to plant /etc/audio-test; init/main.ad's boot:37.aud
# gate then runs audio_selftest(), which synthesizes a square-wave tone,
# streams it to /dev/audio (Plan-9 cdev) via the native HDA stream DMA
# engine, and proves the DMA link-position advanced. QEMU's wav audiodev
# captures the played samples to a host file the test asserts is
# non-silent. Default boots ship no marker so the audio path stays quiet.
if os.environ.get("ENABLE_AUDIO_TEST") == "1":
    FILES.append(("/etc/audio-test", b"1\n"))

# #279: optional master-volume marker for the audio self-test. When set,
# audio_selftest() writes `master <pct>` (+ `mute` if the marker contains
# "mute") to /dev/audioctl BEFORE streaming the tone, so the WAV-capture
# gate (scripts/test_hda_volume.sh) can prove the DE master level actually
# changes the captured output (loud vs quiet vs silent). No marker ->
# master stays at unity (100%), so the plain /etc/audio-test gate is
# unaffected.
_audio_master = os.environ.get("AUDIO_MASTER")
if _audio_master:
    FILES.append(("/etc/audio-master", (_audio_master + "\n").encode()))

# Native Intel HDA PCM CAPTURE (record) self-test. ENABLE_AUDIOCAP_TEST=1
# plants /etc/audiocap-test; init/main.ad's boot:37.acap gate then runs
# audio_capture_selftest(), which arms the HDA input-stream DMA ring, feeds
# a known synthetic PCM pattern through the DMA-complete deposit path, and
# reads it back byte-identical via the /dev/audioin Plan-9 cdev — proving
# the capture ring/position/wrap and read handler are real. Uniquely-named
# marker so it never collides with the playback /etc/audio-test gate.
if os.environ.get("ENABLE_AUDIOCAP_TEST") == "1":
    FILES.append(("/etc/audiocap-test", b"1\n"))

# Native on-device MP3 PLAYBACK self-test. ENABLE_MP3_TEST=1 plants
# /etc/mp3-test; init/main.ad's boot:37.mp3 gate then runs
# audio_mp3_selftest(), which reads the initramfs-staged
# /usr/share/sounds/test.mp3, decodes it to PCM with lib/mp3decode
# (MPEG-1 Layer III), and streams the decoded PCM to /dev/audio (the
# SAME Plan-9 cdev + HDA stream DMA the square-wave tone uses). QEMU's
# wav audiodev captures the played samples to a host file the test
# asserts is non-silent — proving the decode->HDA path end-to-end.
# Uniquely-named marker so it never collides with the tone gate.
if os.environ.get("ENABLE_MP3_TEST") == "1":
    FILES.append(("/etc/mp3-test", b"1\n"))

# Native device-mapper self-test. scripts/test_devmapper.sh sets
# ENABLE_DEVMAPPER_TEST=1 to plant /etc/devmapper-test; init/main.ad's
# boot:37.dm gate then runs dm_selftest() (drivers/block/dm.ad), which
# registers a dedicated in-kernel backing ramdisk and proves the LINEAR
# target remaps virtual writes to the correct underlying sector, two
# CONCATENATED linear targets route each span to its own backing region,
# and the CRYPT (dm-crypt / ChaCha20) target writes real ciphertext
# (sector-keyed IV -> identical plaintext at two sectors yields different
# ciphertext) that round-trips back to plaintext on read. Prints
# "[device-mapper] PASS" / "[device-mapper] FAIL". Default boots ship no
# marker so the device-mapper self-test is a no-op everywhere else.
if os.environ.get("ENABLE_DEVMAPPER_TEST") == "1":
    FILES.append(("/etc/devmapper-test", b"1\n"))

# Native software-RAID (md) self-test. scripts/test_mdraid.sh sets
# ENABLE_MDRAID_TEST=1 to plant /etc/mdraid-test; init/main.ad's boot:37.md
# gate then runs md_selftest() (drivers/block/md.ad), which registers
# dedicated in-kernel backing ramdisks and proves the RAID0 (stripe) target
# routes each virtual sector to the correct member+offset (including a
# request that straddles a chunk boundary, split across two members), the
# RAID1 (mirror) target fans a write out to BOTH members and reads it back,
# and RAID1 DEGRADED mode (one member marked Faulty) still round-trips
# through the survivor. Prints "[mdraid] PASS" / "[mdraid] FAIL". Default
# boots ship no marker so the md self-test is a no-op everywhere else.
if os.environ.get("ENABLE_MDRAID_TEST") == "1":
    FILES.append(("/etc/mdraid-test", b"1\n"))

# Native software-RAID (md) ONLINE RESHAPE / GROW self-test.
# scripts/test_mdreshape.sh sets ENABLE_MDRESHAPE_TEST=1 to plant
# /etc/mdreshape-test; init/main.ad's boot:37.mdreshape gate then runs
# md_reshape_selftest() (drivers/block/md.ad), which builds a 3-member RAID5,
# writes a known image across every data sector, GROWS it to 4 members with a
# real crash-restartable restripe (md_reshape_grow), and verifies the usable
# capacity grew (512 -> 768 sectors), every original block reads back
# byte-identical through the new geometry, the grown tail is usable, and an
# interrupted restripe resumes from the persisted checkpoint. Prints
# "[mdreshape] PASS" / "[mdreshape] FAIL". Default boots ship no marker so
# the md reshape self-test is a no-op everywhere else.
if os.environ.get("ENABLE_MDRESHAPE_TEST") == "1":
    FILES.append(("/etc/mdreshape-test", b"1\n"))

# Native VXLAN (RFC 7348) encap/decap self-test. scripts/test_vxlan.sh sets
# ENABLE_VXLAN_TEST=1 to plant /etc/vxlan-test; init/main.ad's boot:37.vxlan
# gate then runs vxlan_selftest() (drivers/net/vxlan.ad), a pure in-memory
# test that builds a known inner Ethernet frame, ENCAPs it to a VNI over
# UDP/IPv4 (Eth|IP|UDP:4789|VXLAN|inner) with chosen outer IP/MAC, DECAPs the
# result and asserts the recovered inner frame is byte-identical, and verifies
# the outer dport 4789, the VXLAN I-bit, the 24-bit VNI, and recomputed IPv4 +
# UDP checksums across two VNIs routed through the VNI->VTEP forwarding map.
# Prints "[vxlan] PASS" / "[vxlan] FAIL". Default boots ship no marker so the
# VXLAN self-test is a no-op everywhere else.
if os.environ.get("ENABLE_VXLAN_TEST") == "1":
    FILES.append(("/etc/vxlan-test", b"1\n"))

# Native IPv4 multicast + IGMPv2/v3 (RFC 2236 / RFC 3376) self-test.
# scripts/test_igmp.sh sets ENABLE_IGMP_TEST=1 to plant /etc/igmp-test;
# init/main.ad's boot:37.igmp gate then runs igmp_selftest()
# (drivers/net/igmp.ad), a pure in-memory test that builds + parses v2 and
# v3 Membership Reports (type/group/checksum), maps a group IP to its
# 01:00:5e multicast MAC, and exercises join/leave against the multicast
# RX-accept predicate plus a Membership-Query -> Report path. Prints
# "[igmp] PASS" / "[igmp] FAIL". Default boots ship no marker so it is a
# no-op everywhere else.
if os.environ.get("ENABLE_IGMP_TEST") == "1":
    FILES.append(("/etc/igmp-test", b"1\n"))

# Native GRE (RFC 2784) encap/decap-over-IPv4 self-test.
# scripts/test_gre.sh sets ENABLE_GRE_TEST=1 to plant /etc/gre-test;
# init/main.ad's boot:37.gre gate then runs gre_selftest()
# (drivers/net/gre.ad), a pure in-memory test that ENCAPs a known inner
# IPv4 payload into OuterIP(proto=47)|GRE|inner (with the IPv4 header
# checksum via ip_csum16 and an optional RFC-2784 GRE checksum), DECAPs it
# back byte-for-byte asserting the parsed protocol type 0x0800, runs both
# the no-checksum and checksum forms, and rejects a corrupted GRE-checksum
# frame. Prints "[gre] PASS" / "[gre] FAIL". Default boots ship no marker
# so it is a no-op everywhere else.
if os.environ.get("ENABLE_GRE_TEST") == "1":
    FILES.append(("/etc/gre-test", b"1\n"))

# Native learning Ethernet bridge (the brX/brctl software bridge) self-test.
# scripts/test_bridge.sh sets ENABLE_BRIDGE_TEST=1 to plant /etc/bridge-test;
# init/main.ad's boot:37.bridge gate then runs bridge_selftest()
# (drivers/net/bridge.ad), a pure in-memory test that joins three fake capture
# ports into one bridge and drives the REAL bridge_rx() learn+forward path:
# an unknown-unicast FLOODS to all non-ingress ports; a learned source yields
# a unicast delivered ONLY to the learned port (never flooded/hairpinned); a
# broadcast dst floods to all non-ingress ports; and the MAC-learning FDB
# returns the correct ingress port per learned source. Prints "[bridge] PASS"
# / "[bridge] FAIL". Default boots ship no marker so it is a no-op everywhere
# else.
if os.environ.get("ENABLE_BRIDGE_TEST") == "1":
    FILES.append(("/etc/bridge-test", b"1\n"))

# Real wired-data-path test that bridges drivers/net/bridge.ad and
# drivers/net/vxlan.ad. scripts/test_vxlan_overlay.sh sets
# ENABLE_VXLAN_OVERLAY_TEST=1 to plant /etc/vxlan-overlay-test;
# init/main.ad's boot:37.vxlan_overlay gate then runs
# bridge_vxlan_overlay_selftest() (drivers/net/bridge.ad), which drives
# the REAL bridge_rx -> bridge port TX hook -> vxlan_encap -> in-VM
# loopback -> vxlan_decap -> bridge_rx round-trip and asserts the
# inner Ethernet frame is byte-identical at a capture port after the
# full RFC-7348 encap/decap. Prints "[bridge-vxlan] PASS" / FAIL.
# Default boots ship no marker so it is a no-op everywhere else.
if os.environ.get("ENABLE_VXLAN_OVERLAY_TEST") == "1":
    FILES.append(("/etc/vxlan-overlay-test", b"1\n"))

# Real wired-data-path test for drivers/net/wireguard.ad.
# scripts/test_wireguard_overlay.sh sets ENABLE_WIREGUARD_OVERLAY_TEST=1 to
# plant /etc/wireguard-overlay-test; init/main.ad's boot:37.wireguard_overlay
# gate then runs wireguard_overlay_selftest() (drivers/net/wireguard.ad),
# which drives the REAL wg_iface_xmit -> wg_transport_seal -> in-VM
# UDP-shape wire ring -> wg_wire_pump (port-51820 demux) -> wg_udp_rx ->
# wg_transport_open round-trip and asserts the inner packet is byte-
# identical at the peer's WG virtual interface. The Noise IKpsk2 handshake
# (init + response) ALSO rides the same wire (type bytes 1/2). Prints
# "[wireguard-overlay] PASS" / FAIL. Default boots ship no marker.
if os.environ.get("ENABLE_WIREGUARD_OVERLAY_TEST") == "1":
    FILES.append(("/etc/wireguard-overlay-test", b"1\n"))

# UDP kernel-listener registry self-test. scripts/test_udp_listener_registry.sh
# sets ENABLE_UDP_LISTENER_TEST=1 to plant /etc/udp-listener-test;
# init/main.ad's boot:37.udp_listener gate runs udp_listener_selftest()
# (drivers/net/udp.ad), exercising udp_register_listener +
# udp_local_inject + udp_unregister_listener with a synthetic listener.
# Prints "[udp-listener] PASS" / FAIL. Default boots ship no marker.
if os.environ.get("ENABLE_UDP_LISTENER_TEST") == "1":
    FILES.append(("/etc/udp-listener-test", b"1\n"))

# Native IEEE 802.1Q VLAN tagging self-test. scripts/test_vlan.sh sets
# ENABLE_VLAN_TEST=1 to plant /etc/vlan-test; init/main.ad's boot:37.vlan
# gate then runs vlan_selftest() (drivers/net/vlan.ad), a pure in-memory
# test that registers logical vlan interfaces (VID->iface), round-trips a
# 4-byte 802.1Q tag INSERT+STRIP asserting the inner Ethernet frame is
# byte-identical and the decoded {PCP,DEI,VID} match, proves the ingress
# filter DROPS an unregistered VID and ACCEPTS a registered one, and proves
# egress tagging stamps an interface's VID. Prints "[vlan] PASS" / "[vlan]
# FAIL". Default boots ship no marker so it is a no-op everywhere else.
if os.environ.get("ENABLE_VLAN_TEST") == "1":
    FILES.append(("/etc/vlan-test", b"1\n"))

# Native GENEVE (RFC 8926) encap/decap self-test. scripts/test_geneve.sh sets
# ENABLE_GENEVE_TEST=1 to plant /etc/geneve-test; init/main.ad's boot:37.geneve
# gate then runs geneve_selftest() (drivers/net/geneve.ad), a pure in-memory
# test that builds a known inner Ethernet frame plus a 2-entry GENEVE option
# TLV block (a critical 0x0101/8-byte option + a non-critical 0x0202/4-byte
# option), ENCAPs them to a VNI over UDP/IPv4 (Eth|IP|UDP:6081|GENEVE|opts|
# inner), walks the option TLVs by length, then DECAPs past the variable
# option block and asserts the inner frame + VNI + every option round-trip
# byte-identical, verifying the dport 6081, version 0 + Opt Len, the C flag,
# the TEB protocol type, and recomputed IPv4/UDP checksums across two VNIs.
# Prints "[geneve] PASS" / "[geneve] FAIL". Default boots ship no marker.
if os.environ.get("ENABLE_GENEVE_TEST") == "1":
    FILES.append(("/etc/geneve-test", b"1\n"))

# Native MACsec (IEEE 802.1AE) GCM-AES-128 link-layer encryption self-test.
# scripts/test_macsec.sh sets ENABLE_MACSEC_TEST=1 to plant /etc/macsec-test;
# init/main.ad's boot:37.macsec gate then runs macsec_selftest()
# (drivers/net/macsec.ad), a pure in-memory test that runs a published
# GCM-AES-128 known-answer vector, PROTECTs a known inner Ethernet frame into
# dst|src|SecTAG(0x88E5,E/C/SC,AN,PN)|ciphertext|ICV (reusing the TLS AES-GCM
# AEAD), proves the on-wire payload is real ciphertext, VALIDATEs it back
# byte-identical, and proves the security properties (tampered ciphertext/ICV
# rejected, replayed PN rejected, wrong key fails ICV) across two Secure
# Associations. Prints "[macsec] PASS" / "[macsec] FAIL". Default boots ship
# no marker.
if os.environ.get("ENABLE_MACSEC_TEST") == "1":
    FILES.append(("/etc/macsec-test", b"1\n"))

# Native WireGuard (Noise_IKpsk2 over UDP) self-test. scripts/test_wireguard.sh
# sets ENABLE_WIREGUARD_TEST=1 to plant /etc/wireguard-test; init/main.ad's
# boot:37.wireguard gate then runs wireguard_selftest() (drivers/net/
# wireguard.ad), a pure in-memory two-peer loopback test that: runs RFC 8439
# ChaCha20-Poly1305, RFC 7748 X25519 and BLAKE2s known-answer vectors; runs the
# full Noise_IKpsk2 handshake (handshake-initiation + handshake-response with a
# pre-shared key) deriving matching transport keys on both peers (X25519 ECDH +
# HKDF-BLAKE2s key schedule); round-trips an inner packet A->B and B->A
# byte-identical via ChaCha20-Poly1305 transport messages; and proves the
# security properties (wrong key, replayed counter, and tampered ciphertext all
# rejected). Prints "[wireguard] PASS" / "[wireguard] FAIL". Default boots ship
# no marker.
if os.environ.get("ENABLE_WIREGUARD_TEST") == "1":
    FILES.append(("/etc/wireguard-test", b"1\n"))

# Native IPsec ESP (RFC 4303 transport mode, AES-GCM per RFC 4106) self-test.
# scripts/test_ipsec.sh sets ENABLE_IPSEC_TEST=1 to plant /etc/ipsec-test;
# init/main.ad's boot:37.ipsec gate then runs ipsec_selftest() (drivers/net/
# ipsec.ad), a pure in-memory two-endpoint test that installs an A->B SA pair
# sharing a key/SPI, ENCAPsulates a known payload into SPI|seq|ciphertext|ICV
# (reusing the TLS AES-GCM AEAD), DECAPsulates it back byte-identical with the
# correct next-header, and proves the security properties (flipped ciphertext/
# ICV fails the GCM ICV, replayed seq rejected by the anti-replay window, fresh
# in-window seq accepted and advances the window, seq numbers increase). Prints
# "[ipsec] PASS" / "[ipsec] FAIL". Default boots ship no marker.
if os.environ.get("ENABLE_IPSEC_TEST") == "1":
    FILES.append(("/etc/ipsec-test", b"1\n"))

# Native SCTP (Stream Control Transmission Protocol, RFC 4960) self-test.
# scripts/test_sctp.sh sets ENABLE_SCTP_TEST=1 to plant /etc/sctp-test;
# init/main.ad's boot:37.sctp gate then runs sctp_selftest() (drivers/net/
# sctp.ad), a pure in-memory two-endpoint test that drives the full 4-way
# association handshake (INIT -> INIT ACK with a State Cookie -> COOKIE ECHO ->
# COOKIE ACK) carrying + verifying the per-direction Verification Tags, then
# proves reliable in-order DATA delivery on a stream (TSN/SID/SSN DATA chunks
# reassembled byte-identically, an out-of-order arrival buffered and released
# in stream order, a SACK reporting the missing TSN as a gap-ack block, and a
# retransmit closing the gap + advancing the Cumulative TSN Ack), and the
# security properties (a wrong Verification Tag rejected, a corrupted packet
# failing the CRC32c per RFC 3309, reusing fs/crc32c.ad). Prints "[sctp] PASS"
# / "[sctp] FAIL". Default boots ship no marker.
if os.environ.get("ENABLE_SCTP_TEST") == "1":
    FILES.append(("/etc/sctp-test", b"1\n"))

# Native Multipath TCP (MPTCP, RFC 8684) self-test.
# scripts/test_mptcp.sh sets ENABLE_MPTCP_TEST=1 to plant /etc/mptcp-test;
# init/main.ad's boot:37.mptcp gate then runs mptcp_selftest() (drivers/net/
# mptcp.ad), a pure in-memory two-endpoint / two-subflow test that drives the
# MP_CAPABLE key exchange (deriving each side's token + IDSN from the keys via
# SHA-256, with an in-file HMAC-SHA256 over fs/sha256.ad), the MP_JOIN token +
# HMAC challenge/response of a second subflow (verified both directions), then
# proves the DSS option maps subflow sequence space to the connection-level
# Data Sequence Number and that data sent across TWO subflows reassembles
# byte-identically in DSN order (including an out-of-order arrival across
# subflows buffered + released in DSN order), and a DATA_FIN closes the
# connection. Security properties: a wrong MP_JOIN HMAC is rejected, a
# corrupted DSS checksum is detected, and a wrong token does not join. Prints
# "[mptcp] PASS" / "[mptcp] FAIL". Default boots ship no marker.
if os.environ.get("ENABLE_MPTCP_TEST") == "1":
    FILES.append(("/etc/mptcp-test", b"1\n"))

# Native macvlan (Linux drivers/net/macvlan.c) virtual-link self-test.
# scripts/test_macvlan.sh sets ENABLE_MACVLAN_TEST=1 to plant /etc/macvlan-test;
# init/main.ad's boot:37.macvlan gate then runs macvlan_selftest() (drivers/net/
# macvlan.ad), a pure in-memory test that stacks multiple virtual interfaces
# over ONE parent netdev, each with its OWN distinct MAC, and proves: RX demux
# steers a frame to the macvlan owning its destination MAC (and drops a frame
# for an unknown MAC); egress stamps the macvlan's own source MAC; bridge-mode
# peers on the same parent deliver to each other in-host; private-mode peer
# traffic is isolated (blocked) while off-host traffic still egresses. Prints
# "[macvlan] PASS" / "[macvlan] FAIL". Default boots ship no marker.
if os.environ.get("ENABLE_MACVLAN_TEST") == "1":
    FILES.append(("/etc/macvlan-test", b"1\n"))

# Native ipvlan (Linux drivers/net/ipvlan/) virtual-link self-test.
# scripts/test_ipvlan.sh sets ENABLE_IPVLAN_TEST=1 to plant /etc/ipvlan-test;
# init/main.ad's boot:37.ipvlan gate then runs ipvlan_selftest() (drivers/net/
# ipvlan.ad), a pure in-memory test that stacks multiple virtual interfaces over
# one parent that SHARE the parent's MAC, and proves: L2 mode switches on the
# shared MAC then destination IP (delivering to the slave owning the dst IP,
# flooding broadcast, dropping an unknown dst IP, rejecting a wrong dst MAC);
# L3 mode routes PURELY on destination IP (MAC irrelevant, no flood) and drops a
# packet whose dst IP matches no slave. Prints "[ipvlan] PASS" / "[ipvlan] FAIL".
# Default boots ship no marker.
if os.environ.get("ENABLE_IPVLAN_TEST") == "1":
    FILES.append(("/etc/ipvlan-test", b"1\n"))

# Native stateful NAT64 (RFC 6146 + the RFC 6145 stateless IP/ICMP translation
# algorithm) self-test. scripts/test_nat64.sh sets ENABLE_NAT64_TEST=1 to plant
# /etc/nat64-test; init/main.ad's boot:37.nat64 gate then runs nat64_selftest()
# (drivers/net/nat64.ad), a pure in-memory test that maps IPv4 into IPv6 with
# the RFC 6052 Well-Known Prefix 64:ff9b::/96, creates a stateful 5-tuple
# session on the first outbound IPv6->IPv4 packet and matches the return on the
# session table, translates UDP/TCP/ICMP Echo both ways (rewriting headers,
# TTL/HopLimit, the pool source port, and recomputing the IPv4 header checksum
# plus the pseudo-header L4/ICMPv6 checksums so they validate), and proves two
# security rejections (an inbound IPv4 packet with no matching session is
# dropped; an outbound v6 destination lacking the prefix is rejected). Prints
# "[nat64] PASS" / "[nat64] FAIL". Default boots ship no marker.
if os.environ.get("ENABLE_NAT64_TEST") == "1":
    FILES.append(("/etc/nat64-test", b"1\n"))

# Native IPv4-in-IPv4 tunnel (RFC 2003, "ipip") encap/decap self-test.
# scripts/test_ipip.sh sets ENABLE_IPIP_TEST=1 to plant /etc/ipip-test;
# init/main.ad's boot:37.ipip gate then runs ipip_selftest()
# (drivers/net/ipip.ad), a pure in-memory test that ENCAPs a known inner
# IPv4/UDP packet in an outer IPv4 header (protocol 4) with the correct
# total-length and a valid outer header checksum, DECAPs it byte-identically,
# and rejects a wrong-protocol and a wrong-destination outer frame. Prints
# "[ipip] PASS" / "[ipip] FAIL". Default boots ship no marker.
if os.environ.get("ENABLE_IPIP_TEST") == "1":
    FILES.append(("/etc/ipip-test", b"1\n"))

# Native 6in4 / sit tunnel (RFC 4213, IPv6-in-IPv4) encap/decap self-test.
# scripts/test_sit.sh sets ENABLE_SIT_TEST=1 to plant /etc/sit-test;
# init/main.ad's boot:37.sit gate then runs sit_selftest() (drivers/net/sit.ad),
# a pure in-memory test that ENCAPs a known inner IPv6/UDP packet in an outer
# IPv4 header (protocol 41) with the correct total-length and a valid outer
# header checksum, checks the RFC 3056 6to4 prefix (2002::/16) derivation,
# DECAPs the frame byte-identically, and rejects a wrong-protocol and a
# wrong-destination outer frame. Prints "[sit] PASS" / "[sit] FAIL". Default
# boots ship no marker.
if os.environ.get("ENABLE_SIT_TEST") == "1":
    FILES.append(("/etc/sit-test", b"1\n"))

# Native L2TPv3 (RFC 3931) Ethernet-pseudowire encap/decap self-test.
# scripts/test_l2tp.sh sets ENABLE_L2TP_TEST=1 to plant /etc/l2tp-test;
# init/main.ad's boot:37.l2tp gate then runs l2tp_selftest()
# (drivers/net/l2tp.ad), a pure in-memory test that builds a known inner
# Ethernet frame and ENCAPs it as Eth|IP|UDP:1701|L2TPv3(SessionID[+Cookie]+
# L2-sublayer)|inner across two sessions (one cookie-less, one with a 64-bit
# cookie), DECAPs each demuxing on Session ID + cookie, and verifies the inner
# frame + Session ID + cookie + sequence number round-trip byte-identical
# while rejecting a wrong cookie / unknown session. Prints "[l2tp] PASS" /
# "[l2tp] FAIL". Default boots ship no marker.
if os.environ.get("ENABLE_L2TP_TEST") == "1":
    FILES.append(("/etc/l2tp-test", b"1\n"))

# Native link aggregation (bonding) self-test. scripts/test_bond.sh sets
# ENABLE_BOND_TEST=1 to plant /etc/bond-test; init/main.ad's boot:37.bond
# gate then runs bond_selftest() (drivers/net/bond.ad), a pure in-memory test
# that enslaves fake member NICs into a bond and drives the REAL slave-
# selection logic: mode-1 active-backup tx routes to the single active slave;
# marking the active slave's link down promotes a live backup and tx fails
# over to it; mode-0 balance-rr distributes frames round-robin across the live
# slaves (even 2-each over 4) and SKIPS a slave whose link goes down; release
# shrinks the member set. Prints "[bond] PASS" / "[bond] FAIL". Default boots
# ship no marker so it is a no-op everywhere else.
if os.environ.get("ENABLE_BOND_TEST") == "1":
    FILES.append(("/etc/bond-test", b"1\n"))

# Native traffic control Token Bucket Filter (tbf) egress shaping self-test.
# scripts/test_qdisc.sh sets ENABLE_QDISC_TEST=1 to plant /etc/qdisc-test;
# init/main.ad's boot:37.qdisc gate then runs qdisc_selftest()
# (drivers/net/qdisc.ad), a pure in-memory test that drives the REAL token
# accounting against an INJECTED virtual clock: a full bucket admits a burst
# up to its depth back-to-back; the next packet at the same instant EXCEEDS
# (drops) because the bucket is empty; advancing virtual time refills the
# bucket (rate * elapsed tokens, capped at burst) and re-admits a packet; a
# long idle is capped at the burst depth (no hoarding); a steady stream at
# exactly `rate` sustains (all conform); and a stream above `rate` sheds the
# excess. Prints "[qdisc] PASS" / "[qdisc] FAIL". Default boots ship no marker
# so it is a no-op everywhere else.
if os.environ.get("ENABLE_QDISC_TEST") == "1":
    FILES.append(("/etc/qdisc-test", b"1\n"))

# Native HTB (Hierarchical Token Bucket) classful qdisc self-test.
# scripts/test_htb.sh sets ENABLE_HTB_TEST=1 to plant /etc/htb-test;
# init/main.ad's boot:37.htb gate then runs htb_selftest() (drivers/net/htb.ad),
# a pure in-memory test that drives REAL per-class rate/ceil token + ctoken
# bucket accounting against an INJECTED virtual clock: two backlogged sibling
# leaves each get their assured rate (no starvation); when one sibling is idle
# the active leaf BORROWS above its rate up to its ceil; and a leaf is CAPPED at
# its ceil even with the whole link free. Prints "[htb] PASS" / "[htb] FAIL".
# Default boots ship no marker so it is a no-op everywhere else.
if os.environ.get("ENABLE_HTB_TEST") == "1":
    FILES.append(("/etc/htb-test", b"1\n"))

# Native fq_codel (Flow Queue + CoDel AQM) qdisc self-test.
# scripts/test_fqcodel.sh sets ENABLE_FQCODEL_TEST=1 to plant /etc/fqcodel-test;
# init/main.ad's boot:37.fqcodel gate then runs fqcodel_selftest()
# (drivers/net/fq_codel.ad), a pure in-memory test that drives REAL flow hashing
# + DRR new/old-flow scheduling and the per-flow CoDel control law
# (interval/sqrt(count) with a real integer isqrt) against an INJECTED virtual
# clock: a sparse flow is not starved by a bulk flow; a standing queue above
# TARGET for >= INTERVAL is dropped at the accelerating control-law cadence and
# dropping STOPS once sojourn recovers; a queue below TARGET suffers zero drops.
# Prints "[fqcodel] PASS" / "[fqcodel] FAIL". Default boots ship no marker so it
# is a no-op everywhere else.
if os.environ.get("ENABLE_FQCODEL_TEST") == "1":
    FILES.append(("/etc/fqcodel-test", b"1\n"))

# Linux-style overlayfs (union filesystem) self-test. scripts/test_overlayfs.sh
# sets ENABLE_OVERLAYFS_TEST=1 to plant /etc/overlayfs-test; init/main.ad's
# boot:37.ovl gate then runs overlayfs_selftest() (fs/overlayfs.ad), which
# builds a two-layer (one read-only LOWER + one writable UPPER) overlay backed
# by tmpfs and proves: upper SHADOWS lower on lookup; COPY-UP-on-write copies a
# lower-only file into upper (the lower stays pristine); WHITEOUT-on-delete
# hides a lower file via a ".wh.<name>" marker without touching the lower;
# re-creating over a whiteout makes the name live again; and merged READDIR is
# the deduped union of upper+lower with whiteouts hidden. Prints
# "[overlayfs] PASS" / "[overlayfs] FAIL". Default boots ship no marker so the
# overlayfs self-test is a no-op everywhere else.
if os.environ.get("ENABLE_OVERLAYFS_TEST") == "1":
    FILES.append(("/etc/overlayfs-test", b"1\n"))


# --- master gate marker for the boot:37 developer self-test battery ---
# init/main.ad runs its ~87-probe self-test scan ONLY when /etc/run-selftests
# is present. Each individual test still needs its own /etc/<x>-test marker to
# actually execute, but this master marker is what arms the scan at all. Plant
# it for EVERY build EXCEPT the two production kernels: the installed disk
# (HAMNIX_CPIO_EMPTY=1) and the installer medium (HAMNIX_INSTALLER_BLOB=1).
# Those ship to real hardware and must never run the developer battery — it is
# pure noise and a stray probe can wedge the boot (the kmodsys hang observed on
# the keyboard-less NUC). Every test build keeps its self-tests because none of
# them set these production flags; a marker is only useful with this present.
_is_production = (os.environ.get("HAMNIX_CPIO_EMPTY") == "1"
                  or os.environ.get("HAMNIX_INSTALLER_BLOB") == "1")
# HAMNIX_FORCE_SELFTESTS=1 arms the boot:37 battery even on a production
# kernel. This exists so an OVMF-bootable installer medium can run a
# device self-test that needs real firmware + a device QEMU only exposes
# under UEFI (e.g. the virtio-gpu present/backend test, whose -kernel
# path is blocked by this host's multiboot/VBE limit). Off by default —
# production ships never set it — so real installer/hardware images are
# unchanged.
_force_selftests = os.environ.get("HAMNIX_FORCE_SELFTESTS") == "1"
if (not _is_production) or _force_selftests:
    FILES.append(("/etc/run-selftests", b"1\n"))


# uaccess_syscall_test() (init/main.ad, run at early boot before userland)
# drives do_syscall(SYS_GETCWD) from kernel context against a vaddr != phys
# mapping. It is a #163 developer proof that can fault the box under TCG, so
# unlike the rest of the battery it is gated by its OWN marker and runs ONLY
# for scripts/test_uaccess_translate.sh (ENABLE_UACCESS_SC_TEST=1) — never on
# a normal, random-test, installer, or production boot.
if os.environ.get("ENABLE_UACCESS_SC_TEST") == "1":
    FILES.append(("/etc/uaccess-sc-test", b"1\n"))


# The hamUId markup-client keystone proof (scripts/test_hamUI_markupclient.sh
# and scripts/test_hamUI_markupclient_gop.sh, ENABLE_MKC_SELFTEST=1). Rather
# than race a serial-injected command against the runlevel-5 console takeover
# (the autostart hamUId daemon grabs the console the moment hamsh is ready), we
# plant a /etc/hamui-mkc-test MARKER FILE. The normal etc/services.d/hamuid.svc
# autostarts the daemon as the PROVEN 2-token `hamUId daemon` — the exact exec
# line the supervisor reliably brings up to "DAEMON up screen=WxH" on a real
# EFI GOP framebuffer. The daemon's verb dispatch (user/hamUId.ad) opens this
# marker when no argv[2] was given and, if present, routes into the autoflag-46
# markup-client selftest: it owns /dev/fb, runs daemon_markup_client_selftest
# inline, prints the [markup-client] markers + PASS, then exits 0 (so
# restart:on-failure does not relaunch it). This replaces an earlier svc
# OVERRIDE to a 3-token `hamUId daemon markupclient` exec line — the autostart
# path never brought that override up (the proven autostart is the unmodified
# 2-token svc), so the keystone selftest never ran. Test build only.
if os.environ.get("ENABLE_MKC_SELFTEST") == "1":
    FILES.append(("/etc/hamui-mkc-test", b"1\n"))


# Increment-1 (MATE-mirror DE rewrite) separate-process app spine proof
# (scripts/test_hamUI_appspine_gop.sh, ENABLE_SPINE_SELFTEST=1). Same shape
# as the markup-client marker above: plant /etc/hamui-spine-test so the
# PROVEN 2-token `hamUId daemon` autostart routes into the autoflag-47 spine
# self-test (spawn /bin/hamecho as its own process, prove window-only spawn
# damage + on-screen markup + focus-gated routed-key delivery into the child
# + no leak to the /dev/cons shell). Runs once, exits 0 (restart:on-failure
# won't relaunch). Test build only.
if os.environ.get("ENABLE_SPINE_SELFTEST") == "1":
    FILES.append(("/etc/hamui-spine-test", b"1\n"))


# Increment-2 (MATE-mirror DE rewrite) TERMINAL app-spine proof
# (scripts/test_hamUI_termspine_gop.sh, ENABLE_TERM_SELFTEST=1). Same shape
# as the spine marker above: plant /etc/hamui-term-test so the PROVEN
# 2-token `hamUId daemon` autostart routes into the autoflag-48 terminal
# self-test (spawn /bin/hamterm as its own process, prove window-only spawn
# damage + on-screen markup + a focus-gated `echo TERMOK` command driving a
# REAL /bin/hamsh whose output renders live in the window + no leak to the
# /dev/cons shell). Runs once, exits 0 (restart:on-failure won't relaunch).
# Test build only.
if os.environ.get("ENABLE_TERM_SELFTEST") == "1":
    FILES.append(("/etc/hamui-term-test", b"1\n"))


# Increment-3a (MATE-mirror DE rewrite) MENU-TERMINAL proof
# (scripts/test_hamUI_menuterm_gop.sh, ENABLE_MENUTERM_SELFTEST=1). Same shape
# as the term marker above: plant /etc/hamui-menuterm-test so the PROVEN
# 2-token `hamUId daemon` autostart routes into the autoflag-49 menu-Terminal
# self-test, which drives the Applications-menu "Terminal" entry's real
# dispatch (menu_launch(0, ...)) and asserts it spawns /bin/hamterm as a
# SEPARATE process (wid + stdout pipe + auto-detected hamui markup), NOT the
# dormant in-daemon APP_TERM hand-drawn grid. Runs once, exits 0
# (restart:on-failure won't relaunch). Test build only.
if os.environ.get("ENABLE_MENUTERM_SELFTEST") == "1":
    FILES.append(("/etc/hamui-menuterm-test", b"1\n"))


# Live mouse-motion proof (scripts/test_hamUI_mouse_gop.sh,
# ENABLE_MOUSETEST_SELFTEST=1). Plant /etc/hamui-mouse-test so the PROVEN
# 2-token `hamUId daemon` autostart routes into the autoflag-50 live
# pointer-injection self-test: the daemon pumps /dev/mouse and reports
# "[mousetest] PASS" only when BOTH injected PS/2 relative motion (QMP
# input-send-event rel) and usb-tablet absolute motion (QMP abs) actually
# move CUR_X/CUR_Y. Runs once, exits 0. Test build only.
if os.environ.get("ENABLE_MOUSETEST_SELFTEST") == "1":
    FILES.append(("/etc/hamui-mouse-test", b"1\n"))


# Event-driven compositor scheduling proof
# (scripts/test_hamUI_evloop_gop.sh, ENABLE_EVLOOP_SELFTEST=1). Same shape as
# the markers above: plant /etc/hamui-evloop-test so the PROVEN 2-token
# `hamUId daemon` autostart routes into the autoflag-51 event-loop self-test,
# which asserts evl_wait() really parks in sys_waitfds (jiffy-verified),
# markup bodies re-rasterize ONLY on a per-layer gen change (idle frames do
# ZERO body reads / presents), the gen-triggered present is bounded by the
# window rect, a dead child's EOF'd stdout pipe gets closed (no hot-spin),
# and a pure cursor move stays on the blit fast path. Runs once, exits 0.
# Test build only.
if os.environ.get("ENABLE_EVLOOP_SELFTEST") == "1":
    FILES.append(("/etc/hamui-evloop-test", b"1\n"))


# Volume round-trip proof (scripts/test_hamUI_volume_gop.sh,
# ENABLE_VOLRT_SELFTEST=1). Plant /etc/hamui-volrt-test so the PROVEN
# 2-token `hamUId daemon` autostart routes into the autoflag-52 mixer
# round-trip self-test: the panel volume applet path (vol_step /
# vol_mute_toggle) writes ctl verbs to /dev/audioctl and each "[volrt]"
# marker only prints after an independent re-read of the /dev/audio
# status line shows the kernel mixer really changed. Needs QEMU's
# intel-hda device. Runs once, exits 0. Test build only.
if os.environ.get("ENABLE_VOLRT_SELFTEST") == "1":
    FILES.append(("/etc/hamui-volrt-test", b"1\n"))


# See INIT_ELF handling inside build_archive(): set INIT_ELF=path to
# override which on-disk file becomes /init in the cpio archive, e.g.
# to swap in a Hamnix-compiled user binary without touching user/init.S.


# Per-file POSIX mode for sensitive /etc/* entries (full cpio mode incl.
# the S_IFREG type nibble 0o100000). Everything not listed keeps the
# default 0644. The credential stores are 0600 root-owned so a non-root
# reader inside the Linux NS is denied by the kernel's cpio perm-check
# (fs/vfs.ad:_perm_check_cpio) while hostowner/root reads through.
_ETC_MODE_OVERRIDE = {
    "shadow":  0o100600,
    "gshadow": 0o100600,
}


def cpio_entry(name: str, data: bytes, mode: int = 0o100644) -> bytes:
    name_bytes = name.encode() + b"\0"
    header = (
        "070701"
        f"{1:08X}"                      # ino (any non-zero is fine)
        f"{mode:08X}"                   # mode (S_IFREG | 0644 by default)
        f"{0:08X}"                      # uid
        f"{0:08X}"                      # gid
        f"{1:08X}"                      # nlink
        f"{0:08X}"                      # mtime
        f"{len(data):08X}"              # filesize
        f"{0:08X}"                      # devmajor
        f"{0:08X}"                      # devminor
        f"{0:08X}"                      # rdevmajor
        f"{0:08X}"                      # rdevminor
        f"{len(name_bytes):08X}"        # namesize (incl NUL)
        f"{0:08X}"                      # check
    ).encode()
    # Pad after name so data starts 4-aligned from entry start.
    name_field_len = len(header) + len(name_bytes)
    name_pad = (-name_field_len) % 4
    # Pad after data so next entry starts 4-aligned.
    data_pad = (-len(data)) % 4
    return header + name_bytes + (b"\0" * name_pad) \
                  + data + (b"\0" * data_pad)


def cpio_symlink(name: str, target: str) -> bytes:
    # Emit a cpio entry with mode = S_IFLNK | 0777 whose data is the
    # NUL-terminated link target path. The trailing NUL is INCLUDED in
    # the entry's filesize so the in-kernel reader (fs/cpio.ad +
    # fs/vfs.ad's _lookup_name) can treat the bytes as a C-string and
    # resolve them with the same exact-match path lookup it uses for
    # regular files.
    #
    # The standard Linux cpio writer does NOT NUL-terminate symlink
    # data — it writes only the link-target bytes. Adding the NUL is
    # safe for any reader that consults `filesize` (we own the only
    # reader on the Hamnix side) and keeps the in-kernel string
    # comparator simple. It costs 1 byte per applet entry.
    payload = target.encode() + b"\0"
    return cpio_entry(name, payload, mode=0o120777)


def cpio_trailer() -> bytes:
    return cpio_entry("TRAILER!!!", b"")


def _embed_usb_hcd_chain(here: Path) -> bytes:
    """Embed the USB host-controller class L-shim chain (usbcore +
    xhci_pci + xhci_hcd + ehci_pci + ehci_hcd) into a cpio blob.

    This is load-bearing for the .ko-default root-on-USB path: the
    controller is brought up THROUGH these .kos BEFORE the ext4 root is
    online, so the .ko bytes MUST live in the initramfs (the rootfs
    partition is unreadable until USB enumerates). Both the normal fat
    cpio and the HAMNIX_CPIO_EMPTY=1 installed-kernel path
    (build_installer_img.sh Stage 3) call this so the export surface
    (xhci_init_driver / xhci_run / xhci_gen_setup) resolves identically in
    either build.

    See the inline notes at the original call site: the dep filename for
    xhci_hcd is the DASH form (xhci-hcd.ko) because `modinfo -F depends
    xhci_pci.ko` returns `xhci-hcd, usbcore`, and the in-kernel
    modules_dep parser walks dep tokens VERBATIM to build the lookup
    path.
    """
    blob = b""
    for ko_dir, ko_name, dep_filename in (
            ("usbcore",  "usbcore.ko",  "usbcore.ko"),
            ("xhci_pci", "xhci_pci.ko", "xhci_pci.ko"),
            ("xhci_hcd", "xhci_hcd.ko", "xhci-hcd.ko"),
            ("ehci_pci", "ehci_pci.ko", "ehci_pci.ko"),
            ("ehci_hcd", "ehci_hcd.ko", "ehci-hcd.ko"),
    ):
        ko_path = here / "kernel-modules" / ko_dir / ko_name
        if ko_path.is_file():
            data = ko_path.read_bytes()
            paths = [
                f"/lib/modules/{dep_filename}",
                f"/lib/modules/6.12/{dep_filename}",
            ]
            # Also plant the underscore-form filename if it differs from
            # the dep-form — userspace `insmod` users habitually type
            # xhci_hcd.ko (with underscore) since that's the modinfo
            # -F name output.
            if dep_filename != ko_name:
                paths += [
                    f"/lib/modules/{ko_name}",
                    f"/lib/modules/6.12/{ko_name}",
                ]
            for name in paths:
                blob += cpio_entry(name, data)
                print(f"  embedded {name} ({len(data)} bytes from "
                      f"kernel-modules/{ko_dir}/{ko_name})")
    return blob


def _embed_modules_dep(here: Path) -> bytes:
    """Embed the Linux-shape modules.dep dependency table for the
    in-kernel modules_dep parser (kernel/modules_dep.ad).

    The xhci_pci -> xhci-hcd -> usbcore dep chain is resolved from this
    table; without it the parser falls back to "load only the requested
    module, no deps", so xhci_pci's init_module fires before xhci_hcd is
    loaded and the cross-module ksymtab never registers xhci_init_driver.
    Shared by the normal and HAMNIX_CPIO_EMPTY=1 paths.
    """
    blob = b""
    kmods_root = here / "kernel-modules"
    if kmods_root.is_dir() and any(kmods_root.glob("*/*.ko")):
        import importlib.util as _ilu_dep
        _mod_dep_path = here / "scripts" / "build_modules_dep.py"
        _spec_dep = _ilu_dep.spec_from_file_location(
            "build_modules_dep", _mod_dep_path)
        if _spec_dep is None or _spec_dep.loader is None:
            raise SystemExit(
                f"build_initramfs: cannot import {_mod_dep_path}")
        _mod_dep = _ilu_dep.module_from_spec(_spec_dep)
        _spec_dep.loader.exec_module(_mod_dep)
        dep_text = _mod_dep.build_dep_table(kmods_root)
        dep_bytes = dep_text.encode()
        blob += cpio_entry("/lib/modules/modules.dep", dep_bytes)
        _dep_lines_n = sum(
            1 for ln in dep_text.splitlines()
            if ln and not ln.startswith("#"))
        print(f"  embedded /lib/modules/modules.dep "
              f"({len(dep_bytes)} bytes, {_dep_lines_n} module rows)")
    return blob


def build_archive() -> bytes:
    # bytearray, NOT bytes: the archive is assembled by ~hundreds of
    # `blob += cpio_entry(...)` appends. On an immutable `bytes` each `+=`
    # copies the whole accumulator (O(n^2)); once a large entry lands (e.g. the
    # ~500 MiB installer squashfs) every subsequent append recopies it, so
    # Stage 6 of the full-mirror image spends minutes memcpy-ing. A bytearray
    # extends in place (amortized O(1) per append) for byte-identical output.
    blob = bytearray()
    here = Path(__file__).resolve().parent.parent

    # HAMNIX_CPIO_EMPTY=1 — emit a cpio that contains NO files, only the
    # TRAILER. Used by scripts/build_installer_img.sh (Stage 3) for the
    # INSTALLED-system kernel that lands on the NVMe ESP: that system boots
    # ENTIRELY off the ext4 root (the kernel binds '#sysroot' / and ELF-loads
    # /init off
    # the partition — see init/main.ad + docs/rootfs_partition.md), so
    # the kernel needs NO embedded userland at all. The cpio symbol
    # (initramfs_cpio_base/size, fs/cpio.ad) still exists so the kernel
    # links and the `-kernel` developer/test path keeps a real cpio, but
    # the SHIPPED kernel image carries zero cpio userland bytes. This is
    # the "no cpio in the live install path" end state, achieved without
    # the wholesale `-kernel` test-harness rewrite that physically
    # deleting fs/cpio.ad would require (~380 test scripts boot via
    # run_x86_bare.sh's regenerated blob).
    if os.environ.get("HAMNIX_CPIO_EMPTY", "0") == "1":
        # Trailer-only userland — the installed disk boots off ext4 and
        # needs NO embedded userland. BUT the boot-MODE marker files
        # (/etc/xhci-ko*, etc.) are tiny gate files the kernel reads from
        # the cpio BEFORE the ext4 root is online — they select which USB
        # driver brings the root block device up. Those MUST survive into
        # the shipped image (e.g. ENABLE_XHCI_KO_REAL=1 makes the Linux
        # xhci_hcd.ko the default root-on-USB driver). So we emit the
        # /etc/* marker FILES here while still carrying zero userland.
        marker_blob = b""
        n_markers = 0
        for entry in FILES:
            name = entry[0]
            data = entry[1]
            e_mode = entry[2] if len(entry) == 3 else 0o100644
            if name.startswith("/etc/"):
                marker_blob += cpio_entry(name, data, mode=e_mode)
                n_markers += 1
        print("[build_initramfs] HAMNIX_CPIO_EMPTY=1: emitting %d /etc boot "
              "markers + trailer (installed disk boots off ext4)." % n_markers)
        # The .ko-default root-on-USB path (ENABLE_XHCI_KO_REAL=1, the
        # installed-kernel default in build_installer_img.sh) brings the USB controller
        # up THROUGH the Linux xhci_hcd.ko stack BEFORE the ext4 root is
        # online. The /etc/xhci-ko* markers above tell the kernel to take
        # that path, but the controller cannot enumerate — and the cross-
        # module ksymtab can never resolve xhci_init_driver / xhci_run /
        # xhci_gen_setup — unless the .ko bytes + modules.dep are ALSO in
        # the cpio. They CANNOT live on the ext4 root: the root is
        # unreadable until USB enumerates. So embed the USB host-controller
        # .ko chain + modules.dep here whenever the .ko USB path is armed.
        # (Without this the shipped image printed [xhci-real] but FAILED
        # stage1 with ksymtab xhci_init_driver=0x0 — the real-HW NUC #GP.)
        if os.environ.get("ENABLE_XHCI_KO_REAL", "0") == "1":
            here = Path(__file__).resolve().parent.parent
            print("[build_initramfs] HAMNIX_CPIO_EMPTY=1 + ENABLE_XHCI_KO_REAL"
                  "=1: also embedding USB host-controller .ko chain + "
                  "modules.dep (root-on-USB needs them before ext4 is "
                  "online).")
            marker_blob += _embed_usb_hcd_chain(here)
            marker_blob += _embed_modules_dep(here)
        return marker_blob + cpio_trailer()

    # HAMNIX_CPIO_LEAN=1 — strip everything from the cpio that the
    # rootfs partition (build/hamnix-rootfs.img, see
    # scripts/build_rootfs_img.py + docs/rootfs_partition.md) carries
    # instead. Used by scripts/build_iso.sh on the live-USB-style ISO
    # path: the kernel ELF embeds only what's load-bearing BEFORE the
    # block layer brings the rootfs partition online. Everything else
    # (the real Debian apt/dpkg slice, the busybox runtime shell, the
    # ~90 userland Adder binaries) lives on the ext4 partition.
    #
    # When unset (the default), every test that drives `-kernel ELF`
    # directly without attaching the rootfs.img keeps working: the
    # fat-cpio behaviour is preserved, including the in-cpio real
    # Debian apt/dpkg closure that test_linux_apt_install.sh asserts
    # against. Set HAMNIX_CPIO_LEAN=1 ONLY when the rootfs.img will
    # be reachable through the block layer at boot.
    cpio_lean = os.environ.get("HAMNIX_CPIO_LEAN", "0") == "1"

    # If INIT_ELF=<path> is set, embed that file as /init (overriding
    # whatever ELF in build/user/ would otherwise have grabbed the
    # /init slot). Lets us point /init at e.g. a Hamnix-compiled
    # user/hello.elf for one run without touching user/init.S or the
    # glob below. We track which on-disk path is acting as /init so
    # the directory glob doesn't re-embed it under its native name.
    init_override = os.environ.get("INIT_ELF")
    init_override_real: Path | None = None
    if init_override:
        p = Path(init_override)
        if not p.is_absolute():
            p = here / p
        if not p.exists():
            raise SystemExit(f"INIT_ELF={init_override}: file not found")
        data = p.read_bytes()
        # F10-3 #456: 0o755 so an override /init (most tests use this
        # to swap in hamsh.elf) lands with exec mode bits set. Matches
        # the default /init handling further below.
        blob += cpio_entry("/init", data, mode=0o100755)
        init_override_real = p.resolve()
        print(f"  embedded /init ({len(data)} bytes from "
              f"{p.relative_to(here) if p.is_relative_to(here) else p}) "
              f"[INIT_ELF override]")

    # U37: busybox multi-call applet staging. The kernel's _lookup_name
    # (fs/vfs.ad) returns the FIRST cpio entry matching a path — so we
    # plant busybox-bytes at common applet paths BEFORE the build/user
    # glob lands its Adder-built shadows. Without this, busybox sh's
    # PATH walk for `echo a | grep a` finds Adder grep at /bin/grep but
    # passes Linux-ABI argv to it (mismatched), and the pipe stalls.
    # With this, busybox sh finds busybox at every PATH entry it
    # probes; busybox's own argv[0] dispatcher selects the applet.
    # The cost is ~2 MiB per applet path in the initramfs; at the
    # 256 MiB qemu budget every U-track test uses, that's affordable.
    #
    # Source: tests/u-binary/busybox (a copy of u_busybox staged by
    # the test harness). When that file isn't present (CI without
    # host busybox), this block is a no-op.
    ubin_dir_pre = here / "tests" / "u-binary"
    busybox_bytes: bytes | None = None
    bb_src = ubin_dir_pre / "busybox"
    if bb_src.is_file():
        busybox_bytes = bb_src.read_bytes()
        # Curated minimal set. The goal is to cover the names busybox
        # sh actually walks during a `echo a | grep a`-style PATH search
        # without bloating /bin so much that downstream busybox ls /bin
        # output overflows the 4 KiB user stack glibc starts with.
        # /sbin and /usr/sbin paths are first in busybox's default PATH;
        # /bin/sh + /bin/grep are the names sh's exec-fallback touches.
        # When U38 grows the execve ustack we can widen this list back
        # to a full applet roster without breaking ls /bin regressions.
        bb_applets = [
            "/bin/sh",
            "/bin/grep",
            "/sbin/grep",
            "/usr/bin/grep",
            "/usr/sbin/grep",
        ]
        # F10-3 #456: executables under /bin, /sbin, /usr/bin, /usr/sbin
        # ship with S_IFREG | 0o755 so a non-hostowner caller can exec
        # them. Pre-F10-3 every userland task ran as uid 1 and the cpio
        # dispatcher bypass admitted exec regardless of mode bits; with
        # the default uid flipped to NOBODY (65534), the 0o644 entries
        # would deny exec via the cpio mode-bit policy
        # (_perm_check_cpio in fs/vfs.ad). Every real Unix ships
        # binaries world-executable; do the same here.
        for applet in bb_applets:
            blob += cpio_entry(applet, busybox_bytes, mode=0o100755)
        print(f"  staged busybox at {len(bb_applets)} applet paths "
              f"({len(bb_applets) * len(busybox_bytes)} bytes total)")

    # Userland ELFs: anything in build/user/ lands at /bin/<name>.
    # Exception: init.elf is the kernel's boot entrypoint and
    # always goes to /init (unless overridden via INIT_ELF above).
    # Everything else is found by hamsh's PATH walker.
    #
    # The full native Adder toolset (~110 ELFs, ~2.2 MiB total) ALWAYS
    # lives in the cpio, even on the lean ISO path. The cpio is baked
    # into the kernel ELF and is the ONLY filesystem guaranteed
    # readable on every boot medium (CD/ATAPI, USB, virtio, AHCI) —
    # the ext4 rootfs partition is unreachable off a GNOME Boxes CD or
    # a real-HW USB stick, so anything stripped to the partition simply
    # disappears there ("no commands found"). At ~2.2 MiB the toolset
    # is negligible against the 32 MB ESP budget (kernel ELF 26→28 MB).
    # HAMNIX_CPIO_LEAN therefore strips ONLY the heavy distro closure
    # (busybox runtime + the real Debian apt/dpkg slice, tens of MB);
    # the native tools are never lean-stripped. This restores 70a6715
    # ("keep native Adder userland tools in the lean cpio"), which
    # 4c8c10b had wrongly undone.
    user_dir = here / "build" / "user"
    if user_dir.is_dir():
        for elf in sorted(user_dir.glob("*.elf")):
            if init_override_real is not None:
                if elf.resolve() == init_override_real:
                    # This ELF is already embedded above as /init. Still
                    # expose it at /bin/<name> so a NESTED invocation (a
                    # subshell — e.g. `hamsh` launched from the interactive
                    # hamsh that is running as /init) can be found on PATH.
                    # The /init slot keeps its own copy; this is an extra,
                    # harmless world-exec entry (~a few hundred KiB).
                    bin_name = "/bin/" + elf.stem
                    blob += cpio_entry(bin_name, elf.read_bytes(),
                                       mode=0o100755)
                    print(f"  embedded {bin_name} ({elf.stat().st_size} "
                          f"bytes from build/user/{elf.name}, override "
                          f"also on PATH)")
                    continue
                if elf.name == "init.elf":
                    continue          # /init slot is taken by override
            data = elf.read_bytes()
            if elf.name == "init.elf" and init_override_real is None:
                # Default /init = the asm-built init.elf — kernel
                # reads this at boot. F10-3 #456: 0o755 so a future
                # ext4 layout that exec()s /init through the dispatcher
                # finds the exec bit set (the boot path itself loads
                # /init directly into PID 1 without an exec-perm check,
                # so this is defense-in-depth not load-bearing here).
                blob += cpio_entry("/init", data, mode=0o100755)
                print(f"  embedded /init ({len(data)} bytes from "
                      f"build/user/{elf.name})")
                continue
            # F10-3 #456: native userland ELFs land under /bin with
            # S_IFREG | 0o755 so hamsh's PATH walker can exec them
            # post-F10-3 (the default-uid-is-NOBODY flip in
            # kernel/sched/core.ad's create_user_thread). The cpio
            # dispatcher pre-F10-3 admitted exec for the implicit
            # hostowner uid=1 default; with NOBODY as the default,
            # /bin/* needs world-x mode bits.
            bin_name = "/bin/" + elf.stem
            blob += cpio_entry(bin_name, data, mode=0o100755)
            print(f"  embedded {bin_name} ({len(data)} bytes from "
                  f"build/user/{elf.name})")

    # HAMNIX_HAMSH_RC=<path>: when set, replace etc/hamsh.rc (or plant
    # one if absent) with the file at <path>. Used by tests that drive
    # hamsh as /init (INIT_ELF=hamsh.elf) and want their own startup
    # script — the default boot path uses /etc/rc.boot (argv[1]) instead,
    # so /etc/hamsh.rc is normally empty/absent. Override applies before
    # the etc/ glob so the test's rc isn't shadowed by a committed file.
    hamsh_rc_override = os.environ.get("HAMNIX_HAMSH_RC")
    hamsh_rc_override_real: Path | None = None
    if hamsh_rc_override:
        p = Path(hamsh_rc_override)
        if not p.is_absolute():
            p = here / p
        if not p.exists():
            raise SystemExit(f"HAMNIX_HAMSH_RC={hamsh_rc_override}: "
                             f"file not found")
        hamsh_rc_override_real = p.resolve()
        data = p.read_bytes()
        blob += cpio_entry("/etc/hamsh.rc", data)
        print(f"  embedded /etc/hamsh.rc ({len(data)} bytes from "
              f"{p.relative_to(here) if p.is_relative_to(here) else p}) "
              f"[HAMNIX_HAMSH_RC override]")

    # Baseline /etc files: anything in etc/ gets embedded as /etc/<name>
    # so userland (motd, hostname, future login/init scripts) can read
    # config from a Linux-conventional path without baking strings into
    # binaries. Edit etc/* and re-run this script to refresh.
    #
    # Sub-directories under etc/ are walked one level deep and their
    # files land at /etc/<subdir>/<file>. This is how /etc/svc/<name>.hamsh
    # (init-side service-supervisor definition files) reach userland:
    # hamsh's `svc start <name>` builtin opens /etc/svc/<name>.hamsh and
    # parses the key:value lines. Symlinks and nested sub-dirs are
    # intentionally not followed — the cpio layout is one shallow level.
    etc_dir = here / "etc"
    if etc_dir.is_dir():
        for ef in sorted(etc_dir.iterdir()):
            if ef.is_file():
                # Skip etc/hamsh.rc if a HAMNIX_HAMSH_RC override already
                # planted one — the first cpio entry wins in _lookup_name,
                # but listing both is wasteful and confusing.
                if hamsh_rc_override_real is not None \
                        and ef.name == "hamsh.rc":
                    continue
                data = ef.read_bytes()
                name = "/etc/" + ef.name
                # Per-file POSIX mode override. The credential stores MUST
                # ship 0600 root-owned so the kernel's cpio server-boundary
                # perm-check (_perm_check_cpio in fs/vfs.ad) denies a
                # non-root reader (e.g. `dave`, uid 1000) inside `enter
                # linux` while hostowner (Linux root) bypasses. Without this
                # they staged at the default 0644 and were world-readable —
                # the leak the multi-user (#497) work flagged.
                e_mode = _ETC_MODE_OVERRIDE.get(ef.name, 0o100644)
                blob += cpio_entry(name, data, mode=e_mode)
                print(f"  embedded {name} ({len(data)} bytes from "
                      f"etc/{ef.name}, mode={e_mode & 0o7777:04o})")
            elif ef.is_dir():
                # etc/man/ is staged at the conventional Unix manpage
                # path /usr/share/man/<topic>.<N>.md. Source-of-truth
                # for the page bytes lives at etc/man/ in the tree (so
                # gen_install_manifest.py and rc.boot can find it
                # without a separate copy step), but every consumer
                # looks under /usr/share/man/ at runtime — that's
                # where `man <topic>` reads from.
                if ef.name == "man":
                    for sub in sorted(ef.iterdir()):
                        if sub.is_file():
                            data = sub.read_bytes()
                            name = "/usr/share/man/" + sub.name
                            blob += cpio_entry(name, data)
                            print(f"  embedded {name} ({len(data)} bytes "
                                  f"from etc/man/{sub.name})")
                    continue
                for sub in sorted(ef.iterdir()):
                    if sub.is_file():
                        # The markup-client keystone selftest needs the
                        # hamUId daemon (autoflag 46) to be the runlevel-5
                        # hami service that the supervisor autostarts. Both
                        # hamde.svc and hamuid.svc are enabled at runlevel 5,
                        # and the supervisor brings up only ONE of them per
                        # boot (whichever sorts first) — `hamde.svc` < `hamuid.svc`,
                        # so hamde would win and starve hamUId. For the
                        # selftest build, drop hamde.svc so hamUId autostarts
                        # deterministically.
                        if (os.environ.get("ENABLE_MKC_SELFTEST") == "1"
                                or os.environ.get("ENABLE_SPINE_SELFTEST") == "1"
                                or os.environ.get("ENABLE_TERM_SELFTEST") == "1"
                                or os.environ.get("ENABLE_MENUTERM_SELFTEST") == "1"
                                or os.environ.get("ENABLE_MOUSETEST_SELFTEST") == "1"
                                or os.environ.get("ENABLE_EVLOOP_SELFTEST") == "1"
                                or os.environ.get("ENABLE_VOLRT_SELFTEST") == "1") \
                                and ef.name == "services.d" \
                                and sub.name == "hamde.svc":
                            print("  [selftest] skipping "
                                  "etc/services.d/hamde.svc so hamUId "
                                  "autostarts the keystone/spine selftest")
                            continue
                        # FIRST-BOOT UX: the DE self-test fragment
                        # etc/rc.d/rc.5.selftest (the demo-app launches + #99
                        # [visual_gate] render self-test that rc.5 `source`s)
                        # is embedded ONLY when a DE render gate builds with
                        # HAMNIX_DE_SELFTEST=1. A normal build omits it, so
                        # rc.5's `source` no-ops and the first boot is clean.
                        if (ef.name == "rc.d" and sub.name == "rc.5.selftest"
                                and os.environ.get("HAMNIX_DE_SELFTEST") != "1"):
                            print("  [first-boot] omitting etc/rc.d/"
                                  "rc.5.selftest (clean boot; set "
                                  "HAMNIX_DE_SELFTEST=1 for the render gate)")
                            continue
                        data = sub.read_bytes()
                        name = "/etc/" + ef.name + "/" + sub.name
                        blob += cpio_entry(name, data)
                        print(f"  embedded {name} ({len(data)} bytes "
                              f"from etc/{ef.name}/{sub.name})")
                    elif sub.is_dir():
                        # One extra nesting level (e.g. etc/hamde/apps/*.desktop
                        # — the DATA-DRIVEN Applications menu catalogue the
                        # scene panel scans at /etc/hamde/apps). The cpio is a
                        # flat name table, so just embed each nested file at its
                        # full /etc/<a>/<b>/<file> path.
                        for f2 in sorted(sub.iterdir()):
                            if f2.is_file():
                                data = f2.read_bytes()
                                name = ("/etc/" + ef.name + "/"
                                        + sub.name + "/" + f2.name)
                                blob += cpio_entry(name, data)
                                print(f"  embedded {name} ({len(data)} bytes "
                                      f"from etc/{ef.name}/{sub.name}/{f2.name})")

    # Linux runtime shell: plant a busybox-static binary + applet
    # symlinks into the default distro tree so `enter linux { /bin/sh }`
    # finds a working shell out of the box. Without this, the default
    # `linux` namespace recipe (etc/rc.boot: bind / /var/lib/distros/
    # default) resolves /bin/sh into the distro tree at
    # /var/lib/distros/default/bin/sh — which doesn't exist, so the
    # exec returns -ENOENT before anything runs. End-game goal #3
    # ("Run non-graphical Linux binaries") starts with: the user can
    # type `enter linux { /bin/sh }` and get a shell.
    #
    # SOURCE (preference order, picked the first that works):
    #   (a) Pre-built host fixture tests/u-binary/u_busybox_musl —
    #       built once by `make -C tests/u-binary/src/musl_busybox
    #       install` and gitignored (~1 MB musl-static-PIE ET_DYN
    #       busybox, no PT_INTERP, OSABI stamped ELFOSABI_LINUX,
    #       same fixture the U29/U36/U40 tests already use). The
    #       Hamnix ELF loader knows how to run this shape.
    #   (b) (Future) build it on the fly from
    #       tests/u-binary/src/musl_busybox/ if absent — requires
    #       musl-gcc + a network round-trip to fetch the busybox
    #       upstream tarball. Skipped for now to keep the default
    #       ISO build offline-deterministic; if the host hasn't built
    #       u_busybox_musl yet, the default ISO ships WITHOUT a
    #       Linux runtime shell (back to the pre-fix behaviour),
    #       and the build prints a one-line note.
    #   (c) Host's /usr/bin/busybox (apt-installed busybox-static)
    #       — REJECTED: on Debian today this is dynamically linked
    #       (BuildID + interpreter /lib64/ld-linux-x86-64.so.2), so
    #       running it inside the hermetic distro namespace would
    #       require a full glibc tree as well. The musl-static-PIE
    #       fixture is self-contained.
    #
    # APPLETS: each applet name is planted as an S_IFLNK cpio entry
    # pointing at /var/lib/distros/default/bin/busybox. cpio_symlink()
    # below emits a mode=0o120777 entry with NUL-terminated target
    # data; fs/vfs.ad's _lookup_name follows the link to the real
    # busybox bytes. One header per applet vs ~1 MB of duplicate
    # data per applet — ~15 KB total overhead instead of ~15 MB.
    bb_src = here / "tests" / "u-binary" / "u_busybox_musl"
    if cpio_lean:
        print(f"  [LEAN] skipping in-cpio busybox staging — Linux "
              f"runtime shell lives at /var/lib/distros/default/bin/"
              f"busybox on rootfs.img")
    elif bb_src.is_file():
        bb_bytes = bb_src.read_bytes()
        bb_target = "/var/lib/distros/default/bin/busybox"
        blob += cpio_entry(bb_target, bb_bytes, mode=0o100755)
        # Curated applet list — enough for "this feels like a shell":
        # sh / ls / cat / echo / cp / mv / rm / mkdir / pwd / grep /
        # head / tail / wc / true / false / env / printf / date /
        # sleep / basename / dirname. (cd is a shell builtin and does
        # not need its own executable.) busybox itself dispatches by
        # argv[0], so a symlink at /bin/sh -> busybox runs the sh
        # applet automatically.
        bb_applets = [
            "sh", "ash",
            "ls", "cat", "echo", "cp", "mv", "rm", "mkdir",
            "pwd", "grep", "head", "tail", "wc",
            "true", "false", "env", "printf", "date",
            "sleep", "basename", "dirname",
            # ps reads /proc/<pid>/{stat,cmdline} + stats each /proc/<pid>
            # dir — the QA-N17 pid-dir-stat fix is what makes it print rows.
            "ps",
        ]
        for applet in bb_applets:
            link = f"/var/lib/distros/default/bin/{applet}"
            blob += cpio_symlink(link, bb_target)
        print(f"  staged Linux runtime shell: busybox ({len(bb_bytes)} "
              f"bytes from {bb_src.relative_to(here)}) + "
              f"{len(bb_applets)} applet symlinks under "
              f"/var/lib/distros/default/bin/")
    else:
        print(f"  WARN: {bb_src.relative_to(here)} absent — `enter linux"
              f" {{ /bin/sh }}` will not work on this build. Run "
              f"`make -C tests/u-binary/src/musl_busybox install` to "
              f"stage the fixture.")

    # PROVENANCE marker for /var/lib/distros/default/ (the #distro
    # backing the `enter linux { ... }` recipe freezes to in -kernel /
    # test builds). This file exists ONLY in the distro tree, never at
    # the native cpio root, so it is the deterministic needle the
    # isolation gates (test_enter_linux_distro_root.sh,
    # test_enter_linux_two_spawns.sh) grep for to prove `enter linux
    # { ls / }` is a SEPARATE file server from the native `/`. Mirrors
    # build_rootfs_img.py::_plant_distro_provenance for the live image.
    # Skipped only in cpio_lean mode (the slice rides on rootfs.img,
    # which already plants its own PROVENANCE).
    if not cpio_lean:
        prov = (b"hamnix-distro-namespace: Debian-shape root "
                b"(/var/lib/distros/default, cpio fixture)\n"
                b"This tree backs '#distro' / inside "
                b"`enter linux { ... }`.\n"
                b"It is a SEPARATE file server from the native "
                b"Hamnix '/'.\n")
        blob += cpio_entry("/var/lib/distros/default/PROVENANCE",
                           prov, mode=0o100644)
        print("  planted /var/lib/distros/default/PROVENANCE "
              "(distro-only isolation needle)")

    # Distro-shape backing trees. Walk every subdirectory under
    # tests/distros/ and embed each file at
    # /var/lib/distros/<distro>/<rel-path>. Mirrors the etc/ glob's
    # shape but recurses, so a tiny test fixture like
    #   tests/distros/testdistro/etc/debian_version
    # lands at
    #   /var/lib/distros/testdistro/etc/debian_version
    # in the cpio archive, ready for `bind` to splice it under a
    # privatised namespace's /etc. The `default` fixture is the
    # backing /etc/rc.boot's `linux` namespace recipe grafts —
    # running a Linux binary is `enter linux { ... }` (or the
    # `debian` alias), no bespoke launcher. Real debootstrap-style
    # trees are too large to commit here — these are the smoke-test
    # fixtures for scripts/test_distro_namespace.sh.
    #
    # SIZE GATE for real debootstrap'd backings:
    # `tests/distros/debian-minbase/rootfs/` is ~80-150 MB of real
    # Debian binaries (see tests/distros/debian-minbase/HOWTO.md).
    # Embedding it by default would inflate fs/initramfs_blob.S past
    # GitHub's 100 MB push limit, AND blow past fs/cpio.ad's NR_FILES
    # cap (currently 192, well under debootstrap's ~5000 files). Mirror
    # the HAMNIX_EMBED_UBIN opt-in pattern: only embed
    # `debian-minbase/rootfs/` (and any sibling distro whose root is a
    # `rootfs/` subdir) when HAMNIX_EMBED_DEBIAN is set, and gate the
    # embed scope by the env var's value:
    #
    #     HAMNIX_EMBED_DEBIAN=minimal   (default if set)
    #         Curated subset that fits under NR_FILES + initramfs_blob.S
    #         size sanity: /etc/debian_version, /etc/os-release,
    #         /etc/passwd, /etc/group. Enough to prove the namespace
    #         bind grafts the REAL debootstrap'd /etc/ over Hamnix's,
    #         which is what test_distro_debian.sh asserts.
    #     HAMNIX_EMBED_DEBIAN=full
    #         Walk every file in rootfs/. Currently exceeds NR_FILES;
    #         lands when fs/cpio.ad bumps the cap and the kernel
    #         build path can ingest a ~250 MB cpio archive without
    #         turning fs/initramfs_blob.S into a multi-GB .S file.
    #     HAMNIX_EMBED_DEBIAN=1
    #         Backward-compatible alias for `minimal`.
    #
    # Tiny synthetic fixtures (e.g. tests/distros/testdistro/) without
    # a `rootfs/` layer are always embedded.
    embed_debian_raw = os.environ.get("HAMNIX_EMBED_DEBIAN", "0")
    if embed_debian_raw in ("0", "", "off", "no"):
        embed_debian_mode: str | None = None
    elif embed_debian_raw in ("1", "minimal", "min"):
        embed_debian_mode = "minimal"
    elif embed_debian_raw in ("full", "all"):
        embed_debian_mode = "full"
    else:
        raise SystemExit(
            f"HAMNIX_EMBED_DEBIAN={embed_debian_raw!r}: "
            f"expected one of {{0, 1, minimal, full}}")

    # Curated minimal embed set: relative paths under rootfs/ that
    # the test_distro_debian.sh assertions actually touch. Keep this
    # short — every entry consumes one of NR_FILES slots in
    # fs/cpio.ad and adds ~6x its byte size to fs/initramfs_blob.S.
    DEBIAN_MINIMAL_PATHS = [
        "etc/debian_version",
        "etc/os-release",
        "etc/passwd",
        "etc/group",
        "etc/hostname",
        "usr/lib/os-release",  # /etc/os-release symlink target
    ]

    distros_dir = here / "tests" / "distros"
    if distros_dir.is_dir():
        for distro_root in sorted(distros_dir.iterdir()):
            if not distro_root.is_dir():
                continue
            # If the distro stages its tree under a `rootfs/` subdir
            # (debootstrap convention: BUILD.sh emits ./rootfs/), use
            # that subdir as the embed source and gate it behind
            # HAMNIX_EMBED_DEBIAN. Tiny fixtures without rootfs/
            # (testdistro) embed unconditionally as before.
            rootfs_sub = distro_root / "rootfs"
            if rootfs_sub.is_dir():
                if embed_debian_mode is None:
                    print(f"  skipped tests/distros/{distro_root.name}/rootfs/ "
                          f"(set HAMNIX_EMBED_DEBIAN=1 to embed)")
                    continue
                embed_root = rootfs_sub
                if embed_debian_mode == "minimal":
                    src_iter = []
                    for rel in DEBIAN_MINIMAL_PATHS:
                        p = embed_root / rel
                        if p.is_file():
                            src_iter.append(p)
                else:  # full
                    src_iter = [p for p in sorted(embed_root.rglob("*"))
                                if p.is_file()]
            else:
                embed_root = distro_root
                src_iter = [p for p in sorted(embed_root.rglob("*"))
                            if p.is_file()]
            n_embedded = 0
            n_bytes = 0
            for src in src_iter:
                rel = src.relative_to(embed_root)
                name = ("/var/lib/distros/" + distro_root.name
                        + "/" + str(rel))
                try:
                    data = src.read_bytes()
                except (OSError, PermissionError):
                    # Some debootstrap'd files (e.g. /etc/shadow, mode
                    # 0640 root:shadow) are unreadable by the calling
                    # user. Skip with a note rather than fail the build.
                    print(f"  skipped {name} (unreadable)")
                    continue
                blob += cpio_entry(name, data)
                n_embedded += 1
                n_bytes += len(data)
            if rootfs_sub.is_dir():
                print(f"  embedded {n_embedded} files ({n_bytes} bytes) "
                      f"from tests/distros/{distro_root.name}/rootfs/ "
                      f"[HAMNIX_EMBED_DEBIAN={embed_debian_mode}]")
            else:
                print(f"  embedded {n_embedded} files ({n_bytes} bytes) "
                      f"from tests/distros/{distro_root.name}/")

    # HAMNIX_DEFAULT_REAL_DEBIAN=1 — stage REAL Debian apt/dpkg into the
    # `default` distro tree. The orchestrator's V0 of "real package
    # management" runs `enter linux { /usr/bin/apt-get install hello }`,
    # which needs the genuine Debian apt + dpkg binaries (and their
    # dynamic-link closure) at /var/lib/distros/default/usr/bin/apt-get
    # etc. — the linux/debian namespaces in etc/rc.boot bind / to
    # /var/lib/distros/default, so /usr/bin/apt-get inside an
    # `enter linux { }` block resolves to that cpio path.
    #
    # Source: tests/distros/debian-minbase/rootfs/ (debootstrap'd by
    # tests/distros/debian-minbase/BUILD.sh; gitignored). When that
    # tree is absent the env var is a no-op + warning, exactly like
    # u_busybox_musl: tests that need real apt skip themselves.
    #
    # CURATED file list (not full rootfs) — the goal is to ship
    # `apt-get --version`, `dpkg --version`, and a fork-exec'd
    # `apt-get install hello` end-to-end. Walking the full ~4500-file
    # rootfs would inflate fs/initramfs_blob.S past GitHub's 100 MB
    # push limit and burn most of fs/cpio.ad's NR_FILES (8192) on
    # files apt/dpkg never touch. The list below is the closure of
    # `ldd /usr/bin/{apt-get,dpkg,dpkg-deb}` plus the /etc files apt
    # reads at startup, plus the ld.so + libc pair every dynamic
    # binary needs.
    # HAMNIX_DEFAULT_REAL_DEBIAN defaults to "1" (real Debian apt/dpkg
    # staged). Set "0"/"off"/"no" to fall back to the busybox-only fixture
    # (smaller ISO, no real-apt). Per user direction 2026-05-26: Hamnix
    # is meant to ship as a real distro — real Debian is the default.
    real_debian_raw = os.environ.get("HAMNIX_DEFAULT_REAL_DEBIAN", "1")
    if cpio_lean:
        # LEAN mode: real Debian closure is staged into rootfs.img by
        # scripts/build_rootfs_img.py (which honours
        # HAMNIX_DEFAULT_REAL_DEBIAN with the same default-on semantics).
        # Skip the in-cpio embed entirely to keep the kernel ELF small.
        print(f"  [LEAN] real Debian apt/dpkg slice: skipped from cpio "
              f"(staged into rootfs.img instead, "
              f"HAMNIX_DEFAULT_REAL_DEBIAN={real_debian_raw})")
    elif real_debian_raw not in ("0", "", "off", "no"):
        minbase_rootfs = (here / "tests" / "distros" / "debian-minbase"
                          / "rootfs")
        if not minbase_rootfs.is_dir():
            print(f"  WARN: HAMNIX_DEFAULT_REAL_DEBIAN={real_debian_raw}"
                  f" but {minbase_rootfs.relative_to(here)} absent — "
                  f"run tests/distros/debian-minbase/BUILD.sh first")
        else:
            # Curated closure for `apt-get install hello` end-to-end.
            # All paths are RELATIVE to minbase_rootfs/.
            REAL_DEBIAN_FILES = [
                # GENUINE Debian shell. `enter linux { /bin/dash }` (the
                # real Debian /bin/sh -> dash) runs the actual Debian
                # shell, not just the busybox fallback. dash is tiny
                # (~125 KB) and its dynamic closure is only ld.so + libc
                # (already staged below); the usrmerge expansion plants
                # it at /bin/dash too. bash (1.2 MB + libtinfo) is staged
                # ONLY into the ext4 rootfs image (build_rootfs_img.py),
                # NOT this in-cpio slice — the `-kernel` boot loads the
                # whole cpio into the 256 MB guest, so the heavy bash is
                # kept off the RAM-constrained in-cpio path.
                "usr/bin/dash",
                # /bin/sh — the POSIX shell name dpkg's maintainer-script and
                # helper-program resolution searches for ("'sh' not found in
                # PATH or not executable" otherwise). In the rootfs this is a
                # symlink bin/sh -> dash; read_bytes() follows it, so staging
                # the name plants dash's bytes (mode 0755) at /bin/sh — a real
                # executable entry dpkg's PATH stat finds. (usr/bin/dash + the
                # usrmerge alias already give /usr/bin/dash and /bin/dash; this
                # adds the `sh` spelling dpkg looks for first.)
                "bin/sh",
                "usr/bin/sh",
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
                # Dynamic linker + libc (every dynamic binary needs them).
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
                # /etc essentials — apt reads these at startup, dpkg
                # reads admindir status / available.
                "etc/debian_version",
                "etc/os-release",
                "etc/passwd",
                "etc/group",
                # BLOCKER 3 (NSS getpwnam): dpkg resolves system users
                # (getpwnam("root")) through glibc NSS while reading its
                # statoverride DB. Without /etc/nsswitch.conf glibc falls back
                # to a compiled-in default whose service modules may not load
                # in the curated namespace, and dpkg aborts:
                #   "unknown system user 'root' in statoverride file".
                # Stage the conf (its "passwd: files" line points NSS straight
                # at /etc/passwd) plus the libnss_files / libnss_compat service
                # modules (the libdir glob below also catches them; pinning
                # makes the closure self-documenting). getpwnam("root") then
                # reads /etc/passwd directly and resolves.
                "etc/nsswitch.conf",
                "usr/lib/x86_64-linux-gnu/libnss_files.so.2",
                "usr/lib/x86_64-linux-gnu/libnss_compat.so.2",
                # glibc resolves the NSS service module (libnss_files.so.2) at
                # RUNTIME via dlopen of a bare soname, which consults the
                # ld.so cache to locate it. Without the cache the dlopen can
                # miss and getpwnam("root") returns NULL even with the lib
                # staged. Stage the debootstrap-generated cache + ld.so.conf
                # so the runtime NSS dlopen finds the module.
                "etc/ld.so.cache",
                "etc/ld.so.conf",
                "etc/hostname",
                "etc/apt/sources.list",
                "etc/apt/apt.conf",
                # apt.conf.d FRAGMENT files. libapt's ReadConfigDir()
                # readdir()s /etc/apt/apt.conf.d/ at startup; with the
                # directory empty (no fragment entries staged in the flat
                # cpio name table) the readdir returns nothing and libapt
                # logs "Unable to read /etc/apt/apt.conf.d/ -
                # DirectoryExists" then aborts before any fetch. Staging
                # the fragment FILES makes the cpio's synthesized readdir
                # of that prefix enumerate them, satisfying ReadConfigDir.
                # (The 00hamnix auth/insecure fragment, when present, is
                # staged by scripts/stage_host_dpkg_rootfs.sh and globbed
                # below; the two debootstrap-shipped fragments below are
                # the minimum the directory needs to be non-empty.)
                "etc/apt/apt.conf.d/01autoremove",
                "etc/apt/apt.conf.d/70debconf",
                # dpkg DATA TABLES. libapt's APT::Configuration architecture
                # resolution reads /usr/share/dpkg/cputable + tupletable to
                # map the dpkg CPU/arch names; without them apt-get aborts
                # with "E: Error reading the CPU table" before parsing any
                # index. dpkg itself (dpkg-architecture, dpkg-split) reads
                # ostable/abitable too. Stage the whole small table set.
                "usr/share/dpkg/cputable",
                "usr/share/dpkg/tupletable",
                "usr/share/dpkg/ostable",
                "usr/share/dpkg/abitable",
                "usr/share/dpkg/triplettable",
                # dpkg's admindir scaffolding (status starts empty;
                # available may be absent — both files are looked up
                # by dpkg but missing-is-OK after a fresh debootstrap).
                "var/lib/dpkg/status",
                "var/lib/dpkg/available",
                "var/lib/dpkg/diversions",
                "var/lib/dpkg/statoverride",
                # Trusted GPG keyring (apt needs an anchor; the
                # Debian-shipped one is the canonical source).
                "usr/share/keyrings/debian-archive-keyring.gpg",
                "etc/apt/trusted.gpg.d/debian-archive-keyring.gpg",
                # --- OFFLINE apt-get install / dpkg -i closure ---------
                # Goal: `enter linux { apt-get install -y hamhello }` (and
                # the shorter `dpkg -i .../hamhello.deb`) actually populate
                # the live filesystem from a local file:// repo, with the
                # installed binary running afterwards. That fork chain is
                #   apt-get -> /usr/lib/apt/methods/file  (fetch the .deb)
                #           -> dpkg --unpack -> dpkg-deb (-> tar -> gzip)
                #           -> coreutils (rm/mv/cp/mkdir/chmod/...) for the
                #              filesystem install + admindir bookkeeping.
                # Each tool's .so closure is covered by the glob-libs
                # augmentation below (every lib*.so* in the libdir).
                #
                # apt download "methods" — the file:// fetcher (and copy,
                # apt's local-mirror cousin). Without these apt-get can
                # parse the repo but cannot retrieve the .deb.
                "usr/lib/apt/methods/file",
                "usr/lib/apt/methods/copy",
                # apt's INDEX decompress/store worker. `apt-get update`
                # hands the fetched Packages index to the `store:` method
                # (apt's pkgAcqIndex routes the acquired index URI through
                # store: to decompress + record it into /var/lib/apt/lists).
                # libapt's pkgAcquire::Worker::Start() FileExists()-checks the
                # method binary BEFORE forking; with store absent that check
                # fails and apt aborts the whole update with
                #   "E: The method driver /usr/lib/apt/methods/store could
                #    not be found. N: Is the package apt-transport-store
                #    installed?"
                # — so the index never builds and the subsequent
                # `apt-get install` reports "Unable to locate package".
                # store's .so closure (libapt-pkg, libstdc++, libz/bz2/lzma/
                # lz4/zstd, libseccomp) is already covered by the glob-libs
                # augmentation below, so only the method binary needs pinning.
                "usr/lib/apt/methods/store",
                # apt's HTTP fetch method — the LIVE network path. With
                # HAMNIX_APT_NET=1 the staged sources.list points at
                # http://deb.debian.org/debian, and `apt-get update`/
                # `install` fork /usr/lib/apt/methods/http to fetch the
                # Release/Packages indices + the .deb over TCP through the
                # SLIRP gateway. Its extra .so closure (libssl.so.3) is
                # covered by the libdir glob below. Harmless on the offline
                # path (no http source configured -> method never forked).
                "usr/lib/apt/methods/http",
                # apt's GPG signature-verification method + the real gpgv
                # verifier it execs. `apt-get update` over the LIVE
                # deb.debian.org archive verifies the InRelease signature
                # against the debian-archive-keyring; with the gpgv METHOD
                # absent apt aborts "method driver /usr/lib/apt/methods/gpgv
                # could not be found", and with the gpgv BINARY absent the
                # method can't exec the verifier. Stage both (+ libgcrypt/
                # libgpg-error closure, caught by the libdir glob below).
                "usr/lib/apt/methods/gpgv",
                "usr/bin/gpgv",
                # No-op gpgv acquire-method shim (scripts/
                # stage_host_dpkg_rootfs.sh writes it). 00hamnix's
                # `Dir::Bin::Methods::gpgv` points apt at THIS instead of the
                # stock gpgv method, whose real-gpgv verifier child exits 100
                # under linux_abi ("E: Method gpgv has died unexpectedly!").
                # The shim speaks apt's method protocol and reports every
                # InRelease as verified (201 URI Done), so `apt-get update`
                # against the [trusted=yes] deb.debian.org source commits its
                # index; the genuine .deb is still downloaded from the real
                # archive. Embedded as a regular file (POSIX sh; runs under
                # the staged dash, no extra .so closure).
                "usr/lib/apt/methods/hamnix-gpgv-noop",
                # dpkg unpack/install helpers. dpkg forks dpkg-deb to
                # extract data.tar; dpkg-split/-query round out the admin
                # surface dpkg touches during an install.
                "usr/bin/dpkg-deb",
                "usr/bin/dpkg-query",
                "usr/bin/dpkg-split",
                # dpkg's maintainer-script + configure helpers. dpkg
                # findprog()'s these by PATH during unpack/configure; if
                # absent it warns "N expected programs not found in PATH"
                # (ldconfig runs in the libc trigger, start-stop-daemon in
                # many postinst scripts). Staged from the rootfs sbin tree
                # (usrmerge alias plants them at /sbin too).
                "usr/sbin/ldconfig",
                "usr/sbin/start-stop-daemon",
                # dpkg-deb forks tar, which forks the decompressor; the
                # leaf hamhello .deb uses gzip (data.tar.gz). These MUST be
                # spelled `usr/bin/<x>` (NOT `bin/<x>`): the host-staged
                # rootfs (scripts/stage_host_dpkg_rootfs.sh) puts the real
                # binaries ONLY under usr/bin/ — its bin/ holds just the
                # sh/dash symlinks. A `bin/tar` entry's
                # `(minbase_rootfs / "bin/tar").is_file()` is False, so the
                # embed loop SILENTLY SKIPS it (added to `missing`) and the
                # Debian tar never lands in the cpio. dpkg-deb then
                # execvp("tar")'s PATH walk misses /usr/bin/tar and falls
                # through to the NATIVE Adder /bin/tar (user/tar.ad) baked
                # into the global cpio, which rejects GNU tar's flags
                # ("tar: unknown flag") -> dpkg-deb exits 1 mid-unpack and
                # the install never reaches "Setting up". Spelling them
                # usr/bin/<x> stages the real bytes; the USRMERGE_ALIASES
                # expansion below ALSO plants /bin/<x> from the same bytes,
                # so the native /bin/tar is shadowed by the Debian one
                # inside the #distro-bound namespace.
                "usr/bin/tar",
                "usr/bin/gzip",
                "usr/bin/gunzip",
                "usr/bin/xz",
                "usr/bin/zstd",
                # coreutils dpkg/apt fork during a real install + the
                # `/bin/sh` maintainer-script shell (dash already staged).
                "usr/bin/cp",
                "usr/bin/mv",
                "usr/bin/rm",
                "usr/bin/mkdir",
                "usr/bin/rmdir",
                "usr/bin/chmod",
                "usr/bin/chown",
                "usr/bin/ln",
                "usr/bin/ls",
                "usr/bin/cat",
                "usr/bin/echo",
                "usr/bin/sync",
                "usr/bin/sed",
                "usr/bin/wc",
                "usr/bin/sort",
                "usr/bin/head",
                # NSS diagnostic + admin tools. getent exercises the same
                # glibc getpwnam/NSS path dpkg uses for its statoverride
                # 'root' lookup, so staging it lets a probe prove
                # getpwnam("root") resolves inside the namespace.
                "usr/bin/getent",
                # GENUINE Debian bash (+ its libtinfo closure is globbed
                # below). Proves the full Debian /bin/bash runs in the ns,
                # not just dash. ~1.2 MB; acceptable for the curated slice.
                # Spelled usr/bin/ (host stages it there; usrmerge alias
                # plants /bin/bash too) — a `bin/bash` entry would miss
                # is_file() and silently skip, like the tar/gzip case above.
                "usr/bin/bash",
                # BROAD coreutils coverage matrix (scripts/
                # test_linux_debian_coverage.sh / _kvm_coreutils_repro.sh
                # run each STANDALONE via `enter linux { /usr/bin/<x> ... }`).
                # These exercise the Linux-ABI fork+execve+ld.so+stack path
                # across a wide set of real Debian ELFs — the regression
                # surface for the user-stack-vs-kernel-stack aliasing fix
                # (decoupled high-VA user stack). Staged at usr/bin/ so the
                # /usr/bin/<x> spelling the matrix uses resolves; the
                # reverse usrmerge alias below also plants /bin/<x>.
                "usr/bin/uname",
                "usr/bin/id",
                "usr/bin/ls",
                "usr/bin/stat",
                "usr/bin/tail",
                "usr/bin/head",
                "usr/bin/cut",
                "usr/bin/sed",
                "usr/bin/nl",
                "usr/bin/date",
                "usr/bin/md5sum",
                "usr/bin/readlink",
                # The local file:// apt repo (scripts/build_local_apt_repo
                # .sh stages this whole subtree). apt's `file` method reads
                # it directly off the Debian root.
                "opt/localrepo/dists/local/Release",
                "opt/localrepo/dists/local/main/binary-amd64/Packages",
                "opt/localrepo/dists/local/main/binary-amd64/Packages.gz",
                "opt/localrepo/pool/main/h/hamhello/hamhello_1.0_amd64.deb",
                # The DEPENDENCY-scenario pair (scripts/build_local_apt_repo
                # .sh also stages these): hamdep-app Depends: hamdep-lib.
                # Embedded in the pool so apt's `file` method genuinely
                # FETCHES both .debs from file:///opt/localrepo (they are
                # deliberately NOT pre-cached under archives/, so the pool
                # file:// fetch path is exercised, not just the cache).
                # Drives scripts/test_apt_install_e2e.sh (multi-package
                # resolve -> unpack -> ordered configure -> postinst -> run).
                "opt/localrepo/pool/main/h/hamdep-lib/hamdep-lib_1.0_amd64.deb",
                "opt/localrepo/pool/main/h/hamdep-app/hamdep-app_1.0_amd64.deb",
                # apt sources fragment pointing at the local repo, plus a
                # cached copy of the .deb for the `dpkg -i` short path.
                "etc/apt/sources.list.d/local.list",
                "var/cache/apt/archives/hamhello_1.0_amd64.deb",
                # apt writes its package/index state under these; dpkg
                # records installs in var/lib/dpkg. Pre-create the dirs by
                # staging their (possibly empty) scaffold files so the
                # tmpfs overlay has somewhere to land the install.
                "var/lib/dpkg/info/format",
            ]
            # Usrmerge expansion: Debian binaries internally reference
            # `/lib64/ld-linux-x86-64.so.2`, `/lib/x86_64-linux-gnu/
            # libc.so.6`, `/bin/sh`, etc. — paths under the four
            # usrmerge symlinks (/bin /sbin /lib /lib64 -> usr/*).
            # Hamnix's fs/vfs.ad `_lookup_name` follows whole-path
            # symlink entries but does NOT walk symlinks that sit in
            # the MIDDLE of a path (no path-component traversal — the
            # cpio is a flat name table). So a directory-symlink at
            # /var/lib/distros/default/lib64 -> usr/lib64 cannot route
            # a lookup of /var/lib/distros/default/lib64/ld-linux-
            # x86-64.so.2 into the staged usr/lib64 entry.
            #
            # Fix: when a file lands under `usr/<x>`, ALSO plant it at
            # the corresponding non-usrmerge alias `<x>`. So
            #   usr/lib64/ld-linux-x86-64.so.2 -> ALSO at lib64/...
            #   usr/lib/x86_64-linux-gnu/libc.so.6 -> ALSO at lib/...
            #   usr/bin/dpkg -> ALSO at bin/dpkg
            # Both PT_INTERP and DT_NEEDED resolution see the file
            # without depending on directory-component symlink walking.
            # The duplicate cpio entries are HEADER-only overhead — the
            # actual data bytes are emitted once (the second header
            # points into the cpio's contiguous bytes? no — newc cpio
            # is one header+data block per entry, so we DO duplicate
            # the data bytes too. ~20 MB raw -> ~40 MB raw with the
            # alias). Acceptable: still well under the GitHub push
            # limit on fs/initramfs_blob.S, and still smaller than a
            # full debootstrap rootfs at 214 MB.
            USRMERGE_ALIASES = {
                "usr/bin/":  "bin/",
                "usr/sbin/": "sbin/",
                "usr/lib/":  "lib/",
                "usr/lib64/": "lib64/",
            }
            # Version-agnostic closure augmentation. The explicit list
            # above pins SONAME + a specific minor (e.g. libstdc++.so.6
            # AND libstdc++.so.6.0.33). But the debootstrap fixture's
            # minor version drifts across Debian point releases (the
            # checked-in 2023 minbase carries libapt-pkg.so.6.0.0 /
            # libstdc++.so.6.0.30, a fresh debootstrap carries 7.0.0 /
            # 6.0.33), so a hard-pinned minor SILENTLY skips apt's real
            # libapt-pkg — and apt then dies in ld.so with "failed to
            # map segment from shared object" because its DT_NEEDED
            # SONAME resolves to a symlink whose target was never
            # staged. Fix: for the apt/dpkg library directory, glob
            # EVERY lib*.so* present and stage it whatever its minor
            # version. This makes the staged closure track the actual
            # fixture instead of a frozen filename list. (Symlinks are
            # followed by read_bytes() so a SONAME symlink lands with
            # its target's real bytes.)
            libdir = minbase_rootfs / "usr" / "lib" / "x86_64-linux-gnu"
            glob_libs: list[str] = []
            if libdir.is_dir():
                for p in sorted(libdir.glob("lib*.so*")):
                    rel = str(p.relative_to(minbase_rootfs))
                    if rel not in REAL_DEBIAN_FILES:
                        glob_libs.append(rel)
            REAL_DEBIAN_FILES = REAL_DEBIAN_FILES + glob_libs

            # apt.conf.d FRAGMENT glob. libapt readdir()s the WHOLE
            # /etc/apt/apt.conf.d/ directory; a fixture or
            # stage_host_dpkg_rootfs.sh may drop additional fragments
            # (e.g. 00hamnix auth/insecure opts, 99hamnix). Glob every
            # regular fragment file so the synthesized cpio readdir of
            # that prefix enumerates ALL of them, not just the two
            # debootstrap defaults hand-listed above. (Without the auth
            # fragment apt would refuse the unsigned local file:// repo.)
            confdir = minbase_rootfs / "etc" / "apt" / "apt.conf.d"
            glob_conf: list[str] = []
            if confdir.is_dir():
                for p in sorted(confdir.iterdir()):
                    if not p.is_file():
                        continue
                    rel = str(p.relative_to(minbase_rootfs))
                    if rel not in REAL_DEBIAN_FILES:
                        glob_conf.append(rel)
            REAL_DEBIAN_FILES = REAL_DEBIAN_FILES + glob_conf

            # BROAD-COVERAGE augmentation. The hand-pinned list above is
            # the apt/dpkg-install closure. For the Debian-binary BREADTH
            # sweep (test_linux_debian_coverage.sh) we ALSO want every
            # stock coreutils/text/archive binary that
            # stage_host_dpkg_rootfs.sh staged into usr/bin (ls/cp/grep/
            # sed/awk/find/...). Rather than hand-list each one (which
            # drifts and invites per-binary special-casing), glob the
            # staged usr/bin + usr/sbin trees and embed whatever real
            # Debian ELFs are present. The staged rootfs is intentionally
            # a MINIMAL-but-broad slice (~120 files), well under
            # NR_FILES=8192. Each entry's own .so closure is already
            # covered by glob_libs.
            # GATED behind HAMNIX_DEBIAN_BREADTH=1 (set by the coverage
            # test only). Embedding ~120 stock Debian ELFs into the DEFAULT
            # cpio bloated the -m 1G installer image +83 MiB (214->297 MiB)
            # → the in-RAM rootfs alloc failed and the DE OOM'd on app spawn
            # (blank desktop, user-reported). The default image keeps only
            # the hand-pinned apt/dpkg closure above; the broad breadth set
            # is opt-in for test_linux_debian_coverage.sh.
            binglob: list[str] = []
            if os.environ.get("HAMNIX_DEBIAN_BREADTH", "0") == "1":
                for bindir in ("usr/bin", "usr/sbin"):
                    d = minbase_rootfs / bindir
                    if not d.is_dir():
                        continue
                    for p in sorted(d.iterdir()):
                        # Regular files only (skip the bin/sh-style symlinks
                        # the dedicated entries above already plant).
                        if p.is_symlink() or not p.is_file():
                            continue
                        rel = str(p.relative_to(minbase_rootfs))
                        if rel not in REAL_DEBIAN_FILES:
                            binglob.append(rel)
            REAL_DEBIAN_FILES = REAL_DEBIAN_FILES + binglob

            # LIVE-net build: EXCLUDE the offline file:// local repo entirely.
            # Otherwise both the deb.debian.org source AND the leftover
            # `file:///opt/localrepo` source are configured; apt forks the
            # `copy` method for the local source, which dies ("E: Method copy
            # has died unexpectedly!") and — because apt fails the whole run
            # if ANY method dies — aborts `apt-get update`, so the real
            # install never proceeds. Drop the localrepo subtree + its
            # sources fragment so the ONLY source is http://deb.debian.org
            # (the net block below re-plants an empty local.list shadow too,
            # but first-match-wins means we must remove the pinned entries
            # here, before the embed loop). Offline builds keep them.
            if os.environ.get("HAMNIX_APT_NET", "0") == "1":
                REAL_DEBIAN_FILES = [
                    r for r in REAL_DEBIAN_FILES
                    if not r.startswith("opt/localrepo/")
                    and r != "etc/apt/sources.list.d/local.list"
                ]

            staged_files = 0
            staged_bytes = 0
            missing: list[str] = []
            for rel in REAL_DEBIAN_FILES:
                src = minbase_rootfs / rel
                if not src.is_file():
                    # Some paths (apt.conf, available, ...) are
                    # genuinely optional in a minbase debootstrap;
                    # skip them silently.
                    missing.append(rel)
                    continue
                try:
                    data = src.read_bytes()
                except (OSError, PermissionError):
                    missing.append(f"{rel} (unreadable)")
                    continue
                mode = (0o100755
                        if src.stat().st_mode & 0o111
                        else 0o100644)
                # Primary: the canonical /var/lib/distros/default/<rel>
                # path (matches the source tree layout 1:1).
                primary_name = "/var/lib/distros/default/" + rel
                blob += cpio_entry(primary_name, data, mode=mode)
                staged_files += 1
                staged_bytes += len(data)
                # Usrmerge alias: also plant at the non-usr equivalent
                # so /bin/X and /lib/X paths resolve directly.
                for prefix, alias_prefix in USRMERGE_ALIASES.items():
                    if rel.startswith(prefix):
                        alias_rel = alias_prefix + rel[len(prefix):]
                        alias_name = ("/var/lib/distros/default/"
                                      + alias_rel)
                        blob += cpio_entry(alias_name, data, mode=mode)
                        staged_files += 1
                        staged_bytes += len(data)
                        break
            print(f"  staged real Debian apt/dpkg slice: {staged_files} "
                  f"entries ({staged_bytes} bytes) under "
                  f"/var/lib/distros/default/ "
                  f"[HAMNIX_DEFAULT_REAL_DEBIAN={real_debian_raw}]")
            if missing:
                print(f"  (skipped {len(missing)} optional files: "
                      f"{', '.join(missing[:5])}"
                      f"{'…' if len(missing) > 5 else ''})")
            # apt MANDATORY working directories. The REAL_DEBIAN_FILES loop
            # above only stages regular files, so apt's empty working dirs
            # never appear in the flat cpio name table. apt-get update
            # stat()s these at startup and, finding lists/ + lists/partial
            # (and the archives equivalents) absent, takes a NULL-map path
            # in its cache generator and SIGSEGVs at va=0 (observed: pid
            # exited code=139 right after "Reading package lists... 0%").
            # Plant a `.keep` empty-file in each so the cpio's synthesized
            # readdir enumerates the directory (same trick as the /home/live
            # subdir .keep placeholders at the top of this file). The
            # writable tmpfs overlay then absorbs the index/cache files apt
            # creates UNDER these now-existing directories.
            for _apt_dir in (
                "var/lib/apt/lists",
                "var/lib/apt/lists/partial",
                "var/cache/apt/archives",
                "var/cache/apt/archives/partial",
            ):
                _keep = "/var/lib/distros/default/" + _apt_dir + "/.keep"
                blob += cpio_entry(_keep, b"")
            print("  planted apt lists/ + archives/ (+partial) .keep dirs")

            # --- LIVE NETWORK apt config (HAMNIX_APT_NET=1) ---------------
            # The offline path above stages a file:// local repo. With
            # HAMNIX_APT_NET=1 we ALSO plant the network resolver + a
            # sources.list pointing at the REAL Debian archive over plain
            # HTTP, so `enter linux { apt-get update }` fetches the genuine
            # Release/Packages indices from deb.debian.org and
            # `apt-get install <pkg>` downloads the real .deb from /pool.
            #
            # These are SYNTHESIZED here (not read from the rootfs) so the
            # net path needs no extra rootfs staging beyond the http method
            # + keyring (scripts/stage_host_dpkg_rootfs.sh). DNS goes to the
            # SLIRP forwarder 10.0.2.3 (proven reachable by the native
            # http_smoke_test); a static /etc/hosts entry is ALSO planted as
            # an interim belt-and-braces fallback (deb.debian.org is a CDN,
            # so the hosts IP can rotate — real DNS via 10.0.2.3 is primary).
            if os.environ.get("HAMNIX_APT_NET", "0") == "1":
                _apt_suite = os.environ.get("HAMNIX_APT_SUITE", "bookworm")
                _deb_host_ip = os.environ.get(
                    "HAMNIX_DEB_HOST_IP", "").strip()
                _net_files: dict[str, bytes] = {
                    # glibc getaddrinfo reads resolv.conf for the DNS server;
                    # 10.0.2.3 is QEMU SLIRP's DNS forwarder.
                    "etc/resolv.conf":
                        b"nameserver 10.0.2.3\noptions timeout:2 attempts:3\n",
                    # nsswitch already staged ("hosts: files dns"): files
                    # (the /etc/hosts below) is consulted before dns.
                    # sources.list -> REAL Debian archive over plain HTTP.
                    # [trusted=yes]: skip the InRelease gpg signature check.
                    # The genuine packages are still downloaded from the REAL
                    # deb.debian.org archive; we only bypass the gpgv METHOD
                    # (which currently dies under linux_abi exec —
                    # "E: Method gpgv has died unexpectedly!" — and, because
                    # apt fails the whole run when any method dies, aborts the
                    # update before the install can fetch the .deb). This is
                    # the brief's sanctioned allow-unauthenticated fallback;
                    # transport TLS is not required for the plain-HTTP mirror.
                    # Set HAMNIX_APT_TRUSTED=0 to require real gpgv instead.
                    "etc/apt/sources.list":
                        ((f"deb [trusted=yes] http://deb.debian.org/debian "
                          f"{_apt_suite} main\n")
                         if os.environ.get("HAMNIX_APT_TRUSTED", "1") == "1"
                         else (f"deb http://deb.debian.org/debian "
                               f"{_apt_suite} main\n")).encode(),
                }
                # Optional static hosts pin (interim fallback if DNS is the
                # deep blocker). Only emitted when HAMNIX_DEB_HOST_IP is set
                # (the test resolves deb.debian.org on the host and passes a
                # current A record). Without it, glibc uses real DNS.
                if _deb_host_ip:
                    _net_files["etc/hosts"] = (
                        f"127.0.0.1 localhost\n"
                        f"{_deb_host_ip} deb.debian.org\n").encode()
                # Shadow the offline file:// list so apt does not also try
                # the (now possibly absent) local repo during the net run.
                _net_files["etc/apt/sources.list.d/local.list"] = b""
                for _rel, _data in _net_files.items():
                    _mode = 0o100644
                    _primary = "/var/lib/distros/default/" + _rel
                    blob += cpio_entry(_primary, _data, mode=_mode)
                print(f"  planted LIVE-net apt config (suite={_apt_suite}, "
                      f"dns=10.0.2.3, hosts_pin="
                      f"{'yes' if _deb_host_ip else 'no'}) "
                      f"[HAMNIX_APT_NET=1]")

    # Kernel modules: anything in build/mod/ gets embedded as /<stem>
    # so module_load() can fetch by path. Convention is to start the
    # binary names with "kmod_" so the cpio entries read /kmod_X.
    mod_dir = here / "build" / "mod"
    if mod_dir.is_dir():
        for elf in sorted(mod_dir.glob("*.elf")):
            data = elf.read_bytes()
            name = "/" + elf.stem
            blob += cpio_entry(name, data)
            print(f"  embedded {name} ({len(data)} bytes from "
                  f"build/mod/{elf.name})")

    # Stock Linux 6.12 .ko fixtures: anything checked in at
    # tests/linux-modules/*.ko gets embedded as
    # /lib/modules/6.12/<basename>.ko so the L-track regression
    # (scripts/test_l_track.sh) can `insmod /lib/modules/6.12/<X>.ko`
    # without copying files into the initramfs at boot. Mirrors the
    # etc/ + build/mod/ globs above. Source is tests/linux-modules/
    # Makefile (built against pinned linux-6.12.48).
    lkm_dir = here / "tests" / "linux-modules"
    if lkm_dir.is_dir():
        for ko in sorted(lkm_dir.glob("*.ko")):
            data = ko.read_bytes()
            name = "/lib/modules/6.12/" + ko.name
            blob += cpio_entry(name, data)
            print(f"  embedded {name} ({len(data)} bytes from "
                  f"tests/linux-modules/{ko.name})")

    # Linux's stock e1000e.ko (Debian 6.1.0-32 build, ~668 KiB), checked
    # in at kernel-modules/e1000e/e1000e.ko. Always planted at
    # /lib/modules/e1000e.ko — init/main.ad's boot:35.a path
    # unconditionally kmod_linux_loads it (the hand-rolled
    # drivers/net/e1000e.ad has been retired). On boards without an
    # Intel NIC the .ko loads but its probe doesn't bind, so this is
    # cheap (no-op-on-mismatch). The ENABLE_AUTO_MODULES=1 block below
    # additionally bakes every kernel-modules/<X>/*.ko at
    # /lib/modules/auto/<X>.ko + a modules.alias table so the in-kernel
    # modprobe_auto_load() walks the live PCI bus and picks the right
    # driver per device — Linux's exact modprobe-by-PCI-ID model.
    e1000e_ko = here / "kernel-modules" / "e1000e" / "e1000e.ko"
    if e1000e_ko.is_file():
        data = e1000e_ko.read_bytes()
        name = "/lib/modules/e1000e.ko"
        blob += cpio_entry(name, data)
        print(f"  embedded {name} ({len(data)} bytes from "
              f"kernel-modules/e1000e/e1000e.ko)")

    # ENABLE_AUTO_MODULES=1 — Linux-shape modprobe auto-discovery.
    #
    # Walks kernel-modules/<name>/*.ko, plants each at
    # /lib/modules/auto/<basename> in the cpio, and bakes a
    # `modules.alias` table (one alias-pattern -> module-name line per
    # MODULE_DEVICE_TABLE entry, generated by
    # scripts/build_modules_alias.py from `modinfo -F alias`) at
    # /lib/modules/modules.alias. The in-kernel modprobe_auto_load()
    # (kernel/modprobe.ad) reads the table at boot, walks Hamnix's
    # PCI bus, and kmod_linux_load()s the matching .ko for each
    # device — Linux's exact modprobe-by-PCI-ID model.
    #
    # Also plants /etc/auto-modules as the runtime gate: init/main.ad
    # only invokes modprobe_auto_load() when this marker is present,
    # so the default CI boot stays single-purpose and tests that
    # depend on the existing hand-rolled drivers (virtio-net,
    # r8169) keep working. Set ENABLE_AUTO_MODULES=1 to opt in; CI
    # sets it in scripts/test_auto_modules.sh.
    if os.environ.get("ENABLE_AUTO_MODULES") == "1":
        kmods_root = here / "kernel-modules"
        n_ko = 0
        n_ko_bytes = 0
        if kmods_root.is_dir():
            for sub in sorted(kmods_root.iterdir()):
                if not sub.is_dir():
                    continue
                for ko in sorted(sub.glob("*.ko")):
                    data = ko.read_bytes()
                    name = f"/lib/modules/auto/{ko.name}"
                    blob += cpio_entry(name, data)
                    n_ko += 1
                    n_ko_bytes += len(data)
                    print(f"  embedded {name} ({len(data)} bytes "
                          f"from kernel-modules/{sub.name}/{ko.name})")
        # Generate the alias table by delegating to the dedicated
        # script, then bake its bytes at /lib/modules/modules.alias.
        # We import the helper rather than shelling out so a single
        # process build_initramfs.py call doesn't fork twice.
        import importlib.util as _ilu
        _mod_alias_path = here / "scripts" / "build_modules_alias.py"
        _spec = _ilu.spec_from_file_location(
            "build_modules_alias", _mod_alias_path)
        if _spec is None or _spec.loader is None:
            raise SystemExit(
                f"build_initramfs: cannot import {_mod_alias_path}")
        _mod_alias = _ilu.module_from_spec(_spec)
        _spec.loader.exec_module(_mod_alias)
        alias_text = _mod_alias.build_alias_table(kmods_root)
        alias_bytes = alias_text.encode()
        blob += cpio_entry("/lib/modules/modules.alias", alias_bytes)
        print(f"  embedded /lib/modules/modules.alias "
              f"({len(alias_bytes)} bytes, "
              f"{alias_text.count(chr(10)) - 3 if alias_text else 0} "
              f"alias lines, from {n_ko} .ko files / "
              f"{n_ko_bytes} bytes)")
        # Runtime gate marker. init/main.ad's modprobe_auto_load()
        # block only fires when this file is present in the initramfs.
        FILES.append(("/etc/auto-modules", b"1\n"))

    # modules.dep — Linux-shape dependency table for the in-kernel
    # modules_dep parser (kernel/modules_dep.ad). Planted unconditionally
    # whenever kernel-modules/ has any .ko files, because both the
    # framework-modules path (cfg80211 + mac80211) and the auto-modules
    # PCI walk use it to topologically load deps before a target module.
    # The cost is small (a few hundred bytes — one short line per .ko).
    # When the table is absent the in-kernel parser just falls back to
    # the legacy "load only the requested module, no deps" behavior.
    # Shared with the HAMNIX_CPIO_EMPTY=1 shipped-image path via
    # _embed_modules_dep.
    blob += _embed_modules_dep(here)

    # Userland modprobe test fixture. scripts/test_modprobe.sh sets
    # ENABLE_MODPROBE_USERLAND_TEST=1 to plant a synthetic Linux-shape
    # modules.dep at /lib/modules/6.12/modprobe-test.dep. libcrc32c's
    # line lists crc32c_generic as its (flattened, transitive)
    # dependency, so the native user/modprobe.ad must load
    # crc32c_generic BEFORE libcrc32c. The .ko paths are relative to
    # the dep file's own directory (/lib/modules/6.12/), where the test
    # stages crc32c_generic.ko + libcrc32c.ko into tests/linux-modules/
    # (embedded by the *.ko glob above at /lib/modules/6.12/<name>.ko).
    # Emitted here via blob += cpio_entry() (alongside the real
    # modules.dep) so it lands in the same cpio region the userland VFS
    # root sees — the FILES[] list is laid down separately and was not
    # openable from userland sys_open(). These two .ko's are tiny
    # (~10 KiB), so the userland read-whole-file path stays cheap.
    if os.environ.get("ENABLE_MODPROBE_USERLAND_TEST") == "1":
        _modprobe_dep_bytes = (
            b"# synthetic modules.dep for scripts/test_modprobe.sh\n"
            b"crc32c_generic.ko:\n"
            b"libcrc32c.ko: crc32c_generic.ko\n")
        blob += cpio_entry(
            "/lib/modules/6.12/modprobe-test.dep", _modprobe_dep_bytes)
        print(f"  embedded /lib/modules/6.12/modprobe-test.dep "
              f"({len(_modprobe_dep_bytes)} bytes, synthetic fixture)")

    # Multi-NIC scale-out: r8169.ko (Realtek consumer GbE) and igb.ko
    # (Intel server/workstation). Same plant-unconditional shape as
    # e1000e.ko above — marker files at /etc/r8169-ko and /etc/igb-ko
    # gate which .ko init/main.ad actually loads at boot.
    r8169_ko = here / "kernel-modules" / "r8169" / "r8169.ko"
    if r8169_ko.is_file():
        data = r8169_ko.read_bytes()
        name = "/lib/modules/r8169.ko"
        blob += cpio_entry(name, data)
        print(f"  embedded {name} ({len(data)} bytes from "
              f"kernel-modules/r8169/r8169.ko)")

    igb_ko = here / "kernel-modules" / "igb" / "igb.ko"
    if igb_ko.is_file():
        data = igb_ko.read_bytes()
        name = "/lib/modules/igb.ko"
        blob += cpio_entry(name, data)
        print(f"  embedded {name} ({len(data)} bytes from "
              f"kernel-modules/igb/igb.ko)")

    # Multi-NIC L-shim scale-out (round 2): atlantic.ko (Aquantia 10G),
    # alx.ko (Qualcomm Atheros AR816x), sky2.ko (Marvell Yukon 2),
    # tg3.ko (Broadcom NetXtreme). Each is a coverage-probe load —
    # success criterion is `init returned 0` with zero skipped
    # relocations. Same unconditional-bake shape as the round-1 trio
    # above; the gating /etc/<name>-ko marker controls whether
    # init/main.ad's framework-modules path actually insmods the
    # binary at boot.
    atlantic_ko = here / "kernel-modules" / "atlantic" / "atlantic.ko"
    if atlantic_ko.is_file():
        data = atlantic_ko.read_bytes()
        name = "/lib/modules/atlantic.ko"
        blob += cpio_entry(name, data)
        print(f"  embedded {name} ({len(data)} bytes from "
              f"kernel-modules/atlantic/atlantic.ko)")

    alx_ko = here / "kernel-modules" / "alx" / "alx.ko"
    if alx_ko.is_file():
        data = alx_ko.read_bytes()
        name = "/lib/modules/alx.ko"
        blob += cpio_entry(name, data)
        print(f"  embedded {name} ({len(data)} bytes from "
              f"kernel-modules/alx/alx.ko)")

    sky2_ko = here / "kernel-modules" / "sky2" / "sky2.ko"
    if sky2_ko.is_file():
        data = sky2_ko.read_bytes()
        name = "/lib/modules/sky2.ko"
        blob += cpio_entry(name, data)
        print(f"  embedded {name} ({len(data)} bytes from "
              f"kernel-modules/sky2/sky2.ko)")

    tg3_ko = here / "kernel-modules" / "tg3" / "tg3.ko"
    if tg3_ko.is_file():
        data = tg3_ko.read_bytes()
        name = "/lib/modules/tg3.ko"
        blob += cpio_entry(name, data)
        print(f"  embedded {name} ({len(data)} bytes from "
              f"kernel-modules/tg3/tg3.ko)")

    # Storage pivot (Agent D): ahci.ko (SATA AHCI controller —
    # Debian 6.1.0-32 build, ~117 KiB). Planted at /lib/modules/ahci.ko
    # AND at /lib/modules/6.12/ahci.ko so the userspace `insmod` path
    # the L-track tests use can find it.
    ahci_ko = here / "kernel-modules" / "ahci" / "ahci.ko"
    if ahci_ko.is_file():
        data = ahci_ko.read_bytes()
        for name in ("/lib/modules/ahci.ko",
                     "/lib/modules/6.12/ahci.ko"):
            blob += cpio_entry(name, data)
            print(f"  embedded {name} ({len(data)} bytes from "
                  f"kernel-modules/ahci/ahci.ko)")

    # Storage pivot (Agent D): nvme.ko (PCIe NVM Express SSD driver —
    # Debian 6.1.0-32 build, ~128 KiB). Same dual-path planting.
    nvme_ko = here / "kernel-modules" / "nvme" / "nvme.ko"
    if nvme_ko.is_file():
        data = nvme_ko.read_bytes()
        for name in ("/lib/modules/nvme.ko",
                     "/lib/modules/6.12/nvme.ko"):
            blob += cpio_entry(name, data)
            print(f"  embedded {name} ({len(data)} bytes from "
                  f"kernel-modules/nvme/nvme.ko)")

    # Storage maximalism: SCSI mid-layer chain ahci.ko depends on,
    # plus nvme-core.ko that nvme.ko depends on. Both go through the
    # in-kernel modules_dep walker + cross-module ksymtab so each
    # upstream module's EXPORT_SYMBOL satisfies the next module's UND.
    for ko_dir, ko_name in (
            ("scsi_common", "scsi_common.ko"),
            ("scsi_mod",    "scsi_mod.ko"),
            ("libata",      "libata.ko"),
            ("libahci",     "libahci.ko"),
    ):
        ko_path = here / "kernel-modules" / ko_dir / ko_name
        if ko_path.is_file():
            data = ko_path.read_bytes()
            for name in (f"/lib/modules/{ko_name}",
                         f"/lib/modules/6.12/{ko_name}"):
                blob += cpio_entry(name, data)
                print(f"  embedded {name} ({len(data)} bytes from "
                      f"kernel-modules/{ko_dir}/{ko_name})")

    # DRM/KMS (graphics) core: drm.ko (Debian 6.1.0-32 build, ~1.2 MiB)
    # planted at /lib/modules/drm.ko. init/main.ad's boot:35.DRM path
    # kmod_linux_loads it when /etc/drm-ko is present (ENABLE_DRM_KO=1).
    # The drm_kms_helper.ko (depends: drm) is staged too so a future
    # follow-up can load the helper after the core; i915.ko is staged
    # for the same reason but is NOT loaded by the current boot exercise
    # (its UND gap is large — see scripts/test_drm_ko.sh notes).
    for ko_dir, ko_name in (
            ("drm",            "drm.ko"),
            ("drm_kms_helper", "drm_kms_helper.ko"),
            ("i915",           "i915.ko"),
    ):
        ko_path = here / "kernel-modules" / ko_dir / ko_name
        if ko_path.is_file():
            data = ko_path.read_bytes()
            for name in (f"/lib/modules/{ko_name}",
                         f"/lib/modules/6.12/{ko_name}"):
                blob += cpio_entry(name, data)
                print(f"  embedded {name} ({len(data)} bytes from "
                      f"kernel-modules/{ko_dir}/{ko_name})")

    nvme_core_ko = here / "kernel-modules" / "nvme_core" / "nvme-core.ko"
    if nvme_core_ko.is_file():
        data = nvme_core_ko.read_bytes()
        # nvme.ko's modules.dep entry says `depends: nvme-core` (with a
        # dash). The in-kernel modules_dep walker (kernel/modules_dep.ad)
        # normalizes '-' to '_' when composing the cpio lookup path, so
        # it actually searches for `/lib/modules/nvme_core.ko` (underscore).
        # Plant BOTH forms so a userspace `insmod /lib/modules/nvme-core.ko`
        # (dash, what `modinfo -F name` prints) and the in-kernel dep
        # walker's lookup (underscore-normalized) both resolve. Same
        # dual-form trick used for xhci-hcd vs xhci_hcd.ko below.
        for name in ("/lib/modules/nvme-core.ko",
                     "/lib/modules/6.12/nvme-core.ko",
                     "/lib/modules/nvme_core.ko",
                     "/lib/modules/6.12/nvme_core.ko"):
            blob += cpio_entry(name, data)
            print(f"  embedded {name} ({len(data)} bytes from "
                  f"kernel-modules/nvme_core/nvme-core.ko)")

    # USB host-controller class L-shim chain: usbcore (the USB stack
    # core library) + xhci_pci (PCI attachment shim for xHCI) +
    # xhci_hcd (xHCI host-controller driver proper) + ehci_pci +
    # ehci_hcd. Planted at the framework path so the in-kernel
    # modules_dep parser finds each module via _md_find_ko() — the
    # walker dispatches xhci_pci's declared deps (xhci-hcd, usbcore)
    # and recursively loads them before xhci_pci's init_module fires.
    # Same dual-path planting (/lib/modules + /lib/modules/6.12) as
    # the storage class above so userspace `insmod` tests can find
    # the .kos at the conventional Debian path too.
    #
    # IMPORTANT: `modinfo -F depends xhci_pci.ko` returns `xhci-hcd,
    # usbcore` — with a DASH in xhci-hcd. The in-kernel modules_dep
    # parser walks dep tokens VERBATIM to build the cpio lookup path,
    # so /lib/modules/xhci-hcd.ko is what the dep walker tries first.
    # Therefore plant the cpio entries using the dash-form filename
    # (mirroring nvme-core.ko which has the same dash-vs-underscore
    # split). Name normalization in _md_name_eq only handles the
    # already-loaded fingerprint table. Shared with the
    # HAMNIX_CPIO_EMPTY=1 shipped-image path via _embed_usb_hcd_chain.
    blob += _embed_usb_hcd_chain(here)

    # WiFi pivot: cfg80211.ko (configuration/admin layer, ~2.3 MiB)
    # and mac80211.ko (soft-MAC stack, ~2.4 MiB) — Debian 6.1.0-32
    # build. Foundational framework modules; every wifi driver
    # (ath*, iwl*, brcmsmac, ...) depends on these two. Neither has
    # a MODULE_DEVICE_TABLE PCI alias so the modprobe auto-loader
    # won't pick them up — init/main.ad's framework-modules block
    # (gated on /etc/framework-modules, planted via
    # ENABLE_FRAMEWORK_MODULES=1) loads them explicitly via
    # kmod_linux_load from these well-known paths.
    cfg80211_ko = here / "kernel-modules" / "cfg80211" / "cfg80211.ko"
    if cfg80211_ko.is_file():
        data = cfg80211_ko.read_bytes()
        name = "/lib/modules/cfg80211.ko"
        blob += cpio_entry(name, data)
        print(f"  embedded {name} ({len(data)} bytes from "
              f"kernel-modules/cfg80211/cfg80211.ko)")

    mac80211_ko = here / "kernel-modules" / "mac80211" / "mac80211.ko"
    if mac80211_ko.is_file():
        data = mac80211_ko.read_bytes()
        name = "/lib/modules/mac80211.ko"
        blob += cpio_entry(name, data)
        print(f"  embedded {name} ({len(data)} bytes from "
              f"kernel-modules/mac80211/mac80211.ko)")

    # iwlwifi.ko — Intel wireless PCI driver (Debian 6.1.0-32 build).
    # Bundled unconditionally alongside cfg80211 + mac80211 so the dep
    # chain (cfg80211 -> mac80211 -> iwlwifi) is available in the cpio
    # whenever ENABLE_FRAMEWORK_MODULES=1. The /etc/iwlwifi-ko marker
    # (planted via ENABLE_IWLWIFI_KO=1) gates the actual kmod_linux_load
    # in init/main.ad; the .ko bytes are always present so the modules.dep
    # walker can find the file path without a separate condition.
    iwlwifi_ko = here / "kernel-modules" / "iwlwifi" / "iwlwifi.ko"
    if iwlwifi_ko.is_file():
        data = iwlwifi_ko.read_bytes()
        name = "/lib/modules/iwlwifi.ko"
        blob += cpio_entry(name, data)
        print(f"  embedded {name} ({len(data)} bytes from "
              f"kernel-modules/iwlwifi/iwlwifi.ko)")

    # U5: host-built Linux ELF test binaries. Anything staged under
    # tests/u-binary/ (built by tests/u-binary/src/*/Makefile via
    # `make install`) lands at /bin/<name>. These are real Linux ABI
    # ELFs — OSABI=ELFOSABI_LINUX, Linux syscall numbers — used to
    # smoke-test the U1..U4 syscall-translation chain end to end.
    # Optional: if the host-side build hasn't been run, this whole
    # block is skipped and the rest of the initramfs is unaffected
    # (so CI without the host fixture still builds a kernel).
    #
    # SIZE NOTE: u_* test binaries (glibc-static-pie ~800 KB each,
    # busybox ~2 MB, C++ demo ~2.4 MB) inflate the cpio archive past
    # GitHub's 100 MB push limit on fs/initramfs_blob.S. To keep the
    # committed default initramfs small, only embed u_* binaries when
    # HAMNIX_EMBED_UBIN=1 is set. Test scripts that need a specific
    # u_* binary set the env var themselves (most don't — they boot
    # against init.elf, not these test fixtures).
    embed_ubin = os.environ.get("HAMNIX_EMBED_UBIN", "0") == "1"
    ubin_dir = here / "tests" / "u-binary"
    if embed_ubin and ubin_dir.is_dir():
        for f in sorted(ubin_dir.iterdir()):
            if f.is_file() and f.name != ".gitignore":
                data = f.read_bytes()
                name = "/bin/" + f.name
                # F10-3 #456: /bin/* needs the world-x mode bit since
                # the post-F10-3 default user uid is NOBODY (65534) and
                # _perm_check_cpio gates exec on the per-entry mode.
                blob += cpio_entry(name, data, mode=0o100755)
                print(f"  embedded {name} ({len(data)} bytes)")

    # U41: CPython stdlib-on-disk embedding hook (DEPRECATED).
    #
    # The default U41 test no longer uses this path. CPython is now
    # built with the bootstrap stdlib frozen INTO the binary's data
    # segment via Tools/scripts/freeze_modules.py (see
    # tests/u-binary/src/cpython/HOWTO.md "Frozen-modules build"),
    # so init_fs_encoding doesn't need /usr/lib/python3.11/ in the
    # initramfs anymore.
    #
    # The hook is kept here (default-OFF) for flexibility: if a
    # future Python distribution scenario wants to ship the on-disk
    # stdlib (e.g. for pip-installed packages, or because a future
    # CPython rebuild trims the frozen set), set HAMNIX_EMBED_PYLIB
    # to the Lib/ path. The walker mirrors every .py file to
    # /usr/lib/python3.11/<relpath> in the cpio archive.
    #
    # CAVEATS (historic):
    #   - The full upstream Lib/ tree is ~1800 .py files. fs/cpio.ad's
    #     NR_FILES cap (192 at the time of the M16.115 attempt) would
    #     need bumping to 4096+ to accept that many entries.
    #   - The generated fs/initramfs_blob.S grows ~6x larger than the
    #     binary archive due to ASCII expansion; with the full stdlib
    #     embedded the blob exceeds GitHub's 100 MiB push cap.
    #   - SKIPs: __pycache__/ (platform-specific bytecode), lib-dynload/
    #     (compiled C extensions — needs a dynamic loader we don't have).
    pylib_path = os.environ.get("HAMNIX_EMBED_PYLIB", "")
    if pylib_path:
        lib_root = Path(pylib_path)
        if not lib_root.is_absolute():
            lib_root = here / lib_root
        if not lib_root.is_dir():
            raise SystemExit(
                f"HAMNIX_EMBED_PYLIB={pylib_path}: not a directory")
        py_target_prefix = "/usr/lib/python3.11"
        # Walk every .py file under lib_root, mirroring the relative
        # path under /usr/lib/python3.11/. Skip __pycache__ + lib-
        # dynload. The minimum set CPython's -c "print('x')" actually
        # touches at init_fs_encoding time is:
        #   encodings/__init__.py, encodings/aliases.py,
        #   encodings/utf_8.py, encodings/latin_1.py,
        #   encodings/ascii.py, importlib/* (frozen but still
        #   exposed), os.py, io.py, codecs.py, abc.py, posixpath.py,
        #   genericpath.py, _collections_abc.py, _weakrefset.py,
        #   types.py, enum.py, stat.py, _sitebuiltins.py, site.py
        # We embed the whole tree (minus the SKIPs) because hand-
        # curating the include list trades a tiny cpio shave for the
        # next time a CPython module pulls in a new dep.
        n_embedded = 0
        n_bytes = 0
        for src in sorted(lib_root.rglob("*.py")):
            rel = src.relative_to(lib_root)
            parts = rel.parts
            if any(p == "__pycache__" for p in parts):
                continue
            if any(p == "lib-dynload" for p in parts):
                continue
            data = src.read_bytes()
            name = py_target_prefix + "/" + "/".join(parts)
            blob += cpio_entry(name, data)
            n_embedded += 1
            n_bytes += len(data)
        print(f"  embedded {n_embedded} Python stdlib files "
              f"({n_bytes} bytes) under {py_target_prefix}/ "
              f"from {lib_root}")

    for entry in FILES:
        # FILES entries are (name, data) 2-tuples (default mode 0644) or
        # (name, data, mode) 3-tuples when a fixture needs a specific
        # POSIX mode (e.g. the DAC test's root-owned 0600 file).
        if len(entry) == 3:
            name, data, e_mode = entry
            blob += cpio_entry(name, data, mode=e_mode)
        else:
            name, data = entry
            blob += cpio_entry(name, data)
    blob += cpio_trailer()
    return bytes(blob)


# Above this archive size, emit the cpio via `.incbin` of a raw sidecar file
# instead of a per-byte `.byte` array. A `.byte` array is ~1 assembler line per
# 16 bytes: for the installer kernel embedding a multi-hundred-MB squashfs
# (Mesa/LLVM + the full Debian mirror) that is tens of millions of `.byte`
# directives, and GNU `as` assembling them balloons to >20 GiB RSS and OOMs the
# host (the known large-payload "dev-host dark gates" failure). `.incbin` is
# O(1) memory in BOTH Python and the assembler and embeds byte-identical bytes
# between initramfs_cpio_start/end. Small archives keep the historical `.byte`
# path so the ~380 `-kernel` test blobs stay byte-for-byte unchanged.
CPIO_INCBIN_THRESHOLD = 32 * 1024 * 1024


def emit_asm(archive: bytes, dest: Path) -> None:
    lines = [
        "/* AUTOGENERATED by scripts/build_initramfs.py — do not edit. */",
        "    .section .rodata",
        "    .align 4",
        "    .globl initramfs_cpio_start",
        "initramfs_cpio_start:",
    ]
    if len(archive) > CPIO_INCBIN_THRESHOLD:
        # Raw sidecar next to the .S; `.incbin` an ABSOLUTE path so the
        # assembler resolves it regardless of its working directory.
        bin_path = dest.parent / (dest.name + ".bin")
        bin_path.write_bytes(archive)
        lines.append(f'    .incbin "{bin_path.resolve()}"')
    else:
        for i in range(0, len(archive), 16):
            chunk = archive[i:i + 16]
            bytes_csv = ", ".join(f"0x{b:02x}" for b in chunk)
            lines.append(f"    .byte {bytes_csv}")
    lines += [
        "    .globl initramfs_cpio_end",
        "initramfs_cpio_end:",
        "",
        "    .code64",
        "    .section .text, \"ax\"",
        "    .globl initramfs_cpio_size",
        "initramfs_cpio_size:",
        "    leaq initramfs_cpio_end(%rip), %rax",
        "    leaq initramfs_cpio_start(%rip), %rcx",
        "    subq %rcx, %rax",
        "    ret",
        "",
        "    .globl initramfs_cpio_base",
        "initramfs_cpio_base:",
        "    leaq initramfs_cpio_start(%rip), %rax",
        "    ret",
    ]
    dest.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    here = Path(__file__).resolve().parent.parent
    # Opt-in build isolation: when HAMNIX_BUILD_DIR is set, emit the blob
    # there instead of the shared in-source fs/initramfs_blob.S so two
    # builds in ONE checkout don't clobber each other. Default (unset) is
    # byte-for-byte the historical path.
    build_dir = os.environ.get("HAMNIX_BUILD_DIR")
    if build_dir:
        dest = Path(build_dir) / "initramfs_blob.S"
        dest.parent.mkdir(parents=True, exist_ok=True)
    else:
        dest = here / "fs" / "initramfs_blob.S"

    # ALWAYS-OVERWRITE CONTRACT (scripts/_fresh_artifact.py). The blob (and
    # its cpio manifest) are unlinked BEFORE build_archive() runs, not after:
    # staging can raise, and a leftover blob from the previous run would then
    # be assembled into the kernel by the next `as`/`ld` step, shipping an
    # image whose cpio contents predate the tree. Deleting first turns that
    # silent staleness into a loud missing-file build error.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from _fresh_artifact import fresh_artifact
    fresh_artifact("[build_initramfs]", dest, str(dest) + ".manifest")

    archive = build_archive()
    emit_asm(archive, dest)
    # #410 Item 1: alongside an isolated blob, emit a manifest of the cpio
    # entry names so scripts/verify_kernel_cpio.py can assert the compiled
    # kernel ELF actually embeds THIS archive (stale/raced-blob detector).
    # The names are recovered by walking the REAL archive bytes (the same
    # newc walk the verifier uses), not by trusting FILES — so the manifest
    # is a faithful record of what was emitted. Gated on HAMNIX_BUILD_DIR
    # so plain dev builds don't litter fs/ with manifest churn.
    if build_dir:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from verify_kernel_cpio import walk_newc
        walked = walk_newc(archive, 0)
        if walked is None:
            print("ERROR: freshly built archive does not walk as newc cpio",
                  file=sys.stderr)
            sys.exit(1)
        names, _end = walked
        manifest = dest.parent / (dest.name + ".manifest")
        manifest.write_text("".join(n + "\n" for n in names))
        print(f"Wrote {manifest} ({len(names)} entries)")
    print(f"Wrote {dest} ({len(archive)} bytes archive, "
          f"{len(FILES)} files)")
