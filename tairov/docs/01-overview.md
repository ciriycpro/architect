# Compliance Assistant

Автоматизация документооборота ИП Таирова на сервере coo: приём документов по email/Drive → распознавание → запись в реестр PostgreSQL → алерты по 3 типам проблем (отсутствие договора, только драфт, просрочка) в Telegram/WhatsApp/Email.

## Service Blueprint реальности (на 25.05.2026)

### Что работает в продакшене (8 микросервисов)

- **Agent Caller** (`/home/iakshin77/agent-caller/`, Node.js, systemd, coo:3000). Транспорт алертов в три канала: Telegram (бот @CallerBaby666Bot), WhatsApp (whatsapp-web.js, аккаунт `+79266143959`), Email (SMTP). Аптайм с 27.04.2026 непрерывно. См. [DEC-005](../decisions/0005-microservices.md).

- **Mail Service v1.1** (`/opt/mail-stack/mail-service/`, Python 3.11 + FastAPI, systemd, coo:8765). Endpoint `GET /mail/since/<YYYY-MM-DDTHH:MM>?limit=50` отдаёт массив писем с корректным парсингом MIME, кириллицы, ФИО, ISO-дат, имён вложений. Multi-mailbox через env-конфиг `MAILBOXES_JSON` (3 ящика Артёма работают: artem-mailru, artem-gmail, artem-icloud). В production-режиме с 12.05.2026, RAM 39 МБ. Docker-friendly код, env-конфиг изолирован в `/etc/mail-stack/mail-service.env` (chmod 600 root:root). См. [DEC-007](../decisions/0007-deployment-form.md). Параллельно собран Docker-образ `mail-service:test`.

- **Attachment Service v1** (`/opt/mail-stack/attachment-service/`, Python 3.11 + FastAPI, systemd, coo:8766). Endpoint `POST /download` принимает `{messageId, filename}` → скачивает вложение из IMAP → сохраняет в `/var/lib/mail-stack/attachments/<messageId>/<filename>` → возвращает путь + sha256 + size + mime. Кэш через файловую систему: повторный запрос отдаётся из FS за ~30 мс без обращения к IMAP (ускорение ~130×). Запущен 12.05.2026, RAM 28 МБ. См. [DEC-011](../decisions/0011-attachment-service.md). Docker-образ `attachment-service:test` собран.

- **Parser Service v1** (`/opt/mail-stack/parser-service/`, Python 3.10 + FastAPI, systemd, coo:8767). Endpoint `POST /parse` принимает `{path}` → детерминированный роутер по MIME (уровень A) + per-page роутинг внутри PDF (уровень B) → возвращает unified JSON с текстом, методом, форматом, стоимостью. Реализованы все 8 веток L1-L14: TXT, CSV, JSON, XML, HTML, DOCX, XLSX, PDF (с pdf-inspector классификацией + PyMuPDF/pdfplumber извлечением), JPG/PNG/PDF-скан (Qwen3-VL 235B primary + Qwen 2.5 VL 72B fallback по OpenRouter). Запущен 13.05.2026, RAM 38 МБ idle / 86 МБ после первого PDF. Стоимость L14: ~$0.001 за JPG, ~$0.0005-0.0015 за страницу PDF. См. [DEC-008](../decisions/0008-parser-stack.md). Docker-образ `parser-service:test` собран.

- **Summary Service v1** (`/opt/mail-stack/summary-service/`, Python 3.11 + FastAPI, systemd, coo:8768). Endpoint `POST /summary` принимает массив писем с распарсенными вложениями → возвращает JSON с двумя форматами: `summary_markdown` + `summary_telegram` до 1000 символов. Промпт v2 (живой разговорный тон, best practices: Anthropic XML-tags, few-shot example, action verbs, length constraints). Primary: Claude Haiku 4.5 через OpenRouter. Fallback: DeepSeek-chat. Запущен 13.05.2026, RAM 30.6 МБ (рекорд стека — stateless transformer). Стоимость: ~$0.005 за дайджест на 2 письмах. См. [DEC-009](../decisions/0009-summary-haiku.md). Docker-образ `summary-service:test` собран.

- **Orchestrator v1.2.2** (`/opt/mail-stack/orchestrator/`, Go 1.22, systemd, coo:8769). Координатор полного workflow mail-stack. Endpoints: `POST /digest-now`, `POST /check-mail`, `GET /health`, `GET /metrics` (Prometheus). Structured logs (slog JSON) с trace_id (UUID v7). Activities переиспользуются на 80%+ через все три runtime (v1 → v2 Temporal → v3 KAMF). v1.1 (13.05.2026): Telegram-кнопка через Agent Caller callback + Multi-mailbox + product-grade WA-skip. v1.2 (DEC-013 incremental, рядом тестируется в canary). См. [DEC-014](../decisions/0014-orchestrator-go-temporal-kamf.md).

- **State Service v1.0** (`/opt/mail-stack/state-service/`, Go 1.22 + go-redis + chi, systemd, coo:8770). Микросервис состояния для mail-stack. Хранит per chat_id: `last_at` (timestamp последнего успешного дайджеста, persistent) + `lock` (флаг "workflow выполняется" с TTL для защиты от двойного клика). API: GET/POST `/state/{chat_id}/last_at`, POST/DELETE `/state/{chat_id}/lock`, `/health` без auth. Используется orchestrator'ом для incremental digest flow (DEC-013 Mail Check On-Demand). См. [DEC-021](../decisions/0021-state-service.md).

- **Compliance Logic v0.0.5** (`/opt/compliance-logic/`, Java 21 + Spring Boot 3.5.0, systemd, coo:8771 HTTPS mTLS). Business-tier для Registry, Inspector, BackfillService. **30 REST endpoints, 10 Service-классов, 9 entity + Envers audit (9 _aud таблиц + revinfo), 12 Liquibase миграций.** Реализовано: Client / Counterparty / Document / Statement / MoneyOperation / StatementGap / ComplianceEvent / BackfillJob / StatementCalendar. Inspector v2: calendar-based scan через StatementCalendar (генерирует expected periods от monitoring_period_start, сравнивает с existing Statements, создаёт gaps). BackfillService: POST /admin/backfill для batch-импорта (sha256 дедуп). GlobalExceptionHandler: 7 handlers покрывают 28 типов exceptions. K8s manifests готовы. Security: mTLS server-side через internal CA + PKCS12, X-API-Key, Bucket4j rate limit, path whitelist, Envers audit. Запущен 23.05.2026 (6 коммитов 8a828c8 → 5dfd6dc), RAM 217-347 МБ, jar 60 МБ. systemd Backup cron + ротация 14 дней. См. [DEC-023](../decisions/0023-compliance-logic-layer.md) Implementation Notes v0.0.5-SNAPSHOT.

### Инфраструктура

- **PostgreSQL 15.18** (`coo:5432` bind 127.0.0.1, БД `compliance`, пользователь `compliance_app`). Источник правды для Registry compliance-logic. **19 таблиц = 9 бизнес (clients, counterparties, documents, statements, money_operations, statement_gaps, compliance_events, backfill_jobs, statement_calendars) + 9 audit (\*_aud через Hibernate Envers @Audited) + revinfo + 2 liquibase**. ~107 Envers ревизий. По DEC-017 данные физически в РФ (152-ФЗ ready). Backup cron на coo с ротацией 14 дней.

- **Redis** (`coo:6379`). State-service хранит lock/last_at в DB 0 (production), DB 1 для canary.

- **Multi-channel notification: WhatsApp pre-alert + Telegram content delivery**. Двухканальный паттерн через Agent Caller (Node.js + whatsapp-web.js + Telegram Bot API). На v1.0 sequential delay 80 сек из-за hard limit whatsapp-web.js destroy timing, на v1.3 — parallel goroutine. См. [DEC-018](../decisions/0018-multi-channel-notification.md).

### Что работает в режиме полу-заглушки

- **Polygon** (N8N workflow id `1632604d64e14e20`, 14 нод, active=1). Принимает письма по IMAP с ящика `5458508@mail.ru`, раскладывает вложения по папкам отправителей в Google Drive, ведёт два листа в Sheets для совместимости. Работает нестабильно. **Под деактивацию** после миграции на полный compliance-logic pipeline с прямым импортом в PostgreSQL.

- **Google Drive** — остаётся как источник архивных документов Таирова (12 месяцев истории договоров и выписок). Документы выкачиваются через `tools/gdrive-import/` утилиту (rclone + Python) и загружаются через POST /admin/backfill в PostgreSQL compliance-logic. Drive больше **не источник правды** — только staging для архивных данных.

### Что описано в плане, под реализацию следующими сессиями

**Коммит 4 — Contract + Reconciler (горизонт 1 неделя):**
- **Contract entity** с signing_status enum (DRAFT/SIGNED_ONE_SIDE/SIGNED_BOTH_SIDES/UNCLEAR/DISPUTED), client_signed/counterparty_signed boolean + dates, signature_confidence от vision-LLM
- **Act entity** (специализация Document)
- **ReconciliationFlag entity** (MISSING_CONTRACT/DRAFT_ONLY/EXPIRED/UNSIGNED_ACT/AMOUNT_MISMATCH)
- **Reconciler сервис** — алгоритм сверки MoneyOperation ↔ Contract + Act
- **Spring Statemachine** для Statement.status + Contract.status lifecycle
- **Inspector timezone fix** (cron в Europe/Moscow)

**Коммит 5 — Orchestrator integration (горизонт 2-3 недели):**
- **Orchestrator (Go) → compliance-logic (Java)** через mTLS client-side (см. DEC-017 Уровень 1)
- **Orchestrator workflow `backfill`** — GDrive импорт идёт через orchestrator coordination, не через прямую утилиту
- **Springdoc OpenAPI 3 spec** — генерация для cross-service контракта (DEC-022)
- **ComplianceEvent → Scheduler/Planner** — gap создан → автоматический outbound запрос Таирову через Agent Caller

**Коммит 6 — Production hardening:**
- **Шифрование blob at-rest** через age (DEC-017 Уровень 2)
- **Vault для secrets**
- **CI/CD pipeline** (GitHub Actions: push → mvnw package → tests → docker build → deploy)
- **mTLS client-side** для всех остальных сервисов

### Что описано в плане, под реализацию позже

- **classifier-service / pre-filter перед parser** ([открытый вопрос в DEC-008](../decisions/0008-parser-stack.md)). Двухстадийный фильтр для отсечения 80-95% спам-трафика до LLM-vision parser. Кандидат на отдельный ADR (DEC-012).
- **Mail Check On-Demand workflow** ([DEC-013](../decisions/0013-mail-check-on-demand.md)). Telegram-кнопка → ad-hoc проверка с момента последнего обращения. State-service уже готов, orchestrator v1.2 в canary smoke.
- **Temporal headless v2** — durable execution + 115-ФЗ audit log. Триггер: regulatory audit, 5+ workflow, recovery после рестарта.
- **KAMF runtime v3** — собственный multi-agent framework (свидетельство Роспатент ПЭО № 2026611550). Триггер: KAMF в работоспособном состоянии + готовность инвестировать 3-5 дней миграции.

### Артефакты в БД, не используются

- **Inactive `Документовед`** (N8N id `2b0af1a8c92c424f`, 39 нод, active=0). Реализация отменённого DEC-003. Сохранён в БД как историческая запись, под архивацию.

### Вне-проектные артефакты

- **`Telegram Photo to Google Drive`** (N8N workflow id `pvsSCtB0CCpZl50W`, 11 нод, active=1). Telegram-бот фотобудка. Первая успешная сборка владельца в N8N (27.04.2026). К Compliance Assistant не относится.

## Внешние системы

- **mail.ru SMTP/IMAP** — почтовый сервер `5458508@mail.ru`, основной канал входящих документов от Таирова и контрагентов.
- **Google Drive** — staging для архивных документов Таирова (12 месяцев истории). Выкачка через `tools/gdrive-import/` утилиту по запросу. Не источник правды.
- **OpenRouter API** — LLM провайдер: Qwen3-VL 235B + Qwen 2.5 VL 72B (vision parser), Claude Haiku 4.5 + DeepSeek V3 (саммари).
- **Telegram + WhatsApp + Email** — каналы доставки алертов.
- **GitHub** — code repositories (`ciriycpro/Compliance-Assistant`, `ciriycpro/architect`, `ciriycpro/MAIF`).

## Ключевые архитектурные решения

См. полный список в `decisions/`. Краткая сводка:

- [DEC-001](../decisions/0001-n8n-platform.md): N8N как платформа разработки агентов. Accepted, фактически вытесняется через mail-stack + compliance-logic.
- [DEC-005](../decisions/0005-microservices.md): Mail-service как отдельный микросервис. Accepted, реализация v1 закрыта 12.05.2026.
- [DEC-007](../decisions/0007-deployment-form.md): Форма развёртывания mail-stack — docker-friendly код + systemd v1. Accepted, валидировано фактом 12.05.2026.
- [DEC-008](../decisions/0008-parser-stack.md): Parser-service — библиотечный стек L1-L14 + LLM-vision Qwen-каскад. **Implemented 13.05.2026**.
- [DEC-009](../decisions/0009-summary-haiku.md): Summary-service на Claude Haiku 4.5 + DeepSeek-chat fallback. **Implemented 13.05.2026**.
- [DEC-011](../decisions/0011-attachment-service.md): Attachment-service — контракт пути к файлу + FS-кэш + TTL 7 дней. **Implemented 12.05.2026**.
- [DEC-013](../decisions/0013-mail-check-on-demand.md): Mail Check On-Demand workflow — incremental digest flow с last_at tracking. State-service готов, orchestrator v1.2 в canary smoke.
- [DEC-014](../decisions/0014-orchestrator-go-temporal-kamf.md): Orchestrator — Go custom v1 → Temporal headless v2 → KAMF v3. **Implemented v1.0/v1.1/v1.2.2 on coo**. Activities переиспользуются 80%+ через все три runtime.
- [DEC-016](../decisions/0016-kubernetes-manifests.md): Kubernetes-friendly deployment manifests. Accepted, готовы для compliance-logic.
- [DEC-017](../decisions/0017-secure-by-design.md): Secure by Design roadmap по 4 уровням. Уровень 0 встроен в каждый кирпич, Уровень 1 закрыт для compliance-logic (mTLS server-side, Envers audit), Уровни 2-3 на горизонте недель.
- [DEC-018](../decisions/0018-multi-channel-notification.md): Multi-channel notification — WhatsApp pre-alert + Telegram content. **Implemented 13.05.2026**.
- [DEC-021](../decisions/0021-state-service.md): State-service — Go + Redis для last_at + lock tracking. **Implemented**, port 8770.
- [DEC-022](../decisions/0022-mail-stack-as-platform.md): Mail-stack as reusable tool platform. Принят 13.05.2026. Принцип: mail-stack микросервисы — domain-platform с переиспользуемыми инструментами.
- [DEC-023](../decisions/0023-compliance-logic-layer.md): **Compliance Logic Layer — Spring Boot business tier**. Java/Spring для типизированных бизнес-сущностей + production-grade ecosystem (Liquibase, Envers, Statemachine, Spring Data). **Implementation Notes v0.0.5-SNAPSHOT (25.05.2026)** — 6 коммитов в Compliance-Assistant: 9 entity, 30 REST endpoints, 10 Service-классов, Inspector v2 calendar-based, BackfillService, mTLS server-side, 28 типов exceptions.
- [DEC-025](../decisions/0025-compliance-assistant-architecture.md): **Полная архитектура Compliance Assistant**. Карта компонентов и языковая раскладка стека целиком. Связывает mail-stack (Python + Go) с business-tier (Java). Открывает плейсхолдеры под будущие ADR.

## Метрики проекта на 25.05.2026

| Метрика | Значение |
|---|---|
| Production-микросервисов | **8** (agent-caller, mail-service, attachment-service, parser-service, summary-service, orchestrator, state-service, compliance-logic) |
| Канареечные сервисы | 2 (orchestrator-canary v1.2 + state-service-canary v1.0 на DB=1) |
| Инфраструктура | PostgreSQL 15.18 (compliance), Redis (state) |
| Коммитов в Compliance-Assistant | 6 в compliance-logic (8a828c8 → 5dfd6dc, темп ~2 коммита/день в активной фазе) |
| Архитектурных решений (ADR) | 25+ |
| Таблиц в PostgreSQL | 19 (9 бизнес + 9 audit + revinfo + 2 liquibase) |
| REST endpoints в compliance-logic | 30 |
| Service-классов в compliance-logic | 10 |
| Envers audit ревизий | ~107 |
| K8s manifests | готовы для compliance-logic |
| Security уровень (DEC-017) | Уровень 0 (все сервисы) + Уровень 1 (compliance-logic mTLS + Envers) |

## Контакты для оперативной работы

Для деталей по credentials, токенам, API-ключам, путям на coo, паролям — см. персональную память владельца, не репозиторий. Этот репозиторий публичный.
