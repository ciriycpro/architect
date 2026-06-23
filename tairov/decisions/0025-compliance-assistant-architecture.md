# DEC-025 — Compliance Assistant: полная архитектура

## Status

Accepted (23.05.2026). Карта компонентов и языковая раскладка стека комплаенс-ассистента целиком. Связывает существующий mail-stack (DEC-005..024) с business-tier (DEC-023). Открывает плейсхолдеры под будущие ADR. (Refreshed 2026-05-25)

## Context

К 23.05.2026 у комплаенс-ассистента есть:
- **8 production-микросервисов** mail-stack + orchestrator + state-service + Agent Caller
- **Stateless pipeline** «письмо → дайджест» работает
- **DEC-022** зафиксировал twoTier-принцип (BL без LLM → JVM, AI/ML tools → Python), решение по конкретному стеку BL отложено до «первой реальной compliance-задачи»

**Первая реальная compliance-задача сформулирована** (см. `docs/02-compliance-workflow.md`):
- Проактивный поиск пробелов в реестре выписок → запрос недостающих периодов
- Приём ответных писем с классификацией и обновлением реестра
- Сверка операций с основаниями (договор/акт)
- Генерация ответа банку по 115-ФЗ
- Сводная по платежам

**Это переход от stateless pipeline к stateful автомату с памятью и собственной инициативой.**

DEC-025 фиксирует **полную карту** того что нужно построить и **языковую раскладку стека**. Конкретные технологические решения по компонентам — в отдельных ADR (DEC-023, future ADRs).

## Decision

### 1. Архитектурная карта компонентов

```
┌──────────────────────────────────────────────────────────────────┐
│  INFRA TIER (Go) — оркестрация и plumbing                        │
│                                                                  │
│  • orchestrator (DEC-014) ✓                                      │
│    └── workflow "backfill" [planned v1.5 — для Сценария 0]       │
│  • state-service (DEC-021) ✓                                     │
│  • event-bus [future, on demand]                                 │
│  • webhook-gateway [future, on demand]                           │
│  • watchdog [future, on demand]                                  │
└──────────────────────────────────────────────────────────────────┘
         ↓                                            ↓
┌──────────────────────────┐          ┌──────────────────────────────┐
│  AI/ML TIER (Python)     │          │  BUSINESS TIER (Java/Spring) │
│                          │          │                              │
│  • mail-service ✓        │          │  • Registry (JPA + Envers)   │
│  • attachment-service ✓  │          │    └── Document (master)     │
│  • parser-service ✓      │          │    └── Statement/Contract/   │
│  • summary-service ✓     │          │        Act/MoneyOperation/   │
│  • intent-tagger         │          │        ReconciliationFlag    │
│    (расширение summary)  │          │  • Inspector + Scheduler     │
│  • document-classifier   │          │  • Reconciler (engine)       │
│    [future]              │          │  • BackfillService (control  │
│  • reporting-service     │          │    plane) [planned v1.5]     │
│    [future]              │          │  • Document Classifier rules │
│  • contract-vision       │          │    (часть)                   │
│    (часть: scan→signed?) │          │  • Contract Validator        │
│    в parser-service      │          │    (часть: rules/status)     │
│                          │          │  • Template engine           │
│  ← Stateless AI tools    │          │    (Freemarker hot-reload)   │
└──────────────────────────┘          │  • State machines            │
                                      │  • AAA + multi-tenant        │
                                      │  • Outbox (гарантированная   │
                                      │    доставка алертов,         │
                                      │    suppressed_by_historic)   │
                                      │                              │
                                      │  ← Stateful source of truth  │
                                      └──────────────────────────────┘
                                                       ↓
                                       ┌──────────────────────────┐
                                       │  TRANSPORT TIER          │
                                       │                          │
                                       │  • Agent Caller (Node) ✓ │
                                       │    → WA / TG / Email     │
                                       └──────────────────────────┘

         ↓ (хранилище)                          ↑ (источник правды)
┌──────────────────────────────────────────────────────────────────┐
│  STORAGE TIER — Postgres + Filesystem на coo (152-ФЗ ready)       │
│                                                                  │
│  • Postgres 15 на coo — Registry metadata, audit trail           │
│  • Filesystem /var/lib/compliance-files/<inn>/ — blob storage    │
│    ├── staging/  (временно для backfill)                         │
│    ├── statements/                                               │
│    ├── contracts/                                                │
│    └── acts/                                                     │
│  • Drive — опциональный mirror, не runtime-зависимость           │
└──────────────────────────────────────────────────────────────────┘
```

### 2. Языковая раскладка — принципы и обоснования

**Базовый принцип** (наследуется из DEC-022): «Скорость + производительность + цена определяют выбор языка для каждого слоя. Брать лучшее с рынка — аксиома. Карьерные сигналы и мода — не обоснование.»

**Расширение принципа в DEC-025:**

Каждый язык занимает свою нишу по характеру задачи, а не по моде или удобству разработчика.

#### Python — AI/ML Tier

**Берёт:**
- Парсинг документов (PDF/XLSX/DOCX/JPG → текст+таблицы)
- LLM-вызовы (vision на сканы, summary, классификация интентов)
- Document Classifier по содержимому (ML/LLM)
- Rendering документов (docxtpl, openpyxl, LibreOffice headless)
- Всё что использует transformers / langchain / RAG-стек

**Обоснование:** экосистема ML/LLM на Python зрелее и шире чем на любом другом языке. Любая попытка делать парсинг или vision на Java/Go — это переизобретение того что в Python работает в две строки.

**Не берёт:** stateful business logic с типизированной моделью, audit trail, транзакционная сверка нескольких сущностей. Pydantic покрывает ~80% Bean Validation, но Spring Data + Envers по совокупности сильнее SQLAlchemy + sqlalchemy-continuum для enterprise audit под 115-ФЗ.

#### Go — Infra Tier

**Принцип:** Go = high-throughput stateless plumbing с малым RAM. Не лезет в LLM-вызовы и не лезет в сложную бизнес-логику с типизированной моделью данных. Между ними — его территория.

**Берёт:**
- Транспорт между сервисами (orchestrator, HTTP-клиенты)
- Координация workflow (DEC-014 → Temporal → KAMF)
- State management hot-path (Redis-backed, DEC-021)
- Идемпотентность входящих, dedup алертов
- Event Bus (future, Redis Streams под Go-обёрткой когда придут state machines)
- Webhook gateway (future, при банковской интеграции)
- Multi-channel dispatcher (future, рефактор Agent Caller)
- Watchdog (future, cross-service health)

**Обоснование:** RAM 5-15 МБ per сервис, миллисекундная латентность, goroutines под конкурентность из коробки. Это **plumbing-layer** между AI-tools и Business-tier.

**Не берёт:** парсинг (Python), бизнес-логику с типизированной моделью (Java), рендеринг документов (Python).

**Что Go НЕ заменяет в Business Tier:** Registry уходит в Java/Spring **как канон**, не Go. Причина: Hibernate Envers + Spring Data + JPA-связи между сущностями (договор → счета → акты → операции) — индустриальный канон под audit-требования 115-ФЗ. На Go это пришлось бы строить с нуля.

#### Java/Spring — Business Tier

**Берёт:**
- Registry (источник правды о бизнес-сущностях клиента)
- Audit trail через Hibernate Envers (главный аргумент Java в этом стеке)
- Транзакционная сверка нескольких сущностей одновременно (@Transactional)
- Inspector + Scheduler (cron, бизнес-правила поиска пробелов)
- Reconciler engine (правила сверки операций с основаниями)
- State machines per-сущность (Spring Statemachine: per-выписка, per-договор, per-gap)
- AAA + multi-tenant (Spring Security + Spring Data + Postgres RLS)
- Outbox pattern для гарантированной доставки алертов
- Schema evolution через Liquibase
- OpenAPI 3 через springdoc

**Обоснование:** для stateful business-logic с типизированными сущностями, аудитом, транзакциями и AAA — Spring экосистема индустриальный канон. Замена на Python+SQLAlchemy+самописное даёт работающее решение, но менее зрелое для регуляторного аудита.

**Не берёт:**
- mail-stack микросервисы (это AI/ML tools, остаются Python)
- Reporting/Renderer (docxtpl на Python сильнее Apache POI по UX автора шаблона — шаблон правится в самом Word)
- Orchestrator (по DEC-014 — Go → Temporal → KAMF)
- Document/Intent classifier по содержимому (ML/LLM экосистема — Python)
- Vision на скан документа «подписан ли договор» (LLM-vision — Python parser-service)

#### Node.js — Transport Tier

**Берёт:** Agent Caller (whatsapp-web.js — критическая зависимость, удерживает Node.js в стеке)

**Обоснование:** whatsapp-web.js — единственная зрелая опция для неофициального WA-подключения. Telegram/Email можно делать на любом языке, но пока в одном сервисе с WA — экономия на сервисах.

**Будущее:** при росте — multi-channel dispatcher на Go вынесет Telegram/Email/MAX в отдельный сервис, Node.js останется только под WA.

### 3. Карта компонентов: статус, триггер, ADR

| Компонент | Tier | Статус | Триггер реализации | Базовый ADR |
|---|---|---|---|---|
| mail-service | Python | ✓ Production | — | DEC-005 |
| attachment-service | Python | ✓ Production | — | DEC-011 |
| parser-service | Python | ✓ Production | — | DEC-008 |
| summary-service | Python | ✓ Production | — | DEC-009 |
| orchestrator | Go | ✓ Production | — | DEC-014 |
| state-service v1 | Go | ✓ Production | — | DEC-021 |
| Agent Caller | Node.js | ✓ Production | — | (часть DEC-018) |
| **Registry (Client, Document, Statement, ...)** | **Java/Spring** | Planned | DEC-023 v1 | **DEC-023** |
| **Inspector + Scheduler** | **Java/Spring** | Planned | DEC-023 v1 | **DEC-023** |
| **Template engine** | **Java/Spring** | Planned | DEC-023 v1 | **DEC-023** |
| **Compliance-event endpoint** | **Java/Spring** | Planned | DEC-023 v1 | **DEC-023** |
| **BackfillService (control plane)** | **Java/Spring** | Planned | DEC-023 v1.5 | **DEC-023** |
| **Backfill workflow (data plane)** | **Go (orchestrator)** | Planned | DEC-023 v1.5 | DEC-014 (расширение) + DEC-023 |
| **Document storage** | **Postgres + Filesystem** | Planned | DEC-023 v1 | DEC-023 |
| Reconciler | Java/Spring | Planned | DEC-023 v2 | DEC-023 |
| Document Classifier | Python (часть Java) | Planned | После первой volume-нагрузки | Future ADR |
| Reporting-service | Python | Planned | Сценарий 4 (ответ банку) запроса | Future ADR |
| Intent Tagger | Python (в summary) | Planned (расширение) | Совместно с DEC-023 v1 | Расширение DEC-009 |
| Contract Validator (vision) | Python (в parser) | Planned (расширение) | Сценарий 3 (сверка) | Расширение DEC-008 |
| State machines | Java/Spring | Planned | DEC-023 v2 | DEC-023 |
| **OpenTelemetry tracing** | **All tiers** | Planned | DEC-023 v2.5 | **DEC-023** |
| AAA + multi-tenant | Java/Spring | Planned | 2-й клиент | DEC-023 vN |
| Outbox для алертов | Java/Spring | Planned | DEC-023 v2 | DEC-023 |
| state-service v2 (idempotency + dedup) | Go | Planned | DEC-023 v1 запуск | Расширение DEC-021 |
| Event Bus | Go | Future | После Reconciler | Future ADR |
| Webhook gateway | Go | Future | Внешние callback (банк API) | Future ADR |
| Multi-channel dispatcher | Go | Future | Рост канало в | Future ADR |
| Watchdog | Go | Future | 8+ сервисов | Future ADR |
| Filer | Python или Go | Planned | DEC-023 v1 (Drive раскладка) | Future ADR |

### 4. Связь с существующими ADR

| Существующий ADR | Связь с DEC-025 |
|---|---|
| DEC-005..011 (mail-stack) | Mail-stack остаётся как AI/ML tier. DEC-025 фиксирует это как канон, не пытается переписать |
| DEC-013 (Mail Check On-Demand) | Workflow on-demand работает в orchestrator, business-логика проверки переедет в Inspector (DEC-023) на v2 |
| DEC-014 (Orchestrator Go → Temporal → KAMF) | Не меняется. DEC-025 добавляет orchestrator вызов `POST /compliance-event` в Spring tier как новую activity |
| DEC-017 (Secure by Design) | Spring Boot tier унаследует Уровень 0 (X-API-Key + bind 127.0.0.1 + systemd hardening). Multi-tenant закроет Уровень 2-3 при 2-м клиенте |
| DEC-018 (Multi-channel notification) | Agent Caller остаётся. Spring tier зовёт его через HTTP вместо orchestrator (для проактивных алертов из Inspector/Scheduler) |
| DEC-021 (state-service v1) | Расширяется на v2 с idempotency keys + alert dedup. См. DEC-023 implementation |
| DEC-022 (Mail-stack as platform) | DEC-025 — реализация принципа twoTier из DEC-022. Конкретный язык business-tier (Java/Spring) утверждён |
| DEC-024 (Mail-stack v1.1 fixes) | Не связан |

### 5. Принципы поведения системы (фиксируются на уровне архитектуры)

Из `docs/02-compliance-workflow.md`:

1. **Человек подписывает всегда** — система не отправляет документы внешним получателям автоматически
2. **Audit trail обязателен** — Envers на каждое изменение Registry
3. **Алерты дедуплицируются** — один gap не рассылается каждый день
4. **Шаблоны — в Git** — отдельный репо `Compliance-Templates`, Freemarker hot-reload
5. **Идемпотентность входящих** — sha256(messageId+from+date) через state-service v2
6. **Multi-tenant ready с первого дня** — все сущности Registry имеют `client_id`

### 6. Ограничения которые не нарушаются

Из DEC-022 (унаследованы):

- **Spring Boot не должен убивать гибкость mail-stack.** Скорость и протекание data-flows между Python-микросервисами критичны. Если Spring Boot tier создаёт bottleneck или усложняет интеграцию с Python-tools — это плохой выбор.
- **Business-tier не пытается заменить AI-tier.** Reporting остаётся Python, парсинг остаётся Python, vision остаётся Python.
- **Orchestrator остаётся Go** (DEC-014). Spring tier — это **потребитель** compliance-event'ов, не их источник.

## Consequences

### Положительные

- ✅ **Чёткое разделение ответственности по слоям** — каждый язык в своей нише
- ✅ **Карта будущих ADR** — на 12 месяцев вперёд понятно что и в каком порядке писать
- ✅ **Mail-stack защищён от лезущих в него изменений** — Business-tier не пытается его переписать
- ✅ **Audit trail на индустриальном каноне** — Envers даёт автоматический ответ на запрос «история изменений» от регулятора
- ✅ **Multi-tenant архитектурно заложен с v1** — приход 2-го клиента не требует рефакторинга
- ✅ **Реалистичная декомпозиция** — компоненты разнесены по триггерам реализации, не пишутся одновременно

### Отрицательные

- ❌ **Четыре runtime'a на coo** — Python, Go, Node.js, Java. Operational complexity растёт.
  - Митигация: каждый сервис самодостаточен, изоляция через systemd, единый стиль логирования (slog-совместимый JSON)
- ❌ **JVM прожорлив по RAM** — Spring Boot 300-500 МБ на сервис.
  - На coo (e2-small, 2 GB RAM) — на грани. Решение: размещаем как есть, при OOM апгрейд до e2-medium (4 GB, +$4/мес)
- ❌ **Onboarding Spring Boot-стека** — несколько недель плотной работы до production-готовности v1
  - Митигация: первая итерация DEC-023 — минимальная (Registry + Inspector + Scheduler + 1 endpoint + Freemarker), без StateMachine/AAA/Outbox. Эти компоненты на v2+ когда придёт нагрузка
- ❌ **Spring Boot не панацея для multi-tenant** — Spring Data multi-tenancy и Postgres RLS требуют осознанной настройки, не из коробки
  - Митигация: фиксируется как часть DEC-023 vN при приходе 2-го клиента

### Открытые вопросы

- **Postgres deployment**: на coo же (Stop+resize при OOM) или отдельная VM `db-coo`. Решение отложено до момента первого OOM
- **Event Bus**: внутренний Spring events vs внешний Redis Streams + Go-обёртка. Решается в DEC-023 v2 (Reconciler) когда появятся cross-component события
- **Reporting-service** как отдельный микросервис vs модуль внутри какого-то существующего сервиса. Future ADR
- **State persistence стратегия**: state-service v2 + Postgres-mirror для audit log. Решение в расширении DEC-021

## Roadmap реализации

| Веха | Что | Зависимости | Целевой срок |
|---|---|---|---|
| **DEC-023 v1.0** | Registry (минимум) + Inspector + Scheduler + Template engine + endpoint POST /compliance-event + интеграция с Agent Caller + Postgres на coo + Document storage | DEC-025 (этот) | На горизонте 1-2 недель |
| **State-service v2** | idempotency keys + dedup + in-flight tracker | DEC-023 v1.0 запуск | Совместно с DEC-023 v1.0 |
| **DEC-023 v1.1** | Document Classifier rules в Spring tier + расширение mail-stack Intent Tagger | DEC-023 v1.0 в проде | Через 2-3 недели после v1.0 |
| **DEC-023 v1.5 BackfillService + Bootstrap** | Control plane на Spring (`/admin/backfill`) + orchestrator workflow `backfill` + Сценарий 0 (12 месяцев архивных документов в Registry, suppressed_by_historic) + сводный отчёт по завершении | DEC-023 v1.0 в проде, endpoint `/compliance-event` рабочий | После v1.0, до v2.0 |
| **Reporting-service ADR + реализация** | Python микросервис рядом с mail-stack, docxtpl + openpyxl | Сценарий 4 запрос банка | По триггеру (запрос банка пришёл) |
| **DEC-023 v2.0 Reconciler** | Engine сверки, state machines, Outbox | DEC-023 v1.0 + первая полноценная выписка с операциями | 4-6 недель после v1.0 |
| **Contract Vision** | Расширение parser-service: scan→signed/unsigned via LLM-vision | DEC-023 v2.0 | Совместно с Reconciler |
| **DEC-023 v2.5 OpenTelemetry tracing** | W3C `traceparent` через все tiers (orchestrator → mail-stack → Spring) + Jaeger/Tempo на coo + корреляция span_id/trace_id с JSON-логами (MDC уже готов) | 5+ сервисов в цепочке + debugging-задача "почему запрос долго" | По триггеру производительности/debugging |
| **DEC-023 v3.0 Multi-tenant** | Spring Security + Spring Data multi-tenancy + Postgres RLS | 2-й клиент | По триггеру |
| **Event Bus ADR** | Go + Redis Streams внутренняя шина | После Reconciler, при cross-component событиях | По триггеру |
| **Watchdog / Multi-channel dispatcher / Webhook gateway** | Future Go-сервисы | Рост числа сервисов / внешние интеграции | По триггеру |
| **gRPC миграция** | OpenAPI 3 → Protobuf для cross-tier RPC. Полу-автоматическая через конвертеры | Performance bottleneck или строгие типы | По триггеру |

## References

- `docs/02-compliance-workflow.md` — Service Blueprint поведения системы
- DEC-022 — twoTier-принцип и обсуждение Spring Boot как business-tier
- DEC-023 — конкретная реализация Compliance Logic Layer на Spring Boot
- DEC-014 — orchestrator (Go) как координатор workflow
- DEC-021 — state-service v1 (Go), кандидат на расширение v2

## Implementation Notes (23.06.2026) — карта компонентов после Commit 5

После санации канона зафиксирована актуальная карта компонентов системы по факту на coo (см. также DEC-0023 Notes v0.0.7, DEC-0027 Notes 23.06.2026).

### Компоненты compliance-logic (Java/Spring Boot, business-tier)

**Сервисы (17 классов после Commit 5):**

| Сервис | Назначение | Состояние |
|---|---|---|
| `DocumentService` | Storage + sha256-dedup | в проде |
| `StatementService`, `MoneyOperationService`, `CounterpartyService`, `ClientService` | CRUD сущностей реестра | в проде |
| `BackfillService` | GDrive-based одноразовая массовая заливка истории | в проде (с v0.0.4) |
| `InspectorService` | Сканирует client → ищет gaps в `statement_calendars` | в проде (v2 с v0.0.5) |
| `InspectorScheduler` | `@Scheduled` cron для Inspector | в проде |
| `ReconcilerService` | Сверка операций↔договоров, создание `ReconciliationFlag` | в проде |
| `ReconcilerScheduler` | cron 10:30 МСК для Reconciler.rescanAll | в проде |
| `StatementIngestService` | Принимает statement через `/statements/ingest`, ingest+scanClient sync | в проде (v0.0.7) |
| `GapAlertOrchestrator` | Алёрт-loop по statement_gaps с SQL-фильтром по flag_type | в проде (v0.0.7) |
| `OrchestratorScheduler` | `@Scheduled` для GapAlertOrchestrator (16:30 МСК) | в проде (v0.0.7) |
| `NotificationService` | CRUD + write-API для audit-журнала исходящих | в проде (v0.0.7) |
| `HttpCallerClient` (impl. `CallerPort`) | HTTP к agent-caller на :3000 для WA/TG | в проде (timeout 120с, +300с в working tree) |
| `CounterpartyNameNormalizer` | ООО/ИП/АО/ПАО + чистка артефактов выписки | в проде |

**Entity (14 классов):** Client, Tenant, Counterparty, Document, Statement, MoneyOperation, Contract, Act, ReconciliationFlag, StatementCalendar, StatementGap, ComplianceEvent, BackfillJob, Notification. Все @Audited (Envers) кроме Notification (append-only).

**БД на coo (29 таблиц):** 14 бизнес + 14 audit + revinfo. Последняя миграция `0023-2-add-statement-account-aud` (02.06.2026).

### Компоненты orchestrator (Go, инфра-tier)

**Workflows:**
- `email_digest_v1.go` — дайджест Таирову/Артёму **в проде** (v1.2.2 с 16.05.2026).
- `statement_vacuum_v1.go` — пылесос выписок для DEC-0027 **в working tree, не задеплоен**.
- `contracts_vacuum_v1.go` — пылесос договоров для DEC-0028 **не написан**.

**Activities:** mail, attachment, parser, summary, notify, state, telegram, whatsapp, types. Все в проде. `ingest.go` (для DEC-0027 ingest в compliance-logic) — в working tree, не задеплоен.

**Cron:** один cron `c` для email_digest. Второй cron `c2` для statement_vacuum — в working tree, не задеплоен. Соответствующие env-переменные в `/etc/mail-stack/orchestrator.env`: `ORCHESTRATOR_SCHEDULE` (digest), `STATEMENT_VACUUM_SCHEDULE` (vacuum, заготовлено).

### Компоненты mail-stack (Python, инфра-tier)

| Сервис | Порт | Состояние |
|---|---|---|
| `mail-service` | 8765 | в проде, поддержка `?label=&group=` (DEC-022 parity) |
| `attachment-service` | 8766 | в проде, label/group fix 07.06.2026 (DEC-022 parity полная) |
| `parser-service` | 8767 | в проде, endpoint `/parse-statement` (DEC-0027), модули statement_parser/statement_xlsx (ВТБ-only) |
| `summary-service` | 8768 | в проде (без правок с 13.05.2026) |
| `agent-caller` | 3000 | в проде (Node.js, WhatsApp+Telegram через whatsapp-web.js + node-telegram-bot-api) |

### Компоненты state-service (Go)

`state-service` (8770) — Redis-backed last_at + chat lock. В проде с 16.05.2026 (DEC-021).

### Карта связей (по факту, 23.06.2026)

```
                      ┌──────────────────────────────────────────┐
                      │  agent-caller :3000  (Node.js + Chrome)  │
                      └──▲────────────────────────────────▲──────┘
                         │ /send-wa, /send-tg             │
                         │                                │
            ┌────────────┴─────────────┐    ┌─────────────┴───────────┐
            │   compliance-logic :8771 │    │   orchestrator :8769    │
            │   (Spring Boot, mTLS)    │    │   (Go custom)           │
            │                          │    │                         │
            │   GapAlertOrchestrator───┘    │   workflows:            │
            │   ReconcilerService           │   - email_digest_v1 ✅  │
            │   InspectorService            │   - statement_vacuum ⏸  │
            │   StatementIngestService◄─────┤     (working tree)      │
            │                          │    │                         │
            └──┬───────────────────────┘    └──┬─────────────┬─────┬──┘
               │                               │             │     │
               │ Postgres                      │             │     │
               │ 29 tables                     ▼             ▼     ▼
               ▼                          mail-svc    attach-svc  parser-svc
        ┌────────────┐                    :8765       :8766       :8767
        │ postgres   │                    (?label=)   (?label=)   (/parse-statement)
        │ 14 biz +   │                                 ▲
        │ 14 aud +   │                                 │ summary-svc :8768
        │ revinfo    │                                 │ (Haiku+DeepSeek fallback)
        └────────────┘
                                                       ▼
                                                  state-service :8770
                                                  (Redis last_at + lock)
```

**Status:** `email_digest_v1` (Mail Reader, дайджест) — единственный замкнутый контур; statement-vacuum серверная склейка готова (Java+Python), но orchestrator-half не задеплоен → входящий контур DEC-0027 наполовину висит (Open #1). DEC-0028 не запущен.
