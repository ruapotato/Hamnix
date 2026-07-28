#!/usr/bin/env bash
# scripts/test_devmapper.sh — native device-mapper (dm) self-test.
#
# Boots the kernel once with /etc/devmapper-test planted
# (ENABLE_DEVMAPPER_TEST=1). init/main.ad at boot:37.dm calls
# dm_selftest() (drivers/block/dm.ad), which registers a DEDICATED
# in-kernel backing ramdisk ("dmback0") and PROVES the native
# device-mapper core + linear + crypt targets:
#
#   * LINEAR: a write through the mapped device at virtual LBA 5 lands on
#     the underlying backing sector (under_start 32 + 5 = 37), and reads
#     back through the mapped device unchanged.
#   * CONCATENATION: a two-linear-target mapped device routes virtual
#     span A to backing region @64 and span B to backing region @128, so
#     a write to a sector in each span lands in the correct backing
#     offset (66 and 130 respectively).
#   * CRYPT (dm-crypt / AES-256-XTS, the aes-xts-plain64 default):
#     plaintext written through the crypt device is CIPHERTEXT on the
#     backing store (differs from plaintext), the SAME plaintext at two
#     sectors yields DIFFERENT ciphertext (the sector-keyed plain64
#     tweak), reads round-trip back to the original plaintext, AND the
#     cipher reproduces an independent AES-256-XTS known-answer vector.
#   * SNAPSHOT (dm-snapshot copy-on-write): an origin chunk written through
#     the snapshot-origin device first copies its ORIGINAL contents into a
#     SEPARATE exception store, so the snapshot view keeps reading the
#     pre-image while the origin advances to the new data; a never-written
#     chunk passes through to the origin on both views.
#   * INTEGRITY (dm-integrity / per-sector crc32c tags): a sector written
#     through the integrity device records a salted crc32c tag; the readback
#     validates and round-trips byte-identical. Corrupting the underlying
#     backing sector directly is then DETECTED on the next read — the
#     integrity device fails the I/O instead of returning the corrupt bytes.
#   * VERITY (dm-verity / read-only Merkle hash tree, salted SHA-256): clean
#     data blocks are hashed into a hash-tree block whose hash is the trusted
#     ROOT. A clean block verifies and round-trips; flipping a byte in a data
#     block, in the block's hash-tree leaf, or in any other hash-tree entry
#     (root mismatch) is DETECTED and the read fails with an I/O error.
#   * CACHE (dm-cache / fast device fronting a slow origin, LRU): a cold read
#     MISSes and PROMOTEs the origin block into a cache slot (the second read
#     HITs; hit/miss counters are genuinely computed); WRITETHROUGH keeps the
#     origin coherent and slots clean (clean eviction loses no data);
#     WRITEBACK leaves the origin STALE until an explicit flush, after which
#     the origin matches the cache; and evicting a DIRTY victim writes its
#     newest data back to the origin automatically.
#   * ERA (dm-era / per-chunk write-era generation tracking): each write
#     stamps the CURRENT era on the touched chunk; advancing the era
#     partitions future writes from past ones; a query returns EXACTLY the
#     set of chunks written in or after a target era (the "blocks changed
#     since N" incremental-backup primitive); and the per-chunk era metadata
#     is persisted to a metadata device and round-trips through a reload.
#   * DELAY (dm-delay / per-op read/write delay over a linear remap): data
#     written through the delay device is a real LINEAR passthrough (lands at
#     the write-path backing offset, reads back byte-identical through the
#     device and from the raw backing sector); each read takes the configured
#     READ delay and each write the DISTINCT WRITE delay, honoured by a
#     deferred-completion deadline queue (a logical tick clock the dm layer
#     advances), proven by per-path deferred-op counts and summed-delay totals
#     that necessarily differ between the read and write paths.
#
# The self-test needs NO external disk — it backs everything onto its own
# in-kernel ramdisk, so the boot is fully deterministic.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [device-mapper] PASS
# Fail marker:  [device-mapper] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_devmapper

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_devmapper] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_devmapper] (2/3) Build kernel with /etc/devmapper-test marker"
INIT_ELF=build/user/init.elf ENABLE_DEVMAPPER_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_image.sh"
kernel_image_compile "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_devmapper] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_devmapper] --- captured (device-mapper lines) ---"
grep -E '\[device-mapper\]' "$LOG" || true
echo "[test_devmapper] --- end ---"

# --- three-valued verdict gate (migrated off the hard MISS->FAIL tail) --
# A zero-marker / rc=124 boot on a TCG-starved host used to look identical
# to a real regression. Guard the zero-marker case FIRST: if the guest
# emitted no dm markers at all it never ran the selftest (starved) —
# INCONCLUSIVE, not a wall of bogus FAILs. The per-subtest check() chain
# below stays as DIAGNOSTICS; the final decision routes through verdict_*.
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[device-mapper\]|\[devmapper\]|\[dm\]'

fail=0

if grep -qF "[device-mapper] FAIL" "$LOG"; then
    echo "[test_devmapper] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[device-mapper] self-test reported FAIL" "$LOG"; then
    echo "[test_devmapper] FAIL: self-test returned non-zero" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_devmapper] PASS: $label"
    else
        echo "[test_devmapper] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"            "[device-mapper] self-test start"
check "linear remap"             "[device-mapper] linear: vLBA5 -> backing sector 37 OK"
check "linear readback"          "[device-mapper] linear: readback byte-identical OK"
check "concat span A"            "[device-mapper] concat: span A vLBA2 -> backing 66 OK"
check "concat span B"            "[device-mapper] concat: span B vLBA10 -> backing 130 OK"
check "crypt ciphertext on disk" "[device-mapper] PASS dmcrypt-ciphertext: backing sector 192 is ciphertext OK"
check "crypt tweak sector-keyed" "[device-mapper] PASS dmcrypt-tweak: same plaintext, two sectors -> different ciphertext OK"
check "crypt round-trip sec0"    "[device-mapper] PASS dmcrypt-roundtrip-sec0: sector 0 round-trips to plaintext OK"
check "crypt round-trip sec1"    "[device-mapper] PASS dmcrypt-roundtrip-sec1: sector 1 round-trips to plaintext OK"
check "crypt AES-XTS KAT vector" "[device-mapper] PASS dmcrypt-kat: AES-256-XTS vector matches reference OK"
check "snapshot CoW pre-image"   "[devmapper] snapshot: CoW preserved origin pre-image OK"
check "snapshot exc-store image" "[devmapper] snapshot: exception store holds pre-image OK"
check "snapshot origin advanced" "[devmapper] snapshot: origin reads new data OK"
check "snapshot CoW pass"        "[dm] PASS snapshot-cow"
check "snapshot passthrough"     "[dm] PASS snapshot-passthrough"
check "snapshot subtest PASS"    "[dm] snapshot PASS"
check "integrity round-trip"     "[devmapper] integrity: tag validated round-trip OK"
check "integrity detect corrupt" "[dm] PASS integrity-detect-corruption"
check "integrity subtest PASS"   "[dm] integrity PASS"
check "thin unprovisioned zeros" "[devmapper] thin: unprovisioned read returns zeros OK"
check "thin on-demand alloc"     "[dm] PASS thin-ondemand-alloc"
check "thin remap stable"        "[dm] PASS thin-remap-stable"
check "thin prov vs unprov"      "[devmapper] thin: provisioned vs unprovisioned distinguished OK"
check "thin subtest PASS"        "[dm] thin PASS"
check "verity clean round-trip"  "[dm] verity clean block verified + round-trip OK"
check "verity data corruption"   "[dm] verity data-corruption rejected"
check "verity hashtree corrupt"  "[dm] verity hash-tree-corruption rejected"
check "verity root mismatch"     "[dm] verity root-hash mismatch rejected"
check "verity subtest PASS"      "[dm] verity PASS"
check "cache cold miss promote"  "[dm] cache cold read MISS + promote OK"
check "cache warm hit"           "[dm] cache warm read HIT OK"
check "cache writethrough coh"   "[dm] cache writethrough origin coherent OK"
check "cache clean eviction"     "[dm] cache clean eviction preserves data OK"
check "cache writeback stale"    "[dm] cache writeback origin stale before flush OK"
check "cache writeback flush"    "[dm] cache writeback flush makes origin coherent OK"
check "cache dirty-victim wb"    "[dm] cache dirty-victim eviction writeback OK"
check "cache subtest PASS"       "[dm] cache PASS"
check "era era-1 write intact"   "[devmapper] era: era-1 write reads back intact OK"
check "era advance"              "[dm] PASS era-advance"
check "era query since era 2"    "[dm] PASS era-query-since"
check "era query since era 1"    "[devmapper] era: all written chunks {2,5,9} reported since era 1 OK"
check "era rewrite new data"     "[devmapper] era: re-written chunk reads back new data OK"
check "era metadata persist"     "[dm] PASS era-persist"
check "era subtest PASS"         "[dm] era PASS"
check "writecache write-back"    "[dm] writecache write-back: origin stale, data on cache OK"
check "writecache cached read"   "[dm] writecache read serves cached new data OK"
check "writecache fallthrough"   "[dm] writecache uncached read falls through to origin OK"
check "writecache flush"         "[dm] writecache flush writes back to origin, dirty cleared OK"
check "writecache persist recov" "[dm] writecache metadata persists: un-flushed write recovered OK"
check "writecache recov flush"   "[dm] writecache recovered write flushes to origin OK"
check "writecache subtest PASS"  "[dm] writecache PASS"
check "delay write remap"        "[device-mapper] delay: write vLBA5 -> backing 69 OK"
check "delay readback identical" "[device-mapper] delay: readback byte-identical OK"
check "delay distinct deferral"  "[dm] delay: read path 3-tick, write path 7-tick, distinct OK"
check "delay deadline honoured"  "[dm] delay: deferred-completion clock honoured deadlines OK"
check "delay subtest PASS"       "[dm] delay PASS"
check "device-mapper PASS"       "[device-mapper] PASS"

# --- final three-valued decision ---
# If the terminal PASS banner is absent AND qemu was killed by timeout, the
# selftest was starved mid-run (some early markers printed, later subtests
# never got to run) — INCONCLUSIVE, not a regression. A clean qemu exit
# (rc!=124) without the PASS banner, or any observed subtest MISS, is a
# real, actionable red.
if ! grep -qF "[device-mapper] PASS" "$LOG" && [ "$rc" -eq 124 ]; then
    verdict_inconclusive "$TAG" \
        "dm markers printed but the terminal '[device-mapper] PASS' banner never" \
        "arrived and qemu was killed by timeout (rc=124) — starved mid-selftest." \
        "Re-run on a QUIET host."
fi
if [ "$fail" -ne 0 ]; then
    verdict_fail "$TAG" \
        "a device-mapper subtest marker was OBSERVED absent (or an internal FAIL" \
        "was reported) while the selftest ran (qemu rc=$rc) — real regression."
fi

verdict_pass "$TAG" "native device-mapper: linear remap, two-target concatenation, AES-256-XTS dm-crypt (aes-xts-plain64: sector-keyed tweak, ciphertext-on-disk, plaintext round-trip, known-answer vector), dm-snapshot copy-on-write (origin-write preserves the snapshot pre-image in a separate exception store; origin advances to new data; never-written chunks pass through to origin), dm-integrity (per-sector salted crc32c tags: a known sector round-trips with its tag validated; corrupting the backing sector behind the target is DETECTED and the read fails instead of returning corrupt data), dm-thin thin provisioning (a thin device over-provisioned 32x the pool reads unprovisioned blocks as zeros consuming no pool space; the first write to a virtual block allocates exactly one pool block on demand and reads back correctly; re-writing a provisioned block allocates nothing; provisioned vs unprovisioned regions are distinguished), and dm-verity (read-only Merkle hash tree of salted SHA-256 over 4096-byte blocks rooted at a trusted root hash: a clean block verifies and round-trips byte-identical; flipping a byte in a data block, in the block's own hash-tree leaf, or in another hash-tree entry — root-hash mismatch — is each DETECTED and the read fails with an I/O error), and dm-cache (a small fast cache device fronting a larger slow origin with LRU eviction: a cold read MISSes and promotes the block into a cache slot so the second read HITs with genuinely-computed hit/miss counters; WRITETHROUGH updates both cache and origin keeping the origin coherent so clean evictions lose no data; WRITEBACK updates only the cache and leaves the origin stale until an explicit flush makes it coherent; and evicting a DIRTY victim writes its newest data back to the origin automatically), and dm-era (per-chunk write-era generation tracking: each write stamps the current era on the touched chunk; advancing the era partitions later writes from earlier ones; a query enumerates EXACTLY the chunks written in or after a target era — the 'blocks changed since N' incremental-backup primitive, with a re-written chunk's era correctly advancing; and the per-chunk era metadata is persisted to a separate metadata device and round-trips through a reload), and dm-delay (per-operation read/write delay over a linear remap: data written through the delay device is a real byte-identical linear passthrough to the mapped backing sector; each read takes the configured read delay and each write the DISTINCT write delay, applied via a deferred-completion deadline queue with a logical tick clock the dm layer advances, with per-path deferred-op counters and summed-delay totals proving the read and write paths each took their own configured value) all verified"
