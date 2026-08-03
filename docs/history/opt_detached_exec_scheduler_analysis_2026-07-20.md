# `--opt` kernel: detached children never exec — scheduler codegen is CLEAN (precise negative + sharpest probe)

Date: 2026-07-20. Investigates: under `HAMNIX_KERNEL_OPT=1`, RFNOWAIT/`spawn detached`
children (gettys, live_distro_up, DE clients) never reach `_do_execve_inner`, leaving the
desktop blank; non-detached hamsh commands (`cat`) exec fine. Same userland object both ways —
only the kernel codegen differs.

## Result: NOT a scheduler codegen miscompile

Both kernel objects were emitted from `init/main.ad` (host_ac) and the full-extent disassembly
of every function on the detached child's **enqueue → placement → selection → preemption** path
was compared `--opt` vs `--no-opt` (objects cached in `build/opt_fndump/{noopt,opt}.o`; diff
helper `scratchpad/fulldiff.sh` uses next-symbol bounds, so — unlike
`scripts/dump_kernel_opt_fn.sh` — it does NOT truncate at the first `ret`).

Verified **semantically equivalent** under `--opt` (store-for-store / reloc-for-reloc):

| function | offset | verdict |
|---|---|---|
| `task_publish_thread_ready` | 0x2577... | CLEAN — EMBRYO→READY flip + `_rq_list_insert` under rq lock identical |
| `_rq_list_insert` | 0x254f0e | CLEAN — head-insert: rq_prev(0x32b8)=NIL, rq_next(0x32b0)=nh, nh.rq_prev=slot, rq_head[cpu]=slot, rq_on_list(0x32c0)=cpu+1 all present |
| `sched_fork_vruntime` | 0x250cfd | CLEAN — penalty = (VRUNTIME_SCALE[.data+0x13ddf] × NICE0_WEIGHT[.data+0x13dc7] / w) × SCHED_QUANTUM_TICKS[.data+0x13dbf]; identical operands (relocs match) |
| `_pick_next` (CFS min-select loop) | 0x2578e1 | CLEAN — `v=task[i].vruntime`(0xfd0); `best<0`→take; `v<best_v`(unsigned `jae`-skip)→take; `v==best_v`&&`best==cur`&&`i!=cur`→take; walk `i=task[i].rq_next`(0x32b0) |
| `preempt_tick` (full CFS body) | 0x259079 | CLEAN — vruntime accrual (same VSCALE×NICE0/cw×cap globals), `quantum_left`(gs:0x50) decrement, and all 3 return gates (`quantum_left!=0`→0, `from_user==0`→0, `another_task_ready==0`→0 else 1) correct |
| `_another_task_ready` | 0x258cc2 | CLEAN |

Prior agent additionally cleared `do_rfork` / `do_clone` / `_build_initial_kstack` /
`create_user_task_argv*`.

**This disproves the previous (dead) agent's lead** that `preempt_tick`'s CFS path (hidden by the
first-`ret` truncation) held the miscompile. The full CFS path is disassembled here and is correct.

Also confirmed: `detached` and `parent_pid` are read ONLY in wait4 / reap_orphan_zombies /
SIGCHLD paths (`arch/x86/kernel/syscall.ad:3514,3555`, `kernel/sched/core.ad:7741,5528`) — NEVER
in dispatch/selection. The scheduler selects a detached STATE_READY task identically to a
non-detached one. So the flag itself does not gate scheduling.

## Leading hypothesis: `--opt`-exposed vruntime STARVATION (a dynamics bug, not codegen)

The detached-vs-non-detached difference is purely dynamical:

- **Non-detached** (`cat`): the parent hamsh calls `sys_waitpid(child)` → parent goes STATE_WAIT,
  **leaving the runqueue**. The child is then the sole/guaranteed `_pick_next` winner regardless of
  vruntime → it execs. Works under `--opt` (needs no involuntary preemption).
- **Detached** (RFNOWAIT): the parent does **not** wait — it stays STATE_READY and keeps running.
  The child (placed at `sched_vruntime_floor()+penalty`, i.e. one slice *behind*) now competes on
  vruntime and only runs via (a) involuntary preemption once the parent's quantum drains on a
  ring-3 tick, or (b) a later point where every lower-vruntime task leaves the runqueue.

Two charge-model facts make the detached child starvable:
1. vruntime is charged **only** on 100 Hz ticks in `preempt_tick` — a task that yields
   voluntarily before a tick charges it accrues **zero** vruntime and stays pinned low.
2. `quantum_left` is **re-armed to a full slice on every dispatch** (`kernel/sched/core.ad:5147`
   `quantum_left = sched_quantum_for(nxt)`), so a task that is re-dispatched frequently never
   drains its quantum to 0 → involuntary preemption (`preempt_tick`→1) never fires for it.

A faster `--opt` kernel executes the same userland instruction stream in fewer wall-clock µs, so
the parent (and the rl5 DE fork+exec storm) complete more work / re-dispatch more often *between*
10 ms ticks. That shifts tick-landing and yield dynamics so the low-vruntime incumbents keep being
re-picked and the floor+penalty-placed detached children are never selected — the same D3
fork-storm starvation class the `sched_fork_vruntime` banner (core.ad:2202+) partially fixed, now
re-exposed for detached tasks by the `--opt` speedup. No speculative fix applied (per mission).

## Sharpest next probe (Heisenbug-safe — NO printk in the hot path)

A printk inside `_pick_next`/`preempt_tick` would itself slow the kernel and likely MASK a timing
starvation. Instead, instrument with cheap counters and dump from a cold path:

1. In `do_rfork`'s `if (f & RFNOWAIT)` branch (core.ad ~714), append `child_pid` to a small global
   array `g_detached_pids[]` (+count).
2. In `schedule()`'s dispatch (right after `task_table[nxt].state = STATE_RUNNING`), set a
   per-task `ever_dispatched=1` (or record pid into `g_ever_ran[]`).
3. From a COLD path (e.g. alongside the orchestrator's existing `_do_execve_inner` `[execdbg]`
   printk, or a one-shot after N jiffies), printk each detached pid together with
   `ever_dispatched`, its `vruntime`, and the current `sched_vruntime_floor()`.

Boot both ways. Expected discriminator:
- If a detached pid shows `ever_dispatched=0` under `--opt` but `=1` under `--no-opt`, with its
  `vruntime` sitting *above* the min of the runnable set → **confirms vruntime starvation** (fix in
  the charge model: charge partial runtime on voluntary yield, or don't let a frequently-yielding
  incumbent hold an unfairly low vruntime / cap the placement gap).
- If it was dispatched but still never execs → the bug is downstream of selection (child userland
  resume / the `spawn` block's inner rfork+execve for the grandchild), not the scheduler.
