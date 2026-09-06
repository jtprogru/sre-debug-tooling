# DNS does not resolve

> **TL;DR:** run `getent hosts <name>` before `dig`. If `getent` fails and `dig` succeeds, the problem is `resolv.conf` and the search path, not CoreDNS.

## When to apply

The application reports `no such host`, `Name or service not known`, `UnknownHostException`, or resolution that works sometimes and not others.

Not applicable when the name resolves and the connection then hangs — that is [connection-timeout](connection-timeout.md).

## Severity

Usually SEV-2 when one service cannot reach a dependency, SEV-1 when CoreDNS itself is degraded and the whole cluster is affected. Adapt to your own scale.

## Fast diagnosis

Attach to the affected pod, not to a fresh one — the whole point is to see the resolver configuration the application sees:

```bash
./hack/kdebug.sh pod <namespace> <pod> <container>
```

```bash
cat /etc/resolv.conf
getent hosts my-service
getent hosts my-service.other-ns.svc.cluster.local
dig +search +short my-service
dig +short my-service.other-ns.svc.cluster.local @$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)
```

## What the answers mean

`getent` fails, `dig @nameserver` with the FQDN succeeds — the name is fine and CoreDNS is fine. Look at `search` and `ndots` in `resolv.conf`, and at whether the application is appending its own suffix.

Both fail with NXDOMAIN — the record does not exist. Check that the Service exists and has endpoints:

```bash
kubectl -n <namespace> get svc my-service
kubectl -n <namespace> get endpointslices -l kubernetes.io/service-name=my-service
```

A headless Service with no ready endpoints has no A records at all. That is not a DNS bug.

Both fail with SERVFAIL or time out — the resolver is the problem:

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=200
```

Resolution works but is slow — look at `ndots`. The default `ndots:5` means any name with fewer than five dots is tried against every entry in `search` first. `api.example.com` has two dots, so it collects four NXDOMAINs before the real query goes out. Confirm it:

```bash
dig +search +trace api.example.com | head -40
```

## Mitigation

Pin the name so the search path is skipped — a trailing dot makes it absolute:

```bash
curl -sv https://api.example.com./healthz
```

In the pod spec, lower `ndots` for workloads that mostly talk to the outside world:

```yaml
dnsConfig:
  options:
    - name: ndots
      value: "1"
```

If CoreDNS itself is unhealthy, restarting it is a mitigation, not a fix: `kubectl -n kube-system rollout restart deployment/coredns`. Do it knowing you lose the evidence.

## Root cause

Common causes, in the order they actually show up: a Service with no ready endpoints; the application appending a suffix so the FQDN ends up doubled; `ndots:5` plus a chatty client turning DNS into a latency problem; CoreDNS at its memory limit and being OOMKilled; conntrack UDP entries racing on parallel A and AAAA lookups, which shows as intermittent five-second stalls.

## After

If `ndots` was the cause, decide whether NodeLocal DNSCache belongs in the cluster rather than tuning it pod by pod.

_Last updated: 2026-09-06_
