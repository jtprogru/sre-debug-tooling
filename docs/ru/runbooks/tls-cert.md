# Ошибки TLS-сертификата

> **TL;DR:** `openssl s_client -connect host:443 -servername host` закрывает почти любой вопрос про сертификат одной командой. Читай в порядке: цепочка, SAN, даты.

## Когда применять

`x509: certificate signed by unknown authority`, `certificate has expired`, `hostname mismatch`, `unable to get local issuer certificate` — или handshake, падающий без внятного сообщения.

## Severity

Протухший продовый сертификат — SEV-1, пока трафик не пошёл. Сертификат, который истекает через три дня, — SEV-4 и тикет.

## Быстрая диагностика

```bash
openssl s_client -connect api.example.com:443 -servername api.example.com </dev/null 2>&1 | head -40
```

Даты и SAN:

```bash
openssl s_client -connect api.example.com:443 -servername api.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

Проходит ли цепочка проверку тем, чему доверяет этот контейнер:

```bash
curl -sv --max-time 5 https://api.example.com/healthz 2>&1 | grep -E 'SSL|subject|issuer|expire'
```

## Что означают ответы

`Verify return code: 21 (unable to verify the first certificate)` — сервер не отдаёт промежуточный сертификат. Браузеры это замазывают закешированными интермедиатами, Go и Java — нет. Отсюда и берётся «в браузере же открывается», пока сервис лежит.

`Verify return code: 19 (self signed certificate in certificate chain)` с внутренним CA — клиент не доверяет твоему CA. Проверь, подсунув его явно:

```bash
curl -sv --cacert /path/to/internal-ca.crt https://api.internal/healthz
```

В SAN нет имени, на которое ты подключался — сертификат выписан на другой хост. Классика после переименования домена, когда поменяли только host в Ingress.

Даты разъезжаются на часы — проверь clock skew на ноде, прежде чем винить сертификат.

## Митигация

Истёк — перевыпускай. С cert-manager состояние размазано по цепочке объектов, и ломается почти всегда последний:

```bash
kubectl -n <namespace> get certificate,certificaterequest,order,challenge
kubectl -n <namespace> describe certificate my-cert | tail -30
```

Отсутствующий интермедиат чинится на сервере отдачей полной цепочки, а не на клиенте отключением проверки. Если надо разблокировать трафик прямо сейчас — скажи это вслух и положи в канал инцидента план отката.

## Root cause

Автопродление, которое встало, и никто не заметил, потому что на это нет алерта. Сертификат, заменённый руками без интермедиата. Новая версия клиентской библиотеки со строгим дефолтом. Ротация внутреннего CA без обновления trust bundle во всех образах.

## После

Если алерта на истечение не было — вот это и есть action item, а не сам сертификат.

_Обновлено: 2026-09-06_
