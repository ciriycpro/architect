# 7. Форма развёртывания mail-stack: docker-friendly код + systemd

Date: 2026-05-12

## Status

Accepted

## Context

В [DEC-006](0006-reality-check-09052026.md) зафиксирована открытая развилка по форме развёртывания стека `mail-stack/` на coo. Рассматривались три варианта:

1. Чисто systemd (по образцу Agent Caller)
2. Сразу Docker через `docker-compose`
3. Гибрид

Дополнительный констрейн, выявленный при сверке 12.05.2026: на coo всего **1.9 ГБ RAM**, свободно ~900 МБ (N8N 325 МБ, Agent Caller, mail-service v1 39 МБ). Docker-overhead на каждый контейнер ~50-100 МБ. На 4 сервиса стека (`mail`, `attachment`, `parser`, `summary`) Docker накладные расходы — ~200-400 МБ только на overhead, плюс сами сервисы. Под Docker-режим RAM критически тесно.

Параллельно — стратегическое соображение: стек разрабатывается как прототип для будущего KAMF-продукта. Сервисы постепенно эволюционируют в агенты (накопление state, decision-making, autonomous retry), и тогда контейнеризация становится обязательной (изоляция, независимый рестарт, переносимость, версионность). Запирать стек в bare-metal systemd навсегда — нельзя.

## Decision

**Все сервисы `mail-stack/` пишутся в docker-friendly стиле**, но запускаются через **systemd на coo как v1 production**. Контейнеризация — отложена до триггеров.

### 7 правил docker-friendly кода

| # | Правило | Зачем |
|---|---|---|
| 1 | Конфиг через env-переменные (`os.getenv`) | Чтобы Docker-секреты прокидывались как `-e` без правки кода |
| 2 | Listen `0.0.0.0`, не `127.0.0.1` | Docker контейнер должен слушать наружный сетевой интерфейс |
| 3 | Логи только в stdout, без файлов | Docker сам собирает stdout |
| 4 | Healthcheck endpoint (`/health`) | Docker `HEALTHCHECK` директива опирается на него |
| 5 | `requirements.txt` с pinned версиями | Воспроизводимая сборка образа |
| 6 | Нет хардкода путей | Контейнер может монтировать что угодно куда угодно |
| 7 | Graceful shutdown (uvicorn умеет сам) | Docker отправляет SIGTERM при stop |

### Production-режим v1: systemd

Каждый сервис получает:
- Каталог `/opt/mail-stack/<service-name>/` с `server.py`, `requirements.txt`, `venv/`, `Dockerfile`, `.dockerignore`
- Env-файл `/etc/mail-stack/<service-name>.env` (chmod 600, root:root)
- Systemd-юнит `/etc/systemd/system/<service-name>.service` с `EnvironmentFile=...env`, `ExecStart=.../venv/bin/uvicorn server:app --host 127.0.0.1 --port <port>`

В production-режиме listen на 127.0.0.1 (доступ только с хоста). Это **не противоречит docker-friendly правилу №2** — в systemd-юните параметр `--host` указывается явно в `ExecStart`, и при запуске в Docker он перезаписывается на `0.0.0.0` через CMD в Dockerfile.

### Триггеры миграции на Docker

Переход на `docker-compose` инициируется при выполнении одного из:

(а) **Рост RAM-доступности.** coo переезжает на инстанс с ≥4 ГБ свободной RAM (e2-medium или больше)
(б) **Переезд на отдельный хост.** Стек выносится с coo на dedicated infra
(в) **Эволюция в агенты.** Один из сервисов накапливает собственное состояние (БД, кэш messageId, history) и требует isolated lifecycle — это сигнал что он стал агентом, и Docker обязателен

Любой из триггеров → пишется DEC о миграции с конкретным планом и сроком простоя.

## Consequences

**Плюсы:**
- Время на запуск сервиса в v1: ~10-15 минут (systemd-юнит)
- Память на сервис: ~40-50 МБ (вместо ~100-150 МБ в Docker)
- На 4 сервиса экономим ~200-400 МБ RAM
- Код одинаков для обоих режимов запуска — переключение тривиально
- Прецедент: Agent Caller уже работает по этому паттерну с 27.04.2026

**Минусы:**
- Network discovery между сервисами через 127.0.0.1:port, не по hostname. При переезде в Docker нужно будет менять конфиги (но это автоматизируется через env)
- Нет встроенной изоляции файловой системы между сервисами. Решается через систему прав linux
- Зависимость от глобальных пакетов хоста (Python 3.10). Решается через venv внутри каталога сервиса

**Валидация решения:** 12.05.2026 mail-service v1 запущен по этому паттерну. Сборка Dockerfile, тест в Docker (`mail-service:test` контейнер), переключение на systemd — проведены последовательно за один час. Smoke-test: `/health` отвечает, `/mail/since/2026-05-01` возвращает 14 писем, RAM 39 МБ, systemd `enabled+active`. Образец воспроизводим на следующих сервисах стека.

## Структура каталога одного сервиса

```
/opt/mail-stack/<service-name>/
├── server.py              # код сервиса (FastAPI app)
├── requirements.txt       # pinned зависимости
├── venv/                  # Python virtual environment
├── Dockerfile             # для будущей контейнеризации (готов, не используется в v1)
└── .dockerignore          # исключения для сборки образа

/etc/mail-stack/
└── <service-name>.env     # секреты (chmod 600, root:root)

/etc/systemd/system/
└── <service-name>.service # systemd-юнит, EnvironmentFile=/etc/mail-stack/<name>.env
```

## Шаблон systemd-юнита

```ini
[Unit]
Description=<Service Name> (mail-stack v1)
After=network.target

[Service]
Type=simple
User=iakshin77
Group=iakshin77
WorkingDirectory=/opt/mail-stack/<service-name>
EnvironmentFile=/etc/mail-stack/<service-name>.env
ExecStart=/opt/mail-stack/<service-name>/venv/bin/uvicorn server:app --host 127.0.0.1 --port <port>
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

---

## Implementation Notes — 23.06.2026 (bug-fix mail-service `_date_key`)

### Контекст инцидента

С 19.06.2026 по 23.06.2026 mail-service отвечал HTTP 500 на `GET /mail/since/{date}` для окна с 16.06. Workflow `email_digest_v1` падал на `step.fetch_mail` каждое утро в 07:00 UTC. `last_at` chat_id Таирова (1257818936) замёрз на `2026-06-16T07:00:00Z`.

### Корневая причина

В `_date_key` функции (`server.py` строка ~258) сравнение `datetime.fromisoformat(m['date'])` для сортировки. Большинство писем пришли от Mail.ru/Gmail с таймзоной (+0300, -0700) → aware datetime. Письмо `uid=3842` от `important@cloud.mail.ru` (Облако Mail, 18.06 10:59 UTC) пришло с `Date: Thu, 18 Jun 2026 10:59:11 -0000`. По RFC 2822 `-0000` означает "таймзона не сообщается специально"; `parsedate_to_datetime()` для `-0000` возвращает **naive datetime**. После `.isoformat()` строка без зоны → `fromisoformat` возвращает naive.

`all_messages.sort(key=_date_key, reverse=True)` пытается сравнить naive vs aware → `TypeError: can't compare offset-naive and offset-aware datetimes` → 500.

Long-tail bug — до 18.06 в окне Таирова не было писем с `-0000`.

### Решение

Однострочная нормализация после `datetime.fromisoformat`:

```python
def _date_key(m):
    try:
        dt = datetime.fromisoformat(m['date'].replace('Z', '+00:00'))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except Exception:
        return datetime.min.replace(tzinfo=timezone.utc)
```

Не меняет поведение для aware (большинство писем). Защищает от `-0000` и любых других naive в будущем (потенциально могут быть от самописных SMTP-клиентов, ботов).

### Связанные техдолги (не покрыты этим bug-fix)

- **Dedlock `SetLastAt(now)` под `if deliveredOK`** в orchestrator workflow `email_digest_v1`. После падения summary-service на 17-18.06 `last_at` не обновился, окно росло до конца недели, наслаивая ошибку naive→aware (B) на context overflow (A). Решение по dedlock — отдельной задачей в cleanup_backlog_v2.md (раздел 6.1).
- **Context overflow в summary-service** на длинных text-based PDF — решается через **DEC-0030** (summary-prep service).
