workspace "KAMF" "Kafka Agent Multi-Agent Framework — мультиагентная платформа SIRIUS PRO" {

    model {
        # Внешние акторы
        architect = person "Архитектор" "Создаёт и поддерживает агентов"
        operator = person "Оператор" "Запускает и мониторит сценарии"

        # Внешние системы
        llm = softwareSystem "LLM Providers" "OpenAI, Anthropic, OpenRouter, Ollama" "External"
        channels = softwareSystem "Каналы доставки" "Telegram, WhatsApp, Email" "External"
        datasources = softwareSystem "Источники данных" "Корпоративные БД, API" "External"

        # Главная система — KAMF
        kamf = softwareSystem "KAMF" "Multi-Agent Framework на базе Kafka, A2A, MCP" {
            api = container "API Gateway" "Go + gRPC/REST" "Внешняя точка входа"
            orchestrator = container "Orchestrator" "Go" "Управление агентами, маршрутизация" {
                lifecycle = component "Lifecycle Manager" "Go" "Spawn / scale / kill агентов"
                router = component "Task Router" "Go" "Маршрутизация по A2A"
                health = component "Health Checker" "Go" "Мониторинг состояния агентов"
                scheduler = component "Scheduler" "Go" "Планирование задач"
            }
            registry = container "Agent Registry" "Go" "Реестр агентов и capabilities"
            kafka = container "Kafka Bus" "Apache Kafka" "Магистраль межагентного обмена" "MessageBus"
            planner = container "Planner Agent" "Python + LangGraph" "Декомпозиция задач"
            executor = container "Executor Agent" "Python" "Выполнение действий через MCP"
            evaluator = container "Evaluator Agent" "Python" "Оценка качества результатов"
            mcp = container "MCP Server" "Go" "Инструменты для агентов по MCP-протоколу"
            postgres = container "PostgreSQL" "PostgreSQL 16" "Состояния, история, метаданные" "Database"
            redis = container "Redis" "Redis 7" "Кэш, очереди, дедупликация" "Database"
            vectordb = container "Vector Store" "Milvus / pgvector" "Эмбеддинги для RAG" "Database"
        }

        # Связи (Context уровень)
        architect -> kamf "Описывает агентов в DSL, деплоит"
        operator -> kamf "Запускает сценарии"
        kamf -> llm "Запросы к LLM" "HTTPS/REST"
        kamf -> channels "Отправляет ответы" "HTTPS/Webhooks"
        kamf -> datasources "Читает/пишет" "JDBC/REST"

        # Связи (Container уровень)
        operator -> api "Запросы" "HTTPS"
        api -> orchestrator "Маршрут" "gRPC"
        orchestrator -> registry "Поиск агентов" "SQL"
        orchestrator -> kafka "Публикация задач" "Kafka"
        orchestrator -> redis "Очереди, кэш" "RESP"
        kafka -> planner "Доставка задач" "Kafka"
        kafka -> executor "Доставка задач" "Kafka"
        kafka -> evaluator "Доставка задач" "Kafka"
        planner -> kafka "Подзадачи" "Kafka"
        executor -> kafka "Результаты" "Kafka"
        evaluator -> kafka "Оценки" "Kafka"
        planner -> mcp "Инструменты" "MCP"
        executor -> mcp "Инструменты" "MCP"
        evaluator -> mcp "Валидаторы" "MCP"
        planner -> llm "LLM запросы" "HTTPS"
        executor -> llm "LLM запросы" "HTTPS"
        evaluator -> llm "LLM запросы" "HTTPS"
        mcp -> datasources "Доступ к данным" "REST"
        mcp -> vectordb "RAG поиск" "REST"
        planner -> postgres "Состояние" "SQL"
        executor -> postgres "Результаты" "SQL"
        api -> channels "Webhooks" "HTTPS"

        # Связи (Component уровень внутри Orchestrator)
        api -> router "Запрос на маршрутизацию"
        router -> lifecycle "Запрос агента"
        router -> scheduler "Постановка задачи"
        lifecycle -> registry "CRUD агентов"
        scheduler -> kafka "Публикация"
        health -> kafka "Heartbeat"
        health -> registry "Статус"
    }

    views {
        systemContext kamf "SystemContext" "KAMF — системный контекст" {
            include *
            autolayout lr
        }

        container kamf "Containers" "KAMF — контейнеры" {
            include *
            autolayout tb
        }

        component orchestrator "OrchestratorComponents" "Orchestrator — компоненты" {
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
            element "Database" {
                shape Cylinder
                background #438DD5
                color #ffffff
            }
            element "MessageBus" {
                shape Pipe
                background #FF8C00
                color #ffffff
            }
        }

        theme default
    }
}
