#!/usr/bin/env bash
# scripts/test_package_de_coverage.sh — no-VM package-coverage gate.
#
# Catches the silent-drift class permanently. The package table in
# scripts/build_packages.py is hand-curated, while the live rootfs
# (build_rootfs_img.py) globs build/user/*.elf wholesale. When the two
# drift, `hpm install hamnix-base` yields a system MISSING binaries the
# live image has — most painfully, the entire scene-file Desktop
# Environment (it was in NO package until 2026-06-19).
#
# This test asserts, against a freshly-built build/packages/main/index.json:
#
#   1. The hamnix-base dependency closure transitively includes the DE
#      (hamnix-desktop -> apps + config) AND hamUId / rc.5 / hamuid.svc
#      resolve to a file inside some package IN that closure.
#   2. Every /bin/ham* referenced by etc/rc.d/rc.5 and
#      etc/services.d/*.svc resolves to a file in a built package.
#   3. build/user/*.elf MINUS an allowlist of intentional skips
#      (demos/selftests/X11 test harnesses) is fully covered by the
#      union of all built packages' files.
#
# No QEMU, no kernel build. Pure build-system invariant.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

echo "[de-cov] (1/3) build userland (build/user/*.elf)"
bash scripts/build_user.sh >/dev/null

echo "[de-cov] (2/3) build packages (SLIM bootloader + debian)"
HAMNIX_BOOTLOADER_SLIM=1 HAMNIX_LINUX_DEBIAN_SLIM=1 \
    python3 scripts/build_packages.py >/dev/null

echo "[de-cov] (3/3) assert coverage invariants"
python3 - <<'PY'
import json, sys, tarfile, re
from pathlib import Path

ROOT = Path(".").resolve()
IDX = ROOT / "build" / "packages" / "main" / "index.json"
USER = ROOT / "build" / "user"
ETC = ROOT / "etc"
PKGDIR = ROOT / "build" / "packages" / "main"

# Intentional non-packaged binaries: pure demos, compiler self-tests,
# X11/scene test harnesses, the in-tree Adder compiler drivers. These
# are dev/test artifacts, not shipped userland. Keep this list tight —
# anything real that lands here is a coverage hole, not an exemption.
SKIP_BINS = {
    # compiler drivers + selftests
    "adder_cc", "codegen_ac_driver", "codegen_bss_selftest",
    "codegen_elf_selftest", "codegen_selftest", "lex_selftest",
    "parse_selftest",
    # generic demos / fixtures
    "hello", "dup_demo", "stdin_demo", "p9srv_demo", "preempt_demo",
    "preempt_hog", "nice_demo", "nice_hi", "nice_lo", "u_tlstest",
    "test_errstr_perbackend", "test_hugepage", "live_distro_up",
    # spawnfdprobe = Task #28 clean-FD spawn fixture; umdf_host = the
    # Track-4 userland .ko host (first vertical slice, not yet wired into
    # any runlevel/menu). Both are dev/bring-up binaries, not shipped
    # userland — packaged by nothing on purpose.
    "spawnfdprobe", "umdf_host",
    # Audio playback SELF-TEST inits — run AS /init by the HDA gates
    # (scripts/test_audio_playback.sh runs playtone; test_hamaudio_playback.sh
    # runs hamaudioselftest), never launched from a menu/autostart. The SHIPPED
    # audio userland is aplay + the hamaudioscene player (hamnix-hamaudio); these
    # two are test fixtures, packaged by nothing on purpose.
    "playtone", "hamaudioselftest",
    # X11 bridge + scene test harnesses (not the shipped DE). hamimgscene =
    # the #128 scene-IMAGE-tier demo (synthesizes an RGBA image + exercises
    # the draw/ctl 'I' upload verb); a dev demo tested by test_hamimg_host.sh,
    # referenced by no autostart/menu/desktop.icons — not shipped userland.
    "x11apptest", "x11srv", "x11test", "xclient_demo", "xfill",
    "scenetest", "multiwintest", "hamui_demo", "ham2048", "hamsnake",
    "hamimgscene",
    # Legacy PRE-scene-pivot DE widgets (hamui-toolkit era). The DE was
    # rearchitected onto scene FILES (docs/de_scene_file_arch.md); the
    # *scene variants (hampanelscene/hamfmscene/...) in
    # hamnix-desktop-apps superseded these and NOTHING in the autostart
    # (rc.5 / services.d / desktop.icons / panel.conf) references them.
    # Not shipped; pending source removal. If any of these gets wired
    # back into the autostart, drop it from this list and package it.
    "hamUI", "hambottom", "hampanel", "hamcycler", "hamrun", "hamsnap",
    "hamcalpop", "hamnotif", "hamsysmon", "hamecho", "hamfiles",
    # --- 2026-07-31 -------------------------------------------------
    # Nine dev/test binaries that landed 2026-07-15..30 while this gate was
    # outside every sweep (scripts/list_host_gates.sh returned 283 of 645).
    # NONE is referenced by rc.5, services.d, desktop.icons or any shipped
    # .desktop — verified, and now asserted mechanically by the launcher
    # cross-check below, which is what keeps this list from becoming a place
    # to hide a real hole.
    #
    #   audiolife         hamGame/hamSDL audio demo (Game of Life + tones)
    #   sdlpong           hamSDL Pong demo
    #   keydemo           raw keyboard-event demo
    #   ed25519_selftest  signature-verify selftest, run BY a gate
    #   hamvideoselftest  Motion-JPEG decode selftest, run BY a gate
    #   sysirqprobe       IRQ-latency probe (soak instrumentation)
    #   wakelat           wake-latency measurement tool  ...
    #   wakelat_echo      ... its echo peer ...
    #   wakelat_hog       ... and its load generator
    "audiolife", "sdlpong", "keydemo",
    "ed25519_selftest", "hamvideoselftest",
    "sysirqprobe", "wakelat", "wakelat_echo", "wakelat_hog",
}

fail = []

idx = json.loads(IDX.read_text())
pkgs = {p["name"]: p for p in idx["packages"]}

def dep_names(p):
    out = []
    for d in p.get("depends", []):
        out.append(re.split(r"[<>=]", d, 1)[0].strip())
    return out

# --- closure from hamnix-base ---
seen = set()
stack = ["hamnix-base"]
while stack:
    n = stack.pop()
    if n in seen or n not in pkgs:
        continue
    seen.add(n)
    stack += dep_names(pkgs[n])

for want in ("hamnix-desktop", "hamnix-desktop-apps",
             "hamnix-desktop-config", "hamnix-hamsh"):
    if want not in seen:
        fail.append(f"hamnix-base closure MISSING {want}")

# --- map package -> set of installed file basenames + full rel paths ---
def pkg_files(name):
    p = pkgs.get(name)
    if not p:
        return [], []
    tar = PKGDIR / p["url"]
    rels, bases = [], []
    with tarfile.open(tar) as t:
        for m in t.getmembers():
            if not m.isfile():
                continue
            # arc: <pkg>-<v>/files/<rel>
            parts = m.name.split("/files/", 1)
            if len(parts) != 2:
                continue
            rel = parts[1]
            rels.append(rel)
            bases.append(Path(rel).name)
    return rels, bases

# union over ALL built packages (coverage of the live elf set is about
# "is it in ANY package", not just the base closure).
all_bins = set()
all_rels_in_closure = set()
bases_in_closure = set()
for name, p in pkgs.items():
    rels, bases = pkg_files(name)
    for b in bases:
        all_bins.add(b)
    if name in seen:
        for r in rels:
            all_rels_in_closure.add(r)
        for b in bases:
            bases_in_closure.add(b)

# --- 1b: the DE keystones resolve to a file in the base closure ---
for keyfile in ("bin/hamUId", "etc/rc.d/rc.5", "etc/services.d/hamuid.svc"):
    if keyfile not in all_rels_in_closure:
        fail.append(f"hamnix-base closure has no file {keyfile}")

# --- 2: every /bin/ham* referenced by rc.5 + svc resolves ---
ref_files = [ETC / "rc.d" / "rc.5"] + sorted((ETC / "services.d").glob("*.svc"))
referenced = set()
for f in ref_files:
    if not f.is_file():
        continue
    for m in re.findall(r"/bin/(ham[A-Za-z0-9_]+)", f.read_text()):
        referenced.add(m)
for r in sorted(referenced):
    if r not in bases_in_closure:
        fail.append(f"rc.5/svc references /bin/{r} but it is not in the "
                    f"hamnix-base closure")

# --- 2b: LAUNCHER COVERAGE (2026-07-31) ---------------------------------
# Every binary a user can CLICK must be installed by some package. The
# desktop icons (etc/desktop.icons) and the Applications-menu launchers
# (etc/hamde/apps/*.desktop, which user/hamde.ad scans at startup) are the
# two click surfaces, and NEITHER was checked here: check 2 only read
# rc.5 + services.d, so `haminput` shipped an icon AND a menu entry on
# 2026-07-18 while being in no package at all for thirteen days. That is
# this gate's own headline bug ("the entire DE was in NO package") in
# miniature, and the allowlist above cannot launder it — a binary named by
# a launcher fails here whether or not it is allowlisted.
clickable = {}          # basename -> where it is advertised
icons = ETC / "desktop.icons"
if icons.is_file():
    for m in re.findall(r"/bin/([A-Za-z0-9_]+)", icons.read_text()):
        clickable.setdefault(m, "etc/desktop.icons")
else:
    fail.append("etc/desktop.icons is missing (the desktop has no icons)")
appdir = ETC / "hamde" / "apps"
ndesktop = 0
for d in sorted(appdir.glob("*.desktop")):
    ndesktop += 1
    for ln in d.read_text().splitlines():
        if ln.startswith("Exec="):
            prog = ln[5:].split()[0] if ln[5:].split() else ""
            if prog:
                clickable.setdefault(Path(prog).name, f"etc/hamde/apps/{d.name}")
            break
if ndesktop == 0:
    fail.append("etc/hamde/apps has no .desktop launchers (the menu is empty)")
for b in sorted(clickable):
    if b not in all_bins:
        fail.append(f"{clickable[b]} launches /bin/{b} but NO package installs it")

# --- 3: every build/user/*.elf (minus allowlist) is in SOME package ---
built = {p.stem for p in USER.glob("*.elf")}
uncovered = sorted(b for b in built
                   if b not in SKIP_BINS and b not in all_bins)
if uncovered:
    fail.append(f"{len(uncovered)} built binaries packaged by NO package: "
                + ", ".join(uncovered))

# --- 4: GRANULARITY (#115 — a real distro packages every app apart) ---
# The DE must NOT ship as one bundled hamnix-desktop-apps package. Assert
# each application is its OWN package, hamnix-desktop-core exists apart
# from the apps, and the hamnix-desktop metapackage pulls them all in.
EXPECTED_APP_PKGS = {
    "hamnix-ham2048": "ham2048scene",
    "hamnix-hamsnake": "hamsnakescene",
    "hamnix-hamchess": "hamchessscene",
    "hamnix-hamgamedemo": "hamgamedemo",
    "hamnix-hamterm": "hamterm",
    "hamnix-hamfiles": "hamfm",
    "hamnix-hamcalc": "hamcalc",
    "hamnix-hamedit": "hamedit",
    "hamnix-hammon": "hammon",
    "hamnix-hamview": "hamview",
    "hamnix-hambrowse": "hambrowse",
    "hamnix-hamaudio": "hamaudioscene",
    "hamnix-haminbox": "haminbox",
    "hamnix-hamsettings": "hamsettings",
    "hamnix-haminstallui": "haminstallui",
    "hamnix-haminput": "haminput",
    # The OFFICE SUITE — pre-installed first-class DE apps (promoted out
    # of the repo-only apps-optional set): word processor / spreadsheet /
    # presentation. Each is its own package under hamnix-desktop-apps.
    "hamnix-hamwrite": "hamwrite",
    "hamnix-hamsheet": "hamsheet",
    "hamnix-hamslides": "hamslides",
}

# 4a: hamnix-desktop-core is a real, separate package with the compositor.
if "hamnix-desktop-core" not in pkgs:
    fail.append("granularity: hamnix-desktop-core package MISSING")
else:
    _, core_bases = pkg_files("hamnix-desktop-core")
    if "hamUId" not in core_bases:
        fail.append("granularity: hamnix-desktop-core lacks the hamUId "
                    "compositor/window-system daemon")

# 4b: every app is its own package staging its own binary — and NOT
# bundling a sibling app's binary (2048 is its own package, etc.).
sibling_bins = set(EXPECTED_APP_PKGS.values())
for pkg, must_have in sorted(EXPECTED_APP_PKGS.items()):
    if pkg not in pkgs:
        fail.append(f"granularity: app package {pkg} MISSING")
        continue
    _, bases = pkg_files(pkg)
    if must_have not in bases:
        fail.append(f"granularity: {pkg} does not stage {must_have}")
    strays = (set(bases) & sibling_bins) - {must_have}
    if strays:
        fail.append(f"granularity: {pkg} bundles sibling app binaries "
                    f"{sorted(strays)} — apps must be packaged apart")

# 4c: the hamnix-desktop metapackage transitively pulls in core + every
# app package (closure walk from hamnix-desktop).
dseen = set()
dstack = ["hamnix-desktop"]
while dstack:
    n = dstack.pop()
    if n in dseen or n not in pkgs:
        continue
    dseen.add(n)
    dstack += dep_names(pkgs[n])
for want in ["hamnix-desktop-core", "hamnix-desktop-apps",
             *EXPECTED_APP_PKGS]:
    if want not in dseen:
        fail.append(f"granularity: hamnix-desktop closure MISSING {want}")

if fail:
    print("[de-cov] FAIL:")
    for f in fail:
        print("   - " + f)
    sys.exit(1)

print(f"[de-cov] OK: base closure={len(seen)} pkgs; "
      f"rc.5/svc refs={len(referenced)} resolved; "
      f"{len(clickable)} clickable launchers ({ndesktop} .desktop + icons) "
      f"all packaged; "
      f"{len(built)} built bins, {len(SKIP_BINS & built)} allowlisted, "
      "0 uncovered.")
PY

echo "[de-cov] PASS"
