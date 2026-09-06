# Сервис отдаёт 5xx

> **TL;DR:** задай один и тот же вопрос на трёх уровнях — Pod IP, Service, Ingress. Слой, на котором ответ меняется, и есть сломанный.

## Когда применять

Клиенты получают 500, 502, 503 или 504 от задеплоенного и работающего сервиса.

## Severity

По доле затронутого трафика. 502 на каждом запросе — SEV-1 или SEV-2; повышенный error rate, укладывающийся в error budget, — SEV-3.

## Быстрая диагностика

Возьми Pod IP и адрес Service:

```bash
kubectl -n <namespace> get pods -l <selector> -o wide
kubectl -n <namespace> get svc my-service
```

Дальше из debug-контейнера спрашивай каждый слой об одном и том же:

```bash
# 1. напрямую в под, мимо всего
curl -sv --max-time 5 http://10.244.3.17:8080/healthz

# 2. через Service
curl -sv --max-time 5 http://my-service.prod.svc.cluster.local:8080/healthz

# 3. через Ingress, не завися от публичного DNS
curl -sv --max-time 5 --resolve api.example.com:443:10.0.0.10 https://api.example.com/healthz
```

## Что означают ответы

Под отвечает, Service — нет. Балансировка попадает в плохой backend. Пройди по всем Pod IP по очереди, один из них будет отличаться.

Под и Service отвечают, Ingress — нет. Проблема в контроллере: не тот backend-порт, таймаут короче ответа, протухший upstream. 502 от ingress при живом backend почти всегда означает рассогласование протокола: TLS в plaintext-upstream или наоборот.

Все три слоя падают одинаково — это приложение. Иди в логи сразу по всем подам:

```bash
stern -n <namespace> -l <selector> --since 10m
```

И в историю рестартов, которую логи текущего процесса не покажут:

```bash
kubectl -n <namespace> get pods -l <selector> \
  -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,REASON:.status.containerStatuses[0].lastState.terminated.reason'
```

`OOMKilled` в последней колонке полностью меняет направление расследования.

## Митигация

Откати деплой раньше, чем поймёшь причину: `kubectl -n <namespace> rollout undo deployment/my-service`. Если предыдущая версия тоже известно плохая — не откатывай. Если выбивается один под, выведи его из Service через readiness и оставь для анализа. Если таймаут на ingress слишком короткий, поднять его — митигация и одновременно способ соврать себе про время ответа.

## Root cause

Зависимость, в которую ходит сервис, отвечает по таймауту, а сервис превращает это в 500. Memory limit, до которого дотягивается только пиковый профиль трафика. Readiness, который проходит раньше, чем приложение готово обслуживать. Аннотация ingress, изменённая в постороннем PR.

## После

Если 5xx пришли из таймаута зависимости, реши: не должен ли сервис сбрасывать нагрузку или отдавать деградированный ответ вместо 500.

_Обновлено: 2026-09-06_
