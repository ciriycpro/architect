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

(Обновлено 24.05.2026 21:00 МСК: коммит 3 закрыт в `bdcb5d4`, см. v0.0.3 ниже. Архитектурно — между коммитом 3 и 4 теперь два этапа реальных данных.)

1. ✅ ~~StatementGap entity~~ — закрыто (коммит `bdcb5d4`)
2. ✅ ~~ComplianceEvent entity~~ — закрыто (коммит `bdcb5d4`)
3. ✅ ~~POST /compliance-event endpoint~~ — закрыто с idempotency
4. ✅ ~~Inspector + Scheduler~~ — закрыто, но **на пластмассовых данных**
5. ✅ ~~Smoke test полного бизнес-цикла~~ — пройден на synthetic Statement

## Implementation Notes (v0.0.3-SNAPSHOT, 24.05.2026 21:00 МСК)

Прогресс кода: 24.05.2026 19:14 — 24.05.2026 21:00 (текущая сессия). 

### Что реализовано в v0.0.3 (коммит `bdcb5d4` в Compliance-Assistant)

**Inspector — детектирование пробелов в выписках:**

| Файл | Назначение |
|---|---|
| `registry/StatementGap.java` | Entity с `@Audited`, FK на Client + Counterparty(bank), status enum (DETECTED/REQUEST_SENT/RECEIVED/CLOSED), gap_start/end + detected_at + lastRequestAt + closedAt |
| `registry/StatementGapStatus.java` | enum |
| `registry/StatementGapRepository.java` | 5 методов: findByClientId (Page), findByClientIdAndStatus, findByClientIdAndBankId (List), findByClientIdAndBankIdAndGapStartAndGapEnd, findByStatus |
| `0008-create-statement-gaps.xml` | Таблица + 5 индексов + UNIQUE constraint на (client_id, counterparty_id, gap_start, gap_end) + audit таблица statement_gaps_aud |
| `service/StatementGapInspectorService.java` | **Алгоритм поиска пробелов**: scanAllActiveClients() → scanClient(id) → для каждого банка отсортированные Statements → парные сравнения если daysBetween(period_end[i], period_start[i+1]) > 1 → createGapIfNotExists (idempotent через unique constraint). Records ScanResult/ClientScanResult с метриками. Transactional на весь scan |
| `service/InspectorScheduler.java` | `@Scheduled` cron-job, конфиг inspector.statement-gaps.cron=0 0 10 * * * (10:00 UTC ежедневно). @EnableScheduling в ComplianceLogicApplication. Все исключения ловятся (cron не должен останавливаться) |
| `registry/AdminInspectorController.java` | 3 endpoint: POST /admin/inspector/scan-now?clientId=X, GET /clients/{clientId}/statement-gaps (с фильтром по status), GET /statement-gaps/{id} |

**ComplianceEvent — приём событий от orchestrator:**

| Файл | Назначение |
|---|---|
| `registry/ComplianceEvent.java` | Entity с `@Audited`, JSONB payload (JsonNode), event_id UNIQUE для idempotency, trace_id, processed_at/processing_error |
| `registry/EventSource.java` | enum EMAIL/BACKFILL/MANUAL |
| `registry/ComplianceEventRepository.java` | 6 методов: findByEventId, existsByEventId, findByClientInn (Page), findByClientInnAndEventType, findByTraceId, findByProcessedAtIsNull |
| `0009-create-compliance-events.xml` | Таблица + 7 индексов + UNIQUE на event_id + audit таблица compliance_events_aud |
| `service/ComplianceEventService.java` | ingest() с **idempotency check** (existing event_id → возврат IngestResult с alreadyExisted=true). markProcessed/markFailed для будущего processing. Полное логирование (event_id, trace_id, type, client_inn, source, historic) |
| `registry/ComplianceEventController.java` | POST /compliance-event (HTTP 201 если создан, HTTP 200 если idempotency hit), GET /compliance-events/{eventId}, GET /clients/{clientInn}/compliance-events (с фильтром по eventType) |

**mTLS infrastructure (DEC-017 Уровень 1):**

Internal CA создан на coo:
- `/etc/compliance-tls/ca/ca.key` (4096 RSA, chmod 600)
- `/etc/compliance-tls/ca/ca.crt` (10 лет, chmod 644)
- **CA Fingerprint SHA256**: `AD:E6:4E:6E:0F:E6:83:28:54:D6:E2:A8:F0:53:0A:7D:2C:16:26:6F:3C:E1:67:92:11:59:EE:78:B5:A2:A7:8F`

Server cert для compliance-logic:
- `/etc/compliance-tls/compliance-logic/compliance-logic.p12` (PKCS12 keystore)
- `/etc/compliance-tls/compliance-logic/compliance-truststore.p12` (PKCS12 truststore с CA)
- SAN: compliance-logic.local + 3 DNS (K8s FQDN) + localhost + 127.0.0.1
- Extended Key Usage: serverAuth + clientAuth

Spring SSL config:
- `server.ssl.enabled=true`, `server.ssl.client-auth=want` (опциональный client cert — fallback на API-key для текущих клиентов)
- `server.ssl.enabled-protocols=TLSv1.2,TLSv1.3`
- Passwords в env (`SSL_KEYSTORE_PASSWORD`, `SSL_TRUSTSTORE_PASSWORD`), значение `changeit` для dev

**Spring теперь HTTPS на 127.0.0.1:8771**. Plain HTTP на этом порту отбит (HTTP 400 на TLS-handshake-only порт).

**K8s manifests (DEC-016 — намерение для будущей миграции):**

`deploy/kubernetes/compliance-logic/` — 8 файлов:
- `namespace.yaml` — compliance-assistant namespace
- `configmap.yaml` — non-secret config (URLs, ports, logging)
- `secret.yaml.template` — шаблон Secret (POSTGRES_PASSWORD + API_KEY с PLACEHOLDER_BASE64)
- `pvc.yaml` — PVC 50Gi для `/var/lib/compliance-files/`
- `deployment.yaml` — 1 replica recreate, **security context строжайший** (non-root, readOnlyRootFilesystem, drop ALL capabilities, allowPrivilegeEscalation: false), health/readiness probes через Spring Actuator, resource requests/limits
- `service.yaml` — ClusterIP на 8771
- `network-policy.yaml` — **deny-by-default**, только orchestrator → compliance-logic, egress Postgres + DNS
- `README.md` — структура + применение + готовность

**Backup стратегия (DEC-017 Operational):**

- `/usr/local/bin/compliance-backup.sh` — tar.gz `/var/lib/compliance-files/` + pg_dump через gzip
- Хранение: `/var/backups/compliance/`
- Ротация: 14 дней через find -mtime
- Логи в syslog через `logger`
- Cron: `0 3 * * *` (3:00 ежедневно)
- Тестовый запуск прошёл (2 файла созданы, sql + tar)

**GlobalExceptionHandler:**

Добавлен `@ExceptionHandler(DataIntegrityViolationException.class)` → HTTP 422 (Unprocessable Entity) с JSON `{error, message, timestamp}`. До этого CHECK constraint violations возвращали 500 (default Spring).

### Production smoke test (6/6 прошли + idempotency + Envers + gap detection)

| Что | Результат |
|---|---|
| Spring HTTPS health | HTTP 200 (через `curl --cacert /etc/compliance-tls/ca/ca.crt`) |
| POST /compliance-event новый event_id | HTTP 201, alreadyExisted=false, payload JSONB сохранён в БД |
| Повторный POST того же event_id | HTTP 200, alreadyExisted=true (**idempotency работает**) |
| Inspector scan на Таирове с 1 statement | banksScanned=3, gapsFound=0 (правильно — нужно ≥2 statements чтобы был gap) |
| Inspector scan после создания synthetic Statement июнь 2026 | banksScanned=3, gapsFound=1, gapsCreated=1 — **детектил пробел май 2026** |
| Envers audit на statement_gaps_aud | rev=55, revtype=0 (INSERT), полный snapshot создания |

### Метрики прогресса

| Метрика | v0.0.2 | v0.0.3 | Δ |
|---|---|---|---|
| Java строк | ~2600 | ~4000 | +1400 |
| REST endpoints | 17 | 23 | +6 |
| Service классов | 5 | 8 | +3 |
| Entity | 5 | 7 | +2 |
| Audit таблицы | 5 + revinfo | 7 + revinfo | +2 |
| Бизнес-валидации | 8 | 10 | +2 |
| Cron jobs | 0 | 1 (Inspector daily) | +1 |
| K8s manifests | 0 | 8 yaml | +8 |
| mTLS infrastructure | ❌ | ✅ server-side готов | — |
| Backup стратегия | ❌ | ✅ cron + ротация 14 дней | — |
| RSS памяти Spring | 200-329 МБ | 217-347 МБ | стабильно |
| Jar size | 63 МБ | ~65 МБ | +2 МБ (нет новых dependencies) |
| Старт Spring | 14-17 сек | 14-17 сек | без изменения |

### Закрытый архитектурный долг

- ✅ GlobalExceptionHandler DataIntegrityViolationException → 422 (🔴 #2 SECURITY_DEBT)
- ✅ Backup стратегия (🔴 #3 SECURITY_DEBT — закрыто)
- ✅ K8s manifests как намерение (🟡 #5-7 SECURITY_DEBT — закрыто)
- ✅ mTLS server side infrastructure (🟡 #8 SECURITY_DEBT — закрыто частично, client-side для других сервисов остаётся открытым)

### Архитектурное замечание: «пластмассовость» v0.0.3

Все smoke tests коммита 3 проходили на **синтетических данных** (1 клиент Таиров, 1 искусственная Statement, 1 искусственная gap). Это **рабочий скелет**, не работающий продукт.

**До коммита 4 (Contract + Reconciler) добавлены 2 промежуточных этапа** для подключения реального массива данных Таирова. См. «Следующая сессия» ниже.

### Следующая сессия — приоритет (коммит 3.5 → 3.6 → коммит 4)

(Обновлено 24.05.2026 23:30 МСК: коммит 3.5 закрыт в `d6da726`. См. v0.0.4 ниже.)

**Коммит 3.5 — Реальный массив данных (Google Drive интеграция):**

1. ✅ ~~Google Drive import утилита~~ — закрыто (`tools/gdrive-import/import_from_gdrive.py` + README, коммит `d6da726`)
2. ✅ ~~Mass-import в compliance-logic~~ — закрыто через **POST /admin/backfill** endpoint (правильнее чем bulk POST /documents в цикле). BackfillJob entity + BackfillService + AdminBackfillController
3. ⏳ **Client.monitoring_period_start** — поле в Client entity (`@Column` + миграция 0011). Перенесено в коммит 3.6
4. ⏳ **StatementCalendar entity** — для ожидаемых периодов. Перенесено в коммит 3.6

**Коммит 3.6 — Реальный smoke test + ручная верификация:**

5. **Client.monitoring_period_start** + миграция 0011 (перенесено из 3.5)
6. **StatementCalendar entity** + Inspector v2 (expected periods)
7. Загрузка реальных выписок Таирова через `import_from_gdrive.py` + rclone (требует `rclone config` интерактивно)
8. Inspector scan → реальные gaps
9. Ручная верификация (Артём смотрит и подтверждает)
10. **Инсайты** → коррекция алгоритма (предположительно: edge cases в форматах банков, проблемы с парсингом дат, банки с нестандартной нумерацией периодов)

**Коммит 4 — Contract + Act + Reconciler + Contract.signingStatus:**

11. Contract entity с **signing_status** enum (DRAFT/SIGNED_ONE_SIDE/SIGNED_BOTH_SIDES/UNCLEAR/DISPUTED), client_signed/counterparty_signed boolean + dates, signature_confidence от vision-LLM
12. Act entity (специализация Document)
13. ReconciliationFlag entity (MISSING_CONTRACT/DRAFT_ONLY/EXPIRED/UNSIGNED_ACT/AMOUNT_MISMATCH)
14. Reconciler сервис — алгоритм сверки MoneyOperation ↔ Contract + Act
15. Spring Statemachine для Statement.status + Contract.status lifecycle

Это **первая бизнес-ценность с реальным эффектом** — система обрабатывает реальные данные клиента и выдаёт реальные инсайты.

## Implementation Notes (v0.0.4-SNAPSHOT, 24.05.2026 23:30 МСК)

Прогресс кода: 24.05.2026 21:00 — 24.05.2026 23:30 (текущая сессия). 

### Что реализовано в v0.0.4 (коммит `d6da726` в Compliance-Assistant)

**BackfillJob — batch-импорт исторических документов (DEC-023 v1.5):**

| Файл | Назначение |
|---|---|
| `registry/BackfillJob.java` | Entity с `@Audited`, FK на Client, source_path varchar(500), status enum (PENDING/RUNNING/COMPLETED/FAILED), 5 счётчиков (total/processed/created/skipped/failed_files), 3 timestamps, error_message |
| `registry/BackfillJobStatus.java` | enum |
| `registry/BackfillJobRepository.java` | 3 метода поиска (findByClientId, findByClientIdAndStatus, findByStatus) |
| `0010-create-backfill-jobs.xml` | Таблица + 3 индекса + audit таблица backfill_jobs_aud |
| `service/BackfillService.java` | **Синхронный batch-импорт**: createJob (PENDING) → runJob (walk файлы → DocumentService.createFromBytes → COMPLETED). Прогресс update каждые 10 файлов. Exception per file → failed++ (не останавливает батч). 5 типизированных исключений. Конфиг `backfill.enabled` через @Value |
| `service/BackfillService.validateSourcePath()` | **Whitelist `/var/lib/compliance-files/import`** + Path.toRealPath() для защиты от symlink-attack |
| `registry/AdminBackfillController.java` | POST /admin/backfill (синхронный), GET /admin/backfill/{jobId}, GET /clients/{clientId}/backfill-jobs |
| `service/DocumentService.createFromBytes()` | Новый метод для batch — принимает byte[] + filename + mimeType вместо MultipartFile. Возвращает null для дубля (skip-логика backfill) |

**GlobalExceptionHandler полная пересборка:**

Унифицированный `@ControllerAdvice` с 7 handlers:
- **400**: InvalidSourcePathException, IllegalArgumentException
- **404**: 16 *NotFoundException всех Service-классов
- **409**: Duplicate*Exception + IllegalBackfillStateException
- **422**: Invalid*/OutOfRange + DataIntegrityViolationException
- **503**: BackfillDisabledException

Все возвращают унифицированный JSON `{error, message, timestamp}`.

**GDrive Import Utility (`tools/gdrive-import/`):**

| Файл | Назначение |
|---|---|
| `import_from_gdrive.py` | Python скрипт ~250 строк. rclone copy → `/var/lib/compliance-files/import/gdrive-<ts>/`, walk файлов с sha256 hashing, ThreadPoolExecutor 5 workers, retry с exponential backoff (2s/4s/8s), tqdm прогресс-бар, идемпотентный (sha256 дедуп на сервере) |
| `README.md` | Пошаговая инструкция rclone config + параметры |

### Production smoke test (4/4 прошли)

| Тест | Результат |
|---|---|
| Первый backfill synthetic dir (3 файла) | HTTP 201 COMPLETED, created=3, skipped=0, failed=0, duration=781ms |
| Envers ревизии в backfill_jobs_aud | rev 102 (revtype=0 PENDING) → rev 103 (revtype=1 COMPLETED) |
| **Идемпотентность**: повторный backfill той же папки | HTTP 201 COMPLETED, **created=0, skipped=3** ✅ |
| Path traversal /tmp → 400 invalid_source_path | "source path должен быть под /var/lib/compliance-files/import, получено: /tmp" |
| Path traversal /etc → 400 invalid_source_path | Path.toRealPath() резолвит, проверяет prefix |

БД счётчики: documents 33→36 (после 1-го backfill), 36 без изменений (после идемпотентного 2-го), backfill_jobs=2, backfill_jobs_aud=4 ревизии.

### Архитектурное замечание: systemd PrivateTmp ≠ shell /tmp

**Important learning:** systemd `PrivateTmp=true` (security hardening) изолирует `/tmp` сервиса от shell сессии. Spring видит **свой** изолированный /tmp, не shared с пользователем.

**Initial мисдизайн:** whitelist разрешал `/tmp/gdrive-import-*` — но Spring сервис не видел директорию из shell сессии (BackfillService.validateSourcePath падал с `path не существует`).

**Корректное решение:** убрали `/tmp` из whitelist полностью. Все import staging складываются в `/var/lib/compliance-files/import/` (под существующий PVC + systemd ReadWritePaths). Утилита `import_from_gdrive.py` обновлена для использования этого пути.

**Архитектурно правильно**: persistence staging на PVC, не на ephemeral /tmp. Соответствует DEC-016 (K8s manifests) + DEC-007 (Docker-friendly).

### Метрики прогресса

| Метрика | v0.0.3 | v0.0.4 | Δ |
|---|---|---|---|
| Java строк | ~4000 | ~4900 | +900 |
| REST endpoints | 23 | 26 | +3 |
| Service классов | 8 | 9 | +1 |
| Entity | 7 | 8 | +1 (BackfillJob) |
| Audit таблицы | 7 + revinfo | 8 + revinfo | +1 (backfill_jobs_aud) |
| GlobalExceptionHandler types | 16 | 24 | +8 |
| Python tooling | 0 | 1 утилита (~250 строк) | +1 |
| RSS памяти Spring | 217-347 МБ | стабильно | без изменения |

### Закрытый архитектурный долг

- ✅ GDrive import утилита (🔴 #19 SECURITY_DEBT) — закрыто
- ✅ GlobalExceptionHandler для всех business exceptions — закрыто (24 типа exceptions покрыты)

### Новый долг (открыт в этом коммите)

- 🟡 systemd PrivateTmp vs Spring import staging — задокументировано через переезд на /var/lib/compliance-files/import/
- 🟡 Backfill graceful shutdown (cancel running job при SIGTERM)
- 🟡 Backfill rate limiting per-client (предотвращение DDoS через большой массив)

## Implementation Notes (v0.0.5-SNAPSHOT, 25.05.2026 00:00 МСК)

Прогресс кода: 24.05.2026 23:30 — 25.05.2026 00:00 (текущая сессия). 

### Что реализовано в v0.0.5 (коммит `5dfd6dc` в Compliance-Assistant)

**D — Client.monitoring_period_start (SECURITY_DEBT #17):**

| Файл | Назначение |
|---|---|
| `registry/Client.java` | Поле `monitoringPeriodStart` (LocalDate, nullable) + getter/setter |
| `0011-add-client-monitoring-period.xml` | ALTER TABLE clients ADD COLUMN + то же для clients_aud (Envers) |

Таирову установлен `monitoring_period_start = 2025-04-01`.

Inspector использует это поле как нижнюю границу:
```
effectiveStart = max(client.monitoring_period_start, calendar.start_period, today - 12 months)
```

**E — StatementCalendar entity (SECURITY_DEBT #18):**

| Файл | Назначение |
|---|---|
| `registry/StatementFrequency.java` | enum (MONTHLY/QUARTERLY/ANNUAL) |
| `registry/StatementCalendar.java` | Entity @Audited: FK на Client + FK на Counterparty (bank), frequency, start_period (LocalDate), active boolean. Unique constraint (client_id, bank_id, frequency) — нельзя 2 MONTHLY на один банк |
| `registry/StatementCalendarRepository.java` | 3 метода поиска (active клиента, по client+bank+freq, все по client+bank) |
| `0012-create-statement-calendars.xml` | Таблица + 3 индекса + unique constraint + audit таблица statement_calendars_aud |
| `service/StatementCalendarService.java` | create/listForClient/findById/deactivate. 4 типизированных exceptions (ClientNotFoundException, BankNotFoundException, CalendarNotFoundException, DuplicateCalendarException) |
| `registry/StatementCalendarController.java` | POST/GET /clients/{id}/statement-calendars, GET/DELETE /statement-calendars/{id} (soft-delete = active=false) |

**Inspector v2 — calendar-based scan:**

Метод `scanCalendarsForClient(client)` добавлен в StatementGapInspectorService:
- Получает все active StatementCalendar клиента
- Для каждого calendar:
  - `effectiveStart = max(monitoring_period_start, calendar.start_period, today - 12 months)`
  - Генерирует expected periods от `effectiveStart` до `today` с шагом по frequency
  - Для каждого периода проверяет: есть ли Statement покрывающий его?
  - Если не covered → `createGapIfNotExists` (идемпотентность через unique constraint)
- Шаг между периодами: MONTHLY → +1 month, QUARTERLY → +3 months, ANNUAL → +1 year

Existing метод `scanClient()` расширен: после между-Statement gaps вызывается `scanCalendarsForClient`, результаты аккумулируются в общие счётчики.

**GlobalExceptionHandler:** +4 типа exceptions (28 общих типов).

### Production smoke test (6/6 прошли)

| Тест | Результат |
|---|---|
| Liquibase 0011-1 + 0011-2 + 0012-1 + 0012-2 | All ran successfully |
| POST calendar Таиров+Сбер MONTHLY 2025-04-01 | 201 Created + UUID |
| **Идемпотентность**: повторный POST | 409 conflict с понятным сообщением |
| GET список календарей клиента | 1 активный календарь |
| Inspector scan-now (после создания calendar) | gapsFound=13, gapsCreated=11, duration=339ms |
| Финальная БД: 12 gaps в statement_gaps | 2025-05..2025-12 + 2026-01..2026-03 + 2026-05 (всё что не покрыто 2026-04 + 2026-06 Statement) |

**Проверка edge cases:**
- April 2026 покрыт Statement → НЕ создан gap ✅
- June 2026 в будущем (`periodEnd > today`) → break logic работает, НЕ создан gap ✅
- 12-month look-back применился — Inspector не пошёл дальше 2025-05 (хотя monitoring_period_start = 2025-04-01) ✅

### Метрики прогресса

| Метрика | v0.0.4 | v0.0.5 | Δ |
|---|---|---|---|
| Java строк | ~4900 | ~5500 | +600 |
| REST endpoints | 26 | 30 | +4 (statement-calendars) |
| Service классов | 9 | 10 | +1 (StatementCalendarService) |
| Entity | 8 | 9 | +1 (StatementCalendar) |
| Audit таблицы | 8 + revinfo | 9 + revinfo | +1 (statement_calendars_aud) |
| GlobalExceptionHandler types | 24 | 28 | +4 |
| БД таблицы (всего) | 17 | 19 | +2 |

### Закрытый архитектурный долг

- ✅ 🔴 #17 Client.monitoring_period_start — закрыто
- ✅ 🔴 #18 StatementCalendar entity — закрыто

### Архитектурный сдвиг: Inspector переходит от reactive к expected

До v0.0.5 Inspector детектил только **gaps между существующими Statements** (если есть Apr и Jun, найдёт пробел в May). Не мог найти **expected but missing** — если у Таирова нет ни одной выписки за весь 2025 год, Inspector ничего бы не нашёл.

В v0.0.5 через StatementCalendar Inspector **знает что ожидать** — за каждый месяц (или квартал) от `monitoring_period_start` ждёт выписку. Это превращает Inspector из "сравнителя двух соседних выписок" в "аудитора по графику". Соответствует роли **#1 Inspector** в архитектурном workflow Артёма (см. user notes).

### Что НЕ реализовано (out of scope для v0.0.5, но в roadmap)

- **#3 Scheduler/Planner** — gap создан, но никто не пишет Таирову. Это коммит 5+ через outbound через Agent Caller.
- **#9 Intent Classifier** — type документа сейчас передаётся в request. Автоклассификация — отдельный коммит.
- **#13 Reconciler** — коммит 4.
- **Реальная выкачка данных Таирова с GDrive** — `rclone config` + `import_from_gdrive.py`. Отдельная сессия.

### Следующая сессия — коммит 4 (Contract + Reconciler)

1. **Contract entity** с signing_status enum (DRAFT/SIGNED_ONE_SIDE/SIGNED_BOTH_SIDES/UNCLEAR/DISPUTED), client_signed/counterparty_signed boolean + dates, signature_confidence от vision-LLM
2. **Act entity** (специализация Document)
3. **ReconciliationFlag entity** (MISSING_CONTRACT/DRAFT_ONLY/EXPIRED/UNSIGNED_ACT/AMOUNT_MISMATCH)
4. **Reconciler сервис** — алгоритм сверки MoneyOperation ↔ Contract + Act
5. **Spring Statemachine** для Statement.status + Contract.status lifecycle
6. **Inspector timezone fix** (#21 — добавить inspector.timezone=Europe/Moscow)

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
