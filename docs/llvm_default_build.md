# LLVM is the default build path (kernel + apps + installer)

_User directive (2026-07-24): make LLVM the MAIN/DEFAULT build path for HamnixOS,
with the native SSA backend SECONDARY. This doc records the flip and the flags._

The LLVM-compiled kernel boots to the fully-interactive desktop at -O0 (and -O2),
apps already default to LLVM, and the shipped `build/hamnix-installer.img` now
carries the LLVM kernel by default. Native remains reachable behind a flag and
stays load-bearing for bootstrap + the correctness oracle (see the HARD INVARIANT
section — native can NOT be dropped).

## What is the default now

| Artifact | Default backend | Built by | Native fallback |
|----------|-----------------|----------|-----------------|
| **User apps** (`build/user/*.elf`) | **LLVM** (`clang` ELF64) | `scripts/build_user.sh` (`ADDER_LLVM_DEFAULT=1`), per-app auto-fallback | `ADDER_LLVM_DEFAULT=0` |
| **Installed kernel** (NVMe ESP) | **LLVM** native-hybrid | `scripts/build_installer_img.sh` Stage 3 → `_build_ship_kernel` | `HAMNIX_KERNEL_BACKEND=native` |
| **Installer kernel** (embeds `/rootfs.sqfs`) | **LLVM** native-hybrid | `scripts/build_installer_img.sh` Stage 6 → `_build_ship_kernel` | `HAMNIX_KERNEL_BACKEND=native` |
| **`build/hamnix-installer.img`** | **LLVM kernel** image | `scripts/build_installer_img.sh` (no flags) | `HAMNIX_KERNEL_BACKEND=native` |

`scripts/build_installer_img.sh` with **no special flags** produces an
LLVM-kernel `build/hamnix-installer.img`. The separate opt-in lane scripts
(`build_kernel_llvm.sh`, `build_installer_img_llvm.sh`) are collapsed into this
main path: `build_installer_img.sh` now *calls* `build_kernel_llvm.sh` internally
for both shipped kernels. `build_installer_img_llvm.sh` (the OVMF A/B packager)
is retained only for the same-harness native-vs-LLVM comparison in
`docs/de_visual_gate_llvm.md`; it is no longer needed to obtain an LLVM image.

## The flag

```sh
# DEFAULT — LLVM kernel image (needs clang-19 in PATH):
bash scripts/build_installer_img.sh

# FALLBACK — native SSA kernel image (no clang needed):
HAMNIX_KERNEL_BACKEND=native bash scripts/build_installer_img.sh
```

`HAMNIX_KERNEL_BACKEND` is read in `build_installer_img.sh` and routed by the
`_build_ship_kernel <out-elf>` helper:

- `llvm` (default) → `HAMNIX_INITRAMFS_BLOB=<blob> scripts/build_kernel_llvm.sh <out>`
- `native` → `adder_cc_compile compile --target=x86_64-bare-metal init/main.ad -o <out>`
  (i.e. `adder_cc_link_kernel` in `scripts/_adder_cc.sh`).

Both backends consume the SAME initramfs blob (`$OUTDIR/initramfs_blob.S`, empty
cpio for the installed kernel, `/rootfs.sqfs` for the installer kernel) and link
the SAME hand-written boot `.S` under `arch/x86/kernel/kernel.lds`, so either ELF
boots the identical efi_stub → higher-half firmware path.

## The LLVM build IS a native-hybrid — keep this mechanism

The "LLVM kernel" is precisely the native-hybrid image `build_kernel_llvm.sh`
produces: the LLVM object (`kernel_main_llvm.o`, ~11k emitted functions) is linked
FIRST, and a small set of functions the LLVM backend still bails
(`start_kernel`, `do_syscall`, `linux_u_syscall_dispatch_inner`,
`try_parse_hamnix_roots`, `snd_pcm_new`, …) plus the layout-sensitive
`memblock_alloc` route (`KLLVM_DEFAULT_FORCE_NATIVE=memblock_alloc`) fall through
to a native-compiled `native_main.o` via `ld --allow-multiple-definition`. This
mechanism is load-bearing and stays; closing the remaining bails is a separate
follow-up (out of scope here). See `docs/kernel_llvm_phase5b.md`.

Concretely the LLVM installed kernel is ~20 MiB (LLVM object + native fallback
object), vs ~7.7 MiB native — well within the 64 MiB NVMe ESP; the LLVM installer
kernel (~108 MiB, embeds the squashfs) sits on an auto-sized media ESP.

## HARD INVARIANT — native can NOT be dropped

Flipping the *default ship backend* to LLVM does NOT remove the native backend.
Native stays mandatory for:

1. **Bootstrap.** The Python seed compiles `host_ac` via the native backend
   (`adder_cc_bootstrap` in `scripts/_adder_cc.sh`). The LLVM backend lives INSIDE
   that same `host_ac` (`host_ac --backend=llvm`), so there is no LLVM without the
   native-built compiler first. The seed compiles the compiler.
2. **The kobjdiff oracle.** `scripts/test_native_vs_seed_kobjdiff.sh` (native ==
   seed byte-identity across ~11k kernel functions) remains the per-merge
   correctness check. It never runs the LLVM lane and is unaffected by this flip.
3. **The fallback flag.** `HAMNIX_KERNEL_BACKEND=native` reproduces the exact
   historical native image (byte-identical to the seed) for A/B debugging of a
   suspected LLVM-codegen bug and for clang-less environments.

Not touched by this change: the native kernel build path
(`adder_cc_link_kernel`), the kobjdiff gate, and `_adder_cc.sh`.

## CI (orchestrator follow-up)

`.github/workflows/ci.yml` builds `build/hamnix-installer.img` (now the LLVM
backend by default) and boots it under OVMF. Because the LLVM backend needs
`clang-19`, the CI "Install apt dependencies" step should add `clang-19` to its
`apt-get install` list (one line). This doc-only change does not touch `.github`
(agents do not edit CI workflows — the orchestrator owns that file); it is called
out here so the orchestrator can apply it when landing this default flip. A
runner without clang can instead set `HAMNIX_KERNEL_BACKEND=native` on the
installer-image build step to build the native image.

Note the pre-existing `scripts/test_installer_boot_heartbeat.sh` gate greps a
`FATAL_RE` that includes the substring `#DF`, which false-matches the benign
boot line "IST-backed #DF handler installed" and fast-fails before userspace.
That is a gate-regex confound (independent of the kernel backend); a direct OVMF
boot of the LLVM image reaches `M16.35 shell ready` → `entering runlevel 5` →
`[scene_de] kernel scene compositor owns /dev/fb (rl5 flip)` → `clean first-boot
desktop` with no real fatal trap.
