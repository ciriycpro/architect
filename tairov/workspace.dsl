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
            mailservice = container "Mail Service" "Node.js, coo:8765" "IMAP-слушатель: парсит письма от Таирова, отдаёт по HTTP" 
            
            documentoved = container "N8N Документовед" "N8N workflow 'Полигон'" "OCR + извлечение полей + запись в Sheets" {
                ocr = component "OCR Step" "HTTP→Qwen3-VL" "Извлекает текст из PDF/JPG в Markdown"
                extract = component "LLM Extract" "HTTP→DeepSeek V3" "Извлекает структурированные поля (тип, контрагент, ИНН, сумма, дата)"
                validate = component "Validate" "Code-нода" "Проверка корректности полей"
                router = component "Type Switch" "Switch-нода" "Раскладка по 5 типам: договор/счёт/акт/выписка/прочее"
                sheets_writer = component "Sheets Writer" "Google Sheets→Append Row" "Запись в нужный лист реестра"
                drive_mover = component "Drive Mover" "Google Drive→Move" "Перекладывание файла в Обработанные/<тип>"
            }
            
            controller = container "N8N Контроллер" "N8N workflow" "Schedule + сверка по ИНН: ищет проблемы no_contract / draft_only / expired"
            
            agentcaller = container "Agent Caller" "Node.js, coo:3000" "Транспорт алертов: Telegram + WhatsApp + Email"
        }

        # Связи (Context уровень)
        tairov -> mailru "Отвечает на письма с документами" "SMTP"
        compliance -> messengers "Шлёт алерты Таирову и Артёму" "API"
        artem -> google "Просматривает реестр и файлы" "Web"
        compliance -> google "Хранит файлы и реестр" "API"

        # Связи (Container уровень)
        mailru -> mailservice "Входящие письма с вложениями" "IMAP"
        mailservice -> documentoved "Передаёт parsed JSON + binary" "HTTP POST"
        documentoved -> openrouter "OCR + LLM extract" "HTTPS"
        documentoved -> google "Файлы → Drive, поля → Sheets" "API"
        controller -> google "Читает Sheets, ищет проблемы" "API"
        controller -> agentcaller "Триггерит алерт" "HTTP POST"
        agentcaller -> messengers "Отправляет в каналы" "API"

        # Связи (Component уровень внутри Документоведа)
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

        container compliance "Containers" "Compliance Helper — контейнеры" {
            include *
            autolayout tb
        }

        component documentoved "DocumentovedComponents" "Документовед — внутренние компоненты" {
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
