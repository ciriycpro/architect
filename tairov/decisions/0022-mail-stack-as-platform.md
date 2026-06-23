# DEC-022 — Mail-stack as reusable tool platform

## Status

Accepted (13.05.2026) — **архитектурный roadmap**. Реализация постепенная: принципы применяются начиная с v1.1, конкретные шаги формализуются по триггерам (см. ниже).

## Context

Mail-stack v1.0 реализован как поддержка одного бизнес-процесса: **email digest для одного клиента (Таиров)**. Сейчас 4 микросервиса (mail, attachment, parser, summary) вызываются **из одного потребителя** (orchestrator) с одной цепочкой.

**Но на горизонте видны множественные сценарии использования тех же тулов:**

| Будущий потребитель | Какие тулы использует |
|---|---|
| **Compliance Logic Layer** (DEC-023, будущий) — обработка документов на Google Drive, классификация писем, автоответы контрагентам | parser, summary + outbound email через Agent Caller |
| **Mail Check On-Demand workflow** (DEC-013) — отдельный workflow с другим промптом | mail (с state) + summary (другой промпт) |
| **KAMF-агенты** (v3-v4) — собственный multi-agent framework | parser как vision-tool, summary как LLM-tool, mail как inbox-source |
| **MCP-server обёртка** (v1.4-v2) — внешние AI-assistants (Claude Desktop, ChatGPT, etc) | все тулы доступны через MCP-протокол |
| **Multi-tenant** (v2+) — несколько клиентов одновременно | те же тулы + tenant isolation |
| **Внутренний tooling Артёма** (например, его собственная почта, аналитика других проектов) | те же тулы, разный конфиг |

**Архитектурный вывод:** mail-stack — это **не "часть orchestrator'a"**, это **domain-platform** с переиспользуемыми инструментами. Каждый микросервис — **production-grade tool**, который должен работать корректно при вызове из **любого** потребителя.

Это **infrastructure-as-product** паттерн.

## Decision

Принять **архитектурный принцип "mail-stack as reusable tool platform"**. Реализация — поэтапно по 5 направлениям:

### 1. Стабилизация контрактов

**Принцип:** контракты тулов **замораживаются** после v1.0. Каждый breaking change — дорогой (затрагивает всех потребителей).

**Версионирование API при необходимости breaking change:**
```
/v1/parse  (текущий)
/v2/parse  (новый, рядом с v1)
```
Оба работают, потребители переключаются по своему графику.

**Применение:** начиная с v1.1. Любое изменение контракта = либо backward-compatible add, либо новая версия пути.

**Триггер реализации**: первый breaking change в контракте mail-stack. Реализуется внутри существующего сервиса (новый роут `/v2/parse` рядом с `/v1/parse`), отдельного ADR на versioning не требуется.

### 2. Observability per-tool

**Принцип:** каждый тул должен **знать кто его вызвал** для:
- Метрик использования
- Биллинга (на v3 multi-tenant)
- Алертов
- Debug-correlation

**Реализация — header `X-Caller-Id`:**
```
GET /mail/since/2026-05-13T15:00
X-Caller-Id: orchestrator
X-Trace-Id: 019e2227-...

POST /parse
X-Caller-Id: mcp-claude-desktop
X-Trace-Id: ...
```

**Применение:** начиная с v1.2. Сейчас orchestrator пробрасывает X-Trace-Id — добавим X-Caller-Id.

**Метрики per-tool per-caller** (Prometheus):
- `mail_stack_calls_total{tool, caller, outcome}` — counter
- `mail_stack_call_duration_seconds{tool, caller}` — histogram
- `mail_stack_cost_usd_total{tool, caller}` — counter (для summary, parser-LLM)

**Триггер для DEC-024 «Observability layer»**: второй потребитель кроме orchestrator.

### 3. Rate limiting per-tool

**Принцип:** rate limit должен стоять на **тулах**, не на потребителях. Один потребитель может зафлудить **всех остальных**.

**Применение:** начиная с v1.3 или раньше если будет реальная угроза:
- `mail-service`: max 100 req/min (защита IMAP-сессии от lock)
- `attachment-service`: max 50 req/min
- `parser-service`: max 30 req/min (LLM-vision дорогой)
- `summary-service`: max 20 req/min (Haiku-цена)

**Per-caller квоты на v3** (multi-tenant): каждый caller имеет свою квоту.

**Триггер для реализации**: появление любого второго реального потребителя.

### 4. Auth per-tool

**Принцип:** микросервисы не должны доверять localhost. На v1.0 — доверяли (один сервер, один потребитель). На v2+ — **зеро-trust** между микросервисами.

**Применение — поэтапно с DEC-017:**
- **DEC-017 Уровень 1** (триггер: первый внешний потребитель): X-API-Key header per-tool — orchestrator знает API-keys всех тулов, тулы проверяют входящие
- **DEC-017 Уровень 2** (триггер: ротация креденшалов потребовалась): API-keys в Vault, ротация
- **DEC-017 Уровень 3** (триггер: на горизонте масштабирования): mTLS между микросервисами через self-signed CA

**Триггер для DEC-017 Уровень 1**: первое появление **внешнего** потребителя (например, MCP-server, который может теоретически быть скомпрометирован).

### 5. Документация контрактов

**Принцип:** контракты должны быть документированы **отдельно от кода**. Сейчас они живут в head'ах activities-кода orchestrator'a — это не масштабируется на новых потребителей.

**Реализация — OpenAPI spec для каждой ручки:**
```
mail-stack/
├── mail-service/
│   ├── server.py
│   └── openapi.yaml        ← добавится
├── attachment-service/
│   ├── server.py
│   └── openapi.yaml        ← добавится
├── parser-service/
│   ├── server.py
│   └── openapi.yaml        ← добавится
└── summary-service/
    ├── server.py
    └── openapi.yaml        ← добавится
```

**FastAPI генерирует OpenAPI автоматически** — нужно только включить и зафиксировать в git.

**Применение:** v1.2 или v1.3 (когда появится MCP-обёртка или второй потребитель).

**Триггер для DEC-025 «OpenAPI documentation layer»**: запрос «как использовать mail-stack из X» от любого внешнего потребителя.

## Не делаем сейчас

**Multi-mailbox для одного пользователя** (Apple + Gmail + mail.ru у одного клиента) — это **не multi-tenant**. Реализуется в mail-service на v1.1 без архитектурных изменений: env-список ящиков, цикл по mailboxes, объединение писем, один summary, одна доставка. См. DEC-014 v1.1 roadmap.

**Multi-tenant** (несколько клиентов с изоляцией данных) — отдельная архитектурная задача, **DEC-026** на v2.0+. Триггер: второй платящий клиент. Объём работы — 2-3 недели.

**MCP-server обёртка** — отдельная задача, **DEC-027** на v1.4. Триггер: запрос интеграции с Claude Desktop / другим AI-assistant.

**Compliance Logic Layer** — отдельный домен, **DEC-023** когда появится понимание конкретных compliance-задач после демо Таирову. Реальные кейсы зафиксируем когда заказчик их назовёт (обработка документов на Google Drive, классификация писем, автоответы контрагентам, etc).

## Consequences

**Плюсы:**

- ✅ **Готовность к росту** — каждый следующий потребитель плагается без переделки тулов
- ✅ **Senior-сигнал** — infrastructure-as-product, не «один продукт для одного клиента»
- ✅ **Бизнес-сигнал** — на демо клиентам можно показать «у нас не SaaS-приложение, а platform с переиспользуемыми инструментами»
- ✅ **Снижение TCO будущих фич** — каждая новая фича использует существующие тулы, не дублирует логику

**Минусы:**

- ❌ **Дополнительная сложность** в API (versioning, headers, OpenAPI) — на v1.0 это пока не нужно, на v2+ окупается
- ❌ **Дисциплина** требуется — нужно следить чтобы контракты действительно не ломались. Митигация: автотесты на контракты в CI

**Открытые вопросы:**

- **DEC-023 «Compliance Logic Layer»** — когда станет понятен конкретный набор compliance-задач после демо Таирову. Включает в себя обработку документов на Google Drive, классификацию писем, и **outbound email-channel через Agent Caller `/send-email`** для автоответов контрагентам, отправки подписанных документов, подтверждений получения. Email-канал у Agent Caller готов, не используется на v1.0 (входящий поток не требует ответов). Активируется когда compliance-логика будет писать обратно.

  **Архитектурная дискуссия (14.05.2026, открытый вопрос для DEC-023):** Compliance Logic Layer — это **бизнес-логика без LLM-вызовов** (rules engine, SLA-tracking, audit log, state machine, multi-tenant изоляция, notification routing). LLM-операции (parse, summary, classify) остаются в mail-stack Python-микросервисах как переиспользуемые тулы. Это создаёт естественное архитектурное разделение:

  ```
  ┌─────────────────────────────────────────────┐
  │  BUSINESS LOGIC LAYER (без LLM)             │
  │  - Compliance rules engine                  │
  │  - SLA tracking & state machines            │
  │  - Multi-tenant isolation                   │
  │  - Audit log (152-ФЗ)                       │
  │  - Notification preferences                 │
  │  - Scheduling                               │
  │  - Webhook receivers                        │
  └──────────────────┬──────────────────────────┘
                     │ HTTP calls
                     ▼
  ┌─────────────────────────────────────────────┐
  │  AI/ML TOOLS LAYER (mail-stack, Python)     │
  │  - parser-service (LLM vision)              │
  │  - summary-service (LLM digest)             │
  │  - classifier-service (новый, LLM classify) │
  │  - mail / attachment / future agents        │
  └─────────────────────────────────────────────┘
  ```

  **Кандидаты для business-logic слоя:**

  1. **Spring Boot 3 + Spring AI + Temporal Java SDK** — enterprise-grade JVM-стек. Плюсы: Spring Security для AAA, Spring Data JPA для multi-tenant Postgres с RLS, Spring Statemachine для compliance-flows, Spring Cloud GCP для Google Drive API, **на 10+ клиентах JVM дешевле Python** за счёт CPU throughput. Spring AI имеет native поддержку OpenRouter/Anthropic для случаев когда внутри business-логики нужен LLM-call (генерация ответа). Минусы: третий язык в стеке (Python + Go + Node.js + Java), команда должна управлять 4 экосистемами (на масштабах микро-проекта с enterprise-качеством — приемлемо).

  2. **Python (LangGraph / CrewAI / FastAPI + Celery)** — однородный стек со mail-stack. Плюсы: один язык, переиспользование Python-экспертизы, быстрый старт. Минусы: на growing trafic уступает JVM по throughput, Spring Security/Data зрелее для enterprise multi-tenant.

  3. **Go** — отдельный микросервис рядом с orchestrator. Плюсы: переиспользование Go-инфраструктуры, минимальный RAM. Минусы: бедная экосистема для enterprise business-logic (auth, ORM, state machines менее зрелые чем Spring/Python).

  **Архитектурный принцип определяющий выбор (не догма):** «**Скорость + производительность + цена определяют выбор языка** для каждого слоя. Брать лучшее с рынка — аксиома. Карьерные сигналы и мода — не обоснование.»

  **Архитектурный принцип two-tier (предлагается к рассмотрению, не утверждён):** «**Любая логика, не требующая LLM-вызовов или ML-моделей**, может реализовываться на business-tier (Spring Boot или альтернатива). Mail-stack Python-микросервисы остаются как domain-tools для AI/ML операций. Это разделение позволяет каждому слою использовать оптимальный технологический стек.»

  **Ограничение которое не должно нарушаться:** Spring Boot (или любой выбранный business-tier язык) **не должен убивать гибкость и инновации** mail-stack — скорость info-процессов и протекание data-flows между микросервисами критичны. Если выбор языка business-tier создаёт bottleneck или усложняет интеграцию с Python-тулами — это плохой выбор.

  **Решение по DEC-023:** конкретный язык business-tier фиксируется при написании самого DEC-023, после понимания первой реальной compliance-задачи (Таиров уже сделал демо, следующие компонент-задачи определят paradigm).
- **DEC-024 «Observability layer»** — Prometheus + Grafana для метрик per-tool. Триггер: 2-й потребитель.
- **DEC-025 «OpenAPI documentation»** — внешний контракт. Триггер: запрос интеграции.
- **DEC-026 «Multi-tenant architecture»** — изоляция данных между клиентами. Триггер: 2-й платящий клиент.
- **DEC-027 «MCP-server обёртка»** — внешний доступ через Model Context Protocol. Триггер: запрос от AI-assistant партнёра.
- **Биллинг per-tool per-caller** на v3 — кто сколько ресурсов использует и сколько платит.

**Стратегический сигнал:** mail-stack как platform — это **дифференциатор продукта**. Конкуренты (если кто-то делает похожее в РФ для МСП) скорее всего строят monolith «email assistant приложение». У нас — **platform с переиспользуемыми инструментами**, на которой можно построить **семейство продуктов**:
- Compliance Assistant (текущий — для МСП)
- AI-секретарь для предпринимателей (другой UX поверх тех же тулов)
- B2B-документооборот для среднего бизнеса (с CRM-интеграциями)
- Personal email triage (B2C, для физлиц)

Все эти продукты — это **разные оркестраторы + промпты + UI** поверх **одних и тех же мейл-тулов**. Это **умножение продуктовой ценности без удвоения разработки**.

## Roadmap по триггерам (не по календарю)

| Шаг | Триггер | Что |
|---|---|---|
| 1. X-Caller-Id header | 2-й потребитель кроме orchestrator | Включить в активити orchestrator + микросервисах |
| 2. OpenAPI spec | Запрос интеграции | Включить FastAPI auto-generated openapi.yaml в git |
| 3. API versioning | Первый breaking change | /v2/parse рядом с /parse |
| 4. Rate limit per-tool | 2-й потребитель | slowapi/токен-bucket на каждом тулу |
| 5. Auth per-tool (X-API-Key) | Внешний потребитель | X-API-Key middleware на mail/attachment/parser/summary |
| 6. mTLS между микросервисами | DEC-017 Уровень 3 | Self-signed CA + сертификаты |
| 7. Multi-tenant | 2-й платящий клиент | DEC-026 — изоляция данных и creds |
| 8. MCP-server | Запрос интеграции | DEC-027 — обёртка над mail-stack для AI-assistants |
| 9. Биллинг per-tool | Multi-tenant активен | Метрики → биллинг → оплата |

Эти шаги **не календарные**, а **по факту требований**. Например, если следующего клиента не будет 6 месяцев — multi-tenant не делаем 6 месяцев. Если завтра придёт партнёр с запросом MCP-интеграции — MCP делаем послезавтра, остальное ждёт.

**Принцип:** **архитектурные изменения по факту требований, не по теоретическому плану.**

## Update (16.05.2026) — Event bus откладывается до DEC-023

В процессе реализации DEC-013 (Mail Check On-Demand + event-driven progress, см. DEC-014 v1.2.2 Implementation Notes) рассматривался вопрос: **использовать ли Kafka/NATS** для прогресс-событий между orchestrator и Agent Caller вместо HTTP POST?

### Аргумент «за Kafka»
«Out-of-the-box event-driven, не изобретать велосипед, KAMF всё равно будет на Kafka».

### Аргументы «против сейчас»

1. **У нас 1 producer + 1 consumer** (orchestrator → Agent Caller). Kafka pub/sub нужна когда **много** подписчиков на одно событие.
2. **Throughput** — 1-3 события в день. Kafka рассчитана на тысячи/сек. Использовать Kafka для 3 событий = молотом гвоздь забивать.
3. **Operational complexity** — +Kafka broker (500 МБ RAM) + ZooKeeper/KRaft (200 МБ) + Go/Node.js producer/consumer code. coo сейчас 51% RAM используется → +900 МБ риск OOM.
4. **Нет replay/audit требований сейчас** — Agent Caller может пропустить событие, юзер просто увидит таймаут guard-таймера через 11 минут. Не критично.
5. **Loose coupling не нужен** — оба сервиса знают друг друга по HTTP URL.
6. **Compliance Logic Layer (DEC-023)** — действительно увеличит количество сервисов до 9-10. Но pattern общения **по умолчанию RPC** (synchronous classify/generate/route). Pub/sub паттерн появится если задачи compliance потребуют one-to-many (события на несколько подписчиков).

### Принятое решение

**Event bus (Kafka/NATS/Redis Streams) рассматривается на DEC-023** при появлении **конкретных pub/sub паттернов** в compliance workflow.

**Эволюционный путь к event-driven:**

```
v1.2.x (сейчас):   HTTP POST между orchestrator и Agent Caller
                    1 producer + 1 consumer, push-pattern, latency <1сек
                    ↓
v2.0 (Temporal):   Temporal Signals — встроенный event pattern в Workflow Engine
                    Без Kafka (Temporal имеет свою очередь внутри)
                    ↓
v2.5 (DEC-023):    Compliance Logic Layer
                    Если задачи требуют one-to-many → возможно NATS / Redis Streams (легче Kafka)
                    Если RPC достаточно → продолжаем HTTP
                    ↓
v3.0 (KAMF):       Kafka родная — multi-agent industrial, real-time stream processing
                    Здесь Kafka оправдана: множество агентов, audit replay, throughput
```

**Архитектурный принцип DEC-022 подтверждается:** **архитектурные изменения по факту требований, не превентивно**. «На всякий случай» Kafka сейчас — это:
- +900 МБ RAM (риск OOM на coo)
- +операционная сложность (мониторинг, retention, schema registry)
- Время не на бизнес-логику compliance

Когда придёт **реальный pub/sub паттерн** (или multi-tenant с 5+ клиентами, или audit replay) — рефакторинг будет **локальный** (только в orchestrator + получатели), не сквозной.

### Spring Boot для DEC-023 — статус обсуждения

Принятое 14.05.2026 рассмотрение **three-tier (BL без LLM на JVM, AI/ML tools на Python)** остаётся **актуальным** и **не противоречит** решению по event bus:

- Spring Boot как business-logic tier — **отдельный вопрос** от транспорта между сервисами
- Между Spring Boot и mail-stack будет **HTTP RPC** (Spring WebClient / RestTemplate) — то же что сейчас orchestrator использует
- Event bus может появиться **внутри** Spring Boot (Spring Cloud Stream) когда станет нужен — это **локальное решение** DEC-023, не сквозное архитектурное

**Финальное решение DEC-023 по конкретному стеку BL** — фиксируется при написании самого DEC-023 после понимания первой реальной compliance-задачи.

## Implementation Notes (23.06.2026) — Полная label/group parity

После санации канона зафиксирована текущая реализация label/group адресации в mail-stack. Принцип DEC-022 о доменно-адресуемых тулах — реализован в обоих ключевых сервисах.

### mail-service: endpoint `GET /mail/since/{since_date}`

Сигнатура (server.py:225-226):

```python
@app.get("/mail/since/{since_date}")
def get_mail_since(since_date: str, mailbox: str = DEFAULT_MAILBOX,
                   label: str = None, group: str = None):
```

Логика фильтрации (server.py:240-251):

```python
# DEC-022 адресация: label=точный ящик, group=набор, иначе — только default-ящики.
# Дайджест-оркестратор зовёт без параметров → default-ящики;
# compliance-orchestrator зовёт ?label=compliance-5458508 → точечный ящик.
if label:
    boxes = [mb for mb in MAILBOXES if mb.get("label") == label]
elif group:
    boxes = [mb for mb in MAILBOXES if mb.get("group") == group]
else:
    boxes = [mb for mb in MAILBOXES if mb.get("default", True)]
if not boxes:
    log.info(f"No mailbox matched (label={label}, group={group}); ...")
    return []
```

`MAILBOXES` загружается из env `MAILBOXES_JSON` — массив объектов с полями `label`, `group`, `default`, `user`, `host`, `port`, `pass`.

### attachment-service: симметричная реализация (07.06.2026)

До 07.06.2026 attachment-service грузил attachments из **всех** ящиков циклом (нарушая DEC-022 принцип адресуемости). 07.06.2026 в проде была развёрнута правка, добавившая label/group filtering в `_imap_find_message`:

```python
# attachment-service/server.py:182
def _imap_find_message(message_id: str, label: str | None = None, group: str | None = None):
    ...
    if MAILBOXES:
        if label:
            boxes = [mb for mb in MAILBOXES if mb.get("label") == label]
        elif group:
            boxes = [mb for mb in MAILBOXES if mb.get("group") == group]
        else:
            boxes = [mb for mb in MAILBOXES if mb.get("default", True)]
```

Сохранён бэкап `server.py.bak.tairov-fix-20260607-0910` для отката. Прод-копия не зеркалирована в `~/compliance-assistant-repo` (sync с 03.06.2026; правка ждёт коммита).

### Цепочка label-routing в DEC-0027 (statement_vacuum_v1, working tree)

Готовый поток (в коде, не задеплоен):

```
orchestrator/cmd/orchestrator/main.go (хардкод MailboxLabel="compliance-5458508")
   ↓
orchestrator/workflow/statement_vacuum_v1.go
   ↓ передаёт Label в активити
orchestrator/activities/mail.go      ─→ GET /mail/since/...?label=compliance-5458508 → mail-service
orchestrator/activities/attachment.go ─→ POST /attach?label=compliance-5458508       → attachment-service
   ↓
IMAP boxes: только тот, у которого label=="compliance-5458508"
```

Принцип DEC-022 («Каждый дёргает свою адресуемую сущность; не маршрутизируем по типу клиента») реализован полностью.

### Open: вынос label в env

`compliance-5458508` зашит литералом в `main.go` строка 119 (working tree). При смене Таирова на другого клиента или подключении второго клиента — пересборка бинаря. Технический долг (cleanup_backlog_v2 п. 2.4): env-переменная `STATEMENT_VACUUM_MAILBOX_LABEL`.
