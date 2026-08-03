# Booting Hamnix

Hamnix is **UEFI-only**. There is no BIOS/GRUB/El-Torito/hybrid-MBR path
anymore; legacy boot was dropped.

> **RETIRED: the baked `build/hamnix.img` + `scripts/build_img.sh`.** A
> real system is never shipped as a pre-baked ext4 disk image — that is
> what the **installer** produces on a real disk. The single install
> artifact is now `build/hamnix-installer.img`; the installed system is
> the ext4-on-NVMe result of running it. For VM testing,
> `scripts/build_installed_nvme.sh` runs the real installer once into the
> golden disk `build/hamnix-installed.qcow2`, and feature tests boot a
> fresh copy via `scripts/_installed_boot.sh`. Sections below that still
> describe `build/hamnix.img` / `build_img.sh` are **historical** and
> preserved as the record of the earlier baked-image model.

This document covers the ways to boot Hamnix today:

1. **In-RAM installer image** (`build/hamnix-installer.img`) — the
   single install artifact, for both **real hardware** and VM testing
   (built by `scripts/build_installer_img.sh`). An ESP-only GPT image:
   the firmware loads the installer kernel + an embedded squashfs of the
   root filesystem entirely into RAM, so Hamnix never reads the boot
   medium. The in-RAM installer then writes a persistent ext4 root + ESP
   to the target's internal NVMe disk and reboots. This sidesteps the
   unfinished native USB driver. See §3.
2. **Installed ext4-on-NVMe system** — the disk the installer above lays
   down (GPT + ESP + ext4 root). The golden VM copy
   `build/hamnix-installed.qcow2` is produced by
   `scripts/build_installed_nvme.sh`; tests boot a fresh copy through
   `scripts/_installed_boot.sh`. (The retired `build/hamnix.img` was a
   pre-baked stand-in for exactly this disk.)
3. **Developer dev loop** via `scripts/run_x86_bare.sh` — boots the
   kernel ELF directly under QEMU `-kernel` (through a small GRUB-ISO
   PATH shim). This developer/test path STILL boots from an embedded
   cpio root, so the in-kernel cpio machinery is retained for it; the
   shipped `hamnix.img` does not use cpio.

The Hamnix kernel is a true **`elf64-x86-64`** ELF, linked into the
**higher half** at `0xffffffff80000000` (see `arch/x86/kernel/kernel.lds`).
On the disk-image path it is loaded by a native PE/COFF EFI stub off the
ESP; on the developer `-kernel` path it is loaded by GRUB's multiboot1
loader via the shim. Both honour the 64-bit `p_paddr` program-header
fields the kernel's VMA/LMA split needs.

## 0. Try it: build an image, boot it, install it, boot the result

The whole path with plain `qemu-system-x86_64` commands — no wrapper
scripts, so you can see exactly what is being asked of the firmware.

**Two OVMF gotchas are baked into the commands below.** Both cost an
evening if you hit them cold:

1. **Use a *writable* copy of OVMF.** A read-only `-bios` can drop you at
   the EFI shell instead of booting, because the firmware cannot persist
   its boot variables.
2. **Put `bootindex=0` on the medium you want booted.** Once an NVMe
   target or a NIC is attached, OVMF stops auto-selecting the installer
   and falls through to the EFI shell or PXE.

```sh
cd /path/to/Hamnix
cp /usr/share/ovmf/OVMF.fd /tmp/ovmf.fd        # writable OVMF — do this once
```

### 1. Build the installer image

```sh
bash scripts/build_installer_img.sh            # -> build/hamnix-installer.img
```

### 2. Make a blank target disk

```sh
qemu-img create -f qcow2 /tmp/hamnix-disk.qcow2 8G
```

### 3. Boot the installer, with the blank disk attached

This comes up to the **live desktop**. It does **not** touch any disk on
its own — you launch the installer yourself, and it prompts for the target
and confirms the erase before writing anything.

```sh
qemu-system-x86_64 -enable-kvm -cpu host -m 2G -bios /tmp/ovmf.fd \
  -drive file=build/hamnix-installer.img,format=raw,if=none,id=instmedia \
  -device virtio-blk-pci,drive=instmedia,bootindex=0 \
  -drive file=/tmp/hamnix-disk.qcow2,format=qcow2,if=none,id=nvmetgt \
  -device nvme,drive=nvmetgt,serial=hamnvme01 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -vga std -display gtk -serial stdio
```

In the guest, either click **Install Hamnix** on the desktop, or run
`install` at a hamsh prompt. It lists the disks, warns that the target
will be erased, and waits for you to pick one and confirm. When it prints
`[install-nvme] install complete`, shut the VM down.

### 4. Boot the installed system

Drop the installer medium entirely and move `bootindex=0` to the NVMe:

```sh
qemu-system-x86_64 -enable-kvm -cpu host -m 2G -bios /tmp/ovmf.fd \
  -drive file=/tmp/hamnix-disk.qcow2,format=qcow2,if=none,id=nvmeroot \
  -device nvme,drive=nvmeroot,serial=hamnvme01,bootindex=0 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -vga std -display gtk -serial stdio
```

That is a real installed system: GPT + ESP + ext4 root on the NVMe, which
grows to fill the disk on first boot.

### Just look at the live desktop

No target disk, nothing to install:

```sh
qemu-system-x86_64 -enable-kvm -cpu host -m 2G -bios /tmp/ovmf.fd \
  -drive file=build/hamnix-installer.img,format=raw,if=virtio \
  -vga std -display gtk -serial stdio
```

### Onto a USB stick, for real hardware

```sh
sudo dd if=build/hamnix-installer.img of=/dev/sdX bs=4M status=progress
```

Check `/dev/sdX` twice — `dd` will not ask. And see the warning in
[`REAL_HARDWARE.md`](REAL_HARDWARE.md): bare-metal boot worked historically
but is **unverified at this revision**.

### Convenience wrappers, if you would rather not type the above

```sh
DISK=/tmp/hamnix-disk.qcow2 bash scripts/run_installer.sh   # boots live; you run `install`
```

**Testing only — unattended auto-install.** This builds a *separate*
medium carrying an `/etc/installer-autorun` marker and **auto-wipes the
target with no prompt**. It exists for CI and for the keyboard-less NUC. A
normal installer image never does this.

```sh
AUTO_INSTALL=1 DISK=/tmp/hamnix-disk.qcow2 bash scripts/run_installer.sh
```

---

## 1. Developer dev loop

For the inner dev loop while iterating on `init/main.ad` or kernel modules:

```sh
bash scripts/run_x86_bare.sh
```

This rebuilds userland, modules, the initramfs, and the kernel ELF, then
boots it in QEMU.

> **QEMU's `-kernel` cannot load the kernel directly.** QEMU's built-in
> `-kernel` multiboot1 loader rejects 64-bit ELFs outright ("Cannot load
> x86-64 image, give a 32bit one") — it only accepts ELFCLASS32. So the
> test harness boots via a BIOS-GRUB-ISO PATH shim: `scripts/_kernel_iso.sh`
> installs an executable `qemu-system-x86_64` shim into `build/binshim/`
> and prepends it to `PATH`. The shim detects an ELFCLASS64 `-kernel <file>`
> argument, wraps the kernel in a minimal BIOS GRUB ISO, and execs the real
> QEMU with `-cdrom <iso>` substituted in. GRUB's multiboot1 loader (unlike
> QEMU's) happily loads ELFCLASS64. No ISO mastering is visible to the
> caller — much faster turnaround than building the full hybrid ISO.

## 2. The installed-system disk image (`build/hamnix.img`)

### Build

```sh
bash scripts/build_img.sh
```

This produces `build/hamnix.img`, a raw GPT disk image (~546 MiB) laid
out exactly like an installed system:

```
GPT disk
├── Partition 1: ESP (FAT, ~32 MiB)
│     \EFI\BOOT\BOOTX64.EFI   (the native PE/COFF stub, efi_stub.S)
│     \hamnix-kernel.elf      (the elf64 higher-half kernel)
└── Partition 2: ext4 (~512 MiB)
      .hamnix-roots           (sentinel: #sysroot -> sysroot/, #distro -> distro/)
      sysroot/                (native Adder tools + libs + /init + /etc)
      distro/                 (minimal Debian: apt/dpkg/busybox closure)
```

`sysroot/`, `distro/`, and future per-user home roots are SUBTREES of
the **single** ext4 filesystem — they share its free space; they are
NOT separate partitions. On install to a real disk the ext4 grows to
fill the disk and every root draws from one common pool. (See
[`rootfs_partition.md`](rootfs_partition.md).)

`scripts/build_iso.sh` is now a ~44-line deprecation shim that just
delegates to `build_img.sh`; `build/hamnix.iso` is no longer the
primary artifact.

### Boot flow

UEFI-only, end-to-end:

1. UEFI firmware reads the GPT, finds the ESP (partition 1, FAT), and
   launches `\EFI\BOOT\BOOTX64.EFI` — the native Hamnix PE/COFF stub
   (`arch/x86/boot/efi_stub.S`). No GRUB-EFI middleman.
2. The stub (PATH A — see the historical note below) does the FULL
   handoff from firmware to `_x86_start_after_loader`:
    1. Stash EFI ImageHandle + SystemTable; print
       `[hamnix] EFI entry reached` over COM1.
    2. Locate the Simple File System Protocol on the load device
       (`HandleProtocol(ImageHandle, LoadedImageGuid) ->
       HandleProtocol(DeviceHandle, SfspGuid) -> OpenVolume`).
    3. Open `\hamnix-kernel.elf` on the ESP, AllocatePool and read the
       whole ELF in.
    4. Parse the elf64-x86-64 header + program headers; for each
       PT_LOAD, memcpy `p_filesz` bytes from the file buffer to
       `p_paddr`, then zero the trailing `p_memsz - p_filesz` bytes.
    5. Read the Hamnix EFI handoff table planted after the multiboot
       header (`arch/x86/boot/header.S`) — extracts
       `_x86_start_after_loader`, the `boot_via_efi` flag, and `&gdt64`.
    6. Patch `boot_via_efi = 1` so `e820_init()` takes the EFI branch.
    7. `GetMemoryMap` + `ExitBootServices` (retry on stale MapKey);
       print `[hamnix] post-EFI handoff complete`.
    8. Build identity-mapped page tables, `lgdt` the kernel's own
       `gdt64`, set CR3, far-jump, `jmp *_x86_start_after_loader`.
3. The kernel probes block devices (virtio-blk / AHCI / USB), scans
   the GPT, and finds the ext4 root partition by its 0xEF53 superblock
   magic. `mount_rootfs_partition()` reads `.hamnix-roots` and posts a
   named file server for each subtree (`#sysroot`, `#distro`).
4. The kernel binds `#sysroot` at `/`, then ELF-loads `/init` directly
   off ext4 (a fd-less ext4 read path, `_ns_ext4_slurp_by_id` in
   `fs/vfs.ad`, because `/init` loads before any user fd table exists).
5. `/init` execs `/bin/hamsh /etc/rc.boot`; both resolve off `sysroot/`
   through the inherited bind. hamsh-as-PID-1 runs the rc and drops to
   an interactive shell.

There is **no embedded cpio root** in the shipped image: the kernel
links against the cpio symbol (`initramfs_cpio_base`) but `build_img.sh`
fills it with a TRAILER-ONLY (empty) cpio (`HAMNIX_CPIO_EMPTY=1` in
`scripts/build_initramfs.py`). The live system boots entirely off the
ext4 root. (The cpio machinery is retained only for the developer
`-kernel` path of §1.)

Verified end-to-end by `scripts/test_img_uefi_boot.sh` — see §"Test
under QEMU" below.

### Why two separate binaries (stub + kernel) instead of one hybrid file

The stub and the kernel are two separate files on the ESP
(`\EFI\BOOT\BOOTX64.EFI` + `\hamnix-kernel.elf`), and the stub loads the
kernel at runtime. The alternative — merging them into one hybrid binary
the way Linux's bzImage is both a multiboot kernel and a PE/COFF EFI
application — was investigated and abandoned. bzImage works because it
is a **flat blob, not an ELF**: Linux's vmlinux (the ELF) is wrapped
inside bzImage, and vmlinux itself is not what UEFI loads.

The Hamnix kernel binary is an ELF (compiled with `--target=x86_64-bare-metal`
through the Adder compiler + `ld -m elf_x86_64`). An ELF starts with
`\x7fELF` at file offset 0; a PE/COFF starts with `MZ`. The same first
bytes can't be both magic numbers, so Hamnix keeps two outputs:

- `build/hamnix-kernel.elf` — true `elf64-x86-64` higher-half kernel
  ELF (linked at `0xffffffff80000000`), loaded by the stub at runtime
  (and, on the developer `-kernel` path, by GRUB's multiboot1 loader
  via the shim in §1).
- `build/hamnix-bootx64.efi` — true PE32+ EFI_APPLICATION, x86-64,
  subsystem 10 (the stub).

Both are copied onto the ESP by `build_img.sh`; UEFI launches the stub,
which SFSP-loads the kernel ELF off the same ESP.

#### Historical: why the "merge them into one hybrid" plan was abandoned

> The following records the M16.124 diagnosis. It is HISTORICAL design
> rationale, not current behaviour — the two-file (stub + kernel) split
> above is what ships.


The M16.111 + M16.120 wave was structured around an explicit followup:
merge `efi_stub.S` and the kernel ELF into a single hybrid binary so
the stub could reach kernel symbols, then `jmp _x86_start_after_loader`
after `ExitBootServices`. The post-M16.124 honest diagnosis is that
this is blocked by FOUR independent constraints — recorded in
`arch/x86/boot/efi_stub.S`'s header comment as blockers B1..B4 and
summarised here:

- **B1: File-magic conflict at offset 0.** `\x7fELF` and `MZ` can't
  coexist as the first two bytes of the same file. Linux's bzImage
  works around this by being a flat binary; vmlinux (the ELF) is
  NOT what Linux's UEFI loader executes.
- **B2: LMA/VMA split in `.ap_trampoline`.** The AP trampoline lives
  at VMA=0x8000 (SIPI delivery target) with LMA next to `.data`
  (~0x448100). PE/COFF collapses VMA/LMA to a single value per
  section, so converting through `objcopy --target=efi-app-x86_64`
  either drops the section or places it in firmware-reserved low
  memory.
- **B3: Image-base relocation.** The kernel is non-PIC (page tables,
  GDT pointer, percpu offsets all use absolute addresses). UEFI
  always relocates a PE image whose `ImageBase` is page 0; the
  kernel has no `.reloc` table or runtime relocator, so any
  relocation silently corrupts everything.
- **B4: GDT/CR3 handoff from firmware.** Doing this in the stub is
  easy in isolation, but only useful if the kernel code is in
  memory — which it isn't on the UEFI path because of B1.

#### M16.125 shipped: PATH A (UEFI-side ELF loader)

PATH A from the M16.124 diagnosis is now the production UEFI path:

- The .efi stub uses UEFI's Simple File System Protocol BEFORE
  `ExitBootServices` to open `\hamnix-kernel.elf` off the ESP,
  parse program headers, copy PT_LOADs to their LMAs (matching
  multiboot1's loader behaviour on the BIOS side), then
  `ExitBootServices` and `jmp _x86_start_after_loader`.
- The kernel ELF format stays untouched — every existing
  `qemu ... -kernel hamnix-kernel.elf` test keeps working (via the
  `scripts/_kernel_iso.sh` GRUB-ISO PATH shim — see §1).

**Implementation notes worth recording (the B5 we discovered):**

- **FAT ESP geometry:** `scripts/build_img.sh` formats the GPT
  ESP (partition 1) with explicit `mformat -h 64 -s 32 -c 32`
  geometry (FAT12) — comfortably enough for our `~3.8 MB` kernel +
  `~8 KB` stub plus headroom in the 32 MiB ESP. *(Historical: the
  retired optical-media ISO path required FAT12 specifically because
  OVMF on optical media only accepted a FAT12 El Torito UEFI
  alt-platform image — a FAT16/FAT32 ESP at the same LBA range failed
  BdsDxe loading with "Not Found". That constraint no longer applies
  to the GPT disk image, which is read as an `if=virtio` block
  device, not optical media.)*
- **PE32+ image-base relocation:** the stub has no `.reloc` table,
  so UEFI relocates the image but DOES NOT fix up address-typed
  data in `.rdata`. The GDT-descriptor base AND the far-jump
  `m16:64` offset are therefore RUNTIME-PATCHED in `.data` via
  `leaq <label>(%rip), %rax; mov %rax, <slot>(%rip)` before the
  `lgdt` / `ljmp` step. Without these patches the stub triple-
  faults immediately after `mov %rax, %cr3` because the static
  link-time offsets land in unmapped pages on the firmware-chosen
  load base.
- **AT&T `ljmp` quirk:** `ljmp *mem` in 64-bit mode defaults to a
  16:32 far jump (offset is 4 bytes, not 8). To get a 16:64 far
  jump we use the `rex.w ljmp *mem` form, encoding REX.W as a
  prefix byte. GAS rejects the more obvious `ljmpq` spelling.
- **Disk-image packaging (current):** `scripts/build_img.sh` builds a
  raw GPT disk image (`build/hamnix.img`) with `parted` — partition 1
  is the FAT ESP (esp flag, carrying the stub + kernel ELF), partition
  2 is the ext4 root. There is no ISO polyglot anymore. *(Historical:
  the retired ISO recipe built a grub-mkrescue-shape polyglot via
  `xorriso -as mkisofs`, where the same byte ranges were
  simultaneously ISO9660 file data, GPT partition contents, and El
  Torito boot images, all referencing one pre-built FAT12 wide
  efi.img.)*

#### Alternative path (not shipped)

- **PATH B: bzImage-style flat-binary output.** Sibling artifact
  alongside the kernel ELF: `build/hamnix.bin`, produced by
  `objcopy -O binary` over a hand-written PE+multiboot+(optionally
  Linux x86 boot header) prelude. The flat binary starts with "MZ",
  carries the multiboot1 magic in the first 8 KiB, and ships as
  ESP `BOOTX64.EFI`. Larger surgery; not needed now that PATH A
  is functional. Recorded here for posterity in case a future
  signed-EFI / Secure-Boot push needs a sb-signable single-file
  image.

### What the build script assembles

`scripts/build_img.sh`:

1. Rebuilds userland + modules, then builds the ext4 rootfs partition
   image (`scripts/build_rootfs_img.py`, staging `sysroot/` + `distro/`
   + `.hamnix-roots`).
2. Builds a TRAILER-ONLY (empty) cpio so the kernel still links against
   the `initramfs_cpio_base` symbol but carries no embedded userland
   (`HAMNIX_CPIO_EMPTY=1`).
3. Compiles the kernel ELF and assembles the native PE/COFF stub from
   `arch/x86/boot/efi_stub.S`.
4. Builds a FAT12 ESP image holding `\EFI\BOOT\BOOTX64.EFI` (the stub)
   + `\hamnix-kernel.elf`. FAT12 with explicit geometry because OVMF on
   Debian rejects FAT16/FAT32 ESPs.
5. Lays out a GPT disk with `parted` (ESP partition 1 with the `esp`
   flag, ext4 partition 2), `dd`s both filesystem images into their
   partition offsets, and verifies the ext4 0xEF53 magic landed at the
   right byte offset.

### Required Debian packages

```sh
sudo apt-get install mtools binutils e2fsprogs parted ovmf
```

`ovmf` is only needed for testing the boot under QEMU.

### Test under QEMU

`scripts/test_img_uefi_boot.sh` is the acceptance gate. It boots
`build/hamnix.img` under OVMF attached as a **disk** (`if=virtio`),
exactly the way a shipped install boots:

```sh
bash scripts/test_img_uefi_boot.sh
```

It asserts, in order:

- `Hamnix kernel booting` — kernel banner; proves the EFI stub
  SFSP-loaded the kernel ELF and jumped into it.
- `handing off to interactive shell` — shell-ready marker.
- Typed commands resolve OFF EXT4: `ls /bin` lists the native toolset
  and there is **zero** `command not found` (the keystone assertion —
  proves the kernel-bound `#sysroot` at `/` is serving `/bin` off the
  ext4 partition).

It skips cleanly (exit 0) when `/dev/kvm` or OVMF firmware is
unavailable.

> **Legacy / BIOS boot is dropped.** There is no GRUB, grub-mkrescue,
> El-Torito, hybrid-MBR, or SeaBIOS path. `scripts/test_bios_boot.sh`
> now SKIPs unconditionally. The older `scripts/test_iso_qemu.sh` /
> `test_uefi_boot.sh` ISO tests target the deprecated ISO shim; the
> disk-image gate above is the path to use.

#### UEFI boot timing (measured — HISTORICAL, ISO path)

> These numbers were measured on the now-deprecated ISO path (which
> still booted from an embedded cpio, hence the `cpio: registered N
> files` marker). The EFI-stub portion (markers 1–4) is unchanged on
> the disk-image path; the disk image asserts on the
> `handing off to interactive shell` marker instead of the cpio one.

Per-marker wall-clock latencies from a clean QEMU-launch start (OVMF
edk2-stable + ~22 MB higher-half ELF kernel, `HAMNIX_CPIO_LEAN=1`,
32 MB FAT12 ESP, host = developer workstation under no other load):

| Marker                                                      | Time   | Delta from prev |
| ----------------------------------------------------------- | ------ | --------------- |
| `[hamnix] EFI entry reached`                                | 1.9 s  | (firmware + PE) |
| `[hamnix] EFI: kernel ELF read OK` (SFSP read of 22 MB)     | 3.3 s  | +1.4 s          |
| `[hamnix] post-EFI handoff complete` (ExitBootServices ret) | 3.5 s  | +0.2 s          |
| `cpio: registered N files from initramfs` (start_kernel)    | 4.7 s  | +1.2 s          |
| `[hamsh] M16.35 shell ready`                                | 36.3 s | +31.6 s         |

The three EFI-stub markers the test asserts on all land inside the
first ~5 seconds. The default for `ISO_BOOT_TIMEOUT` is **20 s**
(dropped 30→20 in `1b3bdc2` after the measurement above) with
roughly 4× host-load headroom against the slowest asserted marker
(`cpio: registered N files`, ~4.7 s); under host-load variance even
a 15 s timeout passes locally. The bulk of "boot to interactive
shell" time (~31 s) is the post-cpio kernel selftest battery +
userland init, not anything the EFI stub does.

The 22 MB SFSP read off FAT12 in OVMF runs at roughly ~16 MB/s; the
stub already issues a single `EFI_FILE_PROTOCOL.Read` over the whole
buffer (no chunking, no per-cluster ping-pong) so there's nothing
obvious left to optimise on our side. FAT12 cluster size is already
at 16 KiB (mformat `-c 32`); larger clusters would not measurably
help a single-file linear read at this scale.

### Write to a USB stick

`build/hamnix.img` is a raw GPT disk image: writing it byte-for-byte to a
block device produces a bootable USB stick.

```sh
sudo dd if=build/hamnix.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

Replace `/dev/sdX` with your actual USB device. **Confirm with `lsblk`
first.** `dd if=... of=/dev/sda` will happily overwrite your system disk.

A USB stick written this way is bootable from **UEFI firmware only**
(which reads the GPT and launches `\EFI\BOOT\BOOTX64.EFI` off the ESP).
There is no legacy/BIOS MBR boot path — enable UEFI in firmware setup.

## 3. Real-hardware boot

The recommended real-hardware artifact is the **in-RAM installer image**,
built by:

```sh
bash scripts/build_installer_img.sh        # -> build/hamnix-installer.img
```

This is an ESP-only GPT image. UEFI firmware loads the installer kernel
plus an embedded squashfs of the root filesystem **entirely into RAM**,
so Hamnix never reads the boot medium after the firmware hands off — the
unfinished native USB driver is never on the path. The in-RAM installer
then partitions the target's internal NVMe disk, writes a persistent
ext4 root + ESP onto it, and reboots off the NVMe alone. Write it to a
USB stick exactly like any disk image:

```sh
sudo dd if=build/hamnix-installer.img of=/dev/sdX bs=4M conv=fsync status=progress
```

The four-step model (firmware loads blob → in-RAM installer shell →
write ext4-on-NVMe → reboot off NVMe) is proven end-to-end under
OVMF+KVM by `scripts/test_installer_nvme_inram.sh`.

For the full install + boot procedure on physical machines (USB stick
write, firmware boot menus per vendor, expected hardware coverage,
known limitations, and how to report issues), see
[`REAL_HARDWARE.md`](REAL_HARDWARE.md).

Tested-on / known-working list (extend as we verify on more machines).
Hamnix is UEFI-only; all current boots are UEFI:

| Vendor / Model        | Mode | Result | Notes                |
| --------------------- | ---- | ------ | -------------------- |
| QEMU (OVMF, edk2)     | UEFI | works  | scripts/test_img_uefi_boot.sh PASS — boots `build/hamnix.img` as a virtio disk; PE/COFF stub SFSP-loads `\hamnix-kernel.elf`, kernel boots off the ext4 root |
| Intel Skull Canyon NUC | UEFI | boots to `hamsh`, USB keyboard works | Primary real-hardware bring-up target as of 2026-05-25 (M16.139 + L-shim USB-HC bridge `f426aee`). |
| Asus i5-4210U (Haswell ULT) | UEFI | **currently crashes during boot** | Booted to `hamsh` earlier in Legacy/BIOS (M16.156, HISTORICAL — that path is now retired); regressed in a subsequent wave. Preserved for regression observation, not a current bring-up target. See [`REAL_HARDWARE.md`](REAL_HARDWARE.md). |

When testing on real hardware:

1. Plug in a serial cable. The kernel currently only outputs to the
   16550A UART at COM1 (0x3F8); there's no VGA console output for
   diagnostics past the framebuffer smoke test. The EFI stub also
   writes its marker to COM1, so the same cable works for the UEFI
   bringup check.
2. Boot in UEFI mode. Hamnix is UEFI-only — there is no BIOS/CSM path.
3. Disable Secure Boot — the EFI stub is not signed.

## 4. Known limitations / next steps

- **UEFI direct boot reaches `start_kernel()` and beyond** — the
  PE/COFF stub SFSP-loads `\hamnix-kernel.elf` from the ESP, parses
  its program headers, copies PT_LOAD segments to their LMAs, installs
  identity-mapped page tables + the kernel's `gdt64`, and
  `jmp _x86_start_after_loader`. Verified end-to-end by
  `scripts/test_img_uefi_boot.sh`, which boots `build/hamnix.img` as a
  virtio disk all the way to the interactive shell with commands
  resolving off the ext4 root.
- **EFI memory-map memblock window walker landed.** The stub saves
  the UEFI memory map in `efi_mmap_buf` (16 KiB) with descsize at
  `efi_mmap_descsize`, and `e820_init()` now walks it as the primary
  path on UEFI boots, picking the largest `EfiConventionalMemory`
  (Type=7) region above the kernel image end and feeding it to
  memblock (see `arch/x86/kernel/e820.ad::_efi_mmap_walk`). The
  hardcoded 2..240 MiB window remains as a last-resort fallback for
  older stubs / pathological firmware. The >4 GiB identity-map gap
  is also closed — `arch/x86/mm/pgtable.ad` re-walks the memory map
  and extends the identity map per 1 GiB RAM page.
- **Real EFI Runtime Services aren't exposed yet.** The stub
  stashes the SystemTable pointer in `efi_system_table` but kernel
  code doesn't yet call back into RuntimeServices (e.g.
  `GetVariable` / `SetVariable` for persistent boot config, or
  `GetTime` as a real-hardware alternative to the legacy CMOS RTC
  driver in `arch/x86/kernel/time.ad`).
- **Graphical console:** the EFI GOP framebuffer text console has
  landed — UEFI boot renders 8×16 bitmap glyphs into the linear
  framebuffer (the framebuffer info is parsed from the EFI system
  table at handoff). The console scrolls top-to-bottom via a cached
  shadow grid so it doesn't read back the uncached GOP framebuffer.
- **No PCI passthrough boot**: the kernel still hard-codes a few
  legacy assumptions (PCI bus 0, no PCIe ECAM). Real-hardware systems
  will need MCFG-based config space access — already implemented in
  the kernel but only smoke-tested under QEMU.
- **Installed-system image shipped**: `build/hamnix.img` is already
  shaped like an installed system (ESP + ext4 root with `#sysroot` +
  `#distro` subtrees of one filesystem), so the common case is "write
  the image to a disk and boot." `etc/install.hamsh` remains an
  `hpm install`-driven Debian-installer-shape script for laying a
  fresh system down onto a target disk (GPT + partitions, mkfs ESP +
  ext4 rootfs, `hpm install hamnix-base` + `linux-debian-12`, hostowner
  credentials, ext4 grow-to-fit on first boot).
- **No GRUB / no BIOS**: the native PE/COFF stub is the first Hamnix
  code that runs under UEFI; there is no GRUB anywhere in the boot
  path, and no legacy BIOS path at all. The image carries only Hamnix
  binaries.
