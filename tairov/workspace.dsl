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
        openrouter = softwareSystem "OpenRouter API" "Qwen3-VL (OCR), DeepSeek V3 (LLM extract)" "External"
        messengers = softwareSystem "Telegram + WhatsApp + Email" "Каналы доставки алертов" "External"

        # Главная система
        compliance = softwareSystem "Compliance Helper" "Контур автоматической сверки документооборота на coo.gcp" {

            # === Реально работающие компоненты на 09.05.2026 ===

            agentcaller = container "Agent Caller" "Node.js, coo:3000, systemd" "[РАБОТАЕТ В ПРОД] Транспорт алертов: Telegram + WhatsApp + Email. Аптайм с 27.04.2026"

            polygon = container "Polygon (Полигон)" "N8N workflow id 1632604d64e14e20" "[ПОЛУ-ЗАГЛУШКА] Schedule+Webhook+IMAP→Drive раскладка по отправителям + Sheets лог. Работает нестабильно — часть писем теряется. Ждёт замены mail-service'ом"

            # === Working code, не запущен в прод ===

            mailservice = container "Mail Service" "Python 3.10 + FastAPI, /opt/mail-stack/mail-service/" "[WORKING CODE / NOT IN PROD] coo:8765. Endpoints /health и /mail/since/<YYYY-MM-DD>. v1 успешно отдаёт письма, не оформлен в systemd, не докеризован. Развилка по форме развёртывания — DEC-006"

            # === Описано в плане, не реализовано ===

            documentoved = container "N8N Документовед v2 (planned)" "N8N workflow, 12 нод" "[NOT IMPLEMENTED] План DEC-004: OCR + извлечение полей + запись в Sheets. На 09.05.2026 нет ни одной ноды. В БД N8N лежит inactive Документовед-Франкенштейн (DEC-003, 39 нод) — артефакт, не используется" {
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

        # Связи (Container уровень) — отражают замысел; реально работают только agentcaller→messengers и polygon-цепочка
        mailru -> mailservice "Входящие письма с вложениями (planned: replace polygon)" "IMAP"
        mailru -> polygon "Входящие письма (current temporary path)" "IMAP"
        mailservice -> documentoved "Передаёт parsed JSON + binary (planned)" "HTTP POST"
        polygon -> google "Кладёт письма и логи в Drive/Sheets (current)" "API"
        documentoved -> openrouter "OCR + LLM extract (planned)" "HTTPS"
        documentoved -> google "Файлы → Drive, поля → Sheets (planned)" "API"
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

        container compliance "Containers" "Compliance Helper — контейнеры (current state 09.05.2026)" {
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
