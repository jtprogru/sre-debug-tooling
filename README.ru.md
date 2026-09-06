# sre-debug-tooling

Образ для траблшутинга сервисов в Kubernetes. Подцепляешь его к живому поду через `kubectl debug` или поднимаешь отдельно, и в нём уже лежит то, об установке чего ты обычно жалеешь первые десять минут инцидента.

[English version](README.md)

## Почему не просто netshoot

[`nicolaka/netshoot`](https://github.com/nicolaka/netshoot) — хороший baseline, и отталкиваться стоит от него. Этот образ существует потому, что свой debug-образ может нести то, чего публичный не может: `kubectl` под минорную версию твоего кластера, клиенты тех баз, которые у тебя реально крутятся, внутренний CA bundle и версии, которые двигаются только тогда, когда ты решил их двинуть. Здесь всё запинено по digest или sha256, так что пересборка через полгода даёт тот же самый образ.

## Почему Debian, а не Alpine

Из-за glibc. В Alpine musl, и он резолвит DNS иначе, чем glibc в большинстве прикладных образов: `ndots`, обход search-доменов и `/etc/nsswitch.conf` ведут себя по-другому. Разбирать проблему резолва из musl-контейнера — верный способ уверенно починить баг, которого у приложения нет.

## Два варианта

| Вариант | Тег | Размер | Для чего |
|---|---|---|---|
| slim | `ghcr.io/jtprogru/sre-debug-tooling:latest` | ~520 МБ | Сеть, DNS, HTTP/gRPC, TLS, логи подов. Закрывает большинство инцидентов. |
| full | `ghcr.io/jtprogru/sre-debug-tooling:full-latest` | ~1.7 ГБ | Всё из slim плюс трассировка ядра и диска, генерация нагрузки, клиенты хранилищ. |

Затащи образ на ноды до того, как он понадобится. `full`, который тянется впервые во время инцидента, стоит тебе тех минут, которых у тебя нет. DaemonSet со `sleep infinity` или просто `imagePullPolicy: IfNotPresent` на прогретой ноде окупаются в первый же раз.

## Быстрый старт

Эфемерный контейнер в живом поде:

```bash
kubectl debug -n prod my-pod-abc123 -it \
  --image=ghcr.io/jtprogru/sre-debug-tooling:latest \
  --target=app -- bash
```

Или через обёртку, которая помнит флаги за тебя:

```bash
./hack/kdebug.sh pod prod my-pod-abc123 app   # эфемерный контейнер, non-root
./hack/kdebug.sh net prod my-pod-abc123 app   # то же, но root с NET_ADMIN/NET_RAW
./hack/kdebug.sh node worker-3                # привилегированный под на ноде
./hack/kdebug.sh run prod                     # одноразовый отдельный под
```

Отдельный под, проходящий Pod Security Admission `restricted`:

```bash
kubectl apply -n prod -f deploy/pod-debug.yaml
kubectl exec -n prod -it debug -- bash
```

## Две вещи, на которых ты обожжёшься

**Капабилити.** Образ работает под uid 1000. `tcpdump` без `CAP_NET_RAW` и `strace` без `CAP_SYS_PTRACE` работать не будут, и просто добавить капабилити в non-root контейнер тоже не поможет: процесс не под uid 0 не может воспользоваться капабилити, которая лежит только в permitted. Используй `hack/kdebug.sh net` или `--custom=deploy/profile-netadmin.yaml` — он выставляет `runAsUser: 0` вместе с капабилити.

**Что на самом деле делает `--target`.** Все контейнеры пода живут в одном сетевом namespace, поэтому эфемерный контейнер видит трафик пода независимо от того, передал ты `--target` или нет. `--target` даёт другое: PID namespace и файловую систему целевого контейнера через `/proc/<pid>/root`. Без него `ps` покажет тебе пустой контейнер, и ты сделаешь вывод, что приложение не запущено.

## Что внутри

Release-бинари и их запиненные версии лежат в [`hack/tools.list`](hack/tools.list). Тот же файл кладётся в образ по пути `/usr/local/share/sre-debug-tooling/tools.list`, чтобы прямо из пода можно было посмотреть, что у тебя в руках.

**Сеть, в slim:** `ip`, `ss` (iproute2), `ping`, `tracepath`, `traceroute`, `mtr`, `tcpdump`, `socat`, `nc`, `nmap`, `iperf3`, `ethtool`, `conntrack`, `nft`, `iptables`.

**DNS, в slim:** `dig`, `nslookup`, `host` и `getent` из glibc. Важнее всего `getent`: он единственный ходит тем же путём, что и приложение, вместе с `nsswitch.conf` и `resolv.conf`. `dig` бьёт в nameserver напрямую и с удовольствием разойдётся с приложением в показаниях.

**HTTP, gRPC и TLS, в slim:** `curl` с HTTP/2 и `--resolve`, `wget`, `openssl s_client`, `grpcurl`, `websocat`, `jq`, `yq` и `oha` для нагрузки.

**Kubernetes, в slim:** `kubectl` и `stern`. В full: `k9s`, `helm`, `crictl`, `etcdctl`.

**Процессы и производительность:** `ps`, `htop`, `lsof`, `strace` в slim; `iostat`, `pidstat`, `sar`, `atop`, `gdb`, `bpftrace`, `readelf` в full.

**Диск:** `fio`, `ioping`, `ncdu`, `mount.nfs`, `mount.cifs` — всё в full.

**Клиенты хранилищ, в full:** `psql`, `mysql`, `redis-cli`, `kcat`, `etcdctl`.

**JVM, в full:** `jattach`, чтобы снять thread dump или heap dump с JVM в соседнем контейнере.

Два сознательных пропуска. `linux-perf` здесь нет: Debian собирает его под дистрибутивное ядро, с ядром ноды оно почти никогда не совпадает, а `perf`, который молча ничего не показывает, хуже, чем его отсутствие. `mongosh` тоже нет, потому что он требует собственного apt-репозитория MongoDB — добавь, если у тебя Mongo, приняв лишнее звено в цепочке поставки.

`bpftrace` в `full` есть, но с оговоркой: ему нужен привилегированный контейнер и BTF на ноде. Без этого он стартует и не рассказывает ничего полезного.

## Рунбуки

Диагностические плейбуки, один сценарий на файл. Они намеренно generic — секции про severity и эскалацию подставь под свой сервис.

- [Не резолвится DNS](docs/ru/runbooks/dns-resolution.md)
- [Коннект висит или таймаутит](docs/ru/runbooks/connection-timeout.md)
- [Сервис отдаёт 5xx](docs/ru/runbooks/http-5xx.md)
- [Ошибки TLS-сертификата](docs/ru/runbooks/tls-cert.md)
- [gRPC-сервис не отвечает](docs/ru/runbooks/grpc-service.md)
- [Медленный диск](docs/ru/runbooks/slow-disk.md)
- [JVM перестала отвечать](docs/ru/runbooks/jvm-hang.md)

Английские версии — в [`docs/en/runbooks/`](docs/en/runbooks/).

## Сборка

```bash
make build      # оба варианта под локальную архитектуру
make test       # smoke-тест обоих: бинари на месте, архитектура та, резолвер glibc работает
make lint       # hadolint + shellcheck
make scan       # trivy, падает на HIGH и CRITICAL
make size
```

`make push` собирает `linux/amd64` и `linux/arm64` и пушит в `$REGISTRY/$IMAGE_REPO`. CI делает то же самое на push в `main` и на тег `v*`.

`make scan` блокирует сборку только на пакетах ОС, для которых есть фикс. По весу образ — это в основном upstream-бинари, и CVE в Go stdlib внутри `kubectl` чинится тем, что Kubernetes пересоберёт `kubectl`. Падать на этом — способ приучить себя игнорировать сканер. Такие находки никуда не деваются, они в `make scan.report`, который никогда не падает.

## Как обновить запиненный инструмент

Подними версию в `hack/tools.list`, затем:

```bash
make refresh-checksums
make build test
```

`hack/tools.sha256` генерируется, руками его не правят. Пропустишь refresh — сборка упадёт на несовпадении чексуммы и сама скажет, что запустить. В этом и смысл. Renovate заводит PR с бампом версии и вешает лейбл `needs-refresh-checksums`; пересчитать чексуммы за тебя он не может.

## Про распространение этого образа

Внутри `nmap`, `tcpdump` и набор клиентов к базам. Ровно для этого образ и нужен, и ровно это же — готовый набор для латерального движения по кластеру. Два вывода, с которыми стоит что-то сделать: зеркаль образ в приватный registry, а не тяни в проде из публичного, и раздавай право создавать эфемерные контейнеры по namespace через [`deploy/rbac-ephemeral.yaml`](deploy/rbac-ephemeral.yaml), а не через `cluster-admin`. Кто может дебажить под, тот читает все секреты, доступные этому поду.
