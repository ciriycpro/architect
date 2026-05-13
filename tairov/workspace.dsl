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

            # === Mail-stack v1 — основа автоматизации документооборота ===
            # Прод (12-13.05.2026): mailservice, attachmentservice, parserservice, summaryservice
            # Planned: emaildigest

            mailservice = container "Mail Service v1" "Python 3.11 + FastAPI + systemd, /opt/mail-stack/mail-service/" "[РАБОТАЕТ В ПРОД c 12.05.2026] coo:8765. Endpoints /health и /mail/since/<YYYY-MM-DD>?limit=50. Docker-friendly код, env-конфиг в /etc/mail-stack/. RAM 39 МБ. DEC-007"

            # === Планируется к реализации в составе mail-stack (DEC-008, DEC-009, DEC-010) ===

            attachmentservice = container "Attachment Service v1" "Python 3.11 + FastAPI + systemd, /opt/mail-stack/attachment-service/" "[РАБОТАЕТ В ПРОД c 12.05.2026] coo:8766. Endpoint POST /download — скачивание вложения по messageId+filename. Хранилище /var/lib/mail-stack/attachments/<messageId>/<filename>. Кэш через FS (idempotent, ускорение ~130×). RAM 28 МБ. DEC-011"

            parserservice = container "Parser Service v1" "Python 3.10 + FastAPI + systemd, библиотеки L1-L14, /opt/mail-stack/parser-service/" "[РАБОТАЕТ В ПРОД c 13.05.2026] coo:8767. Endpoint POST /parse — детерминированный роутер по MIME + per-page роутинг внутри PDF. Реализованы все 8 веток L1-L14 (TXT/CSV/JSON/XML/HTML/DOCX/XLSX/PDF/JPG). pdf-inspector работает через detect_pdf_bytes(). LLM-vision Qwen3-VL primary + Qwen 2.5 VL fallback. RAM 38 МБ idle, 86 МБ после первого PDF. DEC-008"

            summaryservice = container "Summary Service v1" "Python 3.11 + FastAPI + systemd, Claude Haiku 4.5 + DeepSeek-chat fallback, /opt/mail-stack/summary-service/" "[РАБОТАЕТ В ПРОД c 13.05.2026] coo:8768. Endpoint POST /summary — массив писем с распарсенными вложениями → JSON с двумя форматами (summary_markdown для Sheets + summary_telegram до 1000 символов). Промпт v2 с живым разговорным тоном (Anthropic XML-tags, few-shot, action verbs). RAM 30.6 МБ. Stateless. Цена ~$0.005/дайджест. DEC-009"

            emaildigest = container "N8N Email Digest v1 (planned)" "N8N workflow, 7-8 нод" "[PLANNED — DEC-010] Triggers: Schedule 09:00 MSK + Webhook /digest-now. Цепочка: mail-service → attachment-service → parser-service → summary-service → Sheets + Telegram"

            # === Документовед v2 — заменяется горизонтальным стеком mail-stack ===

            documentoved = container "N8N Документовед v2 (superseded)" "N8N workflow, 12 нод" "[SUPERSEDED by DEC-008] План DEC-004 заменяется горизонтальным стеком mail-stack (attachment + parser + summary + emaildigest). Не реализуется. В БД N8N лежит inactive Документовед-Франкенштейн (DEC-003, 39 нод) — артефакт, не используется" {
                ocr = component "OCR Step (planned)" "HTTP→Qwen3-VL" "Извлекает текст из PDF/JPG в Markdown"
                extract = component "LLM Extract (planned)" "HTTP→DeepSeek V3" "Извлекает структурированные поля (тип, контрагент, ИНН, сумма, дата)"
                validate = component "Validate (planned)" "Code-нода" "Проверка корректности полей"
                router = component "Type Switch (planned)" "Switch-нода" "Раскладка по 5 типам: договор/счёт/акт/выписка/прочее"
                sheets_writer = component "Sheets Writer (planned)" "Google Sheets→Append Row" "Запись в нужный лист реестра"
                drive_mover = component "Drive Mover (planned)" "Google Drive→Move" "Перекладывание файла в Обработанные/<тип>"
            }

            controller = container "N8N Контроллер (planned)" "N8N workflow или Python-сервис" "[NOT IMPLEMENTED] Schedule + сверка по ИНН: ищет проблемы no_contract / draft_only / expired. На 09.05.2026 не существует ни в каком виде — ни workflow в N8N, ни cron-задание, ни сервис"
        }

        # Связи (Context уровень)
        tairov -> mailru "Отвечает на письма с документами" "SMTP"
        compliance -> messengers "Шлёт алерты Таирову и Артёму" "API"
        artem -> google "Просматривает реестр и файлы" "Web"
        compliance -> google "Хранит файлы и реестр" "API"

        # Связи (Container уровень) — реально работают agentcaller→messengers, polygon-цепочка, mailservice работает в проде
        mailru -> mailservice "Чтение почты по IMAP (RUNNING in prod)" "IMAP"
        mailru -> polygon "Входящие письма (legacy path, будет деактивирован после Email Digest v1)" "IMAP"
        mailservice -> emaildigest "Отдаёт письма по /mail/since (planned consumer)" "HTTP GET"
        emaildigest -> attachmentservice "Скачивание вложений (planned)" "HTTP POST"
        emaildigest -> parserservice "Парсинг вложений (planned)" "HTTP POST"
        emaildigest -> summaryservice "Запрос саммари дня (planned)" "HTTP POST"
        parserservice -> openrouter "LLM-vision на JPG/PDF-сканы — Qwen3-VL primary + Qwen 2.5 VL fallback" "HTTPS"
        summaryservice -> openrouter "Claude Haiku 4.5 для дайджеста + DeepSeek-chat fallback" "HTTPS"
        emaildigest -> google "Append «Дайджест» в Sheets (planned)" "API"
        emaildigest -> messengers "Доставка дайджеста Таирову в Telegram (planned)" "API"
        polygon -> google "Кладёт письма и логи в Drive/Sheets (current, будет деактивирован)" "API"
        documentoved -> openrouter "OCR + LLM extract (superseded by DEC-008)" "HTTPS"
        documentoved -> google "Файлы → Drive, поля → Sheets (superseded)" "API"
        controller -> google "Читает Sheets, ищет проблемы (planned)" "API"
        controller -> agentcaller "Триггерит алерт (planned)" "HTTP POST"
        agentcaller -> messengers "Отправляет в каналы (current)" "API"

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
