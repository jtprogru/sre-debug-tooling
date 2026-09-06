# TLS certificate errors

> **TL;DR:** `openssl s_client -connect host:443 -servername host` answers almost every certificate question in one command. Read the chain, the SAN list and the dates in that order.

## When to apply

`x509: certificate signed by unknown authority`, `certificate has expired`, `hostname mismatch`, `unable to get local issuer certificate`, or a TLS handshake that fails without a clear message.

## Severity

An expired production certificate is SEV-1 until traffic is served again. A certificate expiring in three days is SEV-4 and a ticket.

## Fast diagnosis

```bash
openssl s_client -connect api.example.com:443 -servername api.example.com </dev/null 2>&1 | head -40
```

Dates and subject alternative names:

```bash
openssl s_client -connect api.example.com:443 -servername api.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

Whether the chain validates against what this container trusts:

```bash
curl -sv --max-time 5 https://api.example.com/healthz 2>&1 | grep -E 'SSL|subject|issuer|expire'
```

## What the answers mean

`Verify return code: 21 (unable to verify the first certificate)` — the server is not sending its intermediate. Browsers often paper over this with cached intermediates; Go and Java clients do not. That is why "it works in my browser" and the service still fails.

`Verify return code: 19 (self signed certificate in certificate chain)` with an internal CA — the client does not trust your CA. Confirm by supplying it explicitly:

```bash
curl -sv --cacert /path/to/internal-ca.crt https://api.internal/healthz
```

SAN list does not contain the name you connected to — the certificate is for a different host. Common after a domain rename where only the ingress host changed.

Dates look wrong by hours — check clock skew on the node before you blame the certificate.

## Mitigation

If the certificate expired, reissue it. With cert-manager, the state is in the chain of objects, and the failure is almost always in the last one:

```bash
kubectl -n <namespace> get certificate,certificaterequest,order,challenge
kubectl -n <namespace> describe certificate my-cert | tail -30
```

A missing intermediate is fixed on the server side by serving the full chain, not on the client side by disabling verification. If you must unblock traffic first, say out loud that you are doing it and put the rollback in the incident channel.

## Root cause

Renewal automation that stopped and nobody noticed, because nothing alerts on it. A certificate replaced by hand without the intermediate. A new client library with a stricter default. An internal CA rotated without updating the trust bundle in every image.

## After

If there was no alert on expiry, that is the action item, not the certificate.

_Last updated: 2026-09-06_
