"""The Slack drafts gate's scheduling priority (claude-config#2918), loaded by slack_drafts_only_gate.py.

WHY. The gate judges a call within an 11 second budget. On 2026-11-16, on the personal MacBook (8
performance cores, 4 efficiency cores), a cold judgement of `bash tests/test-claude-sync.sh` took 4.2
to 4.5 s on the performance cores, even beside other sessions' full suites, and 11.2 to 11.8 s on the
efficiency cores, where 2 of 4 runs passed the budget and the call was refused. Claude Code starts
the gate at the legacy level (kernel base priority 31), the same level every session's suites run at,
so when those fill the performance cores the scheduler moves the gate to an efficiency core. Dan chose
(2026-11-16) to raise the gate's QoS, a scheduling change and not a cut in the work.

HOW, as measured on that Mac (macOS 26, Python 3.14). Asking for user initiated alone is accepted
(pthread_set_qos_class_self_np returns 0) and changes nothing: the base priority stays 31, because XNU
squashes user initiated and user interactive to legacy for a task with no application role, which is
what a command line process has. So the gate first takes the default application role
(task_policy_set, TASK_CATEGORY_POLICY, TASK_DEFAULT_APPLICATION, both in the SDK's
mach/task_policy.h), then asks for user initiated: base priority 37, above every legacy thread, which
the scheduler keeps on a performance core while one is free of higher work. User initiated rather than
user interactive: a person is waiting on the answer, but it is not drawing frames. The role and the
level last only as long as this process, which ends with the judgement.

A QoS clamp (taskpolicy -c, a throttled or background parent) is a ceiling nothing inside the process
can lift: measured, the base priority stays 20 under a utility clamp and 4 under a background one
after both calls. So the level is never taken from what was asked: it is read back from the kernel
(proc_pidinfo, PROC_PIDTHREADID64INFO) and reported as it is.

Nothing here may stop the gate judging: every failure is reported in the line raise_qos returns, which
the gate traces and puts in a refusal for running out of time, and the judgement goes on at whatever
level it has.
"""

import ctypes
import os
import sys

QOS_CLASS_USER_INITIATED = 0x19
TASK_CATEGORY_POLICY = 1
TASK_DEFAULT_APPLICATION = 7
PROC_PIDTHREADID64INFO = 15
# The base priority of a legacy (default QoS) thread, the level the gate starts at and the level XNU
# squashes user initiated to for a task with no application role. A reading above it is a raise held.
LEGACY_PRIORITY = 31


class _ThreadInfo(ctypes.Structure):
    # struct proc_threadinfo, sys/proc_info.h
    _fields_ = [("pth_user_time", ctypes.c_uint64), ("pth_system_time", ctypes.c_uint64),
                ("pth_cpu_usage", ctypes.c_int32), ("pth_policy", ctypes.c_int32),
                ("pth_run_state", ctypes.c_int32), ("pth_flags", ctypes.c_int32),
                ("pth_sleep_time", ctypes.c_int32), ("pth_curpri", ctypes.c_int32),
                ("pth_priority", ctypes.c_int32), ("pth_maxpriority", ctypes.c_int32),
                ("pth_name", ctypes.c_char * 64)]


def _base_priority(libc):
    """The kernel's base priority of the calling thread, or None where it cannot be read."""
    libc.pthread_threadid_np.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint64)]
    libc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    tid = ctypes.c_uint64()
    if libc.pthread_threadid_np(None, ctypes.byref(tid)) != 0:
        return None
    info = _ThreadInfo()
    got = libc.proc_pidinfo(os.getpid(), PROC_PIDTHREADID64INFO, tid.value, ctypes.byref(info), ctypes.sizeof(info))
    return info.pth_priority if got == ctypes.sizeof(info) else None


def raise_qos():
    """Raise the calling thread to user initiated. Returns (held, line): whether the kernel now runs it
    above the legacy level, and a line saying the level it really runs at and, if not raised, why."""
    if sys.platform != "darwin":
        return False, "qos: not raised: not macOS"
    try:
        libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        task = ctypes.c_uint.in_dll(libc, "mach_task_self_").value
        libc.task_policy_set.argtypes = [ctypes.c_uint, ctypes.c_int, ctypes.POINTER(ctypes.c_int), ctypes.c_uint]
        libc.pthread_set_qos_class_self_np.argtypes = [ctypes.c_uint, ctypes.c_int]
        role = ctypes.c_int(TASK_DEFAULT_APPLICATION)
        rc_role = libc.task_policy_set(task, TASK_CATEGORY_POLICY, ctypes.byref(role), 1)
        rc_qos = libc.pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
        base = _base_priority(libc)
    except Exception as e:  # reported, never fatal: the judgement goes on at the level it has
        return False, f"qos: not raised: {type(e).__name__} {e}"[:200]
    level = f"base priority {base if base is not None else 'unread'}"
    if base is not None and base > LEGACY_PRIORITY:
        return True, f"qos: user-initiated, {level}"
    why = []
    if rc_role != 0:
        why.append(f"the application role was refused ({rc_role})")
    if rc_qos != 0:
        why.append(f"user initiated was refused ({rc_qos})")
    if not why:
        why.append("the level did not rise (a QoS clamp, which nothing inside a process can lift)"
                   if base is not None else "the level could not be read back")
    return False, f"qos: not raised: {', '.join(why)}, {level}"
