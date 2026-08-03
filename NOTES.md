/model opus[1m]
claude --resume e4822f03-edb0-4edc-8b9f-e613be526f38
ENABLE_LOG_SLOW=1 bash scripts/build_installer_img.sh
sudo dd if=/home/david/Hamnix/build/hamnix-installer.img of=/dev/sdb bs=4M status=progress


cd /home/david/Hamnix

# ============================================================================
# THE REAL USER INSTALL PATH (manual — the installer does NOT auto-wipe a disk)
# ============================================================================
# Boot the installer medium -> it comes up to the LIVE DESKTOP (it will NOT
# touch any disk on its own). YOU launch the installer, it prompts for the disk
# and confirms the erase. Then shut down and boot the installed disk.
#
# Two OVMF gotchas the commands below handle:
#   * use a WRITABLE OVMF copy (read-only -bios can drop to the EFI shell), and
#   * put bootindex=0 on the installer media, else OVMF stops auto-selecting it
#     once an NVMe target / NIC is attached and falls to the EFI shell / PXE.

cd /home/david/Hamnix
cp /usr/share/ovmf/OVMF.fd /tmp/ovmf.fd          # writable OVMF (once)

# 1) A blank target disk (reuse an existing one, or make it):
qemu-img create -f qcow2 /tmp/hamnix-disk.qcow2 8G

# 2) BOOT THE INSTALLER with the blank disk attached. Comes up LIVE (no wipe):
qemu-system-x86_64 -enable-kvm -cpu host -m 2G -bios /tmp/ovmf.fd \
  -drive file=build/hamnix-installer.img,format=raw,if=none,id=instmedia \
  -device virtio-blk-pci,drive=instmedia,bootindex=0 \
  -drive file=/tmp/hamnix-disk.qcow2,format=qcow2,if=none,id=nvmetgt \
  -device nvme,drive=nvmetgt,serial=hamnvme01 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -vga std -display gtk -serial stdio
#    In the guest: click "Install Hamnix" on the desktop, OR at a hamsh prompt run
#        install
#    -> it lists disks, WARNS the disk will be erased, you pick it + confirm.
#    When it prints "[install-nvme] install complete", shut the VM down.

# 3) BOOT THE INSTALLED DISK (drop the installer medium; bootindex=0 on the NVMe):
qemu-system-x86_64 -enable-kvm -cpu host -m 2G -bios /tmp/ovmf.fd \
  -drive file=/tmp/hamnix-disk.qcow2,format=qcow2,if=none,id=nvmeroot \
  -device nvme,drive=nvmeroot,serial=hamnvme01,bootindex=0 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -vga std -display gtk -serial stdio

# ---- convenience wrapper (same thing, wires OVMF/bootindex/NVMe/NIC for you) --
#   DISK=/tmp/hamnix-disk.qcow2 bash scripts/run_installer.sh   # boots LIVE; you run `install`
# then boot the installed disk with step 3 above (or scripts/_installed_boot.sh for CI).

# ---- TESTING ONLY: unattended auto-install (no prompt, auto-wipes the target) --
# For CI / the keyboard-less NUC. Builds a SEPARATE medium carrying the
# /etc/installer-autorun marker; a normal install image never auto-wipes.
#   AUTO_INSTALL=1 DISK=/tmp/hamnix-disk.qcow2 bash scripts/run_installer.sh
#   # or build the unattended medium by hand:
#   HAMNIX_INSTALLER_AUTORUN=1 HAMNIX_INSTALLER_IMG_OUT=build/hamnix-installer-autorun.img \
#     bash scripts/build_installer_img.sh

# ---- just look at the live desktop (no target disk at all) ----
#   qemu-system-x86_64 -enable-kvm -cpu host -m 2G -bios /tmp/ovmf.fd \
#     -drive file=build/hamnix-installer.img,format=raw,if=virtio \
#     -vga std -display gtk -serial stdio


# ==== test GUI apps directly on this Linux HOST (no QEMU, milliseconds) ====
# The browser + hamUI apps are dual-target: their engine compiles for the Linux
# host and renders without booting Hamnix. Fast iteration loop.

cd /home/david/Hamnix

# --- native browser: render an HTML page ---
bash scripts/test_hambrowse_host.sh              # full browser gate (builds build/host/hambrowse_host)
build/host/hambrowse_host /path/to/page.html 100 # render ONE page -> layout dump + JS console
#   e.g. echo '<h1 style="color:navy">hi</h1><script>console.log(1+1)</script>' > /tmp/p.html
#        build/host/hambrowse_host /tmp/p.html 100

# --- JS engine: run a .js file ---
bash scripts/test_jsengine_host.sh
build/host/js_host /path/to/script.js

# --- hamUI scene apps (2048, calculator) -> PNG you can open ---
bash scripts/test_ham2048_host.sh   # writes build/host/2048_before.png / 2048_after.png
bash scripts/test_hamcalc_host.sh   # writes build/host/calc_*.png
xdg-open build/host/2048_after.png
