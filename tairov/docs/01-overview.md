# Compliance Assistant

Автоматизация документооборота ИП Таирова на сервере coo: приём документов по email/Drive → распознавание → запись в реестр PostgreSQL → алерты по 3 типам проблем (отсутствие договора, только драфт, просрочка) в Telegram/WhatsApp/Email.

## Service Blueprint реальности (на 23.06.2026)

### Что работает в продакшене (8 микросервисов)

- **Agent Caller** (`/home/iakshin77/agent-caller/`, Node.js, systemd, coo:3000). Транспорт алертов в три канала: Telegram (бот @CallerBaby666Bot), WhatsApp (whatsapp-web.js, аккаунт `+79266143959`), Email (SMTP). Аптайм с 27.04.2026 непрерывно. См. [DEC-0005](../decisions/0005-microservices.md).

- **Mail Service v1.2** (`/opt/mail-stack/mail-service/`, Python 3.11 + FastAPI, systemd, coo:8765). Endpoint `GET /mail/since/<YYYY-MM-DDTHH:MM>?label=&group=&limit=50` отдаёт массив писем с корректным парсингом MIME, кириллицы, ФИО, ISO-дат, имён вложений. **Реальная адресуемость DEC-0022**: `label=X` → точечный ящик, `group=Y` → набор ящиков, иначе → default-ящики. Multi-mailbox через env-конфиг `MAILBOXES_JSON`. В production-режиме с 12.05.2026 (label/group routing с 02.06.2026), RAM 39 МБ. См. [DEC-0007](../decisions/0007-deployment-form.md), [DEC-0022](../decisions/0022-mail-stack-as-platform.md) Implementation Notes 23.06.2026.

- **Attachment Service v1.1** (`/opt/mail-stack/attachment-service/`, Python 3.11 + FastAPI, systemd, coo:8766). Endpoint `POST /download` принимает `{messageId, filename, label?, group?}` → фильтрует MAILBOXES по label/group → скачивает вложение из IMAP → сохраняет в `/var/lib/mail-stack/attachments/<messageId>/<filename>` → возвращает путь + sha256 + size + mime. Label/group filtering добавлен 07.06.2026 для DEC-0022 parity. См. [DEC-0011](../decisions/0011-attachment-service.md), [DEC-0022](../decisions/0022-mail-stack-as-platform.md).

- **Parser Service v1.1** (`/opt/mail-stack/parser-service/`, Python 3.10 + FastAPI, systemd, coo:8767). Endpoints: `POST /parse` (детерминированный роутер L1-L14 по MIME + per-page роутинг внутри PDF) и **`POST /parse-statement`** (специализированный pipeline для банковских выписок — добавлен 02.06.2026 для DEC-0027). Модули: `statement_parser.py` (ВТБ/Альфа PDF) и `statement_xlsx.py` (ВТБ-only — Альфа-xlsx остаётся Open Issue #2). LLM-vision Qwen3-VL 235B primary + Qwen 2.5 VL 72B fallback. См. [DEC-0008](../decisions/0008-parser-stack.md) Implementation Notes 23.06.2026, [DEC-024](../decisions/0024-mail-stack-v1.1-fixes.md), [DEC-0027](../decisions/0027-alert-loop-and-statement-vacuum.md).

- **Summary Service v1** (`/opt/mail-stack/summary-service/`, Python 3.11 + FastAPI, systemd, coo:8768). Endpoint `POST /summary` принимает массив писем с распарсенными вложениями → возвращает JSON `{summary_markdown, summary_telegram}`. Primary: Claude Haiku 4.5 через OpenRouter, Fallback: DeepSeek-chat. Без правок с 13.05.2026. См. [DEC-0009](../decisions/0009-summary-haiku.md).

- **Orchestrator v1.2.2** (`/opt/mail-stack/orchestrator/`, Go 1.22, systemd, coo:8769). В проде задеплоен workflow `email_digest_v1` (Mail Reader дайджест). Endpoints: `POST /digest-now`, `POST /check-mail`, `GET /health`, `GET /metrics`. Один cron `c` для дайджеста по `ORCHESTRATOR_SCHEDULE`. State через state-service. Structured logs slog JSON, `X-Trace-Id` пропагандируется во все исходящие активити. **В working tree (НЕ задеплоено):** второй cron `c2` + workflow `statement_vacuum_v1.go` + активити `ingest.go` + label-проброс. env-файл `/etc/mail-stack/orchestrator.env` содержит заготовки под DEC-0027 (`STATEMENT_VACUUM_SCHEDULE`) и под будущую mTLS-интеграцию (`COMPLIANCE_LOGIC_URL/API_KEY/CA_CERT`). См. [DEC-0014](../decisions/0014-orchestrator-go-temporal-kamf.md) Implementation Notes v1.3-prep (23.06.2026).

- **State Service v1.0** (`/opt/mail-stack/state-service/`, Go 1.22 + go-redis + chi, systemd, coo:8770). Микросервис состояния mail-stack. Хранит per chat_id: `last_at` (timestamp последнего успешного дайджеста, persistent) + `lock` (TTL для защиты от двойного клика). См. [DEC-0021](../decisions/0021-state-service.md).

- **Compliance Logic v0.0.7-SNAPSHOT** (`/opt/compliance-logic/`, Java 21 + Spring Boot 3.5.0, systemd, coo:8771 HTTPS mTLS). Business-tier для Registry, Inspector, Reconciler, Backfill, StatementIngest, AlertLoop. Jar собран 04.06.2026 (Commit 4 31.05 + Commit 5 02-03.06). **~46 REST endpoints, 17 Service-классов, 14 entity + Envers audit (13 `*_aud` + revinfo, `notifications` append-only), 23 Liquibase миграции, 29 таблиц.** Реализовано: Client / Tenant / Counterparty / Document / Statement / MoneyOperation / Contract / Act / ReconciliationFlag / StatementGap / StatementCalendar / ComplianceEvent / BackfillJob / Notification. Сервисы: Inspector v2 (calendar-based), Reconciler (матч по номеру договора из purpose), Backfill, **StatementIngestService** (`POST /statements/ingest` с inspector.scanClient синхронно), **GapAlertOrchestrator** (алёрт-loop по statement_gaps), **OrchestratorScheduler** (`@Scheduled` для алёртов), **NotificationService** (audit-журнал), **HttpCallerClient** (WA/TG через agent-caller). Phase 1 DEC-0028 правки (rescanForContract, post-ingest hook, findByClient...IsNull, HttpCaller timeout 300с) — в working tree, **не в jar**. См. [DEC-0023](../decisions/0023-compliance-logic-layer.md) Implementation Notes v0.0.7-SNAPSHOT (23.06.2026).

### Инфраструктура

- **PostgreSQL 15.18** (`coo:5432` bind 127.0.0.1, БД `compliance`, пользователь `compliance_app`). Источник правды для Registry compliance-logic. **29 таблиц = 14 бизнес (clients, tenants, counterparties, documents, statements, money_operations, contracts, acts, reconciliation_flags, statement_gaps, statement_calendars, compliance_events, backfill_jobs, notifications) + 13 audit (`*_aud` через Hibernate Envers `@Audited`, кроме `notifications` — append-only) + revinfo + 2 liquibase**. 23 миграции (последняя `0023-2-add-statement-account-aud`, 02.06.2026 19:25 UTC). По DEC-017 данные физически в РФ (152-ФЗ ready). Backup cron на coo с ротацией 14 дней.

- **Redis** (`coo:6379`). State-service хранит lock/last_at в DB 0 (production), DB 1 для canary.

- **Multi-channel notification: WhatsApp pre-alert + Telegram content delivery**. Двухканальный паттерн через Agent Caller. См. [DEC-018](../decisions/0018-multi-channel-notification.md).

### Production state на 23.06.2026 (из БД)

| Метрика | Значение |
|---|---|
| `clients` | 2 (Таиров, Веретенникова) |
| `counterparties` | 34 |
| `documents` | 39 |
| `statements` | 6 |
| `money_operations` | 936 |
| `reconciliation_flags` | 26 (все MISSING_CONTRACT, DETECTED) |
| `notifications` | 38 (исходящие WA-алёрты по gap-ам) |
| `statement_gaps` | 23 (детектированы Inspector v2) |
| `contracts` | 0 (DEC-0028 не задеплоен) |
| `acts` | 0 (DEC-0028 Phase 2) |

### Что в работе (working tree, не задеплоено)

**DEC-0027 Go-half (statement-vacuum):**
- `~/compliance-assistant-repo/orchestrator/workflow/statement_vacuum_v1.go` — workflow.
- `~/compliance-assistant-repo/orchestrator/activities/ingest.go` — клиент к `/statements/ingest`.
- `~/compliance-assistant-repo/orchestrator/activities/{mail,parser,attachment}.go` — label-проброс.
- `~/compliance-assistant-repo/orchestrator/cmd/orchestrator/main.go` — второй cron `c2`.
- `~/compliance-assistant-repo/orchestrator/config/config.go` — `STATEMENT_VACUUM_SCHEDULE`.

Без сборки orchestrator-bin и `systemctl restart` — Go-часть DEC-0027 не работает. Входящий контур (DEC-0027 Open #1) не замкнут.

**DEC-0028 Phase 1 Java-правки:**
- `~/compliance-assistant-repo/compliance-logic/.../ReconcilerService.java` — rescanForContract + bulk-линковка.
- `~/compliance-assistant-repo/compliance-logic/.../ContractService.java` — post-ingest hook.
- `~/compliance-assistant-repo/compliance-logic/.../MoneyOperationRepository.java` — новый метод findByClient...IsNull.
- `~/compliance-assistant-repo/compliance-logic/.../HttpCallerClient.java` — таймаут 120→300с (DEC-0027 Open #3 fix).

Без пересборки jar и `systemctl restart compliance-logic` — эти правки не работают.

### Что описано в плане, под реализацию

**DEC-0028 Phase 1 остаток (Drafted, not implemented):**
- parser-service `/parse-document` (типизация contract/act).
- GDrive adapter (`activities/gdrive.go`).
- compliance-logic `/contracts/ingest`, `/acts/ingest` endpoints.
- `MISSING_ACT` enum значение.
- workflow `contracts_vacuum_v1.go`.

**DEC-0028 Phase 2:** EDO провайдер (Контур.Диадок / СБИС / 1С-ЭДО), активация акт-потока, снятие фильтра MISSING_ACT в GapAlertOrchestrator.

**Техдолг (cleanup_backlog_v2.md):** 21 пункт по 5 разделам. Триггеры revisit зафиксированы по каждому пункту.

### Что работает в режиме полу-заглушки

- **Polygon** (N8N workflow id `1632604d64e14e20`, 14 нод, active=1). Принимает письма по IMAP с ящика `5458508@mail.ru`, раскладывает вложения по папкам отправителей в Google Drive, ведёт два листа в Sheets. **Под деактивацию** после деплоя DEC-0027 Go-half (statement-vacuum полностью замыкает входящий контур).

- **Google Drive** — остаётся как источник архивных документов Таирова. Документы выкачиваются через `tools/gdrive-import/` утилиту и загружаются через `POST /admin/backfill` в PostgreSQL. Drive **не источник правды** — только staging для архивных данных.

### Артефакты в БД, не используются

- **Inactive `Документовед`** (N8N id `2b0af1a8c92c424f`, 39 нод, active=0). Реализация отменённого DEC-003. Сохранён как историческая запись.

### Вне-проектные артефакты

- **`Telegram Photo to Google Drive`** (N8N workflow id `pvsSCtB0CCpZl50W`, 11 нод, active=1). Telegram-бот фотобудка. К Compliance Assistant не относится.

## Внешние системы

- **mail.ru SMTP/IMAP** — почтовый сервер `5458508@mail.ru`, основной канал входящих документов.
- **Google Drive** — staging для архивных документов Таирова. Не источник правды.
- **OpenRouter API** — LLM провайдер: Qwen3-VL 235B + Qwen 2.5 VL 72B (vision parser), Claude Haiku 4.5 + DeepSeek V3 (саммари).
- **Telegram + WhatsApp + Email** — каналы доставки алертов.
- **GitHub** — code repositories (`ciriycpro/Compliance-Assistant`, `ciriycpro/architect`, `ciriycpro/MAIF`).

## Ключевые архитектурные решения

Краткая сводка (полный список — в `decisions/`):

- [DEC-0005](../decisions/0005-microservices.md): Mail-service как отдельный микросервис. **Implemented**.
- [DEC-0007](../decisions/0007-deployment-form.md): Docker-friendly код + systemd. **Implemented**.
- [DEC-0008](../decisions/0008-parser-stack.md): Parser-service L1-L14 + LLM-vision. **Implemented + Notes 23.06.2026** (новый `/parse-statement` endpoint).
- [DEC-0009](../decisions/0009-summary-haiku.md): Summary-service на Haiku 4.5 + DeepSeek fallback. **Implemented**.
- [DEC-0011](../decisions/0011-attachment-service.md): Attachment-service. **Implemented + DEC-0022 parity fix 07.06.2026**.
- [DEC-013](../decisions/0013-mail-check-on-demand.md): Mail Check On-Demand с last_at tracking. **Implemented**.
- [DEC-0014](../decisions/0014-orchestrator-go-temporal-kamf.md): Orchestrator — Go custom v1 → Temporal v2 → KAMF v3. **Implemented v1.2.2**. Notes 23.06.2026 (v1.3-prep: deploy form formalized, второй cron заготовлен).
- [DEC-017](../decisions/0017-secure-by-design.md): Secure by Design roadmap.
- [DEC-018](../decisions/0018-multi-channel-notification.md): WhatsApp pre-alert + Telegram content. **Implemented**.
- [DEC-0021](../decisions/0021-state-service.md): State-service Go+Redis. **Implemented**.
- [DEC-0022](../decisions/0022-mail-stack-as-platform.md): Mail-stack as reusable tool platform. **Implemented + Notes 23.06.2026** (полная label/group parity).
- [DEC-0023](../decisions/0023-compliance-logic-layer.md): **Compliance Logic Layer**. **Implemented v0.0.7-SNAPSHOT** — Commit 4 (Reconciler) + Commit 5 (alert-loop + statement-ingest).
- [DEC-024](../decisions/0024-mail-stack-v1.1-fixes.md): Mail-stack v1.1 fixes (XLSX truncation, mixed PDF, vision-prompt). **Implemented**.
- [DEC-0025](../decisions/0025-compliance-assistant-architecture.md): Полная архитектура. **Notes 23.06.2026** — карта компонентов после Commit 5.
- [DEC-026](../decisions/0026-rate-limit-per-tenant-redis.md): Rate-limit per tenant через Redis.
- [DEC-0027](../decisions/0027-alert-loop-and-statement-vacuum.md): Alert-loop + statement-vacuum. **Java half + Python half в проде, Go half в working tree.** Open #3 RESOLVED локально (Caller timeout), Open #1/#2/#5/#6 остаются.
- [DEC-0028](../decisions/0028-contract-act-vacuum.md): **Contract/Act vacuum. Drafted, not implemented.** Phase 1 Java правки в working tree.

## Метрики проекта на 23.06.2026

| Метрика | Значение |
|---|---|
| Production-микросервисов | **8** (agent-caller, mail-service v1.2, attachment-service v1.1, parser-service v1.1, summary-service, orchestrator v1.2.2, state-service, compliance-logic v0.0.7) |
| Инфраструктура | PostgreSQL 15.18 (compliance), Redis (state) |
| Архитектурных решений (ADR) | 23 принятых (DEC-0001..0027 с пропусками 0012, 0015, 0019, 0020) + DEC-0028 Drafted |
| Таблиц в PostgreSQL | 29 (14 бизнес + 13 audit + revinfo + 2 liquibase) |
| Liquibase миграций | 23 (последняя 0023-2-add-statement-account-aud, 02.06.2026) |
| REST endpoints в compliance-logic | ~46 |
| Service-классов в compliance-logic | 17 |
| Entity в compliance-logic | 14 |
| Реальных операций в БД | 936 money_operations / 6 statements / 39 documents |
| Алёртов отправлено (notifications) | 38 |
| Открытых reconciliation_flags | 26 (MISSING_CONTRACT) |
| Детектированных statement_gaps | 23 |

## Контакты для оперативной работы

Для деталей по credentials, токенам, API-ключам, путям на coo, паролям — см. персональную память владельца, не репозиторий. Этот репозиторий публичный.
