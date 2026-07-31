#!/usr/bin/env python3
# scripts/concat_compiler_source.py
#
# Produce ONE single-module Adder source that is the whole self-hosted
# compiler — lexer.ad + parser.ad + codegen.ad — concatenated in dependency
# order, with their intra-compiler `from compiler.X import (...)` blocks
# stripped.
#
# WHY: the self-hosted lexer/parser is SINGLE-MODULE. It does NOT execute
# `import`; the host (Python) build resolves `from compiler.X import (...)`
# at compile time, but the Adder-in-Adder lexer/parser would choke on (or
# at best must ignore) those statements. To compile the WHOLE compiler with
# itself (the self-host fixpoint, task #154) we first need the three modules
# fused into one translation unit with the cross-module imports removed —
# every symbol then resolves within the single concatenated namespace.
#
# This is sound because (verified): the three modules share NO duplicate
# top-level symbol, declare NO `extern def`, and the only imports are the
# intra-compiler `from compiler.{lexer,parser} import (...)` blocks. So
# stripping those blocks and concatenating in dependency order (lexer, then
# parser, then codegen) yields a self-consistent single module.
#
# Usage:
#   python3 scripts/concat_compiler_source.py [-o OUT.ad] [--with-driver]
# Default output: build/selfhost/whole_compiler.ad
#
# With --with-driver, the fusion ALSO includes elf_emit.ad (the ELF image
# emitter) and APPENDS adder/compiler/fused_driver_main.ad — a driver
# `main` that reads /src/input.ad, runs the full
# lex -> parse -> codegen -> elf_emit pipeline, and hex-dumps the emitted
# ELF over stdout (via codegen.ad's inline `__syscallN` builtins). This
# turns the library-of-functions into a SELF-CONTAINED, RUNNABLE compiler
# binary — the artifact the stage1==stage2 fixpoint (test_selfhost_fixpoint.sh)
# compiles with itself.
#
# Deterministic: the output is a pure function of the input files.

import os
import re
import sys

PROJ_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMPILER_DIR = os.path.join(PROJ_ROOT, "adder", "compiler")

# Dependency order: lexer defines tokens, parser consumes them, codegen
# consumes the AST. codegen.ad references parser+lexer symbols, parser.ad
# references lexer symbols — so lexer FIRST, codegen LAST.
#
# Phase-4: codegen.ad now references the register allocator (regalloc.ad), which
# references the CFG/liveness/live-range analysis (cfg.ad), which references the
# IR name helpers (ir.ad). All are PURE ANALYSIS that codegen only enters under
# --opt (OFF by default), but their DEFINITIONS must precede codegen.ad in the
# single concatenated host module. Order: lexer, parser, ir, cfg, regalloc,
# codegen (each references only earlier modules).
MODULES = ["lexer.ad", "parser.ad", "ir.ad", "cfg.ad", "regalloc.ad", "codegen.ad"]

# Extra module fused in ONLY for --with-driver: the ELF image emitter the
# driver `main` calls (elf_emit_image). It imports from compiler.codegen,
# whose `from compiler.X import (...)` block is stripped like the others.
DRIVER_EXTRA_MODULES = ["elf_emit.ad"]

# Appended verbatim (NOT import-stripped — it has no compiler imports) for
# --with-driver: the driver `main` that drives the whole pipeline.
DRIVER_MAIN = "fused_driver_main.ad"

# The HOST self-hosting driver: same pipeline, Linux syscall numbers, runs on
# the build host (NOT on-device). Only this driver compiles the WHOLE Hamnix
# TREE (incl. the kernel's 346-module / ~13.9 MB import closure), so only it
# needs whole-TREE-sized compiler buffers. The on-device drivers
# (fused_driver_main.ad, codegen_elf_selftest.ad, adder_cc_driver.ad) compile
# only TINY programs and MUST keep the small on-disk buffers — they boot in a
# 256 MiB QEMU guest, where the whole-tree ~408 MB of zero-init .bss would OOM.
HOST_DRIVER_MAIN = "fused_driver_host_main.ad"

# Whole-TREE buffer overrides, applied ONLY when fusing the HOST driver
# (HOST_DRIVER_MAIN). Each entry is an exact (small -> large) substring
# replacement on a shared compiler module's source. The on-disk literals stay
# at on-device scale; the host build is the only one scaled up (it runs on the
# host with ample RAM). Keep these in lockstep with the kernel-closure scale
# documented in docs/subsystems/adder-compiler.md (cap#3). Each pair MUST match
# the on-disk text exactly or the substitution silently no-ops (asserted below).
#
#   kernel closure: ~13.9 MB merged / ~1.73 M tokens / 10,161 fns / 9,266
#   globals / ~66 K data refs / ~42 K call fixups. All raised arrays are
#   zero-init (.bss): host_ac.elf FILE size is unchanged; only memsz grows.
HOST_BUFFER_OVERRIDES = {
    "lexer.ad": [
        ("MAX_TOKENS: uint32 = 65536", "MAX_TOKENS: uint32 = 4194304"),
        ("STRBUF_SIZE: uint32 = 524288", "STRBUF_SIZE: uint32 = 16777216"),
        ("tok_type: Array[65536, uint32]", "tok_type: Array[4194304, uint32]"),
        ("tok_line: Array[65536, uint32]", "tok_line: Array[4194304, uint32]"),
        ("tok_val_start: Array[65536, uint32]", "tok_val_start: Array[4194304, uint32]"),
        ("tok_val_len: Array[65536, uint32]", "tok_val_len: Array[4194304, uint32]"),
        ("tok_num_val: Array[65536, uint64]", "tok_num_val: Array[4194304, uint64]"),
        # tok_is_float is a PARALLEL token array (emit_tok writes it for EVERY
        # token). It MUST scale with the other tok_* arrays: with MAX_TOKENS
        # raised to 4194304 but this array left at 65536, emit_tok's
        # `tok_is_float[tok_count] = 0` writes OUT OF BOUNDS for any unit with
        # >65536 tokens (all the large user apps + the compiler self-compile
        # units), silently corrupting adjacent BSS and derailing name lookups
        # deep in codegen. Keep this pair lockstep with the tok_* group above.
        ("tok_is_float: Array[65536, uint32]", "tok_is_float: Array[4194304, uint32]"),
        ("strbuf: Array[524288, uint8]", "strbuf: Array[16777216, uint8]"),
    ],
    "parser.ad": [
        ("MAX_NODES: uint32 = 65536", "MAX_NODES: uint32 = 4194304"),
        ("nd_kind: Array[65536, uint32]", "nd_kind: Array[4194304, uint32]"),
        ("nd_aux: Array[65536, uint32]", "nd_aux: Array[4194304, uint32]"),
        ("nd_num: Array[65536, uint64]", "nd_num: Array[4194304, uint64]"),
        ("nd_name_off: Array[65536, uint32]", "nd_name_off: Array[4194304, uint32]"),
        ("nd_name_len: Array[65536, uint32]", "nd_name_len: Array[4194304, uint32]"),
        ("nd_name2_off: Array[65536, uint32]", "nd_name2_off: Array[4194304, uint32]"),
        ("nd_name2_len: Array[65536, uint32]", "nd_name2_len: Array[4194304, uint32]"),
        ("nd_a: Array[65536, uint32]", "nd_a: Array[4194304, uint32]"),
        ("nd_b: Array[65536, uint32]", "nd_b: Array[4194304, uint32]"),
        ("nd_c: Array[65536, uint32]", "nd_c: Array[4194304, uint32]"),
        ("nd_d: Array[65536, uint32]", "nd_d: Array[4194304, uint32]"),
        ("nd_next: Array[65536, uint32]", "nd_next: Array[4194304, uint32]"),
        ("nd_line: Array[65536, uint32]", "nd_line: Array[4194304, uint32]"),
    ],
    "codegen.ad": [
        ("CODE_CAP: uint32 = 2097152", "CODE_CAP: uint32 = 16777216"),
        ("code: Array[2097152, uint8]", "code: Array[16777216, uint8]"),
        # DEMAND-GAP FIX (2026-07-13): DATA_BASE is intentionally NOT scaled to
        # 16 MiB here. CODE_CAP (above) is the compiler's internal code[] BUFFER
        # and must be large enough to hold the multi-MiB kernel host_ac compiles;
        # DATA_BASE is the OUTPUT user image's .data vaddr and only needs to
        # clear the largest user program's code (<1 MiB). Coupling them forced
        # every emitted app to place .data at vaddr 16 MiB, so the ELF32 loader
        # eagerly region_alloc()'d a 16 MiB CONTIGUOUS inter-segment gap per app
        # and OOM-fragmented the desktop at -m256M. Leaving DATA_BASE at its
        # on-disk 2 MiB shrinks that gap to 2 MiB with headroom to spare; a
        # user program whose code overruns 2 MiB fails LOUDLY in elf_emit
        # (guard changed CODE_CAP->DATA_BASE), never silently corrupting.
        ("GDATA_CAP: uint32 = 65536", "GDATA_CAP: uint32 = 4194304"),
        ("gdata: Array[65536, uint8]", "gdata: Array[4194304, uint8]"),
        # Per-function local/param table. 256 is too small for some large
        # kernel dispatch functions; raised to 2048 for the host build.
        ("MAX_LOCALS: uint32 = 256", "MAX_LOCALS: uint32 = 2048"),
        ("loc_name_off: Array[256, uint32]", "loc_name_off: Array[2048, uint32]"),
        ("loc_name_len: Array[256, uint32]", "loc_name_len: Array[2048, uint32]"),
        ("loc_offset: Array[256, int32]", "loc_offset: Array[2048, int32]"),
        ("loc_elem_size: Array[256, uint32]", "loc_elem_size: Array[2048, uint32]"),
        ("loc_ptr_size: Array[256, uint32]", "loc_ptr_size: Array[2048, uint32]"),
        ("loc_is_signed: Array[256, uint32]", "loc_is_signed: Array[2048, uint32]"),
        ("loc_scalar_size: Array[256, uint32]", "loc_scalar_size: Array[2048, uint32]"),
        ("loc_is_float: Array[256, uint32]", "loc_is_float: Array[2048, uint32]"),
        ("loc_struct_idx: Array[256, uint32]", "loc_struct_idx: Array[2048, uint32]"),
        ("loc_struct_is_ptr: Array[256, uint32]", "loc_struct_is_ptr: Array[2048, uint32]"),
        ("loc_type_node: Array[256, uint32]", "loc_type_node: Array[2048, uint32]"),
        ("MAX_FUNCS: uint32 = 1024", "MAX_FUNCS: uint32 = 16384"),
        ("fn_name_off: Array[1024, uint32]", "fn_name_off: Array[16384, uint32]"),
        ("fn_name_len: Array[1024, uint32]", "fn_name_len: Array[16384, uint32]"),
        ("fn_offset: Array[1024, uint32]", "fn_offset: Array[16384, uint32]"),
        ("MAX_FIXUPS: uint32 = 8192", "MAX_FIXUPS: uint32 = 131072"),
        ("fx_at: Array[8192, uint32]", "fx_at: Array[131072, uint32]"),
        ("fx_name_off: Array[8192, uint32]", "fx_name_off: Array[131072, uint32]"),
        ("fx_name_len: Array[8192, uint32]", "fx_name_len: Array[131072, uint32]"),
        ("MAX_METHODS: uint32 = 1024", "MAX_METHODS: uint32 = 16384"),
        ("mfn_cls_off: Array[1024, uint32]", "mfn_cls_off: Array[16384, uint32]"),
        ("mfn_cls_len: Array[1024, uint32]", "mfn_cls_len: Array[16384, uint32]"),
        ("mfn_m_off: Array[1024, uint32]", "mfn_m_off: Array[16384, uint32]"),
        ("mfn_m_len: Array[1024, uint32]", "mfn_m_len: Array[16384, uint32]"),
        ("mfn_offset: Array[1024, uint32]", "mfn_offset: Array[16384, uint32]"),
        ("MAX_METHOD_FIXUPS: uint32 = 8192", "MAX_METHOD_FIXUPS: uint32 = 131072"),
        ("mfx_at: Array[8192, uint32]", "mfx_at: Array[131072, uint32]"),
        ("mfx_cls_off: Array[8192, uint32]", "mfx_cls_off: Array[131072, uint32]"),
        ("mfx_cls_len: Array[8192, uint32]", "mfx_cls_len: Array[131072, uint32]"),
        ("mfx_m_off: Array[8192, uint32]", "mfx_m_off: Array[131072, uint32]"),
        ("mfx_m_len: Array[8192, uint32]", "mfx_m_len: Array[131072, uint32]"),
        ("MAX_GLOBALS: uint32 = 1024", "MAX_GLOBALS: uint32 = 32768"),
        ("glob_name_off: Array[1024, uint32]", "glob_name_off: Array[32768, uint32]"),
        ("glob_name_len: Array[1024, uint32]", "glob_name_len: Array[32768, uint32]"),
        ("glob_offset: Array[1024, uint32]", "glob_offset: Array[32768, uint32]"),
        ("glob_elem_size: Array[1024, uint32]", "glob_elem_size: Array[32768, uint32]"),
        ("glob_scalar_size: Array[1024, uint32]", "glob_scalar_size: Array[32768, uint32]"),
        ("glob_is_bss: Array[1024, uint32]", "glob_is_bss: Array[32768, uint32]"),
        ("glob_ptr_size: Array[1024, uint32]", "glob_ptr_size: Array[32768, uint32]"),
        ("glob_is_signed: Array[1024, uint32]", "glob_is_signed: Array[32768, uint32]"),
        ("glob_signedness: Array[1024, uint32]", "glob_signedness: Array[32768, uint32]"),
        ("glob_type_node: Array[1024, uint32]", "glob_type_node: Array[32768, uint32]"),
        ("glob_struct_idx: Array[1024, uint32]", "glob_struct_idx: Array[32768, uint32]"),
        ("glob_is_float: Array[1024, uint32]", "glob_is_float: Array[32768, uint32]"),
        ("glob_is_percpu: Array[1024, uint32]", "glob_is_percpu: Array[32768, uint32]"),
        ("MAX_DATA_FIXUPS: uint32 = 8192", "MAX_DATA_FIXUPS: uint32 = 131072"),
        ("df_at: Array[8192, uint32]", "df_at: Array[131072, uint32]"),
        ("df_data_off: Array[8192, uint32]", "df_data_off: Array[131072, uint32]"),
        ("df_is_bss: Array[8192, uint32]", "df_is_bss: Array[131072, uint32]"),
        ("MAX_STRINGS: uint32 = 2048", "MAX_STRINGS: uint32 = 32768"),
        ("str_src_off: Array[2048, uint32]", "str_src_off: Array[32768, uint32]"),
        ("str_src_len: Array[2048, uint32]", "str_src_len: Array[32768, uint32]"),
        ("str_data_off: Array[2048, uint32]", "str_data_off: Array[32768, uint32]"),
        ("MAX_FLOAT_CONSTS: uint32 = 1024", "MAX_FLOAT_CONSTS: uint32 = 16384"),
        ("fc_bits: Array[1024, uint64]", "fc_bits: Array[16384, uint64]"),
        ("fc_width: Array[1024, uint32]", "fc_width: Array[16384, uint32]"),
        ("fc_data_off: Array[1024, uint32]", "fc_data_off: Array[16384, uint32]"),
        ("MAX_STRUCTS: uint32 = 256", "MAX_STRUCTS: uint32 = 4096"),
        ("st_name_off: Array[256, uint32]", "st_name_off: Array[4096, uint32]"),
        ("st_name_len: Array[256, uint32]", "st_name_len: Array[4096, uint32]"),
        ("st_total: Array[256, uint32]", "st_total: Array[4096, uint32]"),
        ("st_field_base: Array[256, uint32]", "st_field_base: Array[4096, uint32]"),
        ("st_nfields: Array[256, uint32]", "st_nfields: Array[4096, uint32]"),
        ("st_decl: Array[256, uint32]", "st_decl: Array[4096, uint32]"),
        ("MAX_STRUCT_FIELDS: uint32 = 4096", "MAX_STRUCT_FIELDS: uint32 = 65536"),
        ("sf_name_off: Array[4096, uint32]", "sf_name_off: Array[65536, uint32]"),
        ("sf_name_len: Array[4096, uint32]", "sf_name_len: Array[65536, uint32]"),
        ("sf_offset: Array[4096, uint32]", "sf_offset: Array[65536, uint32]"),
        ("sf_size: Array[4096, uint32]", "sf_size: Array[65536, uint32]"),
        ("sf_is_signed: Array[4096, uint32]", "sf_is_signed: Array[65536, uint32]"),
        ("sf_elem_size: Array[4096, uint32]", "sf_elem_size: Array[65536, uint32]"),
        ("sf_elem_signed: Array[4096, uint32]", "sf_elem_signed: Array[65536, uint32]"),
        ("sf_struct_idx: Array[4096, uint32]", "sf_struct_idx: Array[65536, uint32]"),
        ("sf_struct_is_ptr: Array[4096, uint32]", "sf_struct_is_ptr: Array[65536, uint32]"),
        ("sf_elem_struct: Array[4096, uint32]", "sf_elem_struct: Array[65536, uint32]"),
        ("sf_type_node: Array[4096, uint32]", "sf_type_node: Array[65536, uint32]"),
        # Kernel-target relocatable-object emission (CAP#3b).
        ("MAX_EXTERNS: uint32 = 1024", "MAX_EXTERNS: uint32 = 16384"),
        ("ext_name_off: Array[1024, uint32]", "ext_name_off: Array[16384, uint32]"),
        ("ext_name_len: Array[1024, uint32]", "ext_name_len: Array[16384, uint32]"),
        ("MAX_EXTERN_RELOCS: uint32 = 8192", "MAX_EXTERN_RELOCS: uint32 = 262144"),
        ("er_at: Array[8192, uint32]", "er_at: Array[262144, uint32]"),
        ("er_sym_idx: Array[8192, uint32]", "er_sym_idx: Array[262144, uint32]"),
        ("er_type: Array[8192, uint32]", "er_type: Array[262144, uint32]"),
    ],
    "cfg.ad": [
        # NM_MAX = max DISTINCT names per function. The on-disk cfg.ad keeps 256
        # (the on-DEVICE self-hosting cap) so the DEFAULT native codegen stays
        # byte-identical — codegen.ad never consults NM_MAX; only the SSA
        # optimizer (cfg.ad/ssa.ad/regalloc.ad, used by ADDER_OPT2 and the LLVM
        # backend) does. A handful of large user apps (hamsh/hamUId/js/hambrowse)
        # have functions with >256 distinct names; at 256 nm_intern overflows,
        # cfg_overflow trips, and the SSA/LLVM path bails to the native lane.
        # Raise the HOST compiler's cap so those functions emit through LLVM.
        # This is exactly the MAX_GLOBALS host-only bump pattern: EVERY
        # array/constant sized by NM_MAX MUST scale in lockstep or the
        # liveness/SSA passes write out of bounds. Derived sizes:
        #   LV_WORDS   = NM_MAX/32                 (liveness bitset words: 8->64)
        #   lv_*       = BB_MAX(8192) * LV_WORDS   (65536 -> 524288)
        #   cfgv_seen  = LV_WORDS                  (8 -> 64)
        #   lr_hole_*  = NM_MAX * LR_MAX_HOLES(4)  (1024 -> 8192)
        # (loop_break_bb/loop_cont_bb are LOOP_MAX-sized, NOT NM_MAX — untouched.)
        #
        # 1024 -> 2048 (2026-07-30). MEASURED, not guessed: instrumenting the
        # emitter to print nm_count per function over the whole-kernel
        # init/main.ad closure (11383 functions) with the cap temporarily at
        # 4096 gives exactly four functions above 400 distinct names —
        #   start_kernel                             nm=1492 (sb=2605 blocks)
        #   block_smoke_test                         nm=596
        #   linux_u_syscall_dispatch_inner           nm=539
        #   do_syscall_dispatch                      nm=471
        # — so 1024 was binding on start_kernel ALONE, and 2048 clears it with
        # 37% headroom while leaving the runner-up 3.4x under. Cost, measured on
        # the same whole-kernel emit: 45.1 s at 1024, 60.6 s at 4096 (+34%), so
        # 2048 is ~+11%; .bss grows 32 -> 64 MiB (ssa_curdef + ssa_incphi, each
        # SSA_BB_MAX(4096) * NM_MAX). Raising beat splitting start_kernel: the
        # split would be a refactor of the SHARED boot sequence (2605 basic
        # blocks) to buy an 11% host-compile win that nobody is asking for.
        # start_kernel had NO caller in the emitted IR, so it was a LATENT (not
        # live) ARM64 link break — but see the guard below: it is exactly the
        # class of bail that goes live the moment the subset broadens.
        ("NM_MAX: uint32 = 256", "NM_MAX: uint32 = 2048"),
        ("nm_off: Array[256, uint32]", "nm_off: Array[2048, uint32]"),
        ("nm_len: Array[256, uint32]", "nm_len: Array[2048, uint32]"),
        ("nm_trunc: Array[256, uint32]", "nm_trunc: Array[2048, uint32]"),
        ("nm_slotread: Array[256, uint32]", "nm_slotread: Array[2048, uint32]"),
        ("nm_usecost: Array[256, uint32]", "nm_usecost: Array[2048, uint32]"),
        ("LV_WORDS: uint32 = 8", "LV_WORDS: uint32 = 64"),
        ("lv_use: Array[65536, uint32]", "lv_use: Array[524288, uint32]"),
        ("lv_def: Array[65536, uint32]", "lv_def: Array[524288, uint32]"),
        ("lv_in: Array[65536, uint32]", "lv_in: Array[524288, uint32]"),
        ("lv_out: Array[65536, uint32]", "lv_out: Array[524288, uint32]"),
        ("cfgv_seen: Array[8, uint32]", "cfgv_seen: Array[64, uint32]"),
        ("lr_start: Array[256, uint32]", "lr_start: Array[2048, uint32]"),
        ("lr_end: Array[256, uint32]", "lr_end: Array[2048, uint32]"),
        ("lr_valid: Array[256, uint32]", "lr_valid: Array[2048, uint32]"),
        ("lr_nhole: Array[256, uint32]", "lr_nhole: Array[2048, uint32]"),
        ("lr_hole_lo: Array[1024, uint32]", "lr_hole_lo: Array[8192, uint32]"),
        ("lr_hole_hi: Array[1024, uint32]", "lr_hole_hi: Array[8192, uint32]"),
        ("lr_hole_depth: Array[1024, uint32]", "lr_hole_depth: Array[8192, uint32]"),
        ("lr_hole_brdepth: Array[1024, uint32]", "lr_hole_brdepth: Array[8192, uint32]"),
        ("cl_set: Array[256, uint32]", "cl_set: Array[2048, uint32]"),
    ],
    "regalloc.ad": [
        # Mirror the cfg NM_MAX host bump (256 -> 1024): the linear-scan allocator
        # indexes ra_* arrays by name id up to RA_MAXNAMES (== cfg NM_MAX). If cfg
        # NM_MAX grows but these stay 256 the allocator reads/writes past the end.
        ("RA_MAXNAMES: uint32 = 256", "RA_MAXNAMES: uint32 = 2048"),
        ("ra_assigned_reg: Array[256, uint32]", "ra_assigned_reg: Array[2048, uint32]"),
        ("ra_store_elim: Array[256, uint32]", "ra_store_elim: Array[2048, uint32]"),
        ("ra_order: Array[256, uint32]", "ra_order: Array[2048, uint32]"),
        ("ra_name_vetoed: Array[256, uint32]", "ra_name_vetoed: Array[2048, uint32]"),
        ("ra_name_isfloat: Array[256, uint32]", "ra_name_isfloat: Array[2048, uint32]"),
        ("ra_xmm_assigned: Array[256, uint32]", "ra_xmm_assigned: Array[2048, uint32]"),
        ("ra_xmm_order: Array[256, uint32]", "ra_xmm_order: Array[2048, uint32]"),
    ],
    "ssa.ad": [
        # Mirror the cfg NM_MAX host bump (256 -> 1024). ssa_curdef/ssa_incphi are
        # indexed [block * NM_MAX + name] => SSA_BB_MAX(1024) * NM_MAX, so they
        # scale to 1024*1024 = 1048576. The per-name ssa_* attribute arrays are
        # indexed by name id and scale 256 -> 1024. (sv_*/sb_* arrays are
        # value-/block-indexed, NOT name-indexed — untouched.)
        ("ssa_curdef: Array[262144, uint32]", "ssa_curdef: Array[2097152, uint32]"),
        ("ssa_incphi: Array[262144, uint32]", "ssa_incphi: Array[2097152, uint32]"),
        ("ssa_islocal: Array[256, uint32]", "ssa_islocal: Array[2048, uint32]"),
        ("ssa_local_sgn: Array[256, uint32]", "ssa_local_sgn: Array[2048, uint32]"),
        ("ssa_local_size: Array[256, uint32]", "ssa_local_size: Array[2048, uint32]"),
        ("ssa_ismem: Array[256, uint32]", "ssa_ismem: Array[2048, uint32]"),
        ("ssa_mem_addr: Array[256, uint32]", "ssa_mem_addr: Array[2048, uint32]"),
        ("ssa_mem_esz: Array[256, uint32]", "ssa_mem_esz: Array[2048, uint32]"),
        ("ssa_mem_esgn: Array[256, uint32]", "ssa_mem_esgn: Array[2048, uint32]"),
        ("ssa_mem_isarr: Array[256, uint32]", "ssa_mem_isarr: Array[2048, uint32]"),
        ("ssa_mem_rowstride: Array[256, uint32]", "ssa_mem_rowstride: Array[2048, uint32]"),
        ("ssa_ptr_esz: Array[256, uint32]", "ssa_ptr_esz: Array[2048, uint32]"),
        ("ssa_ptr_esgn: Array[256, uint32]", "ssa_ptr_esgn: Array[2048, uint32]"),
        ("ssa_local_struct: Array[256, uint32]", "ssa_local_struct: Array[2048, uint32]"),
        ("ssa_local_struct_is_ptr: Array[256, uint32]", "ssa_local_struct_is_ptr: Array[2048, uint32]"),
        ("ssa_local_fw: Array[256, uint32]", "ssa_local_fw: Array[2048, uint32]"),
        ("SSA_BB_MAX: uint32 = 1024", "SSA_BB_MAX: uint32 = 4096"),
        ("sb_first_val: Array[1024, uint32]", "sb_first_val: Array[4096, uint32]"),
        ("sb_last_val: Array[1024, uint32]", "sb_last_val: Array[4096, uint32]"),
        ("sb_term: Array[1024, uint32]", "sb_term: Array[4096, uint32]"),
        ("sb_nval: Array[1024, uint32]", "sb_nval: Array[4096, uint32]"),
        ("sb_succ0: Array[1024, uint32]", "sb_succ0: Array[4096, uint32]"),
        ("sb_succ1: Array[1024, uint32]", "sb_succ1: Array[4096, uint32]"),
        ("sb_nsucc: Array[1024, uint32]", "sb_nsucc: Array[4096, uint32]"),
        ("sb_pred_head: Array[1024, uint32]", "sb_pred_head: Array[4096, uint32]"),
        ("sb_npred: Array[1024, uint32]", "sb_npred: Array[4096, uint32]"),
        ("sb_sealed: Array[1024, uint32]", "sb_sealed: Array[4096, uint32]"),
        ("sb_idom: Array[1024, uint32]", "sb_idom: Array[4096, uint32]"),
        ("sb_ponum: Array[1024, uint32]", "sb_ponum: Array[4096, uint32]"),
        ("sb_visited: Array[1024, uint32]", "sb_visited: Array[4096, uint32]"),
        ("sb_rpo: Array[1024, uint32]", "sb_rpo: Array[4096, uint32]"),
        ("sb_po: Array[1024, uint32]", "sb_po: Array[4096, uint32]"),
        ("ssa_curdef: Array[2097152, uint32]", "ssa_curdef: Array[8388608, uint32]"),
        ("ssa_incphi: Array[2097152, uint32]", "ssa_incphi: Array[8388608, uint32]"),
    ],
    "ssa_opt.ad": [
        ("SSA_BB_MAX_LOCAL: uint32 = 1024", "SSA_BB_MAX_LOCAL: uint32 = 4096"),
        ("sccp_bexec: Array[1024, uint32]", "sccp_bexec: Array[4096, uint32]"),
        ("sccp_e0: Array[1024, uint32]", "sccp_e0: Array[4096, uint32]"),
        ("sccp_e1: Array[1024, uint32]", "sccp_e1: Array[4096, uint32]"),
        ("sccp_bwl: Array[1024, uint32]", "sccp_bwl: Array[4096, uint32]"),
        ("sccp_bq: Array[1024, uint32]", "sccp_bq: Array[4096, uint32]"),
        ("licm_in_loop: Array[1024, uint32]", "licm_in_loop: Array[4096, uint32]"),
    ],
    "ssa_emit.ad": [
        ("se_bid_off: Array[1024, uint32]", "se_bid_off: Array[4096, uint32]"),
    ],
    "ssa_llvm.ad": [
        ("LL_BB_MAX: uint32 = 1024", "LL_BB_MAX: uint32 = 4096"),
        ("llvm_bb_live: Array[1024, uint8]", "llvm_bb_live: Array[4096, uint8]"),
    ],
    "elf_emit.ad": [
        ("ELF_BUF_CAP: uint32 = 131072", "ELF_BUF_CAP: uint32 = 25165824"),
        ("elf_buf: Array[131072, uint8]", "elf_buf: Array[25165824, uint8]"),
        # Kernel ET_REL emitter staging buffers (CAP#3b): whole-tree symbol
        # table / string table for the kernel's ~10 K functions + ~3 K externs.
        ("KELF_MAX_EXTERNS: uint32 = 256", "KELF_MAX_EXTERNS: uint32 = 16384"),
        ("ext_sym: Array[256, uint32]", "ext_sym: Array[16384, uint32]"),
        ("KELF_MAX_FNSYMS: uint32 = 256", "KELF_MAX_FNSYMS: uint32 = 16384"),
        ("fn_sym: Array[256, uint32]", "fn_sym: Array[16384, uint32]"),
        ("KELF_STRTAB_CAP: uint32 = 4096", "KELF_STRTAB_CAP: uint32 = 4194304"),
        ("kelf_strtab: Array[4096, uint8]", "kelf_strtab: Array[4194304, uint8]"),
        ("KELF_MAX_SYMS: uint32 = 256", "KELF_MAX_SYMS: uint32 = 32768"),
        ("ksym_name: Array[256, uint32]", "ksym_name: Array[32768, uint32]"),
        ("ksym_info: Array[256, uint32]", "ksym_info: Array[32768, uint32]"),
        ("ksym_shndx: Array[256, uint32]", "ksym_shndx: Array[32768, uint32]"),
        ("ksym_value: Array[256, uint64]", "ksym_value: Array[32768, uint64]"),
    ],
}


# Carries the host SSA_BB_MAX across the per-module override calls (ssa.ad is
# concatenated before its three siblings, so it is seen first).
_HOST_BB = [None]

# Same, for the host NM_MAX. cfg.ad is concatenated before regalloc.ad/ssa.ad,
# so the cap is seen first and can be enforced on the two sibling modules that
# size arrays by it.
_HOST_NM = [None]

# Every NAME-INDEXED array, by owning module, that MUST be exactly NM_MAX
# entries long. `nm_intern` hands out ids in [0, NM_MAX), and each of these is
# written at that id, so one left at the on-device 256 (or a stale 1024 after a
# raise) is a straight out-of-bounds write into whatever .bss follows it. The
# two sibling CONSTANTS are worse than an array: `RA_MAXNAMES` bounds the
# allocator's own loops, and `LV_WORDS` is the liveness bitset WIDTH — leaving
# LV_WORDS small does not overflow, it silently makes every liveness set only
# describe the first LV_WORDS*32 names, so names past it read as DEAD and their
# live ranges are wrong. That is a miscompile with no crash.
_NM_INDEXED = {
    "cfg.ad": ["nm_off", "nm_len", "nm_trunc", "nm_slotread", "nm_usecost",
               "lr_start", "lr_end", "lr_valid", "lr_nhole", "cl_set"],
    "regalloc.ad": ["ra_assigned_reg", "ra_store_elim", "ra_order",
                    "ra_name_vetoed", "ra_name_isfloat", "ra_xmm_assigned",
                    "ra_xmm_order"],
    "ssa.ad": ["ssa_islocal", "ssa_local_sgn", "ssa_local_size", "ssa_ismem",
               "ssa_mem_addr", "ssa_mem_esz", "ssa_mem_esgn", "ssa_mem_isarr",
               "ssa_mem_rowstride", "ssa_ptr_esz", "ssa_ptr_esgn",
               "ssa_local_struct", "ssa_local_struct_is_ptr", "ssa_local_fw"],
}


def _check_nm_lockstep(mod, text):
    """Fail the concat BY NAME if the host NM_MAX was raised but something it
    sizes was left behind. Mirrors the SSA_BB_MAX guard above; see _NM_INDEXED
    for why a stale sibling CONSTANT is worse than a stale array."""
    m = re.search(r"\nNM_MAX: uint32 = (\d+)", text)
    if m:
        _HOST_NM[0] = int(m.group(1))
    nm = _HOST_NM[0]
    if nm is None or nm == 256:
        return                                  # on-device build: nothing raised
    stale = []
    for name in _NM_INDEXED.get(mod, []):
        for mm in re.finditer(
                r"\n" + re.escape(name) + r": Array\[(\d+), uint(?:8|32|64)\]",
                text):
            if int(mm.group(1)) != nm:
                stale.append("%s[%s] (want %d)" % (name, mm.group(1), nm))
    if mod == "cfg.ad":
        lv = re.search(r"\nLV_WORDS: uint32 = (\d+)", text)
        if lv and int(lv.group(1)) != nm // 32:
            stale.append("LV_WORDS=%s (want NM_MAX/32 = %d)"
                         % (lv.group(1), nm // 32))
        if lv:
            want_lv = 8192 * (nm // 32)         # BB_MAX * LV_WORDS
            for a in ("lv_use", "lv_def", "lv_in", "lv_out"):
                mm = re.search(r"\n" + a + r": Array\[(\d+), uint32\]", text)
                if mm and int(mm.group(1)) != want_lv:
                    stale.append("%s[%s] (want BB_MAX*LV_WORDS = %d)"
                                 % (a, mm.group(1), want_lv))
            mm = re.search(r"\ncfgv_seen: Array\[(\d+), uint32\]", text)
            if mm and int(mm.group(1)) != nm // 32:
                stale.append("cfgv_seen[%s] (want LV_WORDS = %d)"
                             % (mm.group(1), nm // 32))
        for a in ("lr_hole_lo", "lr_hole_hi", "lr_hole_depth", "lr_hole_brdepth"):
            mm = re.search(r"\n" + a + r": Array\[(\d+), uint32\]", text)
            if mm and int(mm.group(1)) != nm * 4:
                stale.append("%s[%s] (want NM_MAX*LR_MAX_HOLES = %d)"
                             % (a, mm.group(1), nm * 4))
    if mod == "regalloc.ad":
        mm = re.search(r"\nRA_MAXNAMES: uint32 = (\d+)", text)
        if mm and int(mm.group(1)) != nm:
            stale.append("RA_MAXNAMES=%s (want NM_MAX = %d)" % (mm.group(1), nm))
    if mod == "ssa.ad":
        bb = _HOST_BB[0] or 1024
        for a in ("ssa_curdef", "ssa_incphi"):
            mm = re.search(r"\n" + a + r": Array\[(\d+), uint32\]", text)
            if mm and int(mm.group(1)) != bb * nm:
                stale.append("%s[%s] (want SSA_BB_MAX*NM_MAX = %d)"
                             % (a, mm.group(1), bb * nm))
    if stale:
        raise SystemExit(
            "[concat] ERROR: host build raised NM_MAX to %d but left "
            "name-indexed name(s) unscaled in %s: %s. nm_intern hands out ids "
            "in [0,NM_MAX), so a stale ARRAY is an out-of-bounds write and a "
            "stale CONSTANT (LV_WORDS / RA_MAXNAMES) silently truncates the "
            "liveness/allocation domain. Update HOST_BUFFER_OVERRIDES['%s'] "
            "(and _NM_INDEXED if you added a new name-indexed array)."
            % (nm, mod, ", ".join(stale), mod))


def apply_host_buffer_overrides(mod, text):
    """For the HOST driver build, scale a shared module's buffers up to
    whole-TREE size. Each (small -> large) pair MUST appear exactly once in
    the on-disk source; a missing pair means the on-disk literal drifted and
    the host build would silently keep an on-device-sized buffer (which can't
    hold the kernel). Assert exactly-once to catch that drift loudly.

    Matches are LINE-ANCHORED (the def must start at column 0, preceded by a
    newline) so a short name that is a SUFFIX of a longer one — e.g.
    `fn_offset: Array[1024, uint32]` is a substring of
    `mfn_offset: Array[1024, uint32]` — is not double-counted."""
    for old, new in HOST_BUFFER_OVERRIDES.get(mod, []):
        anchored_old = "\n" + old
        anchored_new = "\n" + new
        cnt = text.count(anchored_old)
        if cnt != 1:
            raise SystemExit(
                "[concat] ERROR: host buffer override for %s expected exactly "
                "one line '%s' but found %d — the on-disk literal drifted; "
                "update HOST_BUFFER_OVERRIDES." % (mod, old, cnt)
            )
        text = text.replace(anchored_old, anchored_new)

    # Guard against a PARALLEL array being left un-scaled. The token and node
    # tables are parallel arrays indexed by the SAME cursor (tok_count /
    # nd_count) up to the scaled MAX_TOKENS / MAX_NODES. If one member of the
    # group keeps the on-device 65536 size while MAX_* is raised to 4194304,
    # the lexer/parser writes it OUT OF BOUNDS for any unit with >65536
    # tokens/nodes (all the large userland apps + the compiler self-compile
    # units), silently corrupting adjacent .bss. This exact bug (tok_is_float
    # missing from the list) forced ~13 units to the seed. Fail loudly if any
    # `tok_*`/`nd_*` array is still 65536-sized after the overrides ran.
    # Guard the BLOCK-INDEXED family the same way. SSA_BB_MAX sizes ~24 arrays
    # across four modules AND is shadowed by two independently-spelled sibling
    # constants (ssa_opt.ad's SSA_BB_MAX_LOCAL, ssa_llvm.ad's LL_BB_MAX). Raising
    # SSA_BB_MAX while one of those stays at 1024 is NOT a clean under-use:
    # llvm_bb_live[] is the liveness map phi emission consults, and a block id
    # past LL_BB_MAX reads as DEAD, so phi operands from it are silently DROPPED
    # — the emitter then writes phis with missing/zero incoming entries. That IR
    # is invalid, and clang-19 SIGSEGVs on it in SimplifyCFG instead of
    # diagnosing it. This exact pairing bit once (2026-07-30). If SSA_BB_MAX was
    # raised for the host build, fail loudly on any sibling constant or
    # block-indexed array left at the on-device 1024.
    if mod in ("ssa.ad", "ssa_opt.ad", "ssa_emit.ad", "ssa_llvm.ad"):
        m = re.search(r"\nSSA_BB_MAX: uint32 = (\d+)", text)
        host_bb = None
        if m:
            host_bb = int(m.group(1))
            _HOST_BB[0] = host_bb
        host_bb = _HOST_BB[0]
        if host_bb is not None and host_bb != 1024:
            stale = re.findall(
                r"\n(SSA_BB_MAX_LOCAL|LL_BB_MAX): uint32 = 1024", text)
            stale += re.findall(
                r"\n(sb_[a-z0-9_]*|sccp_b[a-z0-9_]*|sccp_e[01]|licm_in_loop"
                r"|se_bid_off|llvm_bb_live): Array\[1024,", text)
            if stale:
                raise SystemExit(
                    "[concat] ERROR: host build raised SSA_BB_MAX to %d but left "
                    "block-indexed name(s) at 1024 in %s: %s. A sibling CONSTANT "
                    "left small makes phi emission drop operands from blocks past "
                    "it (invalid IR, clang SIGSEGV); a sibling ARRAY left small is "
                    "an out-of-bounds write. Add it to "
                    "HOST_BUFFER_OVERRIDES['%s']."
                    % (host_bb, mod, ", ".join(sorted(set(stale))), mod))

    # Guard the NAME-INDEXED family (NM_MAX) exactly the same way — see
    # _check_nm_lockstep. NM_MAX is the costlier of the two caps to raise
    # (ssa_curdef/ssa_incphi are SSA_BB_MAX * NM_MAX), which is precisely why it
    # is the one most likely to be raised in cfg.ad and forgotten in regalloc.ad
    # or ssa.ad.
    _check_nm_lockstep(mod, text)

    prefixes = {"lexer.ad": "tok_", "parser.ad": "nd_"}.get(mod)
    if prefixes is not None:
        pat = re.compile(
            r"\n(" + re.escape(prefixes) + r"[A-Za-z0-9_]*): Array\[65536,")
        leftover = pat.findall(text)
        if leftover:
            raise SystemExit(
                "[concat] ERROR: host build left parallel %s array(s) un-scaled "
                "at 65536 while MAX was raised: %s — every parallel token/node "
                "array MUST be in HOST_BUFFER_OVERRIDES['%s'] or the lexer/parser "
                "writes out of bounds on large units."
                % (mod, ", ".join(leftover), mod)
            )
    return text


def strip_compiler_imports(text):
    """Remove every `from compiler.X import (...)` block.

    The block spans from a line beginning with `from compiler.` (after
    optional leading whitespace; these are all top-level so unindented)
    through the line whose stripped content is exactly `)`. A single-line
    `from compiler.X import a, b` (no paren) is dropped as one line.
    Returns the stripped source text.
    """
    out_lines = []
    lines = text.split("\n")
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        stripped = line.lstrip()
        if stripped.startswith("from compiler."):
            # Parenthesised multi-line import: drop through the line that
            # is just `)`.
            if "(" in line:
                # Consume until the closing `)` line (inclusive).
                while i < n and lines[i].strip() != ")":
                    i += 1
                # Drop the `)` line too (if present).
                if i < n:
                    i += 1
                continue
            # Single-line `from compiler.X import a, b` — drop just it.
            i += 1
            continue
        out_lines.append(line)
        i += 1
    return "\n".join(out_lines)


def main(argv):
    out_path = os.path.join(PROJ_ROOT, "build", "selfhost", "whole_compiler.ad")
    with_driver = False
    args = argv[1:]
    j = 0
    while j < len(args):
        if args[j] in ("-o", "--out"):
            out_path = args[j + 1]
            j += 2
        elif args[j] == "--with-driver":
            with_driver = True
            j += 1
        else:
            sys.stderr.write(
                "usage: concat_compiler_source.py [-o OUT.ad] [--with-driver]\n"
            )
            return 2

    modules = list(MODULES)
    if with_driver:
        modules += DRIVER_EXTRA_MODULES
        # The HOST self-hosting driver (fused_driver_host_main.ad) is the only
        # driver that arms the SSA optimizer/allocator pipeline under --opt (or
        # ADDER_OPT2). The legacy AST optimizer (opt.ad) has been RETIRED — its
        # only caller was this driver's --opt arm, now repointed at SSA. Note the
        # SSA allocator is a fresh module (ssa_emit.ad); the OLD linear-scan
        # allocator (regalloc.ad) stays in MODULES because codegen.ad's -O0 base
        # path still references its symbols, but it is now DEAD (never armed:
        # ra_enable is no longer called anywhere).
        if DRIVER_MAIN == HOST_DRIVER_MAIN:
            # SSA optimizer/allocator pipeline. Fused in ONLY for the host driver,
            # gated at RUNTIME behind ADDER_OPT2 / --opt in
            # fused_driver_host_main.ad — with neither set the SSA path is never
            # entered and host_ac.elf output is byte-identical. Dependency order:
            # ssa.ad references codegen/ir/cfg/parser/lexer (all already ahead of
            # it); ssa_opt.ad references ssa; ssa_emit.ad references
            # ssa + ssa_opt + codegen — so append ssa, ssa_opt, ssa_emit AFTER
            # codegen/elf_emit. NOTE: deliberately NOT added to the frozen Python
            # seed's import-discovery closure — the seed stays the untouched
            # bootstrap oracle; only the self-hosted host_ac.elf links the SSA code.
            #
            # ssa_llvm.ad is the OPTIONAL "release/fast" LLVM backend (a SPIKE).
            # It READS the SSA IR (ssa.ad arenas) + codegen global/enum/class
            # layout tables and emits TEXTUAL LLVM IR (.ll). It references
            # codegen/ssa/parser/lexer symbols only (all ahead of it), so it is
            # appended LAST. Gated at RUNTIME behind the driver's --backend=llvm /
            # --emit-llvm flag; with neither set it is never entered and
            # host_ac.elf's ELF output is byte-identical to the pre-LLVM compiler.
            modules += ["ssa.ad", "ssa_opt.ad", "ssa_emit.ad", "ssa_llvm.ad"]
            # checkarith.ad is the OPT-IN `--check-arith` instrumentation pass
            # (AST -> AST, runs between parse and codegen). It references only
            # lexer + parser symbols, so it may sit anywhere after parser.ad;
            # appended last to keep the diff to this list minimal. Gated at
            # RUNTIME behind the driver's --check-arith flag — with the flag
            # absent ck_instrument_program is never called and host_ac.elf's
            # output is byte-identical to the pre-feature compiler. Like the SSA
            # modules it is deliberately NOT added to the frozen Python seed's
            # import closure: the seed stays the untouched bootstrap oracle.
            modules += ["checkarith.ad"]

    chunks = []
    header = (
        "# GENERATED by scripts/concat_compiler_source.py — do not edit.\n"
        "# Single-module fusion of the self-hosted compiler:\n"
        "#   " + " + ".join(modules) + "\n"
        "# with intra-compiler `from compiler.X import (...)` blocks stripped.\n"
    )
    if with_driver:
        header += "# + appended driver main (" + DRIVER_MAIN + ").\n"
    chunks.append(header)

    # Only the HOST self-hosting driver compiles the whole tree (incl. the
    # kernel), so only it gets the whole-tree-scaled compiler buffers. The
    # on-device drivers keep the small on-disk literals (256 MiB QEMU guest).
    host_build = with_driver and DRIVER_MAIN == HOST_DRIVER_MAIN

    for mod in modules:
        src_path = os.path.join(COMPILER_DIR, mod)
        with open(src_path, "r") as f:
            text = f.read()
        if host_build:
            text = apply_host_buffer_overrides(mod, text)
        stripped = strip_compiler_imports(text)
        chunks.append("\n# ===== begin " + mod + " =====\n")
        chunks.append(stripped)
        chunks.append("\n# ===== end " + mod + " =====\n")

    if with_driver:
        drv_path = os.path.join(COMPILER_DIR, DRIVER_MAIN)
        with open(drv_path, "r") as f:
            drv_text = f.read()
        # The driver has no `from compiler.` imports, but strip defensively
        # so future edits can't sneak one in.
        drv_text = strip_compiler_imports(drv_text)
        chunks.append("\n# ===== begin " + DRIVER_MAIN + " =====\n")
        chunks.append(drv_text)
        chunks.append("\n# ===== end " + DRIVER_MAIN + " =====\n")

    fused = "".join(chunks)

    out_dir = os.path.dirname(out_path)
    if out_dir and not os.path.isdir(out_dir):
        os.makedirs(out_dir, exist_ok=True)
    with open(out_path, "w") as f:
        f.write(fused)

    nbytes = len(fused.encode("utf-8"))
    sys.stderr.write(
        "[concat] wrote %s (%d bytes, %d lines)\n"
        % (out_path, nbytes, fused.count("\n") + 1)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
