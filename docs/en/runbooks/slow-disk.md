# Disk is slow

> **TL;DR:** `iostat -x 2 5` on the node. If `%util` is near 100 and `await` is high, the device is saturated; if `%util` is low and the application is still slow, the disk is not your problem.

## When to apply

Write latency in the application, a database reporting slow queries with no query-plan change, log flushes backing up, or a PVC that feels slower than it did last week.

## Fast diagnosis

Inside the pod, on the mounted volume:

```bash
df -h /data
ioping -c 20 /data
```

On the node, where the real numbers are:

```bash
./hack/kdebug.sh node <node>
```

```bash
iostat -x 2 5
pidstat -d 2 5
```

## What the answers mean

`%util` near 100 with `await` in the tens of milliseconds — the device is saturated. `pidstat -d` names the process doing it, and it is frequently not the application you were called about.

`%util` low, `await` low, application still slow — the storage is fine. Look at fsync patterns instead: a database committing per transaction on a network volume is latency-bound, not throughput-bound, and `iostat` will look idle.

`r_await` much higher than `w_await` — read amplification, usually a cache that no longer fits in memory.

Numbers that look fine but the cloud volume is throttled — check the volume's provisioned IOPS against what you are asking for. Burst credits that ran out look exactly like a disk that suddenly got slow, because that is what happened.

## Measuring properly

`fio` gives you a number you can compare. Run it against a file on the volume, never against the raw device:

```bash
fio --name=lat --filename=/data/fio-test --size=512M --bs=4k --rw=randread \
    --ioengine=libaio --iodepth=16 --direct=1 --runtime=30 --time_based --group_reporting
rm -f /data/fio-test
```

This consumes real IO on a volume that is already suspected of being slow. On a production volume during an incident, that is a decision to make deliberately, not a diagnostic reflex.

## Mitigation

Move the noisy neighbour before you resize anything — `pidstat -d` told you who it is. If the volume is throttled, growing it usually raises the IOPS ceiling with it, and that is faster than migrating. If a log volume filled up, `ncdu /data` finds the directory faster than `du` does.

## Root cause

A sidecar writing debug logs to the same volume. A backup job that overlaps peak traffic. Burst credits exhausted on a cloud volume sized for an average that no longer holds. A database whose working set outgrew page cache.

_Last updated: 2026-09-06_
