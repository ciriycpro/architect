# DEC-014 — Orchestrator: Go custom v1 → Temporal headless v2 → KAMF v3

## Status

Accepted (13.05.2026, refreshed 2026-05-25). **v1.0 Implemented 13.05.2026 (15:13-15:57 UTC, ~45 минут)**. **v1.1 Implemented 13.05.2026 (вечер)** — Telegram-кнопка через Agent Caller callback + Multi-mailbox в mail-service + product-grade WA-skip для on-demand workflow. v2 (Temporal) и v3 (KAMF) — открытые направления с явными триггерами и обоснованием.

## Context

Mail-stack v1 — 4 production-сервиса (mail, attachment, parser, summary) на coo через systemd, общающихся по HTTP через localhost. Для **демонстрации работающего продукта Таирову вечером 13.05.2026** и для дальнейшей эксплуатации нужен **оркестратор** — компонент, который:

1. Запускает workflow по расписанию (`Schedule: 09:00 MSK ежедневно`)
2. Принимает on-demand-вызовы через Webhook (от Telegram-кнопки «Проверить почту»)
3. Координирует цепочку микросервисов: mail → attachment → parser → summary → telegram + sheets
4. Обрабатывает ошибки (retry на сетевых сбоях, fallback при недоступности LLM)
5. Логирует ход выполнения для отладки и compliance

**Долгосрочно** mail-stack должен стать **первой production-имплементацией KAMF** — собственного multi-agent framework, депонированного в Роспатент (свидетельство ПЭО № 2026611550). KAMF включает в себя StateGraph orchestration (LangGraph-inspired), A2A protocol, Kafka exactly-once streaming, OpenTelemetry tracing, distributed coordination mechanisms.

**Промежуточно** для прохождения 115-ФЗ compliance audit нужен **durable execution + structured audit log + replay**. KAMF на момент 13.05.2026 — это **архитектура + драфты кода**, не скомпилированный production-runtime. До работоспособного KAMF может пройти от месяца до квартала.

Между «Go custom v1» и «KAMF v3» нужен **промежуточный production-grade durable runtime** — это **Temporal** (open source, MIT, self-hosted на Docker, без Web UI для compliance).

### Архитектурные принципы определившие подход

**LLM-native development.** В команде из одного разработчика + AI-напарника (Claude) **код в git = единственный источник контекста для следующих сессий**. Когда workflow живёт в UI N8N — LLM при каждой сессии должен **пересказывать** ему как устроена логика, не может **прочитать** её. Это **фундаментальное архитектурное ограничение** для эпохи AI-collaborative development. Решение: **всё критичное — в git, не в визуальном редакторе.** Это принцип нового времени, не просто «удобство».

**Полиглот-стек как senior-pattern.** Сознательное решение использовать разные языки для разных слоёв:
- **Python 3.10/3.11** — микросервисы AI/ML (mail, attachment, parser, summary) — где экосистема LLM/vision/ML библиотек оптимальна
- **Go 1.21+** — оркестратор (DEC-014) — где goroutines + stdlib net/http + memory footprint критичны для конкурентной HTTP-coordination
- **Node.js** — Agent Caller (DEC-005) — для Telegram Bot API и веб-хуков (исторически, не пересматривать)

Это **archetype enterprise AI Architect**, не «один-язык-fit-all». Каждый язык выбран **по силе для слоя**, не «привычка».

**Память по канону (двухуровневая).** Архитектурный принцип на горизонте всех будущих ADR:
- **Hot path: Redis** — last_check_timestamp, current workflow state, dedup IDs, кэши TTL минут-часов
- **Warm path: Postgres** — audit log, история обработки, user preferences, контрагенты, метрики
- **Cold path: GCS + Postgres refs** — архив документов, backup attachments, compliance evidence (срок ПДн по 152-ФЗ)

State-service как отдельный микросервис на v2 (DEC-021). На v1 orchestrator — stateless.

**No Web UI как принцип security.** Все production runtime используются **headless**:
- Orchestrator v1 — только REST endpoints, никакого UI
- Temporal v2 — headless, без Web UI (tctl + API доступ для аудита)
- KAMF v3 — без UI до v3+

Аргумент: **меньше attack surface для 115-ФЗ compliance**, скрипты вместо human-clicks для audit log выгрузки.

Поэтому **стратегия — трёхшаговая эволюция**:

```
v1 (сегодня)      → Go-custom orchestrator
v2 (3-4 недели)   → Temporal headless (когда нужен durable execution + 115-ФЗ audit log)
v3 (3-6 месяцев)  → KAMF runtime с StateGraph (когда фреймворк скомпилирован)
```

**Ключевое:** каждый шаг **переиспользует 80%+ кода** предыдущего. Это **не три снос-и-перепиши**, а **эволюция со сменой runtime под тем же бизнес-кодом**.

## Decision

Реализовать **Go-custom orchestrator v1** прямо сегодня (~3 часа до production), с явной декомпозицией кода под будущие миграции на Temporal (v2) и KAMF (v3).

### Альтернативы (рассмотрены и отвергнуты)

**1. N8N — workflow в UI.**
- Плюсы: быстро (1 час до demo), визуальный
- Минусы:
  - Логика заперта в UI, не в git → LLM-напарник не имеет контекста (фундаментальное противоречие принципу LLM-native development)
  - Дебаг сложнее (как показал опыт DEC-006 — кампания «Документовед-Франкенштейн»)
  - 296 МБ RAM на 1 workflow
  - Структурированный audit log отсутствует
  - 115-ФЗ требует formalized audit log — N8N не дотягивает
  - Миграция позже = переписывание с нуля (логика заперта в UI)
- **TCO-расчёт N8N сегодня vs Go сразу:**
  - N8N сегодня: 1 час кодинга
  - Миграция N8N → Go через 1-2 недели: 5-9 часов (если за неделю добавим Mail Check On-Demand + multi-account — то ближе к 9)
  - **Итого N8N path: 6-10 часов**
  - **Альтернатива Go сразу: 3 часа**
  - **Чистая экономия Go-сразу: 3-7 часов** + избегание психологической резистентности к переписыванию рабочего
- **Отвергнуто.** Объяснено детально в DEC-006 и обсуждении 13.05.2026.

**2. Apache Airflow — DAG-based pipeline platform.**
- Плюсы: индустриальный стандарт для document/data pipelines, архитектурное обоснование
- Минусы:
  - 500+ МБ RAM (worker + scheduler + webserver + Postgres + Redis для Celery)
  - DAG-парадигма для batch jobs, не для webhook-driven workflows
  - Over-engineering для 4-сервисного стека
  - Airflow в нашем сетапе — over-investment в инструмент data engineering при отсутствии batch ETL-нагрузки
- **Отложено на v3** для ML/data pipelines (training classifier, fine-tuning) когда появятся реальные batch jobs. Не для оркестрации mail-stack.

**3. Custom Python orchestrator (asyncio).**
- Плюсы: один язык со всем стеком (Python в микросервисах)
- Минусы:
  - **Полиглот-сигнал важнее** монолитности — Python AI/ML + Go infrastructure = senior-pattern
  - AsyncIO Python менее идиоматичен чем Go goroutines для конкурентных HTTP-вызовов
  - GIL ограничивает CPU-intensive coordination logic
- **Отвергнуто.** Go подходит лучше для этой роли.

**4. Temporal сразу на v1.**
- Плюсы: production-grade durable execution с первого дня
- Минусы:
  - Не успеваем к демо вечером 13.05 (требуется ~6-8 часов: инфраструктура + Temporal SDK + переписать на workflow-парадигму)
  - Внедрение Temporal SDK требует предварительного прототипирования workflow-парадигмы — не успеваем к демо
- **Отложено на v2.** Триггер — реальная необходимость durable execution (regulatory audit, 5+ workflow, recovery после рестарта).

**5. KAMF сразу на v1.**
- Плюсы: проприетарный framework, прямой путь к target architecture
- Минусы:
  - KAMF не скомпилирован, в статусе архитектуры и драфтов кода (свидетельство ПЭО, не работающее ПО)
  - Доводка KAMF до production = месяц-квартал работы
- **Отложено на v3.** Триггер — KAMF в рабочем состоянии + 115-ФЗ требует **свой** runtime, не платформенный.

### Решение — Go custom v1

**Стек:**
- **Go 1.21+** (используется stdlib `slog` для structured logs)
- **Стандартная библиотека `net/http`** для HTTP-сервера и клиента
- **`robfig/cron/v3`** для schedule
- **`caarlos0/env/v10`** для env-конфига (типизированный, idiomatic)
- **`stretchr/testify`** для тестов

**Никаких тяжёлых фреймворков.** Минимум зависимостей — проще миграция.

**Complexity budget v1:** 800-1000 строк Go. Если упираемся в этот бюджет — это **сигнал что архитектурно что-то не так**, не «пишем больше кода». Над-инженерство в v1 = более тяжёлая миграция на Temporal/KAMF. Принцип «**достаточная сложность для v1**, не больше».

**Декомпозиция кода под будущие миграции:**

```
orchestrator/
├── main.go                  # entry point (v1: cron + http; v2: Temporal Worker; v3: KAMF Runner)
├── config/                  # env-конфиг (переиспользуется во всех версиях)
├── activities/              # ⚠️ КРИТИЧНО: 80% кода живёт здесь
│   ├── mail.go              # вызовы mail-service — переиспользуется на v2/v3
│   ├── attachment.go        # вызовы attachment-service
│   ├── parser.go            # вызовы parser-service
│   ├── summary.go           # вызовы summary-service
│   ├── telegram.go          # доставка в Telegram
│   └── sheets.go            # запись в Google Sheets
├── workflow/                # 🔄 МЕНЯЕТСЯ при миграции
│   ├── email_digest_v1.go   # v1: явный последовательный код. v2: Temporal workflow. v3: KAMF StateGraph
│   └── mail_check_v1.go     # on-demand check (для будущего DEC-013)
├── auth/                    # API-key middleware (Уровень 0 secure-by-design)
├── ratelimit/               # slowapi-эквивалент на Go (Уровень 0)
├── logging/                 # structured logs (slog) — переиспользуется
└── server/                  # HTTP-server для webhooks + healthcheck
```

**Принцип:** **activities/ — это бизнес-логика. workflow/ — это оркестрация.** При миграции на Temporal/KAMF — `activities/` переиспользуется как есть, `workflow/` переписывается под новый runtime.

### Контракт v1

**HTTP Endpoints:**

```
POST /digest-now
  Headers: X-API-Key: <orchestrator_api_key>
  Body: {"period_hours": 24, "force_refresh": false}
  Returns: 202 Accepted + {"trace_id": "uuid", "started_at": "ISO-timestamp"}
  
  Запускает full email digest workflow вне расписания.

POST /check-mail
  Headers: X-API-Key: <orchestrator_api_key>
  Body: {"user_chat_id": "1257818936"}
  Returns: 202 Accepted + {"trace_id": "uuid"}
  
  On-demand check для будущего DEC-013 Mail Check On-Demand.
  В v1 — заглушка, возвращающая "not implemented yet".

GET /health
  Returns: 200 OK + конфиг (без секретов)
  
  Standard healthcheck для systemd / K8s liveness probe.

GET /metrics
  Returns: Prometheus-format metrics
  - orchestrator_workflows_total{type, outcome}
  - orchestrator_workflow_duration_seconds (histogram)
  - orchestrator_activity_errors_total{service}
```

**Schedule (cron):**

```
0 9 * * MON-FRI  → /digest-now (только рабочие дни)
```

В env-файле: `ORCHESTRATOR_SCHEDULE="0 9 * * MON-FRI"`. Если пустой — schedule отключен, только webhook.

**Structured logs (slog JSON):**

```json
{
  "time": "2026-05-13T09:00:00Z",
  "level": "INFO",
  "trace_id": "abc-123-def",
  "service": "orchestrator",
  "workflow": "email_digest",
  "step": "fetch_mail",
  "duration_ms": 45,
  "outcome": "success",
  "messages_count": 3
}
```

Каждая activity пишет лог с `trace_id` (UUID v7 для упорядоченности по времени), который **пробрасывается во все микросервисы** через `X-Trace-Id` header. На v2 (Temporal) — `trace_id` становится `workflow_id`.

**Error handling:**

| Сценарий | Поведение v1 | Что переиспользуется на v2 |
|---|---|---|
| mail-service недоступен | retry 3× с backoff (1s, 2s, 4s), потом fail | activity retry policy |
| attachment download fail | log warning, продолжаем без этого вложения | activity timeout + retry |
| parser-service fail на 1 файле | log warning, продолжаем с остальными | partial failure pattern |
| summary-service fail | retry 3×, потом fallback на DeepSeek (уже в коде summary-service) | используем существующий fallback |
| Telegram fail | retry 3×, потом log critical | activity retry + alert |
| Sheets append fail | retry 3×, потом log warning (не критично) | activity retry |

**Secure by Design Уровень 0 встроен:**

- ✅ **API-key auth** на всех POST endpoints (`X-API-Key` header)
- ✅ **Rate limit** через token bucket (стандарт Go, нет dependency): 60 req/min на `/digest-now`, 30 req/min на `/check-mail`
- ✅ **Path traversal validation** для аргументов передаваемых в parser
- ✅ **CORS закрыт** по умолчанию
- ✅ **No secrets in logs** — API-key, OPENROUTER_API_KEY никогда не попадают в slog
- ✅ **Healthcheck без auth** (нужен для k8s/systemd liveness)
- ✅ **Metrics без auth** (на v1; на v2 — внутренний `127.0.0.1:9090` only)

### Контракт миграций (что переиспользуется)

**Go-custom → Temporal (на v2):**

| Что | Что меняется | Что остаётся |
|---|---|---|
| `activities/*.go` | НИЧЕГО (становятся Temporal activities) | 100% |
| `config/*.go` | НИЧЕГО | 100% |
| `logging/*.go` | slog enrichment с workflow_id | 95% |
| `auth/*.go` | НИЧЕГО (Temporal Signal вызывается через auth-wrapper) | 100% |
| `workflow/email_digest_v1.go` | переписывается на Temporal workflow API | 0% (новый файл `email_digest_v2.go`) |
| `main.go` | Cron+HTTP → Temporal Worker + Activity Server | 30% |
| Инфраструктура | systemd → systemd Worker + Docker Temporal Cluster | новые контейнеры |

**Объём миграции:** ~6-10 часов работы. **Бизнес-логика (80%) переиспользуется.**

**Temporal → KAMF (на v3):**

| Что | Что меняется | Что остаётся |
|---|---|---|
| `activities/*.go` | становятся `NodeHandler` в StateGraph | 90% |
| `workflow/email_digest_v2.go` | Temporal workflow → StateGraph definition | 0-30% |
| `main.go` | Temporal Worker → KAMF Runner | ~40% |
| OpenTelemetry tracing | Temporal History → KAMF tracer.go | автоматически |
| State persistence | Temporal внутренний → KAMF Checkpointer | через интерфейс |

**Объём миграции:** ~3-5 дней работы. Не миграция, **эволюция** — переход на собственный runtime с переиспользованием 70-80% кода.

### Триггеры миграций (не календарные — по факту требований)

**Важный принцип:** триггеры — это **реальные требования**, а не «прошёл месяц, пора мигрировать». Если v1 работает стабильно и держит нагрузку — миграция не нужна.

**Go-custom → Temporal на v2:**
- Регулятор спрашивает «покажите durable audit log за 90 дней с replay-возможностью» — миграция обязательна
- 5+ workflow templates в orchestrator — становится тяжело поддерживать в custom-коде
- Recovery after crash требуется (orchestrator упал посреди обработки 50 писем)
- Multi-tenant поддержка (workflow per-client с разными конфигами)

**Temporal → KAMF на v3:**
- KAMF в скомпилированном работающем состоянии
- Готовность инвестировать 3-5 дней на миграцию ради independence
- Архитектурное обоснование «свой framework production-proof»

### v1 может оказаться long-term solution

**Это нормальный сценарий**, не failure. Если orchestrator v1 работает стабильно:
- Не падает (uptime 99%+)
- Держит нагрузку (1-100 клиентов)
- Триггеры миграции не сработали (регулятор не пришёл, multi-tenant не понадобился, durable execution справляется через idempotent retry)

Тогда **остаёмся на Go v1 на годы**. Temporal/KAMF становятся **option, не план**. Это **правильное архитектурное мышление по реальным данным**, а не «у нас roadmap, мы идём по нему вне зависимости от ситуации».

**Принцип:** **архитектурные миграции делаются когда измерены, а не когда теоретически планировались.**

### Не делаем на v1

- ❌ OpenTelemetry trace propagation (на v2)
- ❌ Circuit breaker (на v2)
- ❌ Сложные retry policies с exponential backoff и max attempts (на v2)
- ❌ State persistence (Redis/Postgres) — пока stateless
- ❌ Multi-tenant поддержка (на v3)
- ❌ Web UI (никогда — Temporal headless, KAMF без UI до v3+)

## Diagram — Data Flow (v1)

```
                    ┌─────────────────────────┐
                    │   Schedule (cron 09:00) │
                    │   или Webhook /digest-now│
                    └────────────┬────────────┘
                                 │ trace_id=uuid
                                 ▼
                    ┌─────────────────────────┐
                    │     orchestrator        │
                    │  (Go custom v1, :8769)  │
                    └────────────┬────────────┘
                                 │ X-API-Key + X-Trace-Id
                ┌────────────────┼────────────────┐
                ▼                ▼                ▼
        ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
        │ mail-service │ │ attachment-  │ │ parser-      │
        │   :8765      │ │ service:8766 │ │ service:8767 │
        └──────┬───────┘ └──────┬───────┘ └──────┬───────┘
               │                │                │
               └────────────────┼────────────────┘
                                ▼
                    ┌─────────────────────────┐
                    │   summary-service:8768  │
                    │     (Haiku 4.5 LLM)     │
                    └────────────┬────────────┘
                                 │
                ┌────────────────┴────────────────┐
                ▼                                 ▼
        ┌──────────────┐                 ┌──────────────┐
        │   Telegram   │                 │  Google      │
        │  Bot API     │                 │  Sheets API  │
        └──────────────┘                 └──────────────┘
```

## Consequences

**Плюсы:**

- ✅ **Demo вечером 13.05** обеспечен — Go v1 за 3 часа реально успеть
- ✅ **Senior-сигнал** — Go рядом с Python = полиглот-стек
- ✅ **Контекст в git** — каждое изменение voracable, LLM-напарник имеет full context
- ✅ **Простота миграций** — v1 спроектирован с учётом v2 (Temporal) и v3 (KAMF). Activities переиспользуются.
- ✅ **Secure by Design Уровень 0 встроен** с первого commit'а — не retrofit потом
- ✅ **115-ФЗ-ready audit log** через slog structured logs с trace_id
- ✅ **KAMF positioning** — mail-stack становится первым production-кейсом будущей KAMF-имплементации, не «бумажный фреймворк»

**Минусы:**

- ❌ **3 часа** работы сегодня — есть риск не успеть к демо. Митигация: на 2-м часу контрольная точка, при провале — bash-cron страховка (30 минут) + N8N как третья страховка
- ❌ **Технический долг durable execution** — orchestrator не переживёт рестарт coo с in-flight workflow. Митигация: idempotent activities + retry policy достаточны для нашего объёма (1 workflow в день)
- ❌ **Без OpenTelemetry на v1** — только slog с trace_id, нет визуализации в Jaeger/Tempo. Митигация: trace_id pattern совместим с OTel, добавится на v2

**Открытые вопросы:**

- **DEC-019 «Миграция Go-orchestrator → Temporal headless»** — на v2. Триггер: первая регуляторная проверка, 5+ workflow, или необходимость durable execution. Объём ~6-10 часов. Не блокирует текущее развитие.
- **DEC-020 «Миграция Temporal → KAMF Runtime»** — на v3. Триггер: KAMF в работоспособном состоянии + готовность инвестировать 3-5 дней + потребность в карьерном/продуктовом сигнале. Объём ~3-5 дней.
- **DEC-021 «State-service на Redis (hot) + Postgres (warm)»** — нужен на v2 для tracking `last_check_timestamp` per-user (Mail Check On-Demand), `last_processed_uid` per-account (multi-account), dedup IDs. Двухуровневая память по канону: Redis для hot path, Postgres для warm.
- **Apache Airflow** для batch ML pipelines на v3 — когда появятся classifier-training, fine-tuning, корпус документов клиентов для адаптации Haiku. Не для оркестрации mail-stack.

**Стратегический сигнал:** Trio-эволюция Go custom → Temporal headless → KAMF — это **уникальный архитектурный путь** для AI/Compliance B2B-стартапа в РФ. Это **дороже** чем «взять SaaS и склеить», но **сильно дешевле** чем retrofit production-grade требований на работающую систему позже. В архитектурных обзорах такой путь демонстрирует **системное архитектурное мышление**, не «как сделать быстро».

## Implementation Plan для v1 (сегодня)

**Time budget:** 3 часа до demo (15:00-18:00 MSK), с контрольными точками каждый час.

**Час 1 (15:00-16:00):**
- `go mod init`, базовая структура каталогов
- `config/` с env-loading
- `activities/mail.go`, `attachment.go`, `parser.go`, `summary.go` — HTTP-клиенты к 4 микросервисам
- Юнит-тесты на activities (mock-сервер)
- **Checkpoint:** все 4 activities компилируются, юнит-тесты зелёные

**Час 2 (16:00-17:00):**
- `workflow/email_digest_v1.go` — последовательное выполнение activities
- `activities/telegram.go` и `sheets.go` — финальная доставка
- `main.go` — HTTP-server + cron
- `auth/` API-key middleware
- `ratelimit/` token bucket
- **Checkpoint:** orchestrator принимает webhook, цепочка проходит до конца, есть JSON-логи

**Час 3 (17:00-18:00):**
- `systemd` unit, env-файл, права
- Smoke end-to-end на реальном письме
- Тестовое отправление Таирову в Telegram (с пометкой «тест»)
- Деактивация Polygon (active=0 в N8N UI)
- **Checkpoint:** Полный production-deploy, demo готов

**При провале checkpoint'а:**
- После часа 2 — **bash-cron страховка** (~30 минут): cron на coo с шеллскриптом, который через `curl` дёргает endpoints микросервисов, парсит JSON через `jq`, отправляет результат в Telegram через `curl -X POST $TELEGRAM_BOT_API/sendMessage`. ~30 строк bash, без Go-зависимости. Это **минимальный workflow без durable execution, retry, audit log** — но **демо обеспечивает**. На horizon — заменяется на Go v1.
- При полном провале — N8N workflow за 1 час как **третья страховка**

### Связь с другими ADR

- **DEC-016 (K8s manifests)** — будет писаться **с учётом orchestrator** (deployment + service + NetworkPolicy для него). Не отдельная задача — манифесты для orchestrator пишутся одновременно с манифестами для микросервисов.
- **DEC-017 (Secure by Design)** — Уровень 0 встроен в orchestrator v1 с первого commit'а (API-key auth, rate limit, path validation, CORS). Уровни 1-3 добавляются по мере роста системы.
- **DEC-019 (Temporal migration)** — будет создан при срабатывании триггеров (см. выше). Не сейчас.
- **DEC-020 (KAMF migration)** — будет создан при готовности KAMF к production.
- **DEC-021 (state-service)** — нужен для DEC-013 Mail Check On-Demand. На v2.

## Final Note

Этот ADR — единственный документ, описывающий orchestrator. Каждая миграция (Temporal, KAMF) получит **свой ADR** (DEC-019, DEC-020). Этот документ остаётся как **исторический контекст** того откуда начали и куда движемся.

## Implementation Notes (13.05.2026, v1.0)

Реализован за **45-50 минут** от создания каталога до production-deploy. Планировалось 3 часа. Фактическая скорость доказывает: **отлаженная связка ADR → код → smoke** работает в **4× быстрее теоретических оценок**. Архитектурная подготовка (DEC-014 ADR проработан до кодинга, все принципы зафиксированы) **окупается** в реальной скорости реализации.

### Что реализовано

```
/opt/mail-stack/orchestrator/
├── go.mod, go.sum            # 4 базовых + 3 транзитивных зависимости
├── Dockerfile                # multi-stage build, non-root user, healthcheck
├── .dockerignore             
├── config/
│   └── config.go             # env-driven config (caarlos0/env)
├── logging/
│   └── logging.go            # slog JSON + UUID v7 trace_id
├── activities/               # 80%+ кода переиспользуется на v2/v3
│   ├── types.go              # Message, ParsedAttachment, DigestResult
│   ├── mail.go               # GET /mail/since (с поддержкой date+time precision)
│   ├── attachment.go         # POST /download + path traversal validation
│   ├── parser.go             # POST /parse + path validation
│   ├── summary.go            # POST /summary
│   ├── telegram.go           # POST /send-tg (через Agent Caller)
│   ├── whatsapp.go           # POST /send-wa (через Agent Caller, добавлен в v1.0+wa)
│   └── *_test.go             # 13 юнит-тестов, все PASS
├── workflow/
│   └── email_digest_v1.go    # Полная цепочка с WA-pre-alert
├── auth/
│   └── auth.go               # X-API-Key middleware (constant-time compare)
├── ratelimit/
│   └── ratelimit.go          # Token bucket per-endpoint
├── server/
│   └── server.go             # /health, /metrics, /digest-now, /check-mail
└── cmd/orchestrator/
    └── main.go               # Entry point: cron + HTTP + graceful shutdown
```

### Метрики кода

| Что | Значение |
|---|---|
| Строк Go (production) | ~1100 |
| Строк юнит-тестов | ~380 |
| Тестов | 13 (все PASS) |
| Покрытие | success path, server errors, path traversal, health checks |
| Бинарник (статичный) | 8.6 МБ |
| Время компиляции | ~1 секунда |
| Зависимости | 4 базовых + 3 транзитивных |
| Complexity budget | 1100/1000 = 110% (превышено на 10% из-за добавления WhatsApp activity, в пределах нормы) |

### Метрики production

| Что | Значение |
|---|---|
| Memory footprint | ~10 МБ (минимальный в стеке mail-stack!) |
| Boot time | ~2 секунды |
| Workflow duration (без WA) | **12 секунд** end-to-end |
| Workflow duration (с WA-pre-alert) | **93 секунды** (80 сек WA + 13 сек остальное) |
| Cost per workflow (4 письма, Haiku) | $0.0078 ≈ **0.59 руб** |
| Soft errors на smoke | 0 |

### Подтверждённое поведение

Smoke-тест 13.05.2026 в production:
- ✅ POST /digest-now (period 168h = неделя) принят с trace_id мгновенно
- ✅ GET /mail/since/2026-05-06T16:13 от mail-service вернул 4 письма Контур.Экстерн (с пост-фильтрацией по времени)
- ✅ summary-service выдал живой дайджест за 7 секунд через Haiku 4.5
- ✅ WhatsApp pre-alert ушёл на Таирова (79266143959) через 80 сек после summary
- ✅ Telegram-дайджест ушёл на Артёма (249979054) через 1 сек после WA
- ✅ workflow.done логирован с полной метрикой
- ✅ trace_id (UUID v7) пробросился через весь стек
- ✅ Все 7 правил docker-friendly из DEC-007 соблюдены

### Mail-service contract update (13.05.2026)

В процессе реализации orchestrator обнаружена несовместимость контракта:
- Mail-service принимал только `YYYY-MM-DD` (точность сутки)
- Orchestrator шлёт `YYYY-MM-DDTHH:MM` (точность минута — нужно для DEC-013 Mail Check On-Demand на v2)

**Решение:** **breaking change в mail-service** — теперь принимает **только** `YYYY-MM-DDTHH:MM`. С пост-фильтрацией по времени (IMAP SEARCH SINCE работает по дням, отсекаем письма раньше HH:MM на стороне Python).

Аргументация:
- Mail-service пока единственный клиент = orchestrator
- Точность для будущего v2 (state-service с last_check_timestamp)
- Один формат = меньше кода, чище контракт

### WhatsApp pre-alert findings

В процессе реализации обнаружено **критичное поведение whatsapp-web.js**:
- `wa.sendMessage()` возвращает success даже если **destroy Chrome происходит слишком быстро**
- При `setTimeout(10000)` после send — **silent fail** (WhatsApp не доставляет сообщение, но клиент возвращает OK)
- При `setTimeout(60000)` — **стабильная доставка**

**Зафиксировано в Agent Caller server.js:** `setTimeout(r, 60000)` после `wa.sendMessage()`.

Trade-off: workflow duration 12 сек → 93 сек (8× медленнее). Для v1.0 приемлемо (1 workflow в день), на v1.3 — **WA в parallel goroutine** (не блокирует Telegram-доставку).

### Roadmap версионирования orchestrator

| Версия | Что | Статус |
|---|---|---|
| **v1.0** ✅ | Go-orchestrator + Telegram-доставка + WhatsApp pre-alert | **Implemented 13.05.2026** |
| **v1.1** ✅ | Telegram-кнопка «Проверить почту» (callback в Agent Caller → POST /digest-now) + multi-mailbox в mail-service (один сервис со списком ящиков в MAILBOXES_JSON env-конфиге, не 3 systemd-instance) + product-grade WA-skip для on-demand | **Implemented 13.05.2026 (вечер)** |
| **v1.2** | Google Sheets append через Apps Script (история дайджестов, аналитика) | На этой неделе |
| **v1.3** | WhatsApp pre-alert в parallel goroutine + MAX мессенджер (third channel) | Когда нужно |
| **v1.4** | MCP server обёртка над mail-stack для интеграции с personal AI assistants | На v3 |
| **v2.0** | DEC-013 Mail Check On-Demand + state-service Redis (hot) + Postgres (warm) | 3-4 недели |
| **v3.0** | Temporal headless (durable execution + 115-ФЗ audit log) | По триггерам |
| **v4.0** | KAMF runtime (свой framework production-proof) | По готовности KAMF |

### Архитектурные принципы подтверждены на v1.0

1. ✅ **LLM-native development** — весь orchestrator в git, не в UI. Контекст для AI-напарника полный.
2. ✅ **Полиглот-стек** — Go рядом с Python (mail-stack) и Node.js (Agent Caller). Каждый язык по силе для слоя.
3. ✅ **Activities переиспользуются 80%+** на v2/v3 — workflow/email_digest_v1.go переписывается под Temporal, activities/*.go остаются как есть.
4. ✅ **Secure by Design Уровень 0 встроен** — API-key auth, rate limit, path traversal validation, CORS закрыт.
5. ✅ **No Web UI** — orchestrator headless. Только REST + structured logs в journald.
6. ✅ **Time-precision contract** — date+time через всю систему для будущей точности audit log.
7. ✅ **Complexity budget работает как guard-rail** — 1100/1000 строк ~ в норме, без архитектурного хаоса.

## Implementation Notes (13.05.2026, v1.1)

Реализовано после v1.0 в той же сессии 13.05.2026. Объём ~1.5-2 часа: Telegram-кнопка с callback flow + Multi-mailbox в mail-service + product-grade разделение поведения WA для cron vs on-demand.

### Telegram-кнопка «🔍 Проверить почту»

Реализация через Agent Caller (Node.js):
- Переведён в режим polling: `new TelegramBot(TG_TOKEN, { polling: true })`
- Reply keyboard (persistent внизу чата, не inline под сообщением)
- Обработчик `tg.on('message', ...)` — кнопка работает как текстовое сообщение
- Endpoint `POST /tg/setup-button {chat_id, intro_text}` — активация кнопки у пользователя
- Env через systemd override `/etc/systemd/system/agent-caller.service.d/orchestrator.conf`:
  - `ORCHESTRATOR_URL=http://127.0.0.1:8769`
  - `ORCHESTRATOR_API_KEY=<key>`

Flow по нажатию:
```
Пользователь жмёт кнопку
   ↓
tg.on('message') ловит текст "🔍 Проверить почту"
   ↓
Бот отвечает: "🔄 Проверяю почту..."
   ↓
fetch POST /digest-now с X-API-Key и skip_wa_alert: true
   ↓
Orchestrator workflow (без WA-pre-alert)
   ↓
Telegram дайджест в том же чате
```

Кнопка активирована у Артёма (chat_id 249979054). У Таирова (1257818936) — не активирована (демо планируется на ящиках Артёма).

### Product-grade WA-skip разделение

Добавлено в Orchestrator:
- `RunParams.SkipWAAlert bool` — флаг в workflow
- Поле `skip_wa_alert` в `DigestNowRequest`
- Условие WA: `if w.WhatsAppNumber != "" && w.WhatsApp != nil && !params.SkipWAAlert`

Поведение:
- **Cron (расписание):** WA pre-alert + Telegram content (двухканальный push)
- **Кнопка (on-demand):** только Telegram (пользователь уже в Telegram, ждёт ответа — WA избыточен)
- **Curl ручной:** по выбору через body параметр

Архитектурный принцип: **триггер определяет канал доставки**. Push-уведомление имеет смысл только когда пользователь **не ожидает** результата.

### Multi-mailbox в mail-service

Mail-service расширен поддержкой списка ящиков через env-конфиг `MAILBOXES_JSON`:
```json
[
  {"label":"...","host":"...","port":993,"user":"...","pass":"...","mailbox":"INBOX"},
  ...
]
```

Логика:
- При старте парсит JSON, логирует список ящиков с label/user/host (без паролей)
- В цикле подключается к каждому, собирает письма с пост-фильтрацией по времени
- Объединяет результаты, сортирует по дате (новые сверху)
- Каждое письмо помечено `mailbox_label` и `mailbox_user` для трассировки

Контракт API не сломан — ответ остаётся массивом писем, добавились только новые поля.

Backward compatibility сохранена: если `MAILBOXES_JSON` пустой, mail-service работает по старому через `IMAP_USER/IMAP_PASS`.

Развёрнуто 3 ящика для Артёма (для теста с разным контентом):
- `artem-mailru` (5458508@mail.ru) — рабочая почта, ФНС/СФР/Контур
- `artem-gmail` (powerparadox7777@gmail.com) — рассылки, security alerts, n8n
- `artem-icloud` (armigroup@me.com) — hh.ru, вакансии

### WhatsApp destroy timing fix

В Agent Caller `server.js` исправлено критичное поведение:
```javascript
// Было: setTimeout(r, 10000)  — silent fail
// Стало: setTimeout(r, 60000) — стабильная доставка
```

10 секунд после `wa.sendMessage()` недостаточно для синхронизации сообщения с серверами WhatsApp до закрытия Chrome. Сообщение помечается как «отправлено» в Agent Caller, но реально не доставляется. 60 секунд решают проблему.

Trade-off: WA-этап workflow увеличивается с ~21 до ~82 секунд.

### Mail-service contract clarification

Контракт API после v1.1:
- Endpoint: `GET /mail/since/{YYYY-MM-DDTHH:MM}` (date+time precision, breaking change на v1.0 уже зафиксирован)
- Ответ: массив писем, каждое с полями `messageId`, `from`, `email`, `fio`, `subject`, `date`, `body_text`, `attachment_names`
- **Новые поля от multi-mailbox:** `mailbox_label`, `mailbox_user` (для трассировки источника)
- Письма из всех настроенных ящиков объединены и отсортированы по дате

## Implementation Notes (16.05.2026, v1.2 → v1.2.1 → v1.2.2)

### Контекст: пересмотр roadmap

Триггеры реализованы быстрее графика. DEC-013 «Mail Check On-Demand» планировался на v2.0 (3-4 недели), а реализован в v1.2 за день. Причина — после первых нажатий кнопки стало ясно что **stateless workflow с хардкод 24h** даёт плохой UX (дублирование уже виденных писем). Реальная нагрузка определила приоритет, не теоретический график.

Это подтверждает архитектурный принцип DEC-022: **«архитектурные изменения по факту требований, не превентивно»**.

### Обновлённый Roadmap

| Версия | Что | Статус | Дата |
|---|---|---|---|
| **v1.0** | Go-orchestrator + Telegram + WhatsApp pre-alert | ✅ Implemented | 13.05.2026 |
| **v1.1** | Telegram-кнопка + multi-mailbox + WA-skip on-demand | ✅ Implemented | 13.05.2026 вечер |
| **v1.2** | Incremental workflow (DEC-013) + state-service (DEC-021) + lock защита | ✅ Implemented | 16.05.2026 утро |
| **v1.2.1** | NotifyDone push-pattern к Agent Caller (отмена UX-таймеров) | ✅ Implemented (canary) | 16.05.2026 день |
| **v1.2.2** | WorkflowProgress event-driven UX (синхронизация с состоянием workflow) | ✅ Implemented | 16.05.2026 вечер |
| **v1.3** | Параллельная обработка вложений (3x speedup) | Отложено | Триггер: реальная задержка >5 мин на 25 МБ PDF |
| **v2.0** | Temporal headless (durable execution + 115-ФЗ audit log) | По триггерам | 3-4 недели или позже |
| **v3.0** | KAMF runtime (свой framework production-proof) | По готовности KAMF | 3-6 месяцев |

### v1.2 Implementation (16.05.2026 утро)

**Что реализовано:**

1. **State-service** как отдельный микросервис (DEC-021 — separate ADR)
2. **Incremental period logic** в workflow:
   - AcquireLock с TTL 300 сек (защита от двойного клика)
   - GetLastAt → если есть, period = (now - last_at). Если нет, fallback 24h.
   - SetLastAt(now) после успешной Telegram-доставки
   - defer ReleaseLock на любом return
3. **Новый endpoint `/state/activate`** для записи `last_at = now()` при установке кнопки новому пользователю
4. **WA pre-alert** теперь только при `trigger="cron"` И когда есть письма
5. **Lock_held semantics** — двойной клик возвращает SkippedDueLock без ошибки, не дублирует дайджест
6. **Field `Trigger` в RunParams** — orchestrator различает cron vs button
7. **Дефолтный chat_id** — если не передан в request, используется TELEGRAM_CHAT_ID из config (для cron-trigger'a)

**Контракт API DigestNowRequest:**

```json
{
  "chat_id": "249979054",      // опционально, дефолт из config
  "trigger": "button" | "cron", // дефолт "button"
  "force_refresh": false,       // игнорировать lock (для отладки)
  "period_hours": 24            // DEPRECATED, игнорируется (период из state)
}
```

**Объём кода:** +250 строк production, +204 строк тестов.

### v1.2.1 Implementation (16.05.2026 день) — push-pattern NotifyDone

**Проблема в v1.2:**
Agent Caller имел **слепые setTimeout таймеры** (60/180/360 сек) для прогресс-сообщений. При быстром workflow (10 сек без вложений) сообщения **всё равно приходили** после уже доставленного дайджеста. Юзер видел абсурд: «📚 Тут немало документов...» после того как уже получил дайджест.

**Решение:**
Добавить `activities/notify.go` с методом `WorkflowDone(chat_id, trace_id, status)`. Orchestrator пушит в Agent Caller через `POST /workflow-done` после завершения. Agent Caller отменяет таймеры.

**Defer-pattern для гарантированной cleanup:**

```go
notifyStatus := "failed"  // дефолт
defer func() {
    w.notifyDoneSafe(ctx, traceID, chatIDStr, notifyStatus, logger)
}()

// ... workflow ...
// На каждом return-point ВЫСТАВЛЯЕМ notifyStatus:
//   SkippedDueLock  → notifyStatus = "lock_held"
//   no_messages     → notifyStatus = "no_messages"
//   successful      → notifyStatus = "delivered"
//   any error       → остаётся "failed"
```

**8 точек return в workflow.Run()** все покрыты defer'ом. Это критично — забыть хотя бы одну точку = unfreed таймеры в Agent Caller.

**Статусы и поведение Agent Caller:**

| status | Действие Agent Caller |
|---|---|
| `delivered` | clearUxTimers — финальный дайджест уже пришёл |
| `no_messages` | clearUxTimers — пришло «📭 ничего нет» |
| `failed` | clearUxTimers — workflow упал, лишних сообщений не нужно |
| `lock_held` | **НЕ** очищает таймеры. Отправляет «⏳ Уже обрабатываю предыдущий запрос». Первый workflow продолжается, его прогресс должен приходить. |

**Объём кода:** +96 строк (notify.go) + 102 строки тестов.

### v1.2.2 Implementation (16.05.2026 вечер) — event-driven progress

**Проблема в v1.2.1:**
Слепые setTimeout таймеры **убраны** — сейчас или ничего, или сообщение приходит после workflow-done. Но если workflow реально долгий (25 МБ PDF, 7 минут) — юзер сидит в тишине 7 минут.

**Решение:**
Orchestrator пушит **прогресс-события** на ключевых этапах. Agent Caller сам решает что показать пользователю.

**Активити расширена:**

```go
type WorkflowProgressParams struct {
    ChatID  string
    TraceID string
    Step    string         // "attachments_start" | "summary_start"
    Meta    map[string]any // count, elapsed_ms, ...
}

func (n *NotifyActivity) WorkflowProgress(ctx, params, opts) error
```

**Точки emit'а в workflow:**

1. **Перед циклом attachments** — только если `totalAttachments > 0`:
   ```
   step: "attachments_start"
   meta: { count: 9 }
   ```

2. **Перед summary** — всегда:
   ```
   step: "summary_start"
   meta: { elapsed_ms: 90000 }
   ```

**Логика Agent Caller (server.js, endpoint `POST /workflow-progress`):**

```javascript
attachments_start + meta.count >= 3       → "📚 Тут немало документов..."
summary_start    + meta.elapsed_ms >= 60000 → "⏳ Почти готово, формирую обзор."
```

**Архитектурный принцип:** **бизнес-логика в orchestrator** (что произошло), **UX-логика в Agent Caller** (что показать). Пороги можно менять в `server.js` без переделки Go-кода.

**Сценарии в production:**

| Сценарий | Сообщения юзеру |
|---|---|
| Workflow 10 сек, 0 писем | "🔄 Проверяю..." → "📭 Ничего нет" |
| Workflow 20 сек, 11 писем без вложений | "🔄 Проверяю..." → дайджест |
| Workflow 7 минут, 9 PDF | "🔄 Проверяю..." → "📚 Тут немало документов..." → "⏳ Почти готово..." → дайджест |
| Двойной клик | "🔄 Проверяю..." → (workflow 1 идёт) → "⏳ Уже обрабатываю предыдущий запрос" → "📚..." → "⏳..." → дайджест |

**Объём кода:** +59 строк (расширение notify.go) + 106 строк тестов + 130 строк патча Agent Caller (server.js).

### Canary deployment pattern (доказан в практике)

Все 3 версии (v1.2, v1.2.1, v1.2.2) деплоились по одному паттерну:

1. Параллельный orchestrator-canary на :8779 + state-service-canary на :8771 (Redis DB=1)
2. Smoke-сценарии на изолированном state
3. Switchover canary → production через `switchover.sh` (бэкап + rsync + restart)
4. Rollback за 30 секунд если что-то пошло не так

**Это переиспользуемый паттерн** для будущих deployment'ов. См. `canary-setup/` в orchestrator-репо.

### Архитектурные принципы подтверждены на v1.2.x

В дополнение к 7 принципам v1.0:

8. ✅ **Event-driven, не polling** — push-pattern для UX-уведомлений. Latency < 1 сек, минимум нагрузки.
9. ✅ **State в отдельном микросервисе** (DEC-021) — не in-memory, не в Agent Caller.
10. ✅ **Архитектурные изменения по факту требований** — DEC-013 реализован на v1.2 раньше v2.0 графика, потому что реальный UX потребовал.
11. ✅ **Defer-pattern для cleanup на любом return** — критично для гарантий освобождения lock и notify.
12. ✅ **Canary deployment** — изолированная среда (порт + Redis DB) для smoke без риска production.
13. ✅ **Бизнес-логика в Go, UX-логика в JS** — пороги прогресс-сообщений живут в Agent Caller, меняются без переделки Go-кода.

### Открытые вопросы (на DEC-023+)

- **Параллелизм вложений (v1.3)** — отложен до реальной нагрузки. Архитектурные риски зафиксированы (rate limits OpenRouter, memory parser-service, goroutine leaks, partial failures). Решение по факту первого реального 25 МБ PDF.
- **Event bus (Kafka/NATS)** — НЕ применён для прогресс-событий. Текущий HTTP push достаточен для 1-to-1 общения (orchestrator → Agent Caller). Применение рассматривается на DEC-023 при появлении конкретных pub/sub паттернов (one-to-many, audit replay). См. обновление DEC-022.
- **Mail-stack контракт** — без изменений в v1.2.x.

## Implementation Notes (23.06.2026, v1.3-prep) — статус, второй cron, форма деплоя

После санации канона зафиксированы три направления, относящиеся к orchestrator-tier.

### Статус деплоя на coo

**В проде (что работает):**
- orchestrator-bin (Go, statically linked, stripped, ELF), strings → `orchestrator-v1.2`.
- Один cron `c` запускает workflow `email_digest_v1` по `ORCHESTRATOR_SCHEDULE`.
- env-файл `/etc/mail-stack/orchestrator.env` содержит все нужные переменные для v1.2.x плюс **заготовку под v1.3**: `STATEMENT_VACUUM_SCHEDULE=0 6,10,14,18 * * *`, `COMPLIANCE_LOGIC_URL=`, `COMPLIANCE_LOGIC_API_KEY=`, `COMPLIANCE_LOGIC_CA_CERT=`.
- systemd `Restart=always`, рестарт за 1–2 секунды в случае краша.

**В working tree (не задеплоено):**
- `workflow/statement_vacuum_v1.go` (untracked).
- `activities/ingest.go` (untracked) — клиент к `compliance-logic /statements/ingest`.
- `activities/{mail,parser,attachment}.go` (modified) — добавлен `Label` в параметры активити.
- `cmd/orchestrator/main.go` (modified, +88 строк) — второй cron `c2` для statement_vacuum.
- `config/config.go` (modified, +8 строк) — `STATEMENT_VACUUM_SCHEDULE` env.

Деплой этой группы планируется отдельным шагом санации (build → cp → systemctl restart).

### Второй cron c2 для statement_vacuum (заготовка)

В `main.go` working tree добавлен второй `cron.Cron` с независимым расписанием:

```go
if cfg.StatementVacuumSchedule != "" {
    c2 = cron.New(cron.WithLogger(cronLogger{logger}))
    _, err := c2.AddFunc(cfg.StatementVacuumSchedule, func() {
        // запуск workflow.StatementVacuumV1{MailboxLabel: "compliance-5458508", ...}.Run(ctx)
    })
    c2.Start()
}
```

**MailboxLabel зашит как литерал** в `main.go` строка 119: `MailboxLabel: "compliance-5458508"`. Технический долг (cleanup_backlog_v2 п. 2.4): вынести в env `STATEMENT_VACUUM_MAILBOX_LABEL`. В текущем виде смена адресной метки требует пересборки бинаря.

**Graceful shutdown** в текущей working tree обрабатывает только основной `c.Stop()`. Для `c2` нужен парный `c2.Stop()` в shutdown-блоке — будет добавлен при деплое (cleanup_backlog 2.3).

### Форма деплоя Go-сервисов (стандарт)

Зафиксировано: канон = git репо (`~/compliance-assistant-repo`), деплой = `build → cp → systemctl restart`. Конкретно:

```bash
# 1. Сборка в working dir (на coo или на macOS с GOOS=linux)
cd ~/compliance-assistant-repo/orchestrator
go build -trimpath -ldflags="-s -w" -o orchestrator-bin ./cmd/orchestrator
# Проверка: статичный, stripped, ~5-6 MB
file orchestrator-bin   # → statically linked, stripped

# 2. Бэкап текущего бинаря и копия нового
sudo cp /opt/mail-stack/orchestrator/orchestrator-bin /opt/mail-stack/orchestrator/orchestrator-bin.bak.$(date +%s)
sudo cp orchestrator-bin /opt/mail-stack/orchestrator/orchestrator-bin

# 3. Рестарт через systemd (НЕ дёргать бинарь напрямую — он подхватывает env через systemd unit)
sudo systemctl restart orchestrator

# 4. Проверка
systemctl status orchestrator --no-pager
sudo journalctl -u orchestrator -n 30 --no-pager
```

**Правила:**
- Бэкап старого бинаря **обязательно** перед `cp`. Имя: `.bak.<unix_timestamp>` или `.bak.<semver>`.
- Бинарь **никогда** не запускается напрямую (`./orchestrator-bin` без env положит сервис — env инжектится systemd unit'ом из `/etc/mail-stack/orchestrator.env`).
- Откат: `sudo cp <bak> /opt/.../orchestrator-bin && sudo systemctl restart orchestrator`.
- Сборка через `Makefile` — техдолг (cleanup_backlog 2.5), пока ручные команды.

Эта форма деплоя применяется ко всем Go-сервисам (orchestrator, state-service). Python-сервисы используют свою форму (rsync + `systemctl restart`).

### env-заготовка под mTLS интеграцию с compliance-logic

В `/etc/mail-stack/orchestrator.env` присутствуют переменные `COMPLIANCE_LOGIC_URL`, `COMPLIANCE_LOGIC_API_KEY`, `COMPLIANCE_LOGIC_CA_CERT`. **Соответствующего кода (activities/compliance.go) пока нет.** Заготовка под будущий DEC, в котором orchestrator будет ходить в `compliance-logic /statements/ingest` напрямую (вариант — пока ходит косвенно через `activities/ingest.go` working tree без mTLS).

Решение по этому DEC откладывается: до фактического деплоя statement_vacuum пути и эффекта.
