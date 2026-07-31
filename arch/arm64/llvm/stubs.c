/*
 * arch/arm64/llvm/stubs.c — AArch64 boot-layer stubs for the LLVM whole-kernel
 * link lane (scripts/build_kernel_llvm_arm64.sh, docs/arm64_llvm_scoping.md A3).
 *
 * The whole-kernel `.ll` (init/main.ad closure, --target=aarch64-bare-metal)
 * leaves 105 symbols undefined that on x86 are supplied by arch/x86 .S or the
 * native hybrid main.o: x86-specific CR/MSR/EFI/IDT/TSS/CEA/AP/FPU machinery and
 * x86-only entry points. (It used to also cover the LLVM bails; as of
 * 2026-07-30 the whole-kernel aarch64 emit has ZERO bails — 11383/11383 — so
 * every stub left here is a genuine x86 arch mechanism, and build step 3c
 * localizes any of these the kernel closure now really defines.) NONE of these are reached by
 * the A3 boot proof (which enters head.S and calls only the pure emitted Adder
 * leaf kernel_printk_printk__fmt_is_flag); they exist solely to make the image
 * LINK. Each is a return-0 / nop stub. Real aarch64 mechanisms (PSCI reset/
 * suspend, GICv3, MIDR_EL1 cpuid, per-CPU df stacks, EL0 syscall entry) are the
 * subsequent A4+ phases enumerated in the scoping doc.
 *
 * Ignoring extra args is ABI-safe on AAPCS64: the caller places args in x0..x7,
 * a no-proto/void callee simply never reads them.
 */
typedef unsigned long u64;

u64 ap_cpu_id_slot_addr(void) { return 0; }
u64 ap_cr3_value_addr(void) { return 0; }
u64 ap_landing_addr_addr(void) { return 0; }
u64 ap_main_64(void) { return 0; }
u64 ap_stack_top_addr(void) { return 0; }
u64 ap_trampoline_load_addr(void) { return 0; }
u64 ap_trampoline_size(void) { return 0; }
u64 cea_df_stack_addr(void) { return 0; }
u64 cea_entry_text_end(void) { return 0; }
u64 cea_entry_text_start(void) { return 0; }
u64 cea_gdt_addr(void) { return 0; }
u64 cea_idt_addr(void) { return 0; }
u64 cea_tss_addr(void) { return 0; }
u64 cea_verw_addr(void) { return 0; }
u64 _clac(void) { return 0; }
u64 cpuid_get(void) { return 0; }
u64 diskimg_base(void) { return 0; }
u64 diskimg_size(void) { return 0; }
u64 do_execve_finish(void) { return 0; }
u64 do_syscall(void) { return 0; }
u64 efi_ms_call4(void) { return 0; }
u64 efi_ms_call5(void) { return 0; }
u64 enter_first_task(void) { return 0; }
u64 enter_first_task_sysret(void) { return 0; }
u64 fb_font_glyph_addr(void) { return 0; }
u64 fninit_helper(void) { return 0; }
u64 fpu_fxrstor(void) { return 0; }
u64 fpu_fxsave(void) { return 0; }
u64 fpu_torture_store(void) { return 0; }
u64 fpu_torture_verify(void) { return 0; }
u64 fpu_xrstor(void) { return 0; }
u64 fpu_xsave(void) { return 0; }
u64 get_boot_via_efi(void) { return 0; }
u64 get_bsp_cr3(void) { return 0; }
u64 get_efi_fb_base(void) { return 0; }
u64 get_efi_fb_bpp(void) { return 0; }
u64 get_efi_fb_height(void) { return 0; }
u64 get_efi_fb_pitch_bytes(void) { return 0; }
u64 get_efi_fb_pixel_format(void) { return 0; }
u64 get_efi_fb_present(void) { return 0; }
u64 get_efi_fb_size(void) { return 0; }
u64 get_efi_fb_width(void) { return 0; }
u64 get_efi_mmap_buf_phys(void) { return 0; }
u64 get_efi_mmap_desc_size(void) { return 0; }
u64 get_efi_mmap_desc_version(void) { return 0; }
u64 get_efi_mmap_present(void) { return 0; }
u64 get_efi_mmap_size_bytes(void) { return 0; }
u64 get_efi_rt_config_table(void) { return 0; }
u64 get_efi_rt_num_config(void) { return 0; }
u64 get_efi_rt_present(void) { return 0; }
u64 get_efi_rt_runtime_services(void) { return 0; }
u64 get_efi_rt_system_table(void) { return 0; }
u64 get_irq_stub(void) { return 0; }
u64 get_mb_info(void) { return 0; }
u64 get_mb_magic(void) { return 0; }
u64 get_percpu_df_stack_top(void) { return 0; }
u64 get_per_cpu_load(void) { return 0; }
u64 get_per_cpu_size(void) { return 0; }
u64 get_trap_diag_ist_stack_top(void) { return 0; }
u64 get_trap_diag_stub(void) { return 0; }
u64 get_trap_stub(void) { return 0; }
u64 idt_load(void) { return 0; }
u64 init_main__try_parse_hamnix_roots(void) { return 0; }
u64 initramfs_cpio_base(void) { return 0; }
u64 initramfs_cpio_size(void) { return 0; }
u64 irq_stub_240(void) { return 0; }
u64 irq_stub_242(void) { return 0; }
u64 irq_stub_243(void) { return 0; }
u64 kernel_image_end(void) { return 0; }
u64 kernel_text_end(void) { return 0; }
u64 kernel_text_start(void) { return 0; }
u64 kthread_bootstrap(void) { return 0; }
u64 linux_abi_api_snd_pcm__snd_pcm_new(void) { return 0; }
u64 linux_current_task_offset(void) { return 0; }
u64 load_cr3(void) { return 0; }
u64 pf_race_probe_end(void) { return 0; }
u64 pf_race_probe_entry(void) { return 0; }
u64 read_cr2(void) { return 0; }
u64 read_cr3(void) { return 0; }
u64 read_cr4(void) { return 0; }
u64 read_msr(void) { return 0; }
u64 set_boot_via_efi_asm(void) { return 0; }
u64 set_efer_nxe(void) { return 0; }
u64 set_efer_sce(void) { return 0; }
u64 sig_trampoline(void) { return 0; }
u64 smap_probe_fault_rip(void) { return 0; }
u64 smap_probe_fixup(void) { return 0; }
u64 smap_probe_load(void) { return 0; }
u64 smp_user_probe_end(void) { return 0; }
u64 smp_user_probe_entry(void) { return 0; }
u64 sqfsimg_base(void) { return 0; }
u64 sqfsimg_size(void) { return 0; }
u64 _stac(void) { return 0; }
u64 __switch_to_asm(void) { return 0; }
u64 syscall_entry(void) { return 0; }
u64 tests_core_smoke__list_walk_and_sum(void) { return 0; }
u64 tss64_percpu_init(void) { return 0; }
u64 tss_set_ist1(void) { return 0; }
u64 tss_set_rsp0(void) { return 0; }
/* x86 ring-3 test payload from arch/x86/kernel/syscall_64.S — the SAME class as
 * syscall_entry / smp_user_probe_entry / pf_race_probe_entry above. It was
 * absent from this snapshot only because `start_kernel`, its sole referent, was
 * itself a stub until the NM_MAX raise let it emit: start_kernel takes its
 * ADDRESS as the baked init fallback when no /init ELF is found in the cpio.
 * On aarch64 there is no ring-3 x86 payload, and the fallback is deliberately an
 * address that faults rather than one that runs. */
u64 user_demo_entry(void) { return 0; }
u64 vdso_image_base(void) { return 0; }
u64 vdso_image_size(void) { return 0; }
u64 write_cr4(void) { return 0; }
u64 write_msr(void) { return 0; }
u64 wrmsr_gsbase(void) { return 0; }
u64 xsetbv_xcr0(void) { return 0; }
