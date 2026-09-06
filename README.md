# sre-debug-tooling

A troubleshooting image for Kubernetes services. You attach it to a running pod with `kubectl debug`, or you run it standalone, and it has the tools you would otherwise spend the first ten minutes of an incident wishing you had installed.

[Русская версия](README.ru.md)

## Why not just use netshoot

[`nicolaka/netshoot`](https://github.com/nicolaka/netshoot) is the baseline and it is a good one. This image exists because a debug image that belongs to you can carry things a public one cannot: a `kubectl` pinned to your cluster's minor version, clients for the datastores you actually run, your internal CA bundle, and versions that only move when you decide they move. Everything here is pinned by digest or sha256, so a rebuild six months from now produces the same image.

## Why Debian and not Alpine

glibc. Alpine ships musl, and musl resolves DNS differently from the glibc that most application images use: `ndots`, the search-domain walk and `/etc/nsswitch.conf` all behave differently. Debugging a resolution problem from a musl container is how you end up confidently fixing a bug the application does not have.

## Two variants

| Variant | Tag | Size | What it is for |
|---|---|---|---|
| slim | `ghcr.io/jtprogru/sre-debug-tooling:latest` | ~520 MB | Network, DNS, HTTP/gRPC, TLS, pod logs. Closes most incidents. |
| full | `ghcr.io/jtprogru/sre-debug-tooling:full-latest` | ~1.7 GB | Everything in slim plus kernel and disk tracing, load generation and datastore clients. |

Pull the image onto your nodes before you need it. A `full` image pulled for the first time during an incident costs you minutes you do not have — a DaemonSet with `sleep infinity`, or simply `imagePullPolicy: IfNotPresent` on a prewarmed node, pays for itself the first time.

## Quick start

Attach an ephemeral container to a running pod:

```bash
kubectl debug -n prod my-pod-abc123 -it \
  --image=ghcr.io/jtprogru/sre-debug-tooling:latest \
  --target=app -- bash
```

Or use the wrapper, which remembers the flags for you:

```bash
./hack/kdebug.sh pod prod my-pod-abc123 app   # ephemeral container, non-root
./hack/kdebug.sh net prod my-pod-abc123 app   # same, but root with NET_ADMIN/NET_RAW
./hack/kdebug.sh node worker-3                # privileged pod on a node
./hack/kdebug.sh run prod                     # throwaway standalone pod
```

A standalone pod that is admissible under Pod Security Admission `restricted`:

```bash
kubectl apply -n prod -f deploy/pod-debug.yaml
kubectl exec -n prod -it debug -- bash
```

## Two things that will bite you

**Capabilities.** The image runs as uid 1000. `tcpdump` without `CAP_NET_RAW` and `strace` without `CAP_SYS_PTRACE` will not work, and adding those capabilities to a non-root container does not help either — a process that is not uid 0 cannot use a capability that is merely permitted. Use `hack/kdebug.sh net`, or `--custom=deploy/profile-netadmin.yaml`, which sets `runAsUser: 0` along with the capabilities.

**What `--target` actually does.** Every container in a pod shares one network namespace, so an ephemeral container sees the pod's traffic whether or not you pass `--target`. What `--target` gives you is the process namespace and the target container's filesystem through `/proc/<pid>/root`. Without it, `ps` shows you an empty container and you conclude the application is not running.

## What is inside

Release binaries and their pinned versions live in [`hack/tools.list`](hack/tools.list), which is also copied into the image at `/usr/local/share/sre-debug-tooling/tools.list` so you can check from inside a pod what you are holding.

**Network, in slim:** `ip`, `ss` (iproute2), `ping`, `tracepath`, `traceroute`, `mtr`, `tcpdump`, `socat`, `nc`, `nmap`, `iperf3`, `ethtool`, `conntrack`, `nft`, `iptables`.

**DNS, in slim:** `dig`, `nslookup`, `host`, and `getent` from glibc. `getent` matters most: it is the only one that goes through the same path the application does, `nsswitch.conf` and `resolv.conf` included. `dig` talks to the nameserver directly and will happily disagree with the application.

**HTTP, gRPC and TLS, in slim:** `curl` with HTTP/2 and `--resolve`, `wget`, `openssl s_client`, `grpcurl`, `websocat`, `jq`, `yq`, and `oha` for load.

**Kubernetes, in slim:** `kubectl` and `stern`. In full: `k9s`, `helm`, `crictl`, `etcdctl`.

**Processes and performance:** `ps`, `htop`, `lsof`, `strace` in slim; `iostat`, `pidstat`, `sar`, `atop`, `gdb`, `bpftrace`, `readelf` in full.

**Disk:** `fio`, `ioping`, `ncdu`, `mount.nfs`, `mount.cifs`, all in full.

**Datastore clients, in full:** `psql`, `mysql`, `redis-cli`, `kcat`, `etcdctl`.

**JVM, in full:** `jattach`, for pulling a thread dump or a heap dump out of a JVM running in a neighbouring container.

Two deliberate omissions. `linux-perf` is not here: Debian builds it against the distro kernel, it almost never matches the node kernel, and a `perf` that silently reports nothing is worse than no `perf` at all. `mongosh` is not here either, because it needs MongoDB's own apt repository — add it if you run Mongo, and accept the extra supply-chain edge.

`bpftrace` is in `full`, but read the caveat: it needs a privileged container and BTF on the node. Without those it starts and then tells you nothing useful.

## Runbooks

Diagnostic playbooks, one scenario per file. They are generic on purpose — adapt the escalation and severity sections to your service.

- [DNS does not resolve](docs/en/runbooks/dns-resolution.md)
- [Connections hang or time out](docs/en/runbooks/connection-timeout.md)
- [A service returns 5xx](docs/en/runbooks/http-5xx.md)
- [TLS certificate errors](docs/en/runbooks/tls-cert.md)
- [A gRPC service does not answer](docs/en/runbooks/grpc-service.md)
- [Disk is slow](docs/en/runbooks/slow-disk.md)
- [A JVM has stopped responding](docs/en/runbooks/jvm-hang.md)

Russian versions live in [`docs/ru/runbooks/`](docs/ru/runbooks/).

## Building

```bash
make build      # both variants for the local architecture
make test       # smoke test both: every binary present, right arch, glibc resolver works
make lint       # hadolint + shellcheck
make scan       # trivy, fails on HIGH and CRITICAL
make size
```

`make push` builds `linux/amd64` and `linux/arm64` and pushes to `$REGISTRY/$IMAGE_REPO`. CI does the same on a push to `main` and on a `v*` tag.

`make scan` gates on OS packages that have a fix available, and nothing else. Most of this image by weight is upstream release binaries, and a Go stdlib CVE inside `kubectl` is fixed by Kubernetes rebuilding `kubectl` — failing your build on it teaches you to ignore the scanner. Those findings are still visible, in `make scan.report`, which never fails.

## Updating a pinned tool

Bump the version in `hack/tools.list`, then:

```bash
make refresh-checksums
make build test
```

`hack/tools.sha256` is generated, never hand-edited. If you skip the refresh, the build fails with a checksum mismatch and tells you to run it — which is the point.

These bumps are manual on purpose. An updater that only knows about upstream releases would drag `kubectl` to whatever shipped last week, and `kubectl` here has to follow your cluster rather than the newest tag — the skew policy is one minor version either side. Most of the rest costs nothing by being a release behind. What does need to move on its own is handled by [dependabot](.github/dependabot.yml): the base image digest, and the actions used in the workflow.

## A word on distributing this

The image contains `nmap`, `tcpdump` and a set of database clients. That is exactly what it is for, and it is also a ready-made toolkit for moving laterally through your cluster. Two consequences worth acting on: mirror the image into a private registry rather than pulling from a public one in production, and grant the right to create ephemeral containers per namespace through [`deploy/rbac-ephemeral.yaml`](deploy/rbac-ephemeral.yaml) instead of handing out `cluster-admin`. Whoever can debug a pod can read every secret that pod can read.
