# A service returns 5xx

> **TL;DR:** ask the same question at three layers — pod IP, Service, Ingress — and the layer where the answer changes is the layer that is broken.

## When to apply

Clients get 500, 502, 503 or 504 from a service that is deployed and running.

## Severity

Scale with the share of traffic affected. A 502 on every request is SEV-1 or SEV-2; an elevated error rate that stays inside the error budget is SEV-3.

## Fast diagnosis

Get a pod IP and the Service address:

```bash
kubectl -n <namespace> get pods -l <selector> -o wide
kubectl -n <namespace> get svc my-service
```

Then, from the debug container, ask each layer the same question:

```bash
# 1. straight at the pod, bypassing everything
curl -sv --max-time 5 http://10.244.3.17:8080/healthz

# 2. through the Service
curl -sv --max-time 5 http://my-service.prod.svc.cluster.local:8080/healthz

# 3. through the Ingress, without depending on public DNS
curl -sv --max-time 5 --resolve api.example.com:443:10.0.0.10 https://api.example.com/healthz
```

## What the answers mean

Pod is fine, Service fails — load balancing is picking a backend that is not fine. Hit every pod IP in turn; one of them will differ.

Pod and Service are fine, Ingress fails — the controller is the problem: wrong backend port, a timeout shorter than the response, or a stale upstream. A 502 from the ingress with a healthy backend is almost always a protocol mismatch, TLS to a plaintext upstream or the other way round.

Every layer fails identically — it is the application. Go to the logs across all pods at once:

```bash
stern -n <namespace> -l <selector> --since 10m
```

And to the restart history, which the logs of the current process will not show you:

```bash
kubectl -n <namespace> get pods -l <selector> \
  -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,REASON:.status.containerStatuses[0].lastState.terminated.reason'
```

`OOMKilled` in that last column changes the investigation entirely.

## Mitigation

Roll back the deployment before you understand the cause — `kubectl -n <namespace> rollout undo deployment/my-service` — unless the previous version is known bad too. If one pod is the outlier, cordon it out of the Service by failing its readiness, and keep it for analysis. If the ingress timeout is too short, raising it is a mitigation and a lie you are telling yourself about the response time.

## Root cause

A dependency the service calls is timing out and the service turns that into a 500. A memory limit reached under a traffic shape that only appears at peak. A readiness probe that passes before the application can serve. An ingress annotation changed in an unrelated PR.

## After

If the 5xx came from a dependency timeout, check whether the service should be shedding load or serving degraded instead of returning 500.

_Last updated: 2026-09-06_
