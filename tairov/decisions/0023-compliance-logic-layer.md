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

Statement              — банковская выписка
  ├── client_id (FK)
  ├── bank_name (sberbank, alfa, vtb, ...)
  ├── period_start, period_end
  ├── source_message_id (ссылка на письмо из mail-service)
  ├── sha256
  ├── received_at
  └── status (RECEIVED, PARSED, VERIFIED, FLAGGED)

StatementGap           — обнаруженный пробел в выписках
  ├── client_id (FK)
  ├── bank_name
  ├── gap_start, gap_end
  ├── status (DETECTED, REQUEST_SENT, RECEIVED, CLOSED)
  ├── detected_at
  ├── last_request_at
  └── closed_at

Contract               — договор клиента с контрагентом
  ├── client_id (FK)
  ├── counterparty_id (FK)
  ├── number
  ├── signed_at, expires_at
  ├── status (DRAFT, ACTIVE, EXPIRED, TERMINATED)
  ├── amount
  └── source_message_id

Act                    — акт выполненных работ
  ├── client_id (FK)
  ├── contract_id (FK, nullable)
  ├── counterparty_id (FK)
  ├── number
  ├── act_date
  ├── amount
  └── status (DRAFT, SIGNED)

ComplianceEvent        — лог входящих событий из orchestrator
  ├── event_id (UUID, idempotency)
  ├── trace_id (UUID, проброс из orchestrator)
  ├── event_type
  ├── payload (JSONB)
  ├── received_at
  └── processed_at

OutboxMessage          — исходящие алерты (для гарантированной доставки)
  ├── id
  ├── client_id (FK)
  ├── channel (WA, TG, EMAIL)
  ├── template_id
  ├── rendered_text
  ├── status (PENDING, SENT, FAILED)
  ├── created_at, sent_at
  └── retry_count
```

**Все сущности `@Audited`** — Envers пишет историю в `*_AUD` таблицы автоматически. Это база ответа на регуляторный запрос «история изменений сущности X».

### REST API v1.0

```
POST   /compliance-event                — приём события от orchestrator
       body: ComplianceEventDTO
       auth: X-API-Key
       idempotency: по event_id
       → 200 { processed: true, registry_changes: [...] }
       → 409 если event_id уже обработан (idempotent reply)

GET    /clients/{id}/statement-gaps     — текущие пробелы клиента
GET    /clients/{id}/registry-summary   — сводка реестра (для дашборда)
POST   /admin/inspector/scan-now        — ручной триггер Inspector
       (для дебага и демо)

GET    /health                          — без auth
GET    /metrics                         — Prometheus, без auth (bind 127.0.0.1)
GET    /actuator/info                   — версия, build time
```

### Endpoint POST /compliance-event — контракт

```java
public record ComplianceEventDTO(
    @NotNull UUID eventId,
    @NotNull UUID traceId,
    @NotNull Instant occurredAt,
    @NotBlank String eventType,           // STATEMENT_RECEIVED, CONTRACT_RECEIVED, BANK_REQUEST_115FZ, ...
    @NotBlank String clientInn,
    @NotNull SourceMessage source,
    @Valid List<ParsedAttachment> attachments,
    Map<String, Object> tags,             // ["statement_received", "period: 15.04-30.04", "bank: sberbank"]
    Map<String, Object> meta
) {}

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
    String extractedText,                 // от parser-service
    String method,                        // TEXT_LAYER, PDF_PLUMBER, VISION_LLM
    BigDecimal extractionCost
) {}
```

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

## Roadmap

| Версия | Что | Триггер |
|---|---|---|
| **v1.0** | Registry + Inspector + Scheduler + Template engine + endpoint + Postgres + Liquibase + Envers | DEC-025 принят |
| **v1.1** | Document Classifier rules + расширение mail-stack Intent Tagger + Actuator metrics | После v1.0 в проде |
| **v2.0** | Reconciler engine + State machines (Spring Statemachine) + Full Outbox pattern с retry | Первая полноценная выписка с операциями обработана |
| **v2.1** | Reporting-service интеграция (HTTP-клиент к Python-сервису) | Сценарий 4 (запрос банка пришёл) |
| **v3.0** | Multi-tenant: Spring Security + Spring Data multi-tenancy + Postgres RLS | 2-й платящий клиент |
| **v3.1** | AAA full — OAuth2 / OIDC если будет требование интеграции | По запросу |
| **v4.0** | Spring AI для LLM-вызовов внутри business-логики если появится use case | По запросу |

## References

- DEC-022 — Mail-stack as Platform, twoTier-принцип, обсуждение Spring Boot
- DEC-025 — Compliance Assistant полная архитектура, языковая раскладка
- DEC-014 — Orchestrator (Go), source of compliance-event
- DEC-017 — Secure by Design, Уровень 0 (наследуется в compliance-logic)
- DEC-021 — state-service v1, кандидат на расширение v2 (idempotency + dedup)
- `docs/02-compliance-workflow.md` — поведенческие сценарии, проверочная таблица
