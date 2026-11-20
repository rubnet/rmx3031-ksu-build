#!/bin/bash
# ============================================================================
# Patch KernelSU-Next legacy to use PURE TRACEPOINT hook (no kprobe symbols).
#
# Problem: RMX3031 kernel has CONFIG_HAVE_KPROBES=y but NOT CONFIG_KPROBES=y,
# so register_kprobe/register_kretprobe symbols do NOT exist in the running kernel.
# KSU-Next's "KPROBES_HOOK" mode gates BOTH:
#   (a) hook_manager.c tracepoint hook  <-- we WANT this (sys_enter tracepoint)
#   (b) extras.c / ksud_integration.c kprobe hooks <-- we DON'T (need kprobe syms)
#
# Solution: introduce KSU_SYSCALL_TP_HOOK macro that ONLY enables (a).
#   - Kbuild: make SYSCALL_TABLE branch define KSU_SYSCALL_TP_HOOK, no extra objs
#   - hook_manager.c: top guard accepts either KSU_KPROBES_HOOK or KSU_SYSCALL_TP_HOOK
#   - extras.c / ksud_integration.c keep guarding on KSU_KPROBES_HOOK only => stay OFF
#   - No CONFIG_KRETPROBES => hook_manager's kretprobe section auto-disabled,
#     and it calls ksu_mark_running_process_locked() fallback instead.
# ============================================================================
set -e
cd KernelSU-Next

# --- 1. Kbuild: rewrite SYSCALL_TABLE branch into pure-tracepoint mode ---
python3 - <<'PY'
p = "kernel/Kbuild"
s = open(p, encoding="utf-8").read()
old = '''ifeq ($(CONFIG_KSU_SYSCALL_TABLE_HOOK), y)
$(info -- KernelSU-Next: Hook mode: Syscall table patching)
ccflags-y += -DKSU_SYSCALL_TABLE_HOOK
HAVE_KSU_HOOK := 0
kernelsu-objs += hook/patch_memory.o
kernelsu-objs += hook/syscall_table_hook.o
kernelsu-objs += infra/symbol_resolver.o
endif'''
new = '''ifeq ($(CONFIG_KSU_SYSCALL_TABLE_HOOK), y)
$(info -- KernelSU-Next: Hook mode: PURE SYSCALL TRACEPOINT (no kprobe))
ccflags-y += -DKSU_SYSCALL_TP_HOOK
HAVE_KSU_HOOK := 0
endif'''
if old not in s:
    raise SystemExit("FATAL: Kbuild SYSCALL_TABLE branch not found (layout changed)")
s = s.replace(old, new)
open(p, "w", encoding="utf-8").write(s)
print("[patch] Kbuild: SYSCALL_TABLE -> pure tracepoint")
PY

# --- 2. hook_manager.c: accept KSU_SYSCALL_TP_HOOK as well ---
python3 - <<'PY'
p = "kernel/hook/hook_manager.c"
s = open(p, encoding="utf-8").read()
# top file guard
s = s.replace(
    "#ifdef KSU_KPROBES_HOOK\n",
    "#if defined(KSU_KPROBES_HOOK) || defined(KSU_SYSCALL_TP_HOOK)\n",
    1,
)
open(p, "w", encoding="utf-8").write(s)
print("[patch] hook_manager.c: top guard accepts KSU_SYSCALL_TP_HOOK")
PY

# --- 3. Verify guards ---
echo "=== verify ==="
grep -n 'KSU_SYSCALL_TP_HOOK\|Hook mode: PURE' kernel/Kbuild kernel/hook/hook_manager.c | head
echo "=== extras/ksud still kprobe-only (should stay OFF) ==="
grep -c 'ifdef KSU_KPROBES_HOOK' kernel/extras.c kernel/runtime/ksud_integration.c
