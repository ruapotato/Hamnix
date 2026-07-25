# scripts/_installer_img.sh — STALE-IMAGE GUARD for every gate that boots
# build/hamnix-installer*.img.
#
# THE BUG THIS EXISTS TO KILL
# ===========================
# Every DE gate historically did:
#
#     if [ ! -f "$INSTALLER_IMG" ]; then bash scripts/build_installer_img.sh; fi
#
# i.e. "rebuild only when the file is ABSENT". A gate whose image path is
# DEDICATED (scripts/test_de_visual_gate.sh exports
# HAMNIX_DE_SELFTEST=1 and boots build/hamnix-installer-selftest.img) then
# reuses that image FOREVER — nobody ever deletes it — so the gate boots a
# build from days ago while the developer stares at freshly-compiled
# binaries in build/user/.
#
# This produced a real, expensive false diagnosis on 2026-07-24: the office
# suite (HamWrite/HamSheet/HamSlides) was reported "still missing from the
# booted desktop" with hard serial evidence (`[panel] appmenu entries: 24`,
# 13 desktop icons). The evidence came from the visual gate, which had
# silently re-booted build/hamnix-installer-selftest.img from 07-22 09:35 —
# TWO DAYS OLDER than the office launchers and the AM_MAX fix. That stale
# image contains ZERO `etc/hamde/apps/hamwrite.desktop`. The freshly built
# build/hamnix-installer.img from the SAME tree was already correct (26
# launchers, 16 desktop icons, `appmenu entries: 27`). Two agents burned
# full cycles chasing staging code that was never broken.
#
# THE RULE: an image is stale if it is OLDER than any tracked build input.
# Booting a stale image is a FALSE RESULT in both directions (false red, as
# above; and false green when a regression has landed but the image predates
# it), so gates must never do it silently.
#
# Usage (source AFTER $INSTALLER_IMG is resolved):
#
#     source "$PROJ_ROOT/scripts/_installer_img.sh"
#     ensure_installer_img "$INSTALLER_IMG" "[my_gate]" || exit 0
#
# ensure_installer_img rebuilds when the image is missing OR stale, honours
# HAMNIX_SKIP_BUILD=1 (reuse as-is, but LOUDLY warn when stale — never
# silently), and returns non-zero only when it cannot produce an image
# (caller decides SKIP vs FAIL).

# Directories whose tracked contents end up inside the shipped image. Kept
# explicit (not "the whole repo") so an unrelated docs/ edit never forces a
# 6-minute rebuild.
_HAMNIX_IMG_INPUT_DIRS="user lib etc init kernel arch drivers fs net compiler"
# Plus the BUILD scripts themselves (not the test_*.sh gates — a gate edit
# does not change a single byte of the shipped image, and forcing a 6-minute
# rebuild for one would make this guard hated and then disabled).
_HAMNIX_IMG_INPUT_GLOBS="scripts/build_*.sh scripts/build_*.py scripts/_*.sh scripts/gen_*.py"

# installer_img_newest_input — mtime (epoch seconds) of the newest build input.
installer_img_newest_input() {
    local root="${PROJ_ROOT:-.}" d newest=0 t g f
    for d in $_HAMNIX_IMG_INPUT_DIRS; do
        [ -d "$root/$d" ] || continue
        t=$(find "$root/$d" -type f -not -path '*/.git/*' -printf '%T@\n' \
                2>/dev/null | sort -rn | head -1)
        t="${t%%.*}"
        [ -n "$t" ] || continue
        [ "$t" -gt "$newest" ] 2>/dev/null && newest="$t"
    done
    for g in $_HAMNIX_IMG_INPUT_GLOBS; do
        for f in $root/$g; do
            [ -f "$f" ] || continue
            t=$(stat -c %Y "$f" 2>/dev/null || echo 0)
            [ "$t" -gt "$newest" ] 2>/dev/null && newest="$t"
        done
    done
    echo "$newest"
}

# installer_img_is_stale <img> — 0 (true) when <img> is absent or older than
# the newest tracked build input.
installer_img_is_stale() {
    local img="$1"
    [ -f "$img" ] || return 0
    local img_t newest
    img_t=$(stat -c %Y "$img" 2>/dev/null || echo 0)
    newest=$(installer_img_newest_input)
    [ "$img_t" -lt "$newest" ]
}

# ensure_installer_img <img> <tag> — guarantee <img> exists and is not stale.
# Returns 0 when a usable image is in place, 1 when none could be produced.
ensure_installer_img() {
    local img="$1" tag="${2:-[installer_img]}"
    if installer_img_is_stale "$img"; then
        if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
            if [ -f "$img" ]; then
                echo "$tag WARNING: $img is STALE (older than a tracked build" >&2
                echo "$tag   input) but HAMNIX_SKIP_BUILD=1 — booting it anyway." >&2
                echo "$tag   Any PASS/FAIL below may describe an OLD build." >&2
                return 0
            fi
            echo "$tag SKIP: $img absent and HAMNIX_SKIP_BUILD=1" >&2
            return 1
        fi
        if [ -f "$img" ]; then
            echo "$tag $img is STALE (older than a tracked build input) — rebuilding (~6 min)"
        else
            echo "$tag $img absent — building installer image (~6 min)"
        fi
        bash "${PROJ_ROOT:-.}/scripts/build_installer_img.sh" || {
            echo "$tag ERROR: build_installer_img.sh failed" >&2
            return 1
        }
    fi
    [ -f "$img" ] || { echo "$tag ERROR: $img still absent after build" >&2; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# ROLLOUT API (2026-07-24) — the shapes found across the ~70 other gates that
# boot a prebuilt build/ artifact. See scripts/test_artifact_freshness.sh for
# the QEMU-free canary that keeps this honest.
# ---------------------------------------------------------------------------

# installer_img_age_str <path> — "2d00h13m old (built 2026-07-22 09:35:41)".
installer_img_age_str() {
    local p="$1" t now age d h m
    [ -f "$p" ] || { echo "ABSENT"; return 0; }
    t=$(stat -c %Y "$p" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$(( now - t ))
    [ "$age" -lt 0 ] && age=0
    d=$(( age / 86400 )); h=$(( (age % 86400) / 3600 )); m=$(( (age % 3600) / 60 ))
    printf '%dd%02dh%02dm old (built %s)' "$d" "$h" "$m" \
        "$(date -d "@$t" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?')"
}

# _installer_img_loud <tag> <line>... — a banner nobody can miss in a CI log.
_installer_img_loud() {
    local tag="$1"; shift
    echo "$tag ############################################################" >&2
    local l
    for l in "$@"; do echo "$tag ## $l" >&2; done
    echo "$tag ############################################################" >&2
}

# installer_img_warn_if_stale <img> <tag>
#
# For gates that deliberately boot a PRE-EXISTING artifact (the
# `if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]` family, and the handful that never
# build at all). ALWAYS returns 0 — it only makes the staleness LOUD so a
# PASS/FAIL below can never be silently attributed to the wrong build.
installer_img_warn_if_stale() {
    local img="$1" tag="${2:-[installer_img]}"
    [ -f "$img" ] || return 0
    installer_img_is_stale "$img" || return 0
    _installer_img_loud "$tag" \
        "STALE ARTIFACT WARNING" \
        "$img" \
        "  $(installer_img_age_str "$img")" \
        "  is OLDER than a tracked build input — it does NOT contain the" \
        "  code in this working tree. The verdict below may describe an" \
        "  OLD build (this exact trap cost two agent-days on 2026-07-24)." \
        "  Rebuild: bash scripts/build_installer_img.sh"
    return 0
}

# installer_img_needs_build <img> <tag>
#
# Drop-in replacement for the buggy `if [ ! -f "$IMG" ]; then <build>; fi`
# condition. Returns 0 (=> run the gate's own build block, which may carry
# gate-specific env such as ENABLE_SPINE_SELFTEST=1) when the image is
# missing OR stale; returns 1 when the image is present and fresh.
#
# HAMNIX_SKIP_BUILD=1 + present-but-stale => LOUD warning and return 1, so the
# gate boots the old image knowingly rather than silently.
installer_img_needs_build() {
    local img="$1" tag="${2:-[installer_img]}"
    if ! installer_img_is_stale "$img"; then
        return 1                       # present and fresh — nothing to do
    fi
    if [ -f "$img" ]; then
        if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
            installer_img_warn_if_stale "$img" "$tag"
            return 1
        fi
        _installer_img_loud "$tag" \
            "$img is STALE ($(installer_img_age_str "$img"))" \
            "  — older than a tracked build input. REBUILDING (~6-14 min)."
        return 0
    fi
    return 0                           # absent — caller's block handles it
}
