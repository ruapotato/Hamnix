# scripts/_fresh_artifact.sh — ALWAYS-OVERWRITE contract for build scripts.
#
# THE BUG THIS EXISTS TO KILL (the other half of _installer_img.sh)
# ================================================================
# scripts/_installer_img.sh guards the CONSUMER side: a gate that boots a
# prebuilt artifact must notice when that artifact is older than its own
# inputs. That guard is reactive — it only fires when staleness is
# *detected*, and detection is mtime heuristics over a fixed input-dir list.
# Anything the heuristic misses (an untracked generator, a fixture rebuilt
# in place, a build that half-failed) slips through.
#
# This file guards the PRODUCER side, where the invariant is much simpler
# and needs no heuristics at all:
#
#     RUNNING A BUILD SCRIPT ALWAYS PRODUCES A FRESH ARTIFACT.
#
# Two concrete rules follow from it:
#
#   1. NO "skip if the output already exists". A build script that returns
#      early because its output file is present is a stale-artifact factory:
#      nothing ever deletes those files, so the "build" silently becomes a
#      no-op forever. (This is exactly the shape that cost two agent-days on
#      2026-07-24 — see scripts/_installer_img.sh.)
#
#   2. THE OUTPUT IS DELETED BEFORE THE BUILD STARTS. If the build then
#      fails halfway, the old artifact is GONE rather than sitting there
#      looking valid with a plausible mtime. A missing artifact makes the
#      next gate SKIP or rebuild loudly; a stale one makes it lie.
#      `set -e` + a mid-build failure is precisely how you get an artifact
#      that is neither old-and-obviously-stale nor new-and-correct.
#
# TRADEOFF (deliberate): gates that build get SLOWER — a re-run that would
# previously have reused a good image now pays the full ~6-14 min rebuild.
# That is the price of never validating a stale artifact, and it is the
# right trade: a slow gate wastes minutes, a stale gate wastes days.
#
# OPT-OUT: HAMNIX_REUSE_ARTIFACTS=1 restores the old reuse-if-present
# behaviour for the rare interactive case (iterating on a gate, not on the
# image). It prints a LOUD banner every time, because any PASS/FAIL produced
# downstream of it may describe an old build.
#
# Usage in a bash builder, right after the output paths are resolved:
#
#     source "$PROJ_ROOT/scripts/_fresh_artifact.sh"
#     fresh_artifact "[build_installer_img]" "$OUT" "$ROOTFS_IMG" ...
#
# and for an early-return reuse block:
#
#     if artifact_reuse_allowed "[build_installed_nvme]" "$GOLDEN_NVME"; then
#         exit 0            # reuse honoured (loudly)
#     fi
#     # ... always rebuild ...

# artifact_reuse_requested — 0 (true) when the caller opted out of the
# always-overwrite contract via HAMNIX_REUSE_ARTIFACTS=1.
artifact_reuse_requested() {
    [ "${HAMNIX_REUSE_ARTIFACTS:-0}" = "1" ]
}

# _fresh_artifact_loud <tag> <line>... — a banner nobody can miss in a log.
_fresh_artifact_loud() {
    local tag="$1"; shift
    echo "$tag ############################################################" >&2
    local l
    for l in "$@"; do echo "$tag ## $l" >&2; done
    echo "$tag ############################################################" >&2
}

# _fresh_artifact_age <path> — "2d00h13m old (built 2026-07-22 09:35:41)".
_fresh_artifact_age() {
    local p="$1" t now age d h m
    [ -e "$p" ] || { echo "ABSENT"; return 0; }
    t=$(stat -c %Y "$p" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$(( now - t )); [ "$age" -lt 0 ] && age=0
    d=$(( age / 86400 )); h=$(( (age % 86400) / 3600 )); m=$(( (age % 3600) / 60 ))
    printf '%dd%02dh%02dm old (built %s)' "$d" "$h" "$m" \
        "$(date -d "@$t" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?')"
}

# fresh_artifact <tag> <path>...
#
# Delete every named output so the build cannot possibly finish (or FAIL
# halfway) with an older file still in place. Always returns 0.
#
# HAMNIX_REUSE_ARTIFACTS=1 keeps the files and warns loudly.
fresh_artifact() {
    local tag="${1:-[build]}"; shift
    [ "$#" -gt 0 ] || return 0
    if artifact_reuse_requested; then
        local present=""
        local p
        for p in "$@"; do [ -e "$p" ] && present="$present $p"; done
        if [ -n "$present" ]; then
            _fresh_artifact_loud "$tag" \
                "HAMNIX_REUSE_ARTIFACTS=1 — NOT deleting existing outputs:" \
                "$(echo "$present" | tr ' ' '\n' | sed '/^$/d' | sed 's/^/    /' | tr '\n' ' ')" \
                "  Whatever this build leaves behind may be a MIX of old and" \
                "  new bytes, and a build that fails halfway will leave the" \
                "  OLD artifact looking valid. Any verdict downstream of this" \
                "  run may describe an OLD build. Unset HAMNIX_REUSE_ARTIFACTS" \
                "  to get the always-overwrite contract back."
        fi
        return 0
    fi
    local p
    for p in "$@"; do
        [ -n "$p" ] || continue
        if [ -e "$p" ]; then
            echo "$tag overwrite: removing previous $p ($(_fresh_artifact_age "$p"))"
        fi
        rm -rf -- "$p"
    done
    return 0
}

# artifact_reuse_allowed <tag> <path>...
#
# For builders that historically had an early-return "reuse the existing
# artifact" fast path. Returns 0 (=> caller may reuse and return) ONLY when
# HAMNIX_REUSE_ARTIFACTS=1 *and* every named path exists; otherwise returns
# 1 so the caller rebuilds. The reuse path is always announced loudly.
artifact_reuse_allowed() {
    local tag="${1:-[build]}"; shift
    artifact_reuse_requested || return 1
    local p
    for p in "$@"; do [ -e "$p" ] || return 1; done
    _fresh_artifact_loud "$tag" \
        "HAMNIX_REUSE_ARTIFACTS=1 — REUSING the existing artifact instead of" \
        "  rebuilding it:" \
        "$(for p in "$@"; do echo "    $p  $(_fresh_artifact_age "$p")"; done)" \
        "  Nothing here was rebuilt. Any PASS/FAIL downstream describes" \
        "  whatever tree produced those bytes, NOT this working tree."
    return 0
}
