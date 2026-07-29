# scripts/_adder_cc.sh — shared Adder-compiler backend selector for the
# build (Track-3 self-hosting cutover scaffolding).
#
# `source` this from a build script, then call `adder_cc_compile`:
#
#     source "$PROJ_ROOT/scripts/_adder_cc.sh"
#     adder_cc_compile --target=x86_64-adder-user in.ad -o out.elf
#
# Backend is chosen by the ADDER_CC env var:
#
#   ADDER_CC=adder    (DEFAULT, 2026-06-22) — route the compile through the
#                     self-hosted `.ad` host compiler (build/cutover/host_ac.elf),
#                     bootstrapped once by the seed. ~300x faster per-compile
#                     (126ms->0.4ms). The native compiler builds the whole
#                     kernel + userland and produces an installer image that is
#                     BEHAVIORALLY IDENTICAL to the seed's (all differentials
#                     green; native rl5 boots to the desktop — VISUALLY verified).
#
#   ADDER_CC=python   — the frozen Python seed (`python3 -m compiler.adder
#                     compile ...`). The bootstrap/trust root + equivalence
#                     oracle; it ALWAYS compiles 100% of the tree. Used to
#                     compile the compiler and as the differential oracle only.
#
# ====================================================================
# CUTOVER STATUS (2026-06-22): ADDER_CC=adder IS NOW THE DEFAULT. The native
# `.ad` host compiler builds the WHOLE kernel + all userland and produces an
# installer image behaviorally identical to the seed's: fuzzer 500/500 0
# miscompiles; userland objdiff 193 clean; kernel objdiff (kobjdiff) 0
# collisions + 0 histogram/branch divergences across 10162 funcs; native
# installer rl5 PASS with `[live-root] DONE` + `entering runlevel 5`; the
# native desktop was VISUALLY verified (hamedit + calculator painted). The
# Python seed stays the FROZEN bootstrap + differential oracle (compile the
# compiler only). Escape hatch: set ADDER_CC=python to build via the seed.
# See docs/subsystems/adder-compiler.md + the kobjdiff/objdiff harnesses.
# ====================================================================

# Build build/cutover/host_ac.elf once (idempotent within a build) using
# the Python seed. Safe to call even when ADDER_CC=python (it just no-ops
# the bootstrap unless the .ad backend is actually selected).
adder_cc_bootstrap() {
    if [ "${ADDER_CC:-adder}" != "adder" ]; then
        return 0
    fi
    if [ -n "${_ADDER_CC_BOOTSTRAPPED:-}" ]; then
        return 0
    fi
    local root="${PROJ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    echo "[adder_cc] bootstrap: building build/cutover/host_ac.elf via the Python seed"
    mkdir -p "$root/build/cutover"
    python3 - "$root" <<'PY' || { echo "[adder_cc] ERROR: concat host compiler failed" >&2; return 1; }
import sys, importlib.util, os
root = sys.argv[1]; os.chdir(root)
spec = importlib.util.spec_from_file_location("ccs", "scripts/concat_compiler_source.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.DRIVER_MAIN = "fused_driver_host_main.ad"
raise SystemExit(m.main(["concat", "-o", "build/cutover/host_compiler.ad", "--with-driver"]))
PY
    # host_ac.elf is linked as ET_DYN/PIE (ADDER_X86_LINUX_PIE=1) so its
    # ~474 MiB BSS lands at a HIGH vaddr on-device (loader rebase to >=4 GiB),
    # clear of the kernel's low-identity direct map. The code is fully
    # position-independent (RIP-relative, zero dynamic relocations), so this is
    # behaviourally identical to the old ET_EXEC link on the host.
    ( cd "$root" && ADDER_X86_LINUX_PIE=1 python3 -m compiler.adder compile \
        --target=x86_64-linux \
        build/cutover/host_compiler.ad -o build/cutover/host_ac.elf ) \
        || { echo "[adder_cc] ERROR: host_ac.elf failed to build" >&2; return 1; }
    [ -x "$root/build/cutover/host_ac.elf" ] \
        || { echo "[adder_cc] ERROR: no host_ac.elf produced" >&2; return 1; }
    export _ADDER_CC_BOOTSTRAPPED=1
    echo "[adder_cc] bootstrap OK: $(stat -c%s "$root/build/cutover/host_ac.elf") bytes"
}

# adder_cc_compile <args...> — drop-in for `python3 -m compiler.adder compile`.
# Accepts the same CLI shape (`--target=T <in.ad> -o <out>`). Routes to the
# selected backend. For ADDER_CC=adder the args are translated to host_ac.elf's
# positional <in> <out> form. The seed `--target` is FORWARDED to host_ac so it
# selects the output ELF format (x86_64-bare-metal -> the higher-half kernel
# ELF; everything else -> the self-contained user ELF) — see elf_emit.ad
# elf_emit_image_target(). The kernel format is not yet emittable (cap#3b/cap#4,
# see docs/subsystems/adder-compiler.md); host_ac fails it with a precise
# diagnostic rather than silently emitting a user-shaped ELF.
adder_cc_compile() {
    local backend="${ADDER_CC:-adder}"
    if [ "$backend" = "python" ]; then
        # Callers pass the full seed CLI verb (`compile ...`); forward as-is.
        python3 -m compiler.adder "$@"
        return $?
    fi
    if [ "$backend" = "adder" ]; then
        adder_cc_bootstrap || return 1
        local root="${PROJ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
        # Parse the seed-style CLI to extract <in>, <out>, and the --target.
        local in_ad="" out_elf="" target="" a
        local -a rest=("$@")
        local i=0
        while [ $i -lt ${#rest[@]} ]; do
            a="${rest[$i]}"
            case "$a" in
                --target=*) target="${a#--target=}" ;;  # forwarded below
                -o) i=$((i+1)); out_elf="${rest[$i]}" ;;
                -o*) out_elf="${a#-o}" ;;
                compile) : ;;
                -*) : ;;                                # ignore other flags
                *) [ -z "$in_ad" ] && in_ad="$a" ;;
            esac
            i=$((i+1))
        done
        if [ -z "$in_ad" ] || [ -z "$out_elf" ]; then
            echo "[adder_cc] ERROR: could not parse in/out from: $*" >&2
            return 2
        fi
        # Forward the format selector (host_ac accepts the flag anywhere).
        local -a hc=()
        [ -n "$target" ] && hc+=("--target=$target")
        # USERLAND --opt: HAMNIX_USER_OPT=1 compiles every user ELF WITH the
        # Phase-1..5 optimizer (the shipped-image default; ~1.42x of gcc-O2 +
        # SIMD on paint-shaped loops). A specific binary can be EXCLUDED from
        # --opt (built no-opt) by listing its basename — with or without the
        # .elf suffix — in HAMNIX_USER_OPT_EXCLUDE (space-separated). Used to
        # ship the rest of the OS optimized while one miscompiling binary
        # stays unoptimized. Kernel targets go through adder_cc_link_kernel
        # below, which is gated on HAMNIX_KERNEL_OPT independently.
        if [ "$target" != "x86_64-bare-metal" ] && [ "${HAMNIX_USER_OPT:-0}" = "1" ]; then
            local _bn; _bn="$(basename "$out_elf")"; _bn="${_bn%.elf}"
            local _excluded=0 _ex
            for _ex in ${HAMNIX_USER_OPT_EXCLUDE:-}; do
                _ex="${_ex%.elf}"
                if [ "$_ex" = "$_bn" ]; then _excluded=1; break; fi
            done
            if [ "$_excluded" = "1" ]; then
                echo "[adder_cc] USER --opt EXCLUDED (no-opt): $_bn" >&2
            else
                hc+=("--opt")
            fi
        fi
        # HAMNIX_CHECK_ARITH turns on the OPT-IN checked-integer-arithmetic mode
        # (adder/compiler/checkarith.ad) for EVERY unit this wrapper builds:
        #   HAMNIX_CHECK_ARITH=1     trap on the first detected overflow
        #   HAMNIX_CHECK_ARITH=warn  report each site once and continue (triage)
        # Default unset -> the flag is never passed and the build is
        # byte-identical to the unchecked one.
        case "${HAMNIX_CHECK_ARITH:-}" in
            warn) hc+=("--check-arith-warn") ;;
            "" ) : ;;
            *  ) hc+=("--check-arith") ;;
        esac
        if [ "$target" = "x86_64-bare-metal" ]; then
            # KERNEL target: host_ac emits a RELOCATABLE .o (ET_REL); we then
            # `as`+`ld` it together with the hand-written boot stubs under
            # arch/x86/kernel/kernel.lds, EXACTLY as the seed's
            # assemble_and_link_x86_bare does. <out_elf> is the final kernel ELF.
            if adder_cc_link_kernel "$root" "$in_ad" "$out_elf"; then return 0; fi
            echo "[adder_cc] native kernel compile failed -> Python seed fallback: $in_ad" >&2
            python3 -m compiler.adder "$@"
            return $?
        fi
        if "$root/build/cutover/host_ac.elf" "${hc[@]}" "$in_ad" "$out_elf"; then return 0; fi
        echo "[adder_cc] native compile failed -> Python seed fallback: $in_ad" >&2
        python3 -m compiler.adder "$@"
        return $?
    fi
    echo "[adder_cc] ERROR: unknown ADDER_CC='$backend' (want python|adder)" >&2
    return 2
}

# adder_cc_link_kernel <root> <in.ad> <out.elf>
# Compile init/main.ad to a relocatable .o with host_ac, then assemble the
# hand-written boot stubs + all extra .S and `ld` them together under
# arch/x86/kernel/kernel.lds into the final higher-half kernel ELF — a
# byte-for-byte mirror of compiler/adder.py assemble_and_link_x86_bare's
# file list, flags, and link order (header.o, head_64.o, main.o, extras).
adder_cc_link_kernel() {
    local root="$1" in_ad="$2" out_elf="$3"
    local as_cmd="${AS:-as}" ld_cmd="${LD:-ld}"
    local boot_s="$root/arch/x86/boot/header.S"
    local head_s="$root/arch/x86/kernel/head_64.S"
    local lds="$root/arch/x86/kernel/kernel.lds"
    local f
    for f in "$boot_s" "$head_s" "$lds"; do
        [ -f "$f" ] || { echo "[adder_cc] ERROR: missing $f" >&2; return 1; }
    done
    local tmp; tmp="$(mktemp -d)" || return 1
    local main_o="$tmp/main.o"
    # 1) host_ac emits the relocatable Adder object.
    #    HAMNIX_KERNEL_OPT=1 compiles the kernel object WITH the Phase-1..5
    #    optimizer (--opt). Default OFF -> byte-identical to the seed
    #    (kobjdiff/objdiff clean). HAMNIX_KERNEL_OPT_NOVEC=1 additionally passes
    #    --no-vec (bisection lever; the vectorizer is paint-shaped so normally
    #    a no-op in the kernel, but the lever is here for isolation runs).
    local -a kopt=()
    if [ "${HAMNIX_KERNEL_OPT:-0}" = "1" ]; then
        kopt+=("--opt")
        [ "${HAMNIX_KERNEL_OPT_NOVEC:-0}" = "1" ] && kopt+=("--no-vec")
        [ "${HAMNIX_KERNEL_OPT_NOIREMIT:-0}" = "1" ] && kopt+=("--no-iremit")
        echo "[adder_cc] KERNEL --opt build (${kopt[*]})" >&2
    fi
    # HAMNIX_CHECK_ARITH (see adder_cc_compile): checked integer arithmetic for
    # the KERNEL object too. The kernel is NOT exempt from this check — the
    # defect that motivated the mode (the cyc_to_ns 64-bit multiply that wrapped
    # the monotonic clock after 1099 s and unbounded every timed wait) is kernel
    # code. `=1` routes a detected overflow to panic(); `=warn` to printk0().
    case "${HAMNIX_CHECK_ARITH:-}" in
        warn) kopt+=("--check-arith-warn"); echo "[adder_cc] KERNEL --check-arith-warn build" >&2 ;;
        "" ) : ;;
        *  ) kopt+=("--check-arith"); echo "[adder_cc] KERNEL --check-arith build" >&2 ;;
    esac
    "$root/build/cutover/host_ac.elf" "${kopt[@]}" --target=x86_64-bare-metal "$in_ad" "$main_o" \
        || { echo "[adder_cc] ERROR: host_ac kernel .o emit failed" >&2; rm -rf "$tmp"; return 1; }
    # 2) Assemble the boot stubs + every other hand-written .S under arch/x86,
    #    fs, drivers (excluding the two boot stubs, which lead the link order).
    #    The initramfs override mirrors the seed's HAMNIX_INITRAMFS_BLOB path.
    "$as_cmd" --64 -o "$tmp/header.o" "$boot_s" \
        || { echo "[adder_cc] ERROR: as header.S failed" >&2; rm -rf "$tmp"; return 1; }
    "$as_cmd" --64 -o "$tmp/head_64.o" "$head_s" \
        || { echo "[adder_cc] ERROR: as head_64.S failed" >&2; rm -rf "$tmp"; return 1; }
    local blob_override="${HAMNIX_INITRAMFS_BLOB:-}"
    if [ -z "$blob_override" ] && [ -n "${HAMNIX_BUILD_DIR:-}" ]; then
        blob_override="$HAMNIX_BUILD_DIR/initramfs_blob.S"
    fi
    local -a extra_objs=()
    local s o n=0
    while IFS= read -r s; do
        [ "$s" = "$boot_s" ] && continue
        [ "$s" = "$head_s" ] && continue
        # Drop an in-source initramfs_blob.S when an override is provided.
        if [ -n "$blob_override" ] && [ "$(basename "$s")" = "initramfs_blob.S" ]; then
            continue
        fi
        o="$tmp/extra_$n.o"; n=$((n+1))
        "$as_cmd" --64 -o "$o" "$s" \
            || { echo "[adder_cc] ERROR: as $s failed" >&2; rm -rf "$tmp"; return 1; }
        extra_objs+=("$o")
    done < <(find "$root/arch/x86" "$root/fs" "$root/drivers" -name '*.S' 2>/dev/null | sort)
    if [ -n "$blob_override" ]; then
        [ -f "$blob_override" ] || { echo "[adder_cc] ERROR: HAMNIX initramfs blob $blob_override missing" >&2; rm -rf "$tmp"; return 1; }
        o="$tmp/extra_blob.o"
        "$as_cmd" --64 -o "$o" "$blob_override" \
            || { echo "[adder_cc] ERROR: as initramfs blob failed" >&2; rm -rf "$tmp"; return 1; }
        extra_objs+=("$o")
    fi
    # 3) Link: header.o first (multiboot magic at top of .head.text), then
    #    head_64.o, then the Adder main.o, then the extras — kernel.lds places
    #    everything. Same flags as the seed.
    "$ld_cmd" -m elf_x86_64 -nostdlib -static \
        -z noexecstack -z max-page-size=4096 \
        -T "$lds" -o "$out_elf" \
        "$tmp/header.o" "$tmp/head_64.o" "$main_o" "${extra_objs[@]}" \
        || { echo "[adder_cc] ERROR: ld kernel link failed" >&2; rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    return 0
}
