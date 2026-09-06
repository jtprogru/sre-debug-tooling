# Connections hang or time out

> **TL;DR:** check that the Service has ready endpoints before you touch anything else. An empty EndpointSlice explains most hanging connections.

## When to apply

The name resolves, but the connection hangs, times out, or is refused. Includes `context deadline exceeded`, `connection reset by peer` and clients stuck in `SYN_SENT`.

## Severity

SEV-2 when one dependency path is broken. SEV-1 if it is cluster-wide — check whether kube-proxy or the CNI is the common factor before you assume it is your service.

## Fast diagnosis

```bash
./hack/kdebug.sh pod <namespace> <pod> <container>
```

```bash
nc -zv my-service 8080
curl -sv --max-time 5 http://my-service:8080/healthz
ss -tnp state syn-sent
ss -s
```

From outside the pod:

```bash
kubectl -n <namespace> get endpointslices -l kubernetes.io/service-name=my-service -o wide
kubectl -n <namespace> get pods -l <selector> -o wide
kubectl -n <namespace> get networkpolicy
```

## What the answers mean

No addresses in the EndpointSlice — the Service selector matches nothing, or nothing is passing its readiness probe. Stop here, that is your answer.

Connection refused, immediately — something is listening on the node but not on that port, or nothing is listening at all. Check `targetPort` against the port the process actually binds:

```bash
ss -tlnp
```

Connection hangs with no response — a packet is being dropped. Capture on both sides. Attach with capabilities, since a non-root ephemeral container cannot capture:

```bash
./hack/kdebug.sh net <namespace> <client-pod> <container>
tcpdump -ni any -c 20 'tcp port 8080'
```

SYN going out and nothing coming back means the drop is in between: a NetworkPolicy, a security group, or a full conntrack table. SYN-ACK coming back but the application never sees it means the drop is local.

Conntrack:

```bash
conntrack -S | head
conntrack -C
cat /proc/sys/net/netfilter/nf_conntrack_max
```

`insert_failed` or `drop` counters climbing, or the count sitting at the maximum, is a real finding.

MTU, when large responses hang and small ones do not:

```bash
ping -M do -s 1400 my-service
ping -M do -s 1472 my-service
```

## Mitigation

If a NetworkPolicy is the cause, widen it deliberately rather than deleting it. If conntrack is full, raising `nf_conntrack_max` on the node buys time; the real fix is whatever is opening that many connections. If a single backend is bad, remove it from rotation by failing its readiness probe rather than deleting the pod, so you keep it for the postmortem.

## Root cause

Selector and label drift after a rename; readiness probes that never pass; `targetPort` pointing at the wrong container port; a NetworkPolicy added for one namespace that quietly denies another; conntrack exhaustion under retry storms; MTU mismatch after a CNI or VPN change.

_Last updated: 2026-09-06_
