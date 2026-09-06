# A gRPC service does not answer

> **TL;DR:** `grpcurl -plaintext host:port list`. If that fails with `Unimplemented`, reflection is off and the service is probably fine — you are holding the wrong tool.

## When to apply

gRPC calls fail with `Unavailable`, `Unimplemented`, `DeadlineExceeded`, or a stream that closes immediately.

## Fast diagnosis

```bash
./hack/kdebug.sh pod <namespace> <pod> <container>
```

Plaintext, straight at the pod:

```bash
grpcurl -plaintext 10.244.3.17:9090 list
grpcurl -plaintext 10.244.3.17:9090 list my.package.Service
grpcurl -plaintext -d '{"id":"1"}' 10.244.3.17:9090 my.package.Service/GetThing
```

Over TLS, and through the Service:

```bash
grpcurl my-service.prod.svc.cluster.local:443 list
grpcurl -insecure my-service.prod.svc.cluster.local:443 list
```

With metadata, when the call needs auth:

```bash
grpcurl -plaintext -H 'authorization: Bearer <token>' host:9090 my.package.Service/GetThing
```

## What the answers mean

`Failed to list services: server does not support the reflection API` — the server is answering. Reflection is simply disabled, which is normal in production. Use the proto file:

```bash
grpcurl -plaintext -import-path ./proto -proto service.proto host:9090 list
```

`Unavailable: connection refused` or a timeout — this is a network problem, not a gRPC problem. Go to [connection-timeout](connection-timeout.md).

`Unavailable` with a TLS error in the message — you are speaking plaintext to a TLS port or the reverse. `-plaintext` for h2c, no flag for real TLS, `-insecure` for TLS you do not want to verify.

Works against the pod IP, fails through the Ingress — the ingress is not configured for gRPC. On ingress-nginx that is `nginx.ingress.kubernetes.io/backend-protocol: GRPC`; without it the controller downgrades to HTTP/1.1 and the stream dies.

Works for one method and not another — read the error message rather than the transport. `Unimplemented` on a single method usually means a version skew between client and server protos.

## Load

When the question is "is it slow or is it broken":

```bash
ghz --insecure --proto ./proto/service.proto --call my.package.Service/GetThing \
  -d '{"id":"1"}' -c 10 -n 500 host:9090
```

Run this against a canary or a staging endpoint. Load-testing a production service during an incident makes the incident worse.

## Root cause

Reflection disabled and the debugging assumption that it is on. h2c versus TLS mismatch at the Service or the ingress. `appProtocol` missing on the Service port so the mesh treats gRPC as opaque TCP and load-balances per connection instead of per request — which shows up as one backend taking all the traffic.

_Last updated: 2026-09-06_
