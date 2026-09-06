# A JVM has stopped responding

> **TL;DR:** `jattach <pid> threaddump` from an ephemeral container with `--target`. You need the target's PID namespace and `SYS_PTRACE`, and it works without restarting anything.

## When to apply

A Java service is up, its process is alive, and it answers nothing: health checks time out, threads appear stuck, or CPU sits at 100% with no work getting done.

Do not restart it first. A restart destroys the only evidence that explains this.

## Fast diagnosis

Attach with the target's process namespace and enough privilege to attach to another process:

```bash
kubectl debug -n <namespace> <pod> -it \
  --image=ghcr.io/jtprogru/sre-debug-tooling:full-latest \
  --target=<container> \
  --custom=deploy/profile-sysadmin.yaml -- bash
```

Find the JVM and take a thread dump:

```bash
ps aux | grep -m1 '[j]ava'
jattach <pid> threaddump > /tmp/threads.txt
head -50 /tmp/threads.txt
```

Heap and GC state:

```bash
jattach <pid> jcmd GC.heap_info
jattach <pid> jcmd VM.flags
```

## What the answers mean

`ps` shows no java process — you forgot `--target`, and you are looking at the debug container's own process namespace. This is the single most common mistake here.

Many threads `BLOCKED` on the same monitor — lock contention. The stack at the top of the blocked set names the lock.

Many threads `WAITING` on a connection pool — the pool is exhausted, and the real problem is downstream. Take the dependency's latency, not the JVM's.

Threads in `RUNNABLE` doing socket reads — the JVM is waiting on the network and is not hung at all.

`GC.heap_info` showing old gen at capacity with high GC time — the JVM is alive but spending all of it collecting. Confirm against the container's memory limit before you conclude it is a leak.

## Getting a heap dump out

A heap dump stops the JVM for the duration and can be gigabytes. Do it when you have decided the diagnosis is worth the pause:

```bash
jattach <pid> dumpheap /tmp/heap.hprof
ls -lh /tmp/heap.hprof
```

Ephemeral containers do not support `kubectl cp`, so copy through the target container's filesystem or write the dump to a mounted volume in the first place.

## Mitigation

Once you have the thread dump, restarting is a legitimate mitigation and you now have the evidence. If a connection pool is exhausted, raising it hides the downstream problem for exactly as long as it takes to fill again.

## Root cause

A downstream dependency that stopped answering and a client with no timeout. A synchronized block on a hot path. A heap sized above the container memory limit, so the JVM gets OOMKilled by the kernel before it ever throws `OutOfMemoryError`.

_Last updated: 2026-09-06_
