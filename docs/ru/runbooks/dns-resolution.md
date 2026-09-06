# DNS не резолвится

> **TL;DR:** сначала `getent hosts <имя>`, только потом `dig`. Если `getent` падает, а `dig` отвечает — дело в `resolv.conf` и search-домене, а не в CoreDNS.

## Когда применять

Приложение пишет `no such host`, `Name or service not known`, `UnknownHostException`, или резолв работает через раз.

Не применяй, если имя резолвится, а коннект потом висит — это [connection-timeout](connection-timeout.md).

## Severity

Обычно SEV-2, когда один сервис не дотягивается до зависимости. SEV-1, если деградировал сам CoreDNS и задет весь кластер. Подставь свою шкалу.

## Быстрая диагностика

Цепляйся к тому поду, который сломан, а не к свежему — весь смысл в том, чтобы увидеть конфигурацию резолвера глазами приложения:

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

## Что означают ответы

`getent` падает, `dig @nameserver` с FQDN отвечает — с именем и с CoreDNS всё нормально. Смотри `search` и `ndots` в `resolv.conf`, а ещё проверь, не дописывает ли приложение свой суффикс поверх.

Оба падают с NXDOMAIN — записи просто нет. Проверь, что Service существует и у него есть endpoints:

```bash
kubectl -n <namespace> get svc my-service
kubectl -n <namespace> get endpointslices -l kubernetes.io/service-name=my-service
```

У headless Service без готовых endpoints A-записей нет вообще. Это не баг DNS.

Оба падают с SERVFAIL или по таймауту — проблема в резолвере:

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=200
```

Резолвится, но медленно — смотри `ndots`. Дефолтный `ndots:5` означает, что любое имя меньше чем с пятью точками сначала прогоняется по всем записям `search`. У `api.example.com` две точки, поэтому до настоящего запроса он собирает четыре NXDOMAIN. Проверить:

```bash
dig +search +trace api.example.com | head -40
```

## Митигация

Прибей имя так, чтобы search-домены не использовались. Точка в конце делает имя абсолютным:

```bash
curl -sv https://api.example.com./healthz
```

В спеке пода снизь `ndots` для нагрузок, которые ходят в основном наружу:

```yaml
dnsConfig:
  options:
    - name: ndots
      value: "1"
```

Если нездоров сам CoreDNS, рестарт — это митигация, а не фикс: `kubectl -n kube-system rollout restart deployment/coredns`. Делай понимая, что вместе с ним ты теряешь улики.

## Root cause

Частые причины, в порядке реальной встречаемости: Service без готовых endpoints; приложение дописывает суффикс и FQDN удваивается; `ndots:5` плюс болтливый клиент превращают DNS в проблему латентности; CoreDNS упирается в memory limit и его прибивает OOM; гонка UDP-записей в conntrack при параллельных A и AAAA запросах — выглядит как случайные пятисекундные залипания.

## После

Если причиной был `ndots`, решай не про один под, а про кластер: не пора ли ставить NodeLocal DNSCache.

_Обновлено: 2026-09-06_
