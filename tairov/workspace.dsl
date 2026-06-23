workspace "Compliance Assistant" "Автоматизация документооборота ИП Таирова — сверка договоров/счетов/актов, алерты по 3 типам проблем" {

    !docs ./docs
    !adrs ./decisions

    model {
        # Акторы
        tairov = person "ИП Таиров" "Клиент. Получает алерты, отвечает на письма с документами."
        artem = person "Якшин Артём" "Оператор системы. Получает алерты, дебажит, обновляет реестр."

        # Внешние системы
        mailru = softwareSystem "mail.ru SMTP/IMAP" "Почтовый сервер 5458508@mail.ru" "External"
        google = softwareSystem "Google Workspace" "Drive (хранилище файлов) + Sheets (реестр документов)" "External"
        openrouter = softwareSystem "OpenRouter API" "Qwen3-VL 235B (vision primary), Qwen 2.5 VL 72B (vision fallback), Claude Haiku 4.5 (summary), DeepSeek V3 (summary fallback)" "External"
        messengers = softwareSystem "Telegram + WhatsApp + Email" "Каналы доставки алертов" "External"

        # Главная система
        compliance = softwareSystem "Compliance Assistant" "Контур автоматической сверки документооборота на coo.gcp (DEC-0023, DEC-0025)" {

            # === Реально работающие компоненты на 12.05.2026 ===

            agentcaller = container "Agent Caller" "Node.js, coo:3000, systemd" "[РАБОТАЕТ В ПРОД] Транспорт алертов: Telegram + WhatsApp + Email. Аптайм с 27.04.2026"

            polygon = container "Polygon (Полигон)" "N8N workflow id 1632604d64e14e20" "[ПОЛУ-ЗАГЛУШКА — будет деактивирован после Email Digest v1] Schedule+Webhook+IMAP→Drive раскладка по отправителям + Sheets лог. Работает нестабильно — часть писем теряется. Замещается mail-service v1 + Email Digest v1 workflow"

            # === Mail-stack v1.0 — основа автоматизации документооборота ===
            # Прод (12-13.05.2026): mailservice, attachmentservice, parserservice, summaryservice, orchestrator
            # На v1.1: multi-account email + Telegram-кнопка через Agent Caller

            mailservice = container "Mail Service v1.2" "Python 3.11 + FastAPI + systemd, /opt/mail-stack/mail-service/" "[РАБОТАЕТ В ПРОД, server.py 02.06.2026] coo:8765. Endpoints /health и GET /mail/since/<YYYY-MM-DDTHH:MM>?label=&group=&limit=50. Real label/group routing (DEC-0022): label=X → точечный ящик, group=Y → набор, иначе default. MAILBOXES_JSON в env. Docker-friendly, env в /etc/mail-stack/. RAM 39 МБ. DEC-007 + DEC-0022 + DEC-0027"

            # === Планируется к реализации в составе mail-stack (DEC-008, DEC-009, DEC-010) ===

            attachmentservice = container "Attachment Service v1.1" "Python 3.11 + FastAPI + systemd, /opt/mail-stack/attachment-service/" "[РАБОТАЕТ В ПРОД, label/group fix 07.06.2026] coo:8766. Endpoint POST /download — скачивание вложения по messageId+filename+label+group. _imap_find_message фильтрует MAILBOXES по label/group (DEC-0022 parity к mail-service). Хранилище /var/lib/mail-stack/attachments/<messageId>/<filename>. FS-кэш idempotent. RAM 28 МБ. DEC-011 + DEC-0022"

            parserservice = container "Parser Service v1.1" "Python 3.10 + FastAPI + systemd, библиотеки L1-L14, /opt/mail-stack/parser-service/" "[РАБОТАЕТ В ПРОД, /parse-statement добавлен 02.06.2026] coo:8767. Endpoints: POST /parse (общий L1-L14 роутер) + POST /parse-statement (детерминированный pipeline для банковских выписок). Модули: statement_parser.py (ВТБ/Альфа PDF), statement_xlsx.py (только ВТБ — Альфа-xlsx Open #2). pdf-inspector через detect_pdf_bytes(). LLM-vision Qwen3-VL primary + Qwen 2.5 VL fallback. RAM 38 МБ idle / 86 МБ. DEC-008 + DEC-024 + DEC-0027 + DEC-0028 (/parse-document planned)"

            summaryservice = container "Summary Service v1" "Python 3.11 + FastAPI + systemd, Claude Haiku 4.5 + DeepSeek-chat fallback, /opt/mail-stack/summary-service/" "[РАБОТАЕТ В ПРОД c 13.05.2026] coo:8768. Endpoint POST /summary — массив писем с распарсенными вложениями → JSON с двумя форматами (summary_markdown для Sheets + summary_telegram до 1000 символов). Промпт v2 с живым разговорным тоном (Anthropic XML-tags, few-shot, action verbs). RAM 30.6 МБ. Stateless. Цена ~$0.005/дайджест. DEC-009"

            orchestrator = container "Orchestrator v1.2.2 (Go custom)" "Go 1.22 + net/http + robfig/cron + slog + caarlos0/env + uuid, /opt/mail-stack/orchestrator/" "[РАБОТАЕТ В ПРОД, strings → orchestrator-v1.2] coo:8769. В проде workflow email_digest_v1 (Mail Reader дайджест). Endpoints: POST /digest-now, POST /check-mail, GET /health, GET /metrics. Cron c для дайджеста по ORCHESTRATOR_SCHEDULE. State через state-service. X-Trace-Id во все исходящие активити (mail/parser/summary/attachment/notify). Structured logs slog JSON. Auth X-API-Key, rate limit token bucket. RAM 10 МБ. ~1100 строк production-Go + 380 тестов. В working tree (НЕ задеплоено): второй cron c2 + workflow statement_vacuum_v1.go + activity ingest.go + label-проброс через MailboxLabel='compliance-5458508' (DEC-0027 Go-half). env-заготовка STATEMENT_VACUUM_SCHEDULE + COMPLIANCE_LOGIC_URL/API_KEY/CA_CERT. См. DEC-0014 Implementation Notes v1.3-prep"

            # === Документовед v2 — заменяется горизонтальным стеком mail-stack ===

            documentoved = container "N8N Документовед v2 (superseded)" "N8N workflow, 12 нод" "[SUPERSEDED by DEC-008] План DEC-004 заменяется горизонтальным стеком mail-stack (attachment + parser + summary + orchestrator). Не реализуется. В БД N8N лежит inactive Документовед-Франкенштейн (DEC-003, 39 нод) — артефакт, не используется" {
                ocr = component "OCR Step (planned)" "HTTP→Qwen3-VL" "Извлекает текст из PDF/JPG в Markdown"
                extract = component "LLM Extract (planned)" "HTTP→DeepSeek V3" "Извлекает структурированные поля (тип, контрагент, ИНН, сумма, дата)"
                validate = component "Validate (planned)" "Code-нода" "Проверка корректности полей"
                router = component "Type Switch (planned)" "Switch-нода" "Раскладка по 5 типам: договор/счёт/акт/выписка/прочее"
                sheets_writer = component "Sheets Writer (planned)" "Google Sheets→Append Row" "Запись в нужный лист реестра"
                drive_mover = component "Drive Mover (planned)" "Google Drive→Move" "Перекладывание файла в Обработанные/<тип>"
            }

            controller = container "N8N Контроллер (planned)" "N8N workflow или Python-сервис" "[NOT IMPLEMENTED] Schedule + сверка по ИНН: ищет проблемы no_contract / draft_only / expired. На 09.05.2026 не существует ни в каком виде — ни workflow в N8N, ни cron-задание, ни сервис"

            # === Compliance Logic Layer — business tier (DEC-023, DEC-025) ===

            compliancelogic = container "Compliance Logic v0.0.7-SNAPSHOT" "Java 21 + Spring Boot 3.5.0 + Liquibase + Hibernate + Envers, /opt/compliance-logic/" "[РАБОТАЕТ c 23.05.2026, jar собран 04.06.2026 — Commit 4 (31.05) + Commit 5 (02-03.06)] coo:8771 (HTTPS mTLS server-side via internal CA). ~46 REST endpoints, 17 Service-классов, 14 entity + Envers audit (13 *_aud + revinfo, notifications append-only). БД: 29 таблиц, 23 миграции Liquibase. Сервисы: Document/Statement/MoneyOperation/Counterparty/Client + Inspector v2 + Reconciler + Backfill + StatementIngestService + GapAlertOrchestrator + OrchestratorScheduler + NotificationService + HttpCallerClient (CallerPort) + CounterpartyNameNormalizer. Production state: clients=2, counterparties=34, documents=39, statements=6, money_operations=936, reconciliation_flags=26 (MISSING_CONTRACT), notifications=38, statement_gaps=23, contracts=0, acts=0. К Phase 1 DEC-0028: правки Reconciler/ContractService/Repository в working tree (не задеплоены). См. DEC-0023 Implementation Notes v0.0.6+v0.0.7 и DEC-0027/0028" {
                registry = component "Registry Services" "Spring @Service" "Client/Tenant/Counterparty/Document/Statement/MoneyOperation/Contract/Act CRUD + nameNormalizer (DEC-0023 v0.0.2-v0.0.6)"
                inspector = component "InspectorService + Scheduler" "Spring @Service + @Scheduled" "Calendar-based gap detection (v2). scanClient(clientId) синхронно после StatementIngest. Cron в Europe/Moscow (DEC-0023 v0.0.5)"
                reconciler = component "ReconcilerService + Scheduler" "Spring @Service + @Scheduled 10:30 MSK" "Сверка MoneyOperation↔Contract по основанию (regex от purpose). rescanAll + rescanForContract post-ingest hook (DEC-0023 v0.0.6 + DEC-0028 Phase 1 в working tree)"
                statementingest = component "StatementIngestService" "Spring @Service" "POST /statements/ingest (multipart file+meta) → Document/Statement/MoneyOperation атомарно + sha256-dedup + inspectorService.scanClient sync. Точка входа для DEC-0027 statement-vacuum (DEC-0023 v0.0.7)"
                gapalert = component "GapAlertOrchestrator" "Spring @Service" "Алёрт-loop по statement_gaps с SQL-фильтром по flag_type (точка расширения для DEC-0028 MISSING_ACT). reminder_interval_hours + max_reminders + last_request_at lifecycle (DEC-0023 v0.0.7)"
                orchscheduler = component "OrchestratorScheduler" "Spring @Scheduled INSPECTOR_STATEMENT_GAPS_CRON (16:30 MSK default)" "Запускает GapAlertOrchestrator по cron из env. Отдельный scheduler от ReconcilerScheduler (DEC-0023 v0.0.7)"
                notification = component "NotificationService" "Spring @Service" "CRUD + write-API audit-журнала исходящих алёртов (channel/recipient/payload/status/sent_at/trace_id). 38 записей в проде (DEC-0023 v0.0.7)"
                httpcaller = component "HttpCallerClient (CallerPort impl)" "Java 21 HttpClient" "Транспорт WA/TG к agent-caller :3000. Таймаут 120с (300с в working tree — DEC-0027 Open #3 fix). X-API-Key, structured logging (DEC-0023 v0.0.7)"
                backfill = component "BackfillService" "Spring @Service" "POST /admin/backfill для batch-импорта (sha256 дедуп). GDrive→PostgreSQL (DEC-0023 v0.0.4)"
            }

            postgres = container "PostgreSQL 15.18" "Postgres 15.18 + Liquibase migrations, БД compliance, пользователь compliance_app" "[РАБОТАЕТ c 22.05.2026] coo:5432 (bind 127.0.0.1). Источник правды для Registry. На v0.0.7: 29 таблиц = 14 бизнес (clients, tenants, counterparties, documents, statements, money_operations, contracts, acts, reconciliation_flags, statement_gaps, statement_calendars, compliance_events, backfill_jobs, notifications) + 13 audit (*_aud через Envers, кроме notifications append-only) + revinfo + 2 liquibase. 23 миграции Liquibase 4.27 (последняя 0023-2-add-statement-account-aud, 02.06.2026 19:25 UTC). Hibernate Envers @Audited. По DEC-017 — данные физически в РФ (152-ФЗ ready). Backup cron на coo с ротацией 14 дней"

            compliancefiles = container "Filesystem Document Storage" "ext4 на coo, /var/lib/compliance-files/<inn>/" "[FOLDER ГОТОВА c 23.05.2026] Хранилище blob-файлов документов (выписки, договоры, акты). Структура: /staging/, /statements/, /contracts/, /acts/, /other/. chmod 700, владелец iakshin77. Метаданные в Postgres (Document table), blob на диске. По DEC-023 + DEC-017 — не зависит от Drive, source-of-truth"

            stateservice = container "State Service v1.0 (Go)" "Go 1.22 + go-redis + chi + slog, /opt/mail-stack/state-service/" "[РАБОТАЕТ В ПРОД c 16.05.2026] coo:8770. Микросервис состояния mail-stack: хранит per-chat_id last_at (timestamp последнего успешного дайджеста, persistent) + lock (TTL для защиты от двойного клика). REST API: GET/POST /state/{chat_id}/last_at, POST/DELETE /state/{chat_id}/lock. Auth X-API-Key. Storage Redis (DB=0 prod, DB=1 canary). RAM 6 МБ. Uptime 1+ мес. См. DEC-0021"

            redis = container "Redis 7.x" "Redis in-memory store, systemd" "[РАБОТАЕТ В ПРОД] coo:6379 (bind 127.0.0.1). Backing store для state-service (per chat_id: last_at + lock). DB=0 production, DB=1 canary. См. DEC-0021"
        }

        # Связи (Context уровень)
        tairov -> mailru "Отвечает на письма с документами" "SMTP"
        compliance -> messengers "Шлёт алерты Таирову и Артёму" "API"
        artem -> google "Просматривает реестр и файлы" "Web"
        compliance -> google "Хранит файлы и реестр" "API"

        # Связи (Container уровень) — реально работают agentcaller→messengers, polygon-цепочка, mailservice работает в проде
        mailru -> mailservice "Чтение почты по IMAP (RUNNING in prod)" "IMAP"
        mailru -> polygon "Входящие письма (legacy path, будет деактивирован после Email Digest v1)" "IMAP"
        mailservice -> orchestrator "Отдаёт письма по /mail/since (planned consumer)" "HTTP GET"
        orchestrator -> attachmentservice "Скачивание вложений (planned)" "HTTP POST"
        orchestrator -> parserservice "Парсинг вложений (planned)" "HTTP POST"
        orchestrator -> summaryservice "Запрос саммари (planned)" "HTTP POST"
        parserservice -> openrouter "LLM-vision на JPG/PDF-сканы — Qwen3-VL primary + Qwen 2.5 VL fallback" "HTTPS"
        summaryservice -> openrouter "Claude Haiku 4.5 для дайджеста + DeepSeek-chat fallback" "HTTPS"
        orchestrator -> google "Append дайджест-row в Sheets (planned)" "API"
        orchestrator -> agentcaller "WhatsApp pre-alert + Telegram dispatch" "HTTP POST"
        orchestrator -> google "Append дайджест-row в Sheets (planned v1.2)" "API"
        agentcaller -> messengers "Отправляет в каналы (Telegram + WhatsApp) — РАБОТАЕТ В ПРОД" "API"
        polygon -> google "Кладёт письма и логи в Drive/Sheets (current, будет деактивирован)" "API"

        # State-service связи (DEC-0021)
        orchestrator -> stateservice "last_at + lock per chat_id (incremental digest workflow + защита от двойного клика)" "HTTP REST + X-API-Key"
        stateservice -> redis "Persistent key-value store" "TCP (go-redis)"

        documentoved -> openrouter "OCR + LLM extract (superseded by DEC-008)" "HTTPS"
        documentoved -> google "Файлы → Drive, поля → Sheets (superseded)" "API"
        controller -> google "Читает Sheets, ищет проблемы (planned)" "API"
        controller -> agentcaller "Триггерит алерт (planned)" "HTTP POST"

        # === Compliance Logic Layer связи (DEC-0023, DEC-0025, DEC-0027) — статус 23.06.2026 ===

        compliancelogic -> postgres "JPA / Hibernate / Liquibase migrations (23 миграции)" "JDBC (Hikari pool)"
        compliancelogic -> compliancefiles "Запись/чтение blob-файлов документов (sha256-дедуп)" "Filesystem (java.nio.file)"
        compliancelogic -> agentcaller "Проактивные алёрты Таирову через GapAlertOrchestrator + HttpCallerClient — WA на :3000 (DEC-0027 в проде, 38 notifications в журнале)" "HTTP POST"
        orchestrator -> compliancelogic "POST /statements/ingest для DEC-0027 statement-vacuum (workflow в working tree, не задеплоено) + env COMPLIANCE_LOGIC_URL/API_KEY/CA_CERT заготовлены под mTLS" "HTTP POST (mTLS planned)"
        compliancelogic -> parserservice "Re-parse документа при backfill через orchestrator (planned, не используется в проде)" "HTTP POST"
        compliancelogic -> summaryservice "Re-summarize / Intent tagging для классификации (planned)" "HTTP POST"

        # Связи (Component уровень внутри Документоведа — все planned)
        ocr -> extract "Передаёт Markdown"
        extract -> validate "Передаёт JSON"
        validate -> router "Отвалидированные поля"
        router -> sheets_writer "Тип определён"
        router -> drive_mover "Тип определён"
    }

    views {
        systemContext compliance "SystemContext" "Compliance Assistant — контекст" {
            include *
            autolayout lr
        }

        container compliance "Containers" "Compliance Assistant — контейнеры (state 23.06.2026, после Commit 5 + DEC-0027/0028 ADR)" {
            include *
            autolayout tb
        }

        component documentoved "DocumentovedComponents" "Документовед — внутренние компоненты (planned, not implemented)" {
            include *
            autolayout lr
        }

        component compliancelogic "ComplianceLogicComponents" "Compliance Logic — компоненты Java/Spring-tier (DEC-0023 v0.0.7, 23.06.2026)" {
            include *
            autolayout tb
        }

        styles {
            element "Person" {
                shape Person
                background #08427B
                color #ffffff
            }
            element "External" {
                background #999999
                color #ffffff
            }
            element "Software System" {
                background #1168BD
                color #ffffff
            }
            element "Container" {
                background #438DD5
                color #ffffff
            }
            element "Component" {
                background #85BBF0
                color #000000
            }
        }

        theme default
    }
}
