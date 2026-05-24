workspace "Tairov Compliance Helper" "Автоматизация документооборота ИП Таирова — сверка договоров/счетов/актов, алерты по 3 типам проблем" {

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
        compliance = softwareSystem "Compliance Helper" "Контур автоматической сверки документооборота на coo.gcp" {

            # === Реально работающие компоненты на 12.05.2026 ===

            agentcaller = container "Agent Caller" "Node.js, coo:3000, systemd" "[РАБОТАЕТ В ПРОД] Транспорт алертов: Telegram + WhatsApp + Email. Аптайм с 27.04.2026"

            polygon = container "Polygon (Полигон)" "N8N workflow id 1632604d64e14e20" "[ПОЛУ-ЗАГЛУШКА — будет деактивирован после Email Digest v1] Schedule+Webhook+IMAP→Drive раскладка по отправителям + Sheets лог. Работает нестабильно — часть писем теряется. Замещается mail-service v1 + Email Digest v1 workflow"

            # === Mail-stack v1.0 — основа автоматизации документооборота ===
            # Прод (12-13.05.2026): mailservice, attachmentservice, parserservice, summaryservice, orchestrator
            # На v1.1: multi-account email + Telegram-кнопка через Agent Caller

            mailservice = container "Mail Service v1" "Python 3.11 + FastAPI + systemd, /opt/mail-stack/mail-service/" "[РАБОТАЕТ В ПРОД c 12.05.2026, contract update 13.05] coo:8765. Endpoints /health и /mail/since/<YYYY-MM-DDTHH:MM>?limit=50 (date+time precision с пост-фильтрацией по времени для DEC-013 на v2). Docker-friendly код, env-конфиг в /etc/mail-stack/. RAM 39 МБ. DEC-007"

            # === Планируется к реализации в составе mail-stack (DEC-008, DEC-009, DEC-010) ===

            attachmentservice = container "Attachment Service v1" "Python 3.11 + FastAPI + systemd, /opt/mail-stack/attachment-service/" "[РАБОТАЕТ В ПРОД c 12.05.2026] coo:8766. Endpoint POST /download — скачивание вложения по messageId+filename. Хранилище /var/lib/mail-stack/attachments/<messageId>/<filename>. Кэш через FS (idempotent, ускорение ~130×). RAM 28 МБ. DEC-011"

            parserservice = container "Parser Service v1" "Python 3.10 + FastAPI + systemd, библиотеки L1-L14, /opt/mail-stack/parser-service/" "[РАБОТАЕТ В ПРОД c 13.05.2026] coo:8767. Endpoint POST /parse — детерминированный роутер по MIME + per-page роутинг внутри PDF. Реализованы все 8 веток L1-L14 (TXT/CSV/JSON/XML/HTML/DOCX/XLSX/PDF/JPG). pdf-inspector работает через detect_pdf_bytes(). LLM-vision Qwen3-VL primary + Qwen 2.5 VL fallback. RAM 38 МБ idle, 86 МБ после первого PDF. DEC-008"

            summaryservice = container "Summary Service v1" "Python 3.11 + FastAPI + systemd, Claude Haiku 4.5 + DeepSeek-chat fallback, /opt/mail-stack/summary-service/" "[РАБОТАЕТ В ПРОД c 13.05.2026] coo:8768. Endpoint POST /summary — массив писем с распарсенными вложениями → JSON с двумя форматами (summary_markdown для Sheets + summary_telegram до 1000 символов). Промпт v2 с живым разговорным тоном (Anthropic XML-tags, few-shot, action verbs). RAM 30.6 МБ. Stateless. Цена ~$0.005/дайджест. DEC-009"

            orchestrator = container "Orchestrator v1.0 (Go custom)" "Go 1.22 + net/http + robfig/cron + slog + caarlos0/env + uuid, /opt/mail-stack/orchestrator/" "[РАБОТАЕТ В ПРОД c 13.05.2026 15:57] coo:8769. Triggers: Schedule (cron, disabled на v1.0) + Webhook /digest-now + /check-mail (заглушка для v2). Координирует цепочку: mail → attachment → parser → summary → WhatsApp pre-alert → Telegram delivery. Structured logs (slog JSON) с trace_id UUID v7. Auth: X-API-Key constant-time compare. Rate limit token bucket. Path traversal validation. RAM 10 МБ (минимальный в стеке!). Workflow 12s без WA / 93s с WA. ~1100 строк production-Go + 380 тестов. Спроектирован для миграции на Temporal headless v2 → KAMF v3 (80%+ кода переиспользуется)"

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

            compliancelogic = container "Compliance Logic v0.0.5-SNAPSHOT" "Java 21 + Spring Boot 3.5.0 + Liquibase + Hibernate + Envers, /opt/compliance-logic/" "[РАБОТАЕТ c 23.05.2026, 6 коммитов: 8a828c8 → 5dfd6dc на 25.05.2026 00:00 МСК] coo:8771 (HTTPS mTLS server-side via internal CA). 30 REST endpoints, 10 Service-классов, 9 entity + Envers audit (9 *_aud таблиц + revinfo). БД: 19 таблиц. Реализовано: Client/Counterparty/Document/Statement/MoneyOperation/StatementGap/ComplianceEvent/BackfillJob/StatementCalendar (полный Service+REST). Inspector v2 (calendar-based scan): expected periods через StatementCalendar + между-Statement gaps. BackfillService: POST /admin/backfill для batch-импорта (sha256 дедуп). GlobalExceptionHandler: 7 handlers покрывают 28 типов exceptions. K8s manifests готовы. Security: X-API-Key + mTLS server-side + Bucket4j rate limit + path whitelist + Envers audit. systemd Backup cron + ротация 14 дней. RAM 217-347 МБ, jar 60 МБ. К коммиту 4: Contract + Act + Reconciler + Spring Statemachine. См. DEC-023 Implementation Notes v0.0.5"

            postgres = container "PostgreSQL 15.18" "Postgres 15.18 + Liquibase migrations, БД compliance, пользователь compliance_app" "[РАБОТАЕТ c 22.05.2026] coo:5432 (bind 127.0.0.1). Источник правды для Registry. На v0.0.5: 19 таблиц = 9 бизнес (clients, counterparties, documents, statements, money_operations, statement_gaps, compliance_events, backfill_jobs, statement_calendars) + 9 audit (*_aud через Envers) + revinfo + 2 liquibase. ~107 Envers ревизий. 12 миграций Liquibase 4.27. Hibernate Envers @Audited на всех entity. По DEC-017 — данные физически в РФ (152-ФЗ ready). Backup cron на coo с ротацией 14 дней. Зависимости от reorganization будущих коммитов: Contract + Act + ReconciliationFlag в коммите 4, OpenTelemetry + Vault в коммите 5+"

            compliancefiles = container "Filesystem Document Storage" "ext4 на coo, /var/lib/compliance-files/<inn>/" "[FOLDER ГОТОВА c 23.05.2026] Хранилище blob-файлов документов (выписки, договоры, акты). Структура: /staging/, /statements/, /contracts/, /acts/, /other/. chmod 700, владелец iakshin77. Метаданные в Postgres (Document table), blob на диске. По DEC-023 + DEC-017 — не зависит от Drive, source-of-truth"
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
        documentoved -> openrouter "OCR + LLM extract (superseded by DEC-008)" "HTTPS"
        documentoved -> google "Файлы → Drive, поля → Sheets (superseded)" "API"
        controller -> google "Читает Sheets, ищет проблемы (planned)" "API"
        controller -> agentcaller "Триггерит алерт (planned)" "HTTP POST"

        # === Compliance Logic Layer связи (DEC-023, DEC-025) ===

        compliancelogic -> postgres "JPA / Hibernate / Liquibase migrations" "JDBC (Hikari pool)"
        compliancelogic -> compliancefiles "Запись/чтение blob-файлов документов" "Filesystem (java.nio.file)"
        orchestrator -> compliancelogic "POST /compliance-event при появлении нового документа (planned v1.0) + POST /admin/backfill для Сценария 0 (planned v1.5)" "HTTP POST"
        compliancelogic -> orchestrator "POST /backfill/run для запуска workflow backfill (planned v1.5)" "HTTP POST"
        compliancelogic -> agentcaller "Проактивные алерты Таирову от Inspector/Scheduler (planned v1.0)" "HTTP POST"
        compliancelogic -> parserservice "Re-parse документа при backfill через orchestrator (planned v1.5)" "HTTP POST"
        compliancelogic -> summaryservice "Re-summarize / Intent tagging для классификации (planned v1.5)" "HTTP POST"

        # Связи (Component уровень внутри Документоведа — все planned)
        ocr -> extract "Передаёт Markdown"
        extract -> validate "Передаёт JSON"
        validate -> router "Отвалидированные поля"
        router -> sheets_writer "Тип определён"
        router -> drive_mover "Тип определён"
    }

    views {
        systemContext compliance "SystemContext" "Compliance Helper — контекст" {
            include *
            autolayout lr
        }

        container compliance "Containers" "Compliance Helper — контейнеры (state 12.05.2026: mail-service v1 in prod, mail-stack под реализацию)" {
            include *
            autolayout tb
        }

        component documentoved "DocumentovedComponents" "Документовед — внутренние компоненты (planned, not implemented)" {
            include *
            autolayout lr
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
