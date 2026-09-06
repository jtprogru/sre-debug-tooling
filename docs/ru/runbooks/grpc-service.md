# gRPC-сервис не отвечает

> **TL;DR:** `grpcurl -plaintext host:port list`. Если падает с `Unimplemented` — reflection просто выключен, и с сервисом, скорее всего, всё в порядке. Инструмент не тот.

## Когда применять

gRPC-вызовы падают с `Unavailable`, `Unimplemented`, `DeadlineExceeded` или стрим закрывается сразу.

## Быстрая диагностика

```bash
./hack/kdebug.sh pod <namespace> <pod> <container>
```

Plaintext, напрямую в под:

```bash
grpcurl -plaintext 10.244.3.17:9090 list
grpcurl -plaintext 10.244.3.17:9090 list my.package.Service
grpcurl -plaintext -d '{"id":"1"}' 10.244.3.17:9090 my.package.Service/GetThing
```

По TLS и через Service:

```bash
grpcurl my-service.prod.svc.cluster.local:443 list
grpcurl -insecure my-service.prod.svc.cluster.local:443 list
```

С метаданными, если вызов требует авторизации:

```bash
grpcurl -plaintext -H 'authorization: Bearer <token>' host:9090 my.package.Service/GetThing
```

## Что означают ответы

`Failed to list services: server does not support the reflection API` — сервер отвечает. Reflection просто выключен, и в проде это нормально. Работай через proto-файл:

```bash
grpcurl -plaintext -import-path ./proto -proto service.proto host:9090 list
```

`Unavailable: connection refused` или таймаут — это сетевая проблема, а не gRPC. Иди в [connection-timeout](connection-timeout.md).

`Unavailable` с TLS-ошибкой в тексте — ты говоришь plaintext в TLS-порт или наоборот. `-plaintext` для h2c, без флага для настоящего TLS, `-insecure` для TLS, который не хочешь проверять.

Работает по Pod IP, не работает через Ingress — ingress не настроен под gRPC. В ingress-nginx это `nginx.ingress.kubernetes.io/backend-protocol: GRPC`; без неё контроллер откатывается на HTTP/1.1 и стрим умирает.

Работает один метод и не работает другой — читай текст ошибки, а не транспорт. `Unimplemented` на отдельном методе обычно значит расхождение версий proto у клиента и сервера.

## Нагрузка

Когда вопрос звучит «оно медленное или сломанное»:

```bash
ghz --insecure --proto ./proto/service.proto --call my.package.Service/GetThing \
  -d '{"id":"1"}' -c 10 -n 500 host:9090
```

Гоняй это по канарейке или стенду. Нагрузочное тестирование прода во время инцидента делает инцидент хуже.

## Root cause

Выключенный reflection и предположение при отладке, что он включён. Рассогласование h2c и TLS на Service или на ingress. Отсутствующий `appProtocol` на порту Service: mesh считает gRPC обычным TCP и балансирует по соединениям, а не по запросам — снаружи это выглядит как один backend, забравший весь трафик.

_Обновлено: 2026-09-06_
