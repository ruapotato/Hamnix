#!/usr/bin/env bash
# scripts/test_devmax_covers_all_ids.sh — FAST, QEMU-free guard for a bug class
# that has now bitten this kernel FOUR times.
#
# sys/src/9/port/namec.ad gates every inline cdev chan on
#     DEV_NONE < dev_type < DEV_MAX
# in _chan_id_valid(). A DEV_* constant declared at or above DEV_MAX therefore
# OPENS fine and then fails EVERY read and write with -EBADF, before the cdev
# body is ever entered. The failure is silent at the syscall boundary: `cat`
# prints nothing and exits 0, a write "succeeds" as far as a shell redirect is
# concerned. The comment above DEV_MAX records three previous rounds of this
# (DEV_FBPIX=124, the scene leaves 125..129, DEV_WSYS_WINDOWS=130). The fourth
# was DEV_SNARF_PRIMARY=132 vs DEV_MAX=131, which killed the X11 PRIMARY
# selection outright: highlighting text stored nothing and middle-click pasted
# nothing — the user-reported "mid mouse does not paste the hilated text".
#
# WHY A GATE AT THIS ALTITUDE. Nine host gates covered the PRIMARY selection
# and all nine were green throughout, because every one of them calls
# devsnarf_primary_read/write DIRECTLY. Nothing they can assert passes through
# _chan_id_valid, so no amount of clipboard-behaviour testing could ever see
# it. The invariant that was actually violated is a numeric one in namec.ad,
# and that is what this gate checks: DEV_MAX must sit STRICTLY above every
# inline DEV_* id.
#
# Pool-only dev_types (DEV_MNT and the file-backed families) are exempt: they
# are explicitly excluded from the inline arm of _chan_id_valid and never ride
# an inline chan id. They are listed below, mirroring that exclusion list.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SRC="sys/src/9/port/namec.ad"
[ -f "$SRC" ] || { echo "[devmax] FAIL: $SRC missing"; exit 1; }

python3 - "$SRC" <<'PY'
import re, sys

src = sys.argv[1]
text = open(src).read()

ids = {}
for m in re.finditer(r"^(DEV_[A-Z0-9_]+)\s*:\s*int32\s*=\s*(-?\d+)\s*(?:#.*)?$",
                     text, re.M):
    ids[m.group(1)] = int(m.group(2))

if "DEV_MAX" not in ids:
    print("[devmax] FAIL: DEV_MAX not found in %s" % src)
    sys.exit(1)
dev_max = ids.pop("DEV_MAX")

# Mirrors the exclusion list in _chan_id_valid: these never ride an inline
# chan id, so they are not bounded by DEV_MAX.
POOL_ONLY = {
    "DEV_NONE", "DEV_MNT", "DEV_EXT4_FILE", "DEV_FAT_FILE", "DEV_TMPFS_FILE",
    "DEV_DIR_FILE", "DEV_BUF_FILE", "DEV_PROC", "DEV_AUTH", "DEV_BLK",
    "DEV_PIPE_R", "DEV_PIPE_W", "DEV_SOCKET", "DEV_SOCKETPAIR", "DEV_NET",
    "DEV_PTMX", "DEV_FUSE_CONN", "DEV_FUSE_FILE",
}

inline = {k: v for k, v in ids.items() if k not in POOL_ONLY}
if not inline:
    print("[devmax] FAIL: parsed no DEV_* ids — has the declaration shape "
          "changed? This gate would silently pass forever.")
    sys.exit(1)

over = sorted(((v, k) for k, v in inline.items() if v >= dev_max),
              reverse=True)
if over:
    print("[devmax] FAIL: DEV_MAX=%d does not cover %d inline dev id(s); "
          "_chan_id_valid will reject them and EVERY read/write on those "
          "devices returns -EBADF:" % (dev_max, len(over)))
    for v, k in over:
        print("[devmax]        %s = %d" % (k, v))
    print("[devmax]        set DEV_MAX = %d" % (over[0][0] + 1))
    sys.exit(1)

hi_v, hi_k = max((v, k) for k, v in inline.items())
if dev_max != hi_v + 1:
    print("[devmax] FAIL: DEV_MAX=%d but the highest inline id is %s=%d; "
          "the invariant is DEV_MAX == (highest inline dev_type) + 1, so a "
          "gap here means the next id added lands outside the gate."
          % (dev_max, hi_k, hi_v))
    sys.exit(1)

print("[devmax] PASS DEV_MAX=%d covers all %d inline dev ids "
      "(highest: %s=%d)" % (dev_max, len(inline), hi_k, hi_v))
PY
rc=$?
if [ $rc -ne 0 ]; then
    echo "[devmax] RESULT: FAIL"
    exit 1
fi

# The device this bug actually broke, pinned by name: /dev/snarf.primary must
# still be a routable inline cdev on BOTH the read and the write dispatch.
for fn in devsnarf_primary_read devsnarf_primary_write; do
    if ! grep -q "$fn" "$SRC"; then
        echo "[devmax] FAIL: namec no longer dispatches $fn"
        exit 1
    fi
done
if ! grep -q '"#c/snarf.primary"' "$SRC"; then
    echo "[devmax] FAIL: namec no longer resolves #c/snarf.primary"
    exit 1
fi
echo "[devmax] PASS /dev/snarf.primary is routed on read and write"
echo "[devmax] RESULT: PASS"
exit 0
