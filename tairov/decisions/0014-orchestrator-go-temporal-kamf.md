# DEC-014 — Orchestrator: Go custom v1 → Temporal headless v2 → KAMF v3

## Status

Accepted (13.05.2026). **v1 реализуется сегодня**, v2 и v3 — открытые направления с явными триггерами и обоснованием.

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
- Плюсы: индустриальный стандарт для document/data pipelines, карьерный сигнал
- Минусы:
  - 500+ МБ RAM (worker + scheduler + webserver + Postgres + Redis для Celery)
  - DAG-парадигма для batch jobs, не для webhook-driven workflows
  - Over-engineering для 4-сервисного стека
  - Без data engineering background — выглядит как «один раз попробовать»
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
  - Сложность обучения SDK без готового прототипа кода
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
- Демо на ИЦК/АП РФ/Минцифры — показ KAMF на работающем продукте
- Карьерный/продуктовый сигнал «свой framework production-proof»

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
- **Compliance Helper как production-proof для KAMF.** На ИЦК Электроэнергетика 26.05 — показ KAMF архитектуры с референсом на работающую B2B-имплементацию (документооборот ИП Таирова). Позиционирование: «не теоретический стандарт, а проверенный на конкретном бизнес-кейсе».

**Стратегический сигнал:** Trio-эволюция Go custom → Temporal headless → KAMF — это **уникальный архитектурный путь** для AI/Compliance B2B-стартапа в РФ. Это **дороже** чем «взять SaaS и склеить», но **сильно дешевле** чем retrofit production-grade требований на работающую систему позже. На собеседованиях AI Architect такой путь демонстрирует **системное архитектурное мышление**, не «как сделать быстро».

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
