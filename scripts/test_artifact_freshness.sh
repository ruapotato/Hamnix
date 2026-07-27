#!/usr/bin/env bash
# scripts/test_artifact_freshness.sh — QEMU-FREE canary against the
# stale-artifact false-report class.
#
# WHY THIS GATE EXISTS
# ====================
# On 2026-07-24 three separate agents plus the orchestrator each reported
# "the office suite ships" / "the office suite does not ship" — all wrong, in
# different directions — because each inspected a DIFFERENT build artifact and
# none of them matched what actually booted. The proximate bug:
# scripts/test_de_visual_gate.sh boots a DEDICATED image
# (build/hamnix-installer-selftest.img via HAMNIX_DE_SELFTEST=1) and rebuilt it
# only `if [ ! -f "$INSTALLER_IMG" ]`. Nothing ever deletes that file, so the
# gate re-booted a TWO-DAY-OLD image predating the fixes under test and
# produced a confident, screenshot-backed FALSE NEGATIVE.
#
# The fix is scripts/_installer_img.sh (rebuild-when-stale, LOUD warn when a
# stale artifact is deliberately reused) rolled out across every gate that
# boots a prebuilt build/ artifact. This gate is the cheap canary that keeps
# that rollout honest. It runs in ~1 s, boots nothing, and checks two things:
#
#   PART 1 — FRESHNESS. Every tracked build artifact that EXISTS under build/
#            must be NEWER than the newest tracked build input. An artifact
#            older than its own inputs is, by definition, not the thing the
#            tree describes; anything asserted against it is unsound.
#
#   PART 2 — WIRING LINT. No gate may reuse a prebuilt image/kernel/disk
#            without going through the guard. Concretely: a
#            `if [ ! -f "$IMG" ]; then ... build ... fi` block around a
#            build_installer_img.sh / build_installed_nvme.sh / build_iso.sh
#            call is BANNED — that is the exact shape of the original bug.
#            New gates written in the old shape fail here instead of silently
#            validating an artifact from last week.
#
# Exit 0 = PASS, 1 = FAIL. Missing artifacts are NOT a failure (they will be
# built); only present-and-stale ones are.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[artifact_freshness]"
# shellcheck source=_installer_img.sh
source "$PROJ_ROOT/scripts/_installer_img.sh"

FAILED=0

# Tracked build artifacts: everything a gate may boot / assert against without
# having built it in the same run.
ARTIFACTS="
build/hamnix-installer.img
build/hamnix-installer-selftest.img
build/hamnix-installed.qcow2
build/hamnix-live-distro.img
build/hamnix-rootfs.img
build/hamnix-kernel.elf
build/hamnix-installer-kernel.elf
build/hamnix-installed-kernel.elf
build/hamnix.iso
build/hamnix.img
build/ext4.img
fs/initramfs_blob.S
"

echo "$TAG PART 1: artifact freshness (mtime vs newest tracked build input)"
NEWEST=$(installer_img_newest_input)
echo "$TAG newest tracked build input: $(date -d "@$NEWEST" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$NEWEST")"

CHECKED=0
for a in $ARTIFACTS; do
    [ -f "$a" ] || continue
    CHECKED=$((CHECKED + 1))
    if installer_img_is_stale "$a"; then
        echo "$TAG FAIL: $a is STALE — $(installer_img_age_str "$a")" >&2
        echo "$TAG   It predates a tracked build input, so it does NOT contain" >&2
        echo "$TAG   this tree's code. Any gate booting it reports on an OLD build." >&2
        FAILED=1
    else
        echo "$TAG   ok  $a — $(installer_img_age_str "$a")"
    fi
done
if [ "$CHECKED" -eq 0 ]; then
    echo "$TAG   (no tracked artifacts present in this tree — nothing to check)"
fi

echo "$TAG PART 2: guard wiring lint (no gate may reuse a prebuilt artifact"
echo "$TAG         behind a bare \`if [ ! -f \"\$IMG\" ]\` rebuild block)"

# A gate is IN VIOLATION when it invokes one of the artifact builders from
# inside an `if [ ! -f "$VAR" ]; then` block. That block rebuilds only on
# ABSENCE, so a present-but-ancient artifact is reused forever.
VIOLATIONS=$(python3 - <<'PY'
import re, glob, sys
BUILDERS = r'(build_installer_img|build_installed_nvme|build_iso|build_rootfs_img)\.(sh|py)'
bad = []
for f in sorted(glob.glob('scripts/*.sh')):
    if f.endswith('_installer_img.sh'):
        continue
    lines = open(f, errors='replace').read().split('\n')
    for i, l in enumerate(lines):
        if l.lstrip().startswith('#'):
            continue
        if not re.search(r'(bash|python3)\s+\S*' + BUILDERS, l):
            continue
        # a builder NAMED inside an echo/message is not an invocation
        if re.match(r'\s*(echo|say|printf|#)', l):
            continue
        bind = len(re.match(r'^(\s*)', l).group(1))
        # walk out to the enclosing `if`s; flag a bare `if [ ! -f "$X" ]`
        for j in range(i - 1, -1, -1):
            m = re.match(r'^(\s*)if \[ ! -f "\$\{?\w+\}?" \]', lines[j])
            if not m or len(m.group(1)) >= bind:
                continue
            ind = m.group(1)
            for k in range(j + 1, len(lines)):
                if lines[k] == ind + 'fi':
                    if k > i:
                        bad.append('%s:%d: %s' % (f, j + 1, lines[j].strip()))
                    break
            break
print('\n'.join(bad))
PY
)
if [ -n "$VIOLATIONS" ]; then
    echo "$TAG FAIL: gates still using the rebuild-only-when-ABSENT shape:" >&2
    echo "$VIOLATIONS" | sed "s|^|$TAG   |" >&2
    echo "$TAG   Fix: source scripts/_installer_img.sh and replace the condition" >&2
    echo "$TAG   with \`if installer_img_needs_build \"\$IMG\" \"[tag]\"; then\`." >&2
    FAILED=1
else
    echo "$TAG   ok  no gate rebuilds an artifact only when it is absent"
fi

# Every gate that consumes an artifact it did not build in the same run must
# reference the guard at least once. (Advisory list — reported, not fatal, so
# a legitimately self-building gate never blocks the battery.)
UNGUARDED=""
for f in scripts/test_*.sh; do
    grep -q 'INSTALLER_IMG\|GOLDEN_NVME\|HAMNIX_ISO' "$f" 2>/dev/null || continue
    grep -q 'installer_img_needs_build\|installer_img_warn_if_stale\|ensure_installer_img\|installer_img_is_stale\|_installed_boot.sh\|test_installer_nvme_inram.sh' "$f" 2>/dev/null && continue
    UNGUARDED="$UNGUARDED $f"
done
if [ -n "$UNGUARDED" ]; then
    echo "$TAG NOTE: gates naming an artifact but not referencing the guard:" >&2
    for f in $UNGUARDED; do echo "$TAG   $f" >&2; done
fi

echo "$TAG PART 2b: WARN-ONLY is not a guard for a gate that BOOTS the image"
# The hole this closes (2026-07-27): PART 2 above accepts
# installer_img_warn_if_stale as "guarded". But that helper ALWAYS returns 0
# and rebuilds NOTHING — the gate still boots the stale image and still
# prints PASS or FAIL. A loud warning in a 4000-line serial log is not a
# guard; it is a footnote nobody reads. Counted on 7240d3b2, 13 gates that
# BOOT build/hamnix-installer.img under QEMU were in exactly this state, and
# one of them (test_de_wallpaper_themes.sh) had no guard at all and produced
# a false FAIL that cost an hour that morning. The false GREEN is worse: a
# stale image that predates a regression silently PASSES the gate written to
# catch it.
#
# RULE: a test_*.sh that launches QEMU against $INSTALLER_IMG must either
#   (a) call ensure_installer_img (rebuild-when-stale), or
#   (b) invoke build_installer_img.sh itself (the ENABLE_*_SELFTEST family,
#       which needs gate-specific build env), optionally alongside
#       installer_img_needs_build / warn_if_stale.
# warn_if_stale ALONE is a FAIL. Gates that never boot the image (size
# checks, -kernel fast paths) are exempt: they cannot be fooled by a stale
# boot.
WARNONLY=$(python3 - <<'PY'
import glob, re
bad = []
for f in sorted(glob.glob('scripts/test_*.sh')):
    src = open(f, errors='replace').read()
    code = [l for l in src.split('\n') if not l.lstrip().startswith('#')]
    # Only the real build artifact path counts — not an mktemp TEMPLATE that
    # merely happens to be named hamnix-installer-stageB-raw.XXXXXX.img
    # (scripts/test_installer_full.sh), and not a defensive `rm -f` of a
    # stale image in a gate that boots via -kernel
    # (scripts/test_apt_install_e2e.sh). Both are exempt: neither BOOTS it.
    uses = [l for l in code
            if re.search(r'build/hamnix-installer[\w.-]*\.img', l)
            and not re.match(r'\s*rm\b', l)]
    if not uses:
        continue
    code = '\n'.join(code)
    if 'qemu-system' not in code:            # never boots it — exempt
        continue
    if 'ensure_installer_img' in code:
        continue
    if re.search(r'(bash|python3)\s+\S*build_installer_img\.sh', code):
        continue
    bad.append(f)
print('\n'.join(bad))
PY
)
if [ -n "$WARNONLY" ]; then
    echo "$TAG FAIL: gates that BOOT the installer image with no rebuild guard:" >&2
    echo "$WARNONLY" | sed "s|^|$TAG   |" >&2
    echo "$TAG   These boot whatever image happens to be on disk. Fix:" >&2
    echo "$TAG     source \"\$PROJ_ROOT/scripts/_installer_img.sh\"" >&2
    echo "$TAG     ensure_installer_img \"\$INSTALLER_IMG\" \"[tag]\" \\\\" >&2
    echo "$TAG         || { echo \"[tag] SKIP: no usable image\" >&2; exit 0; }" >&2
    echo "$TAG   Do NOT satisfy this by deleting the QEMU boot or exiting 0." >&2
    FAILED=1
else
    echo "$TAG   ok  every image-booting gate rebuilds when the image is stale"
fi

echo "$TAG PART 3: assertion-altitude registry (a gate that asserts on"
echo "$TAG         EMISSION or a DIRECTORY LISTING must name the gate that"
echo "$TAG         asserts on the SHIPPED RESULT)"

# The second half of the 2026-07-24 failure. Two gates were green throughout:
#   * the desktop-label gate proved label glyph runs were EMITTED into the
#     display list — while the shipped desktop rendered blank space under
#     every icon;
#   * the appmenu gate proved the .desktop DIRECTORY LISTING was well-formed —
#     while the live menu silently dropped every app past an internal cap.
# Both are legitimate fast gates; neither is a verdict on what ships. Each
# must therefore carry an `ASSERTION ALTITUDE` note naming the result-level
# gate that IS such a verdict. This part keeps that annotation from rotting.
ALTITUDE_REGISTRY="
scripts/test_de_desktop_label_budget_host.sh
scripts/test_de_appmenu_datadriven.sh
"
for g in $ALTITUDE_REGISTRY; do
    if [ ! -f "$g" ]; then
        echo "$TAG   note: $g no longer exists — drop it from ALTITUDE_REGISTRY"
        continue
    fi
    if ! grep -q 'ASSERTION ALTITUDE' "$g"; then
        echo "$TAG FAIL: $g lost its ASSERTION ALTITUDE note — a reader can no" >&2
        echo "$TAG   longer tell that its green does not mean the feature ships." >&2
        FAILED=1
        continue
    fi
    ref=$(grep -m1 '^# RESULT-LEVEL GATE:' "$g" | sed 's/^# RESULT-LEVEL GATE:[[:space:]]*//')
    if [ -z "$ref" ]; then
        echo "$TAG FAIL: $g has no '# RESULT-LEVEL GATE: <script>' line" >&2
        FAILED=1
    elif [ ! -f "$ref" ]; then
        echo "$TAG FAIL: $g names result-level gate '$ref' which does not exist" >&2
        FAILED=1
    else
        echo "$TAG   ok  $g -> $ref"
    fi
done

echo "$TAG PART 4: PRODUCER-side always-overwrite contract"
echo "$TAG         (a build script must ALWAYS write a fresh artifact)"

# PARTS 1-3 are all CONSUMER-side: they catch a gate that boots something old.
# That is reactive — it depends on mtime heuristics over a fixed input-dir
# list, and anything the heuristic misses slips through. The producer-side
# invariant needs no heuristics: RUNNING A BUILD SCRIPT ALWAYS PRODUCES A
# FRESH ARTIFACT. scripts/_fresh_artifact.sh implements it (delete the output
# BEFORE building, so a half-failed build leaves nothing that looks valid);
# this part keeps the primary producers wired to it.
PRODUCERS="
scripts/build_installer_img.sh
scripts/build_installed_nvme.sh
scripts/build_kernel_llvm.sh
scripts/build_rootfs_img.py
scripts/build_initramfs.py
"
for p in $PRODUCERS; do
    [ -f "$p" ] || { echo "$TAG   note: $p no longer exists"; continue; }
    if grep -q 'fresh_artifact\|artifact_reuse_allowed' "$p"; then
        echo "$TAG   ok  $p honours the always-overwrite contract"
    else
        echo "$TAG FAIL: $p produces a build artifact but never calls" >&2
        echo "$TAG   fresh_artifact() — a failed run there can leave an OLD" >&2
        echo "$TAG   artifact in place looking valid. See scripts/_fresh_artifact.sh" >&2
        FAILED=1
    fi
done

# A build script must not RETURN EARLY because its output already exists.
# That is a stale-artifact factory: nothing ever deletes those outputs, so the
# "build" silently becomes a permanent no-op. The one legal form is
# artifact_reuse_allowed(), which requires the explicit HAMNIX_REUSE_ARTIFACTS
# opt-out and shouts about it.
REUSE_VIOLATIONS=$(python3 - <<'PY'
import glob, re
bad = []
for f in sorted(glob.glob('scripts/build_*.sh')):
    lines = open(f, errors='replace').read().split('\n')
    for i, l in enumerate(lines):
        if l.lstrip().startswith('#'):
            continue
        # `if [ -f "$OUT" ] ...` guarding an early `exit 0` a few lines below
        if not re.match(r'\s*if \[ -f "\$\{?\w+\}?" \]', l):
            continue
        window = '\n'.join(lines[i:i + 8])
        if re.search(r'^\s*exit 0\s*$', window, re.M) and \
           'artifact_reuse_allowed' not in window:
            bad.append('%s:%d: %s' % (f, i + 1, l.strip()))
print('\n'.join(bad))
PY
)
if [ -n "$REUSE_VIOLATIONS" ]; then
    echo "$TAG FAIL: build scripts that skip the build when the output exists:" >&2
    echo "$REUSE_VIOLATIONS" | sed "s|^|$TAG   |" >&2
    echo "$TAG   Fix: source scripts/_fresh_artifact.sh and use" >&2
    echo "$TAG   \`if artifact_reuse_allowed \"[tag]\" \"\$OUT\"; then exit 0; fi\`," >&2
    echo "$TAG   which reuses ONLY under an explicit HAMNIX_REUSE_ARTIFACTS=1." >&2
    FAILED=1
else
    echo "$TAG   ok  no build script skips itself when its output already exists"
fi

if [ "$FAILED" -ne 0 ]; then
    echo "$TAG FAIL"
    exit 1
fi
echo "$TAG PASS"
exit 0
