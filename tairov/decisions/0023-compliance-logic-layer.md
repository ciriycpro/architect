# DEC-023 — Compliance Logic Layer: Spring Boot business tier

## Status

Accepted (23.05.2026). Конкретное технологическое решение для **business-tier** (см. DEC-022, DEC-025). Реализация v1.0 — на горизонте 1-2 недель.

## Context

DEC-022 «Mail-stack as Platform» зафиксировал twoTier-принцип: «Любая логика, не требующая LLM-вызовов или ML-моделей, может реализовываться на business-tier. Mail-stack Python-микросервисы остаются как domain-tools для AI/ML операций.» Решение по конкретному языку business-tier откладывалось до «первой реальной compliance-задачи».

DEC-025 утвердил **архитектурную карту** комплаенс-ассистента и языковую раскладку. Business-tier — **Java/Spring**, Reporting остаётся **Python**, Orchestrator — **Go** (DEC-014).

DEC-023 — **конкретная реализация** business-tier: стек, минимальная модель данных, контракты, deployment.

## Decision

### Стек

- **Java 21 LTS** (текущая LTS)
- **Spring Boot 3.2+**
- **Spring Web** для REST API
- **Spring Data JPA + Hibernate** для ORM
- **Hibernate Envers** для audit trail (115-ФЗ requirement)
- **Liquibase** для миграций схемы
- **Postgres 15** для хранения (на том же coo, упрётся в RAM — апгрейд)
- **Bean Validation (Jakarta Validation)** для DTO
- **Freemarker** для шаблонов сообщений (Word/PDF документы — это другой пайплайн, см. Reporting-service в DEC-025)
- **springdoc-openapi** для автогенерации OpenAPI 3 из аннотаций
- **Spring Boot Actuator** для health checks и metrics
- **Micrometer + Prometheus exporter** для метрик
- **slf4j + logback** с JSON-форматом (совместимый с slog mail-stack для единого пайплайна логов)

**На v1.0 НЕ включаем:**
- Spring Security (AAA) — v3.0 при 2-м клиенте
- Spring Statemachine — v2.0 при Reconciler
- Spring Cloud Stream — future ADR Event Bus
- GraalVM native image — преждевременная оптимизация
- Spring AI — пока нет случая когда LLM нужно вызывать из business-логики

### Сервис

**Имя:** `compliance-logic-service`

**Деплой:**
- Путь на coo: `/opt/compliance-logic/`
- systemd unit: `compliance-logic.service`
- Port: 8771 (следующий свободный после state-service:8770)
- Запуск: `java -jar compliance-logic.jar` через systemd
- Env: `/etc/mail-stack/compliance-logic.env` (chmod 600 root:root)
- Логи: stdout → systemd-journald

**Postgres:**
- Той же coo, instance `compliance_pg`
- Port: 5432 bind 127.0.0.1
- Database: `compliance`
- User: `compliance_app` (с правами на схему `public`)
- Backup: pg_dump через cron в `/var/backups/postgres/` ежедневно, retention 7 дней

### Минимальная entity-модель v1.0

```
Client                 — клиент комплаенс-ассистента (Таиров, будущие)
  ├── inn (unique)
  ├── full_name
  ├── phone (для WA)
  ├── status (ACTIVE, INACTIVE)
  └── created_at, updated_at

Counterparty           — контрагенты клиента
  ├── inn
  ├── name
  ├── client_id (FK → Client)
  └── trust_level (TRUSTED, NEUTRAL, FLAGGED)
  uniqueness: (client_id, inn)

Document               — master-сущность для всех файлов (выписки, договоры, акты, счета)
  ├── id (UUID)
  ├── client_id (FK → Client)
  ├── type (STATEMENT, CONTRACT, ACT, INVOICE, OTHER)
  ├── source (EMAIL, MANUAL_UPLOAD, BACKFILL_IMPORT)
  ├── historic (boolean) — true для backfill, false для real-time
  ├── file_path (например, /var/lib/compliance-files/<inn>/statements/2025-04_sber.xlsx)
  ├── sha256 (для дедупа по содержимому)
  ├── mime_type
  ├── size_bytes
  ├── original_filename
  ├── attributes (JSONB — гибкие атрибуты по типу документа)
  ├── parsed_at (когда parser-service извлёк текст)
  ├── classified_at (когда type был определён)
  └── created_at, updated_at
  uniqueness: (client_id, sha256) — дедуп

Statement              — банковская выписка (специализация Document)
  ├── document_id (FK → Document)
  ├── client_id (FK)
  ├── bank_name (sberbank, alfa, vtb, ...)
  ├── period_start, period_end
  ├── source_message_id (для EMAIL — ссылка на письмо в mail-service)
  ├── amount_total (агрегат сумм операций)
  ├── operation_count
  └── status (RECEIVED, PARSED, VERIFIED, FLAGGED)
  attributes (в Document.attributes): {currency, opening_balance, closing_balance, format_version, ...}

StatementGap           — обнаруженный пробел в выписках
  ├── client_id (FK)
  ├── bank_name
  ├── gap_start, gap_end
  ├── status (DETECTED, REQUEST_SENT, RECEIVED, CLOSED)
  ├── detected_at
  ├── last_request_at
  └── closed_at

Contract               — договор клиента с контрагентом (специализация Document)
  ├── document_id (FK → Document)
  ├── client_id (FK)
  ├── counterparty_id (FK)
  ├── number
  ├── signed_at, expires_at
  ├── status (DRAFT, ACTIVE, EXPIRED, TERMINATED)
  ├── amount
  └── source_message_id
  attributes (в Document.attributes): {subject_type, payment_schedule, signed_pages, signature_verified, ...}

Act                    — акт выполненных работ (специализация Document)
  ├── document_id (FK → Document)
  ├── client_id (FK)
  ├── contract_id (FK, nullable)
  ├── counterparty_id (FK)
  ├── number
  ├── act_date
  ├── amount
  └── status (DRAFT, SIGNED)

MoneyOperation         — операция в выписке (производная)
  ├── statement_id (FK → Statement)
  ├── client_id (FK)
  ├── counterparty_id (FK, nullable если ИНН не извлечён)
  ├── operation_date
  ├── amount
  ├── direction (DEBIT, CREDIT)
  ├── purpose (назначение платежа)
  └── linked_contract_id, linked_act_id (после Reconciler)

ReconciliationFlag     — флаг сверки от Reconciler
  ├── client_id (FK)
  ├── operation_id (FK → MoneyOperation, nullable)
  ├── document_id (FK → Document, nullable)
  ├── flag_type (MISSING_CONTRACT, DRAFT_ONLY, EXPIRED, UNSIGNED_ACT, AMOUNT_MISMATCH)
  ├── severity (INFO, WARN, CRITICAL)
  ├── raised_at
  ├── resolved_at (nullable)
  └── notes (text)

ComplianceEvent        — лог входящих событий из orchestrator
  ├── event_id (UUID, idempotency)
  ├── trace_id (UUID, проброс из orchestrator)
  ├── event_type
  ├── source (EMAIL, BACKFILL, MANUAL) — откуда пришло
  ├── historic (boolean) — true для backfill, false для real-time
  ├── payload (JSONB)
  ├── received_at
  └── processed_at

BackfillJob            — управление batch-задачей загрузки исторических данных
  ├── id (UUID)
  ├── client_id (FK)
  ├── source (STAGING_FILESYSTEM, DRIVE_DOWNLOAD)
  ├── source_path (для STAGING_FILESYSTEM: /var/lib/compliance-files/<inn>/staging/)
  ├── period_start, period_end (за какой период загружаем)
  ├── status (PENDING, RUNNING, COMPLETED, FAILED)
  ├── files_total, files_processed, files_failed
  ├── started_at, completed_at
  └── error_summary (nullable, JSONB)

OutboxMessage          — исходящие алерты (для гарантированной доставки)
  ├── id
  ├── client_id (FK)
  ├── channel (WA, TG, EMAIL)
  ├── template_id
  ├── rendered_text
  ├── status (PENDING, SENT, FAILED)
  ├── suppressed_by_historic (boolean) — true если событие из backfill (не алертим)
  ├── created_at, sent_at
  └── retry_count
```

**Все сущности `@Audited`** — Envers пишет историю в `*_AUD` таблицы автоматически. Это база ответа на регуляторный запрос «история изменений сущности X».

### Document storage strategy

**Принцип:** Postgres хранит **метаданные** документов (типизированные колонки + JSONB attributes), filesystem coo хранит **бинарные blob'ы** в `/var/lib/compliance-files/<client_inn>/`.

**Структура filesystem:**

```
/var/lib/compliance-files/
  └── 050900147847/        ← ИНН Таирова
      ├── staging/          ← временно перед обработкой (Сценарий 0 Backfill)
      ├── statements/
      │   ├── 2025-04_sber_<uuid>.xlsx
      │   └── 2025-05_sber_<uuid>.xlsx
      ├── contracts/
      │   └── <counterparty_inn>_<contract_num>_<uuid>.pdf
      ├── acts/
      │   └── <contract_id>_<act_num>_<uuid>.pdf
      └── other/
          └── (всё что не классифицировано)
```

**Права:**
- Папка `/var/lib/compliance-files/` — `chmod 700`, владелец `iakshin77`
- Внутри клиента — `chmod 700` per-client (multi-tenant isolation)
- На v2.1 (DEC-017 Уровень 2) — шифрование at-rest через `age`

**Источник правды:** наша БД + filesystem coo. Внешние сервисы (Google Drive) — **опциональный mirror/transport**, не runtime-зависимость:
- 152-ФЗ: ПДн физически в РФ
- Контроль аудита через Envers
- Backup: ежедневный `tar` + `pg_dump` в `/var/backups/compliance/`, retention 14 дней
- Сменить любого внешнего провайдера без миграции данных

### REST API v1.0

```
POST   /compliance-event                — приём события от orchestrator
       body: ComplianceEventDTO
       auth: X-API-Key
       idempotency: по event_id
       → 200 { processed: true, registry_changes: [...] }
       → 409 если event_id уже обработан (idempotent reply)

POST   /admin/backfill                  — запуск Bootstrap из архива (Сценарий 0)
       body: BackfillRequestDTO
       auth: X-API-Key
       → 202 Accepted { jobId, status: PENDING }

GET    /admin/backfill/{jobId}          — статус backfill-задачи
       → 200 BackfillStatusDTO (files_total, files_processed, status)

PATCH  /admin/backfill/{jobId}/progress — обновление прогресса (зовёт orchestrator)
       body: { files_processed, files_failed }
       → 200

GET    /clients/{id}/statement-gaps     — текущие пробелы клиента
GET    /clients/{id}/registry-summary   — сводка реестра (для дашборда)
GET    /clients/{id}/reconciliation-flags  — флаги Reconciler
POST   /admin/inspector/scan-now        — ручной триггер Inspector
       (для дебага и демо)

GET    /health                          — без auth
GET    /metrics                         — Prometheus, без auth (bind 127.0.0.1)
GET    /actuator/info                   — версия, build time
GET    /v3/api-docs                     — OpenAPI 3 спецификация (springdoc)
GET    /swagger-ui                      — Swagger UI для interactive тестов
```

### Endpoint POST /compliance-event — контракт

```java
public record ComplianceEventDTO(
    @NotNull UUID eventId,
    @NotNull UUID traceId,
    @NotNull Instant occurredAt,
    @NotBlank String eventType,           // STATEMENT_RECEIVED, CONTRACT_RECEIVED, BANK_REQUEST_115FZ, ...
    @NotBlank String clientInn,
    @NotNull EventSource source,          // EMAIL | BACKFILL | MANUAL
    boolean historic,                     // true для backfill, false для real-time
    SourceMessage sourceMessage,          // nullable если source != EMAIL
    @Valid List<ParsedAttachment> attachments,
    Map<String, Object> tags,             // ["statement_received", "period: 15.04-30.04", "bank: sberbank"]
    Map<String, Object> meta
) {}

public enum EventSource {
    EMAIL,              // от mail-stack pipeline
    BACKFILL,           // от orchestrator при Сценарии 0 Bootstrap
    MANUAL              // прямой ручной upload через UI/API
}

public record SourceMessage(
    String messageId,
    String mailboxLabel,
    String from,
    String subject,
    Instant receivedAt
) {}

public record ParsedAttachment(
    String filename,
    String mime,
    String sha256,
    long sizeBytes,
    String filePath,                      // /var/lib/compliance-files/<inn>/staging/... или final
    String extractedText,                 // от parser-service
    String method,                        // TEXT_LAYER, PDF_PLUMBER, VISION_LLM
    BigDecimal extractionCost
) {}
```

**Поведение по флагу `historic`:**
- `historic: false` — стандартный real-time pipeline: Inspector реагирует, Reconciler ловит флаги, Outbox отправляет алерты Таирову
- `historic: true` — backfill mode: Reconciler работает, флаги поднимаются, **но OutboxMessage помечается `suppressed_by_historic: true` и НЕ отправляется**. После завершения Backfill — Reporting-service формирует сводный отчёт со всеми накопленными флагами

### Endpoint POST /admin/backfill — контракт

```java
public record BackfillRequestDTO(
    @NotBlank String clientInn,
    @NotNull BackfillSource source,       // STAGING_FILESYSTEM | DRIVE_DOWNLOAD
    @NotBlank String sourcePath,          // абсолютный путь к staging/ или Drive folder ID
    @NotNull LocalDate periodStart,
    @NotNull LocalDate periodEnd
) {}

public enum BackfillSource {
    STAGING_FILESYSTEM,                   // /var/lib/compliance-files/<inn>/staging/
    DRIVE_DOWNLOAD                        // на v1.5+ — Drive API
}

public record BackfillStatusDTO(
    UUID jobId,
    String clientInn,
    BackfillJobStatus status,             // PENDING | RUNNING | COMPLETED | FAILED
    int filesTotal,
    int filesProcessed,
    int filesFailed,
    Instant startedAt,
    Instant completedAt,                  // nullable
    String errorSummary                   // nullable
) {}
```

### BackfillService — взаимодействие с orchestrator

```java
@Service
public class BackfillService {

    private final OrchestratorClient orchestratorClient;
    private final BackfillJobRepository jobRepository;

    @Transactional
    public BackfillStatusDTO startBackfill(BackfillRequestDTO request) {
        // 1. Валидация: клиент существует, period_start < period_end, source_path readable
        Client client = clientRepository.findByInn(request.clientInn())
            .orElseThrow(() -> new ClientNotFoundException(request.clientInn()));
        
        // 2. Подсчёт файлов в source_path
        int filesTotal = countFilesInStaging(request.sourcePath());
        
        // 3. Создаём BackfillJob со статусом PENDING
        BackfillJob job = BackfillJob.builder()
            .client(client)
            .source(request.source())
            .sourcePath(request.sourcePath())
            .periodStart(request.periodStart())
            .periodEnd(request.periodEnd())
            .filesTotal(filesTotal)
            .status(BackfillJobStatus.PENDING)
            .build();
        job = jobRepository.save(job);
        
        // 4. Отправляем команду orchestrator'у
        orchestratorClient.startBackfillWorkflow(job.getId(), request);
        
        return toStatusDTO(job);
    }
}
```

**Принципиально:** BackfillService — это **control plane**. Реальная обработка файлов (parser, summary, classifier) — в orchestrator (Go) и mail-stack (Python). Spring tier валидирует, ставит job в очередь, мониторит прогресс через PATCH endpoint.



### Inspector — минимальная логика v1.0

```java
@Component
public class StatementGapInspector {

    @Scheduled(cron = "${inspector.statement-gaps.cron:0 0 10 * * *}")
    @Transactional
    public void scanForStatementGaps() {
        for (Client client : clientRepository.findAllActive()) {
            for (String bank : client.getBanks()) {
                List<DateRange> existing = statementRepository
                    .findByClientAndBank(client.getId(), bank)
                    .stream().map(s -> new DateRange(s.getPeriodStart(), s.getPeriodEnd()))
                    .toList();
                
                List<DateRange> gaps = gapAnalyzer.computeGaps(
                    client.getStatementCalendar(bank),  // ожидаемые периоды по календарю
                    existing
                );
                
                for (DateRange gap : gaps) {
                    StatementGap entity = statementGapRepository
                        .findOrCreate(client, bank, gap);
                    
                    if (entity.needsRequest()) {
                        scheduler.scheduleRequest(entity);
                    }
                }
            }
        }
    }
}
```

### Scheduler — отправка запроса

```java
@Component
public class WhatsAppRequestScheduler {

    private final TemplateEngine templateEngine;
    private final AgentCallerClient agentCaller;
    private final OutboxRepository outbox;

    @Transactional
    public void scheduleRequest(StatementGap gap) {
        if (gap.getLastRequestAt() != null 
            && Duration.between(gap.getLastRequestAt(), Instant.now()).toHours() < 48) {
            return;  // dedup: не чаще раза в 48 часов
        }
        
        Map<String, Object> ctx = Map.of(
            "client", gap.getClient(),
            "bank", gap.getBankName(),
            "period_start", gap.getGapStart(),
            "period_end", gap.getGapEnd()
        );
        
        String message = templateEngine.render("wa/request-statement.ftl", ctx);
        
        OutboxMessage out = outbox.save(OutboxMessage.builder()
            .client(gap.getClient())
            .channel(Channel.WA)
            .templateId("wa/request-statement")
            .renderedText(message)
            .status(OutboxStatus.PENDING)
            .build());
        
        // Async dispatch — но в transaction (Outbox pattern на v2.0)
        agentCaller.sendWA(gap.getClient().getPhone(), message);
        
        out.markSent();
        gap.markRequestSent();
    }
}
```

**Внимание:** на v1.0 это **simple-Outbox без полноценного pattern**. Если Agent Caller упадёт — Outbox запись останется PENDING, на v2.0 добавится @Scheduled retry-job. Этого достаточно для одного клиента.

### Шаблоны

**Расположение:** отдельный репо `https://github.com/ciriycpro/Compliance-Templates`

**Структура:**
```
templates/
├── wa/
│   ├── request-statement.ftl
│   ├── request-contract.ftl
│   ├── request-signed-contract.ftl
│   ├── alert-unsigned-contract.ftl
│   ├── alert-missing-act.ftl
│   └── alert-bank-response-ready.ftl
├── email/
│   └── (на v2+)
└── docs/
    └── (для Reporting-service, на v2+)
```

**Деплой на coo:** клон в `/opt/compliance-logic/templates/`. Sync-кнопка по образцу `sync-dsl.command` — `sync-templates-to-coo.command`:
```bash
gcloud compute ssh coo --zone=us-west4-a --command="cd /opt/compliance-logic/templates && git pull origin main"
```

**Hot-reload:** Freemarker конфиг `template_update_delay_seconds=0` — Spring Boot перечитывает изменённые шаблоны без рестарта.

### Auth

X-API-Key constant-time compare (как orchestrator, state-service — DEC-017 Уровень 0).

Bind 127.0.0.1, доступ извне через ssh tunnel.

systemd hardening: `NoNewPrivileges=true, ProtectSystem=strict, ProtectHome=true, PrivateTmp=true`.

### Связи с другими сервисами

```
Orchestrator (Go) ──POST /compliance-event──→ compliance-logic (Java)
                                              │
                                              ├──HTTP──→ Agent Caller (Node)
                                              ├──JDBC──→ Postgres (coo:5432)
                                              └──файлы──> /opt/compliance-logic/templates/ (Git)
```

### Альтернативы (рассмотрены и отвергнуты)

**1. Python (FastAPI + SQLAlchemy + sqlalchemy-continuum).**
- Плюсы: однородный стек с mail-stack, быстрее старт, меньше RAM
- Минусы:
  - sqlalchemy-continuum для audit trail — рабочий, но менее канон для регуляторного аудита чем Hibernate Envers
  - Spring Data multi-tenancy и Spring Security при росте — зрелее чем самописное на FastAPI
  - Карьерный/рыночный сигнал «полиглот-стек с Java» — отличает от стартаперских end-to-end Python команд
- **Отвергнуто** для business-tier. Python остаётся для AI/ML tools.

**2. Go (для всего business-tier).**
- Плюсы: однородность с orchestrator и state-service, минимальный RAM
- Минусы: бедная экосистема для enterprise business-logic. ORM (gorm, ent) и audit-библиотеки уступают Hibernate + Envers. State machines — самописные или через mage-style библы, ничего на уровне Spring Statemachine
- **Отвергнуто** для business-tier. Go остаётся для infra-tier (orchestrator, state, future event-bus).

**3. Spring Boot + Spring AI + LangChain4j (с LLM-вызовами из Java).**
- Плюсы: единый стек для LLM-задач и business-logic
- Минусы: LLM-экосистема на Java догоняет Python, но не сравнялась. Vision-задачи (scan→signed) намного зрелее в Python parser-service на v1.0. Spring AI — добавим если по факту понадобится LLM-вызов изнутри business-логики
- **Отложено.** На v1.0 LLM остаётся в Python AI-tier. Spring AI может быть включён позже без слома архитектуры.

### Deployment v1.0

| Шаг | Что | Где | Кем |
|---|---|---|---|
| 1 | `apt install openjdk-21-jdk postgresql-15` на coo | coo | вручную |
| 2 | `createdb compliance && createuser compliance_app -P` | coo | вручную |
| 3 | Spring Boot Initializr → minimal pom.xml/build.gradle | локально (Mac) | автоматом |
| 4 | Liquibase changelogs для entity-схемы | локально | в репо `Compliance-Logic-Service` |
| 5 | Сборка `compliance-logic.jar` (Maven/Gradle) | локально | `mvn clean package` |
| 6 | scp jar на coo: `/opt/compliance-logic/` | локально → coo | вручную |
| 7 | systemd unit + env-конфиг + start | coo | вручную |
| 8 | Liquibase запустится автоматом при первом старте Spring | coo | автоматом |
| 9 | Smoke test: `curl -X POST :8771/compliance-event -H "X-API-Key: $KEY" -d @event.json` | coo | вручную |
| 10 | Orchestrator → новая activity `PostComplianceEvent()` | в репо Compliance-Assistant | патч orchestrator |

**При OOM на coo (e2-small, 2 GB):** Stop coo → resize до e2-medium (4 GB, +$4/мес) → Start. Простой 2-3 минуты, согласуем окно с Таировым.

### v1.0 НЕ покрывает (явно)

- ❌ Reconciler (engine сверки) — DEC-023 v2.0
- ❌ State machines per-сущность — v2.0
- ❌ Outbox с retry-job — v2.0 (на v1.0 simple-outbox без retry)
- ❌ Document Classifier — v1.1 (в Python мае)
- ❌ Reporting-service интеграция — future ADR
- ❌ Multi-tenant изоляция через Postgres RLS — v3.0
- ❌ AAA, Spring Security — v3.0
- ❌ Метрики Prometheus + дашборд — v1.1 (Actuator endpoint включён, Grafana — потом)

## Consequences

### Положительные

- ✅ **Демонстрируемый интерактив с первого запуска**: cron Inspector → запрос Таирову в WA → ответ → Registry обновлён → следующий cron уже не алертит. Это уже «ассистент», не пайплайн
- ✅ **Audit trail из коробки** через Envers — основа ответа на регуляторные запросы
- ✅ **Multi-tenant ready** на уровне модели данных (все сущности имеют `client_id`) — приход 2-го клиента не ломает архитектуру
- ✅ **Шаблоны в Git** — версионирование, ревью, откат через `git revert`
- ✅ **OpenAPI 3 автоматом** через springdoc — внешний контракт без ручного описания
- ✅ **Карьерный сигнал** — полиглот-стек Python+Go+Node+Java выгодно отличает от стандартных стартаперских команд

### Отрицательные

- ❌ **+4-й runtime на coo** — Python, Go, Node.js, Java. Сложность эксплуатации растёт
  - Митигация: каждый сервис самодостаточен, единый стиль systemd + JSON-логов
- ❌ **JVM прожорлив по RAM** — 300-500 МБ на Spring Boot сервис + 150-300 МБ на Postgres = +500-800 МБ к текущей нагрузке
  - Текущий coo (e2-small, 2 GB): уже впритык. Решение принято: ставим как есть, при OOM апгрейд e2-medium (+$4/мес)
- ❌ **Кривая освоения Spring Boot** — несколько недель плотной работы для разработчика без Java-опыта
  - Митигация: v1.0 минимальный (Registry + Inspector + Scheduler + 1 endpoint). Без Statemachine/AAA/Outbox/Security
- ❌ **N+1 queries и lazy loading** — типичные грабли JPA для новичков
  - Митигация: ставим Hibernate `@EnableJpaRepositories(considerNestedRepositories=false)`, на debug-логах ловим N+1 в early stage

### Открытые вопросы

- **Postgres на coo vs отдельная VM `db-coo`** — пока на coo. При OOM или 2-м клиенте — выносим
- **Кодовый репо для compliance-logic** — отдельный `Compliance-Logic-Service` или часть `Compliance-Assistant`? Предполагается отдельный (по образцу разделения архитектуры и кода). Финализируется при первом коммите кода
- **Hibernate Envers и Liquibase сосуществование** — Envers создаёт `*_AUD` таблицы автоматом, Liquibase про них не знает. Решение: либо `org.hibernate.envers.audit_strategy=org.hibernate.envers.strategy.DefaultAuditStrategy` + позволить Hibernate автогенерить, либо явно описать `*_AUD` в Liquibase. Финализируется при первом миграционном файле
- **Связь с state-service v2** — нужен ли Spring tier'у прямой доступ к state-service или достаточно через orchestrator. Принципиально: state-service остаётся **infra-tool** (DEC-021), не должен зависеть от Spring tier. Spring tier может писать **свой** state в Postgres напрямую

## Implementation Notes (v0.0.1-SNAPSHOT, 23.05.2026)

Прогресс кода: 22.05.2026 22:00 — 23.05.2026 (текущая сессия). Репо: `Compliance-Assistant/compliance-logic/`. Реализован каркас + первая entity, но **бизнес-функциональности (Statement/Inspector/Scheduler/Backfill) пока нет**. Это база для последующих коммитов.

### Что реализовано

**Инфраструктура (22.05.2026 22:00-22:25):**

| Компонент | Версия | Статус |
|---|---|---|
| Java | OpenJDK 21.0.10 | Production-ready на coo |
| Maven | 3.6.3 + wrapper 3.9.x | Wrapper берёт свежий Maven |
| Postgres | 15.18 | На coo, БД `compliance`, пользователь `compliance_app` |
| Spring Boot | 3.5.0 | На момент начала актуальный (3.4.0 не поддерживается, потолок 4.0.6) |
| Hibernate ORM | 6.6.15.Final | Из Spring Boot 3.5.0 BOM |
| Liquibase | 4.x (из Spring Boot BOM) | XML changelogs, формат `4.27.xsd` |

**Security baseline (23.05.2026 09:00-09:30, коммит `793a703`):**

| Что | Где реализовано | DEC-ссылка |
|---|---|---|
| Listen только 127.0.0.1 | `application.properties: server.address=${SERVER_ADDRESS:127.0.0.1}` | DEC-017 Уровень 0 |
| Graceful shutdown | `server.shutdown=graceful` + `lifecycle.timeout-per-shutdown-phase=20s` | DEC-007 правило 7 |
| API-Key middleware | `ApiKeyFilter.java` — OncePerRequestFilter с constant-time compare | DEC-017 Уровень 1 |
| Constant-time auth check | `MessageDigest.isEqual` (защита от timing attacks) | DEC-017 |
| Whitelist для health | `/actuator/health`, `/actuator/info` без auth (мониторинг) | DEC-017 |
| 401 JSON + WARN-log | Через ApiKeyFilter при отсутствии/неверном ключе | DEC-017 audit |
| Open-in-View отключён | `spring.jpa.open-in-view=false` | Spring best practice |

**JSON structured logging (23.05.2026, в `793a703`):**

| Компонент | Что |
|---|---|
| `logback-spring.xml` | LogstashEncoder, MDC slots: trace_id, span_id, client_inn |
| Custom field | `service:"compliance-logic"` для SIEM-агрегации |
| Зависимость | `net.logstash.logback:logstash-logback-encoder:8.0` |
| Готовность к tracing | MDC slots уже подключены — заработают при включении OpenTelemetry на v2.5 |

**Docker artifacts (23.05.2026, в `793a703`):**

| Файл | Состояние |
|---|---|
| `Dockerfile` (multi-stage builder + runtime) | Готов, но не собран |
| `.dockerignore` | Готов |
| `eclipse-temurin:21-jre-alpine` runtime | Non-root user `compliance` |
| HEALTHCHECK через `/actuator/health` | Зафиксирован в Dockerfile |
| Триггер сборки образа | Откладывается по DEC-007 (RAM на coo впритык, в v1.0 systemd достаточно) |

**Client entity + CRUD (23.05.2026 11:00-11:30, коммит `31ea6aa`):**

| Файл | Содержит |
|---|---|
| `registry/Client.java` | JPA entity. UUID PK, ИНН (`@NotBlank @Size(min=10, max=12)` unique), full_name, phone, status enum, `@PrePersist`/`@PreUpdate` для timestamps |
| `registry/ClientStatus.java` | enum ACTIVE / INACTIVE, хранится как STRING |
| `registry/ClientRepository.java` | extends `JpaRepository<Client, UUID>`, методы `findByInn` + `existsByInn` |
| `registry/ClientController.java` | POST `/clients` (201 + DTO, 409 на дубль, 400 на валидацию), GET `/clients/{id}` (200/404). Inner records `ClientCreateRequest` + `ClientResponse` |
| `db/changelog/changes/0001-create-clients.xml` | Liquibase migration. Таблица `clients` со всеми колонками, индексы `idx_clients_inn`, `idx_clients_status` |
| `db/changelog/db.changelog-master.xml` | Master changelog с `<include>` на migration 0001 |

### Smoke test результаты (23.05.2026 11:21)

**Полный сквозной production-цикл прошёл успешно:**

| Шаг | Результат |
|---|---|
| Maven сборка | BUILD SUCCESS за 5-12 сек (incremental кэш) |
| Spring старт | 14.7-17.8 секунд |
| HikariPool подключение к Postgres | < 1 сек |
| Liquibase применение Changeset 0001-create-clients | 208 ms |
| Tomcat embedded на 127.0.0.1:8771 | OK |
| Health endpoint без ключа | HTTP 200 (whitelist) |
| Metrics без ключа | HTTP 401 + WARN-лог |
| Metrics с правильным ключом | HTTP 200 |
| Metrics с неверным ключом | HTTP 401 |
| **POST /clients создание Таирова** | **HTTP 201**, реальный UUID `54e21d1a-ec55-4f8c-b4ed-18b8698e16fe` |
| Запись в БД | 1 строка, все колонки на месте, auto-generated timestamps |
| Дубль по ИНН | HTTP 409 |
| Невалидный ИНН (3 символа) | HTTP 400 (Bean Validation) |
| **JSON-логи валидны** | Парсятся `python -m json.tool`, поле `service` на месте |

### Метрики производительности (на e2-small, 2 GB RAM)

| Метрика | Значение |
|---|---|
| Jar size | 60 МБ (fat-jar со всеми зависимостями) |
| Maven кэш `~/.m2/repository` | 103 МБ |
| Spring Boot RSS | 287-294 МБ |
| Spring старт | 14-17 сек |
| Postgres idle | ~30 МБ overhead |
| coo total RAM after Spring | 580-850 МБ used, 1.2 GB available (запас комфортный) |

### Что НЕ реализовано на v0.0.1-SNAPSHOT (отложено)

- ❌ **Document master-entity** — следующий шаг, для master-таблицы документов
- ❌ **Statement / Contract / Act / MoneyOperation entities** — специализации Document
- ❌ **Inspector + Scheduler** — основная бизнес-логика DEC-023 v1.0
- ❌ **POST /compliance-event endpoint** — главный приёмник от orchestrator
- ❌ **BackfillService control plane** — для Сценария 0 v1.5
- ❌ **systemd unit** — сервис пока запускается вручную `java -jar ... &`. Это блокер на v1.0 production (после reboot coo не поднимется)
- ❌ **Reconciler / Outbox / State machines** — v2.0
- ❌ **Document Classifier** — v1.1
- ❌ **OpenAPI 3 spec через springdoc** — зависимость не подключена пока (добавим при первом cross-service вызове)
- ❌ **OpenTelemetry tracing** — v2.5
- ❌ **Hibernate Envers `@Audited`** — пока ddl-auto=validate работает, при включении Envers потребуется отдельная Liquibase миграция для `*_AUD` таблиц

### Коммиты в Compliance-Assistant

| Коммит | Описание |
|---|---|
| `d090ffe` | Spring Boot 3.5.0 skeleton (Initializr, Maven Wrapper, pom.xml, application.properties) |
| `793a703` | Security baseline + JSON logs + Dockerfile (4 micro-step: A конфиг, B ApiKeyFilter, C logback-spring.xml, D Dockerfile+.dockerignore) |
| `31ea6aa` | Client entity + ClientRepository + ClientController + Liquibase migration 0001 + master changelog |

### Архитектурный долг по этому этапу

- **systemd unit отсутствует** — первый production-блокер для v1.0
- **БД в коде только Client** — фактический Registry v1.0 минимум должен иметь Document + Statement + StatementGap + ComplianceEvent. Реализация в следующих коммитах
- **Springdoc OpenAPI не подключён** — нужен при cross-service вызовах от orchestrator
- **Деплой-скрипт** — нужно автоматизировать build → copy jar → systemctl restart. Сейчас manual

### Следующая сессия — приоритет

(Обновлено 24.05.2026: пункты 1-3 закрыты в v0.0.2, см. ниже. Следующая сессия фокусируется на бизнес-ценности.)

1. ✅ ~~Завершить systemd unit~~ — закрыто 23.05.2026 (см. ниже)
2. ✅ ~~Document master-entity + Liquibase migration 0002~~ — закрыто 23.05.2026 (коммит `8a828c8`)
3. ✅ ~~Statement entity как первая специализация Document~~ — закрыто 24.05.2026 (коммит `ad29636`)
4. ⏳ POST /compliance-event endpoint (минимум для приёма от orchestrator)
5. ⏳ Inspector + Scheduler для Сценария 1 — основная бизнес-ценность v1.0

## Implementation Notes (v0.0.2-SNAPSHOT, 24.05.2026)

Прогресс кода: 23.05.2026 18:00 — 24.05.2026 19:14 (текущая сессия). 

### Что реализовано в v0.0.2

**Service слой (ReestrService pattern из DEC-023):**

| Файл | Назначение |
|---|---|
| `service/ClientService.java` | Управление клиентами + `updateStatus()` для lifecycle |
| `service/CounterpartyService.java` | Управление контрагентами + `changeTrustLevel(reason)` с записью причины в notes для audit |
| `service/DocumentService.java` | Orchestrate storage + дедуп + transactional cleanup blob при exception |
| `service/StatementService.java` | Управление выписками + 4 валидации (period_end >= period_start, document.type == STATEMENT, дубль документа, FK) |
| `service/MoneyOperationService.java` | Управление операциями + 3 валидации (amount > 0, parsing_confidence ∈ [0..1], operation_date в period statement) + методы `linkToContract`/`linkToAct`/`findUnlinkedForClient` для Reconciler v2.0 |

**Controllers рефакторинг:** 706 строк → 408 строк (-42%). Логика перенесена в Service (659 строк бизнес-логики).

**Web layer:**

| Файл | Назначение |
|---|---|
| `web/GlobalExceptionHandler.java` | `@ControllerAdvice` — типизированные Service-исключения → HTTP коды. NotFound→404, Duplicate*→409, Invalid*/OutOfRange→422. JSON response: `{error, message, timestamp}` |

**Entity Counterparty (новый):**

| Файл | Что |
|---|---|
| `registry/Counterparty.java` | UUID PK, FK на Client, ИНН, name, trust_level enum (TRUSTED/NEUTRAL/FLAGGED), notes |
| `registry/CounterpartyTrustLevel.java` | enum |
| `registry/CounterpartyRepository.java` | findByClientIdAndInn, existsByClientIdAndInn, findByClientIdAndTrustLevel |
| `0003-create-counterparties.xml` | таблица + 3 индекса + UNIQUE (client_id, inn) |

**Entity Statement (специализация Document):**

| Файл | Что |
|---|---|
| `registry/Statement.java` | UUID PK, OneToOne на Document (UNIQUE), ManyToOne на Counterparty (банк), period_start/end, amount_total, operation_count, currency, status enum |
| `registry/StatementStatus.java` | enum RECEIVED/PARSED/VERIFIED/FLAGGED |
| `registry/StatementRepository.java` | findByDocumentId, findByClientIdAndBankId, findByClientIdAndPeriod (для Inspector) |
| `0004-create-statements.xml` | таблица + 5 индексов (документ, клиент, банк, period composite, status) + UNIQUE document_id |

**Entity MoneyOperation (операции из выписки):**

| Файл | Что |
|---|---|
| `registry/MoneyOperation.java` | UUID PK, FK на Statement/Client/Counterparty(nullable). Парадигма raw + parsed + linked: raw поля (counterparty_inn/name_raw), parsed (contract_number, contract_date, invoice_number, subject, subject_category, quantity, unit, vat_amount, confidence), linked (linked_contract_id, linked_act_id nullable UUID для Reconciler) |
| `registry/OperationDirection.java` | enum DEBIT/CREDIT |
| `registry/MoneyOperationRepository.java` | 5 методов включая findByClientIdAndLinkedContractIdIsNull (для Reconciler) |
| `0005-create-money-operations.xml` | таблица + 8 индексов |

**Hibernate Envers audit trail (DEC-017 Уровень 1 closed):**

| Что | Где |
|---|---|
| Dependency `org.hibernate.orm:hibernate-envers` | pom.xml (BOM version, без явной версии для compatibility с Hibernate 6.6) |
| `@Audited` annotation | На 5 entity (Client, Counterparty, Document, Statement, MoneyOperation) |
| Envers конфиг | application.properties: audit_table_suffix=_aud, revision_field_name=rev, revision_type_field_name=revtype, store_data_at_delete=true |
| `0006-create-envers-audit-tables.xml` | revinfo + sequence (incrementBy=50 для эффективности batch резервирования) + 5 audit таблиц с PK (id, rev), FK rev→revinfo |

**CHECK constraint (DEC-017 Уровень 0):**

| Что | Где |
|---|---|
| `0007-add-category-check-constraint.xml` | CHECK на money_operations.parsed_subject_category — разрешены только: GOODS, SERVICES, RENT, SALARY, TAX, LOAN, TRANSFER, OTHER (+NULL) |

**Документация:**

| Файл | Что |
|---|---|
| `SECURITY_DEBT.md` | 16 пунктов архитектурного долга в 3 приоритетах (🔴 Critical, 🟡 Medium, 🟢 Low). Каждый с триггером закрытия + ссылкой на DEC |

### Production smoke test (10/10 прошли + 3 security проверки)

| Что | Результат |
|---|---|
| Spring через systemd | active running, PID 1018384, RSS 200 МБ |
| Health endpoint | HTTP 200 |
| Таблицы в БД | 13 (6 бизнес + 5 audit + revinfo + 2 liquibase) |
| Существующие данные не потеряны | Таиров + 2 counterparties + 1 statement + 2 operations через все рестарты |
| Создание Counterparty + автоматический audit | revtype=0 INSERT в counterparties_aud, revinfo с timestamp |
| **Envers revinfo: 2 ревизии** (Альфа-Банк + RENT-операция) | ✅ |
| Service бизнес-валидации | amount=0 → 422, parsing_confidence>1 → 422, operation_date вне периода → 422, period_end<start → 422 |
| GlobalExceptionHandler | JSON {error, message, timestamp} на всех типизированных exceptions |
| Дубль counterparty по ИНН | HTTP 409 с детальным сообщением |
| **CHECK constraint** | INVALID_CATEGORY → 500 (DB rejection), RENT → 201 ✅ |

### Метрики

| Метрика | v0.0.1 | v0.0.2 | Δ |
|---|---|---|---|
| Java строк | ~600 | ~2600 | +2000 |
| REST endpoints | 4 (Client + Document) | 17 (Client + Counterparty + Document + Statement + MoneyOperation CRUD) | +13 |
| Service классов | 0 | 5 | +5 |
| Entity | 2 | 5 | +3 |
| Audit таблицы | 0 | 5 + revinfo | +6 |
| Бизнес-валидации | 1 (BV @Size@NotBlank) | 8 (BV + 7 Service-level) | +7 |
| RSS памяти | 287-294 МБ | 200-329 МБ | стабильно |
| Старт Spring | 14-17 сек | 14-17 сек | без изменения |
| Jar size | 60 МБ | 63 МБ | +3 МБ (envers) |

### Что НЕ реализовано в v0.0.2 (отложено в SECURITY_DEBT.md)

**🔴 Critical (закроем перед production):**
- Шифрование blob at-rest через `age` (DEC-017 L2)
- GlobalExceptionHandler для `DataIntegrityViolationException` (CHECK violation → 422 вместо 500)
- Backup стратегия для `/var/lib/compliance-files/`
- Contract entity со SigningStatus (запланировано в коммит 4)

**🟡 Medium:**
- K8s manifests + PVC + NetworkPolicy
- mTLS между сервисами
- Vault для secrets
- Springdoc OpenAPI 3 spec

**🟢 Low:**
- OpenTelemetry tracing (v2.5)
- gRPC миграция (v5.0)
- Spring Statemachine для lifecycle Statement
- CounterpartyClassifier agent (LLM)

### Коммиты в Compliance-Assistant

| Коммит | Описание |
|---|---|
| `d090ffe` | Spring Boot 3.5.0 skeleton |
| `793a703` | Security baseline + JSON logs + Dockerfile |
| `31ea6aa` | Client entity + Liquibase migration 0001 + REST CRUD |
| `8a828c8` | **Коммит 1**: Document master + Storage + REST CRUD + Security Layer 0 (Bucket4j rate limit + CORS + Transactional orphan fix) |
| `ad29636` | **Коммит 2**: Service слой + Counterparty + Statement + MoneyOperation + Envers audit + CHECK constraints |

### Архитектурный долг по этому этапу

**Закрыто в v0.0.2:**
- ✅ systemd unit (hardened) — closed 23.05.2026
- ✅ Document master entity — closed 23.05.2026
- ✅ ReestrService pattern (Service слой) — closed 24.05.2026
- ✅ Envers audit trail — closed 24.05.2026
- ✅ Бизнес-валидации в Service слое — closed 24.05.2026
- ✅ GlobalExceptionHandler — closed 24.05.2026
- ✅ CHECK constraint на category — closed 24.05.2026
- ✅ SECURITY_DEBT.md документация — closed 24.05.2026

**Остаётся (в SECURITY_DEBT.md):**
- ❌ POST /compliance-event endpoint — для коммита 3 или 5
- ❌ Inspector + Scheduler — для коммита 3
- ❌ Reconciler — для коммита 4 (Contract + ReconciliationFlag)
- ❌ Backfill — для коммита 5

### Следующая сессия — приоритет (коммит 3)

1. **StatementGap entity** + Liquibase migration 0008 (для Inspector)
2. **ComplianceEvent entity** + Liquibase migration 0009 (для приёма событий от orchestrator)
3. **POST /compliance-event endpoint** — главный приёмник от orchestrator с idempotency по event_id
4. **Inspector сервис + Scheduler** — основная бизнес-логика. Поиск пробелов в Statement.period_start/end по client_id + bank_id. Создание StatementGap. Логирование (без алерта Таирову пока)
5. **Smoke test полного бизнес-цикла**: загрузка 2-3 выписок Таирова с пробелом → Inspector детектит gap → запись в БД

**Это первая бизнес-ценность** — система реально решает задачу клиента.

## Roadmap

| Версия | Что | Триггер |
|---|---|---|
| **v1.0** | Registry + Inspector + Scheduler + Template engine + endpoint + Postgres + Liquibase + Envers | DEC-025 принят |
| **v1.1** | Document Classifier rules + расширение mail-stack Intent Tagger + Actuator metrics | После v1.0 в проде |
| **v1.5** | **BackfillService (control plane) + Bootstrap из архива 12 месяцев** (Сценарий 0). Data plane — orchestrator workflow `backfill`. Source: STAGING_FILESYSTEM. Документы складываются в Document/Statement/Contract/Act, ReconciliationFlag'и с `suppressed_by_historic`. Сводный отчёт по завершении | После v1.0 — когда есть Registry + Inspector + хотя бы 1 рабочий endpoint `/compliance-event` |
| **v2.0** | Reconciler engine + State machines (Spring Statemachine) + Full Outbox pattern с retry | Первая полноценная выписка с операциями обработана |
| **v2.1** | Reporting-service интеграция (HTTP-клиент к Python-сервису) | Сценарий 4 (запрос банка пришёл) |
| **v2.5** | **OpenTelemetry tracing (W3C `traceparent`)** — span propagation между orchestrator → mail-stack → Spring tier. Jaeger или Tempo как backend на coo. MDC-слоты `trace_id`/`span_id` в logback уже готовы — нужна только инструментация | Когда есть 5+ сервисов в цепочке и появится debugging-задача "почему запрос долго" |
| **v3.0** | Multi-tenant: Spring Security + Spring Data multi-tenancy + Postgres RLS | 2-й платящий клиент |
| **v3.1** | AAA full — OAuth2 / OIDC если будет требование интеграции | По запросу |
| **v4.0** | Spring AI для LLM-вызовов внутри business-логики если появится use case | По запросу |
| **v5.0** | gRPC миграция (если будет performance bottleneck или строгие типизированные контракты) — OpenAPI → Protobuf конвертация полу-автоматическая | По триггеру производительности |

## References

- DEC-022 — Mail-stack as Platform, twoTier-принцип, обсуждение Spring Boot
- DEC-025 — Compliance Assistant полная архитектура, языковая раскладка
- DEC-014 — Orchestrator (Go), source of compliance-event
- DEC-017 — Secure by Design, Уровень 0 (наследуется в compliance-logic)
- DEC-021 — state-service v1, кандидат на расширение v2 (idempotency + dedup)
- `docs/02-compliance-workflow.md` — поведенческие сценарии, проверочная таблица
