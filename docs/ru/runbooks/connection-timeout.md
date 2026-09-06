# Коннект висит или отваливается по таймауту

> **TL;DR:** прежде чем трогать что-либо ещё, проверь, что у Service есть готовые endpoints. Пустой EndpointSlice объясняет большинство висящих коннектов.

## Когда применять

Имя резолвится, но соединение висит, отваливается по таймауту или получает refused. Сюда же `context deadline exceeded`, `connection reset by peer` и клиенты, застрявшие в `SYN_SENT`.

## Severity

SEV-2, когда сломан один путь до зависимости. SEV-1, если это кластерная история — проверь, не является ли общим знаменателем kube-proxy или CNI, прежде чем винить свой сервис.

## Быстрая диагностика

```bash
./hack/kdebug.sh pod <namespace> <pod> <container>
```

```bash
nc -zv my-service 8080
curl -sv --max-time 5 http://my-service:8080/healthz
ss -tnp state syn-sent
ss -s
```

Снаружи пода:

```bash
kubectl -n <namespace> get endpointslices -l kubernetes.io/service-name=my-service -o wide
kubectl -n <namespace> get pods -l <selector> -o wide
kubectl -n <namespace> get networkpolicy
```

## Что означают ответы

В EndpointSlice нет адресов — селектор Service ни во что не попадает, либо ничего не проходит readiness. Дальше можно не искать, это и есть ответ.

Connection refused сразу — на ноде что-то слушает, но не этот порт, либо не слушает ничего. Сверь `targetPort` с портом, на который процесс реально биндится:

```bash
ss -tlnp
```

Коннект висит без ответа — пакет где-то дропается. Снимай трафик с обеих сторон. Цепляйся с капабилитями, потому что non-root эфемерный контейнер снимать не сможет:

```bash
./hack/kdebug.sh net <namespace> <client-pod> <container>
tcpdump -ni any -c 20 'tcp port 8080'
```

SYN уходит, в ответ ничего — дроп посередине: NetworkPolicy, security group или переполненный conntrack. SYN-ACK возвращается, но приложение его не видит — дроп локальный.

Conntrack:

```bash
conntrack -S | head
conntrack -C
cat /proc/sys/net/netfilter/nf_conntrack_max
```

Растущие `insert_failed` или `drop`, либо счётчик, упершийся в максимум, — это находка, а не шум.

MTU, когда большие ответы висят, а маленькие проходят:

```bash
ping -M do -s 1400 my-service
ping -M do -s 1472 my-service
```

## Митигация

Если причина в NetworkPolicy, расширяй её осознанно, а не удаляй. Если забился conntrack, поднятие `nf_conntrack_max` на ноде купит время; чинить надо то, что открывает столько соединений. Если плох один backend, выводи его из ротации через readiness, а не удалением пода — под пригодится для постмортема.

## Root cause

Разъехавшиеся лейблы и селектор после переименования; readiness, который никогда не проходит; `targetPort`, смотрящий не на тот порт контейнера; NetworkPolicy, добавленная под один namespace и тихо запретившая другой; переполнение conntrack на retry-шторме; несовпадение MTU после смены CNI или VPN.

_Обновлено: 2026-09-06_
