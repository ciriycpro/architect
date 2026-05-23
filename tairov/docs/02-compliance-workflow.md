# Compliance Assistant — Workflow Blueprint

Поведенческое описание процессов комплаенс-ассистента **без привязки к стеку**. Сначала «что делает система», затем — на каждом шаге пометка какой компонент это реализует и на каком языке.

Документ — проверочная таблица для всех ADR. Если ADR противоречит Blueprint, виноват ADR.

## Назначение системы

Compliance Assistant — это **проактивный stateful автомат**, который:

1. Ведёт реестр документов и операций клиента (контрагенты, договоры, акты, выписки, операции)
2. Самостоятельно обнаруживает пробелы и нарушения (отсутствующая выписка, неподписанный договор, операция без основания)
3. Запрашивает у клиента недостающие документы через мессенджер
4. Принимает входящие документы по почте, классифицирует, заносит в реестр
5. Сверяет операции с основаниями (договор/акт)
6. Генерирует готовые документы-ответы (ответ банку, акт сверки, пояснения)
7. Ведёт audit trail всех изменений для регуляторных запросов (115-ФЗ)

Принципиальное отличие от mail-stack v1.x: **там был stateless pipeline (письмо → дайджест), здесь — система с памятью и собственной инициативой**.

## Базовые сценарии

### Сценарий 0 — Bootstrap реестра из архива (12 месяцев истории)

**Назначение:** обеспечить бизнес-ценность с первой минуты работы системы. Без bootstrap'а реестр стартует пустым, и Inspector долгое время не может обнаружить пробелы — нет с чем сравнивать. Backfill заполняет реестр историческими данными за 12 месяцев, после чего Inspector с первого cron'а видит полную картину.

**Триггер:** один раз при онбординге клиента (через `POST /admin/backfill`).

**Источники данных (приоритет):**

1. **Файлы на coo** — Артём вручную через `scp` копирует папки с выписками/договорами/актами Таирова в `/var/lib/compliance-files/<inn>/staging/` перед запуском backfill (v1.0 default)
2. **Drive download** — опционально, если архив изначально в Google Drive. Drive используется как **временный buffer**, не как source-of-truth (см. принципы)
3. **Email-архив** — не включается на v1.0 (mail-stack обрабатывает только новые письма)
4. **Telegram-чат** — не существует (бота не было)
5. **1С** — не подключается на v1.0 (нет коннектора)

**Шаги:**

| # | Что происходит | Компонент | Язык |
|---|---|---|---|
| 1 | Артём кладёт файлы в `/var/lib/compliance-files/<inn>/staging/` (scp с локального диска или Drive download) | manual / scp / gcloud | bash |
| 2 | Артём вызывает `POST /admin/backfill` на Spring tier с параметрами `client_inn, period_start, period_end` | Spring REST | Java |
| 3 | BackfillService создаёт `BackfillJob` сущность в Registry со статусом `PENDING` | Spring + Registry | Java |
| 4 | BackfillService делает HTTP POST на orchestrator: `/backfill/run` c `jobId` | Spring HTTP client | Java |
| 5 | Orchestrator запускает workflow `backfill` — перебирает файлы в staging-папке | Orchestrator | Go |
| 6 | Для каждого файла orchestrator вызывает parser-service (извлечение текста) | parser-service | Python |
| 7 | Orchestrator вызывает summary-service с intent-tagging (классификация) | summary-service + Intent Tagger | Python |
| 8 | Orchestrator формирует `ComplianceEvent` с флагом `historic: true` и `source: BACKFILL` | Orchestrator | Go |
| 9 | Orchestrator делает `POST /compliance-event` на Spring tier | Orchestrator HTTP client | Go |
| 10 | Spring tier принимает event, валидирует, Document Classifier определяет тип документа | Spring controller | Java |
| 11 | Spring tier создаёт `Document` сущность с метаданными + `Statement`/`Contract`/`Act` запись | Registry | Java |
| 12 | Файл перемещается из `staging/` в постоянное расположение `/var/lib/compliance-files/<inn>/<type>/` | Filesystem | Java |
| 13 | Reconciler в фоне применяет правила сверки на накопленные данные (по флагу `historic`) | Reconciler | Java |
| 14 | Orchestrator репортит прогресс через `PATCH /admin/backfill/{jobId}/progress` (например 234/500 processed) | Orchestrator | Go |
| 15 | Когда все файлы обработаны — orchestrator меняет `BackfillJob.status = COMPLETED` | Spring + Registry | Java |
| 16 | Reconciler формирует сводный отчёт: «47 операций без оформленных договоров, контрагент X на сумму Y без актов...» | Reconciler + Reporting | Java/Python |
| 17 | Spring tier отправляет отчёт Таирову через Agent Caller (или ждёт явного запроса) | Scheduler + Agent Caller | Java + Node.js |

**Состояние после Сценария 0:**
- В Registry: 1 Client, ~50-500 Document'ов, ~50-100 Statement'ов, ~20-50 Contract'ов, ~30-100 Act'ов
- Все ReconciliationFlag'и поднятые от историч. данных
- Готовая база для Inspector в Сценарии 1
- Отчёт Таирову: текущее состояние комплаенса с цифрами

**Принципиальное отличие от Сценария 1:**

| Параметр | Сценарий 0 (Backfill) | Сценарий 1 (Inspector) |
|---|---|---|
| Триггер | Однократный, on-demand | Cron + on-demand |
| Объём | 100-500 документов одной пачкой | 1-10 событий в день |
| LLM-нагрузка | Высокая (массовая классификация) | Низкая |
| Реакция Inspector'а | Подавлена по флагу `historic: true` (не алертит) | Активная (запросы Таирову) |
| Источник | Файлы в staging-папке | Входящие письма |
| Завершение | `BackfillJob.status = COMPLETED` | Никогда (продолжается циклически) |

**Что Сценарий 0 НЕ делает (явно):**

- ❌ Не отправляет автоматические алерты по historic данным (только сводный отчёт)
- ❌ Не запрашивает у Таирова новые выписки за период bootstrap'а (он сам положил всё что есть)
- ❌ Не модифицирует исходные файлы в staging (после копирования в постоянное хранилище)
- ❌ Не зависит от Drive (Drive — опциональный transport на этапе подготовки staging, не runtime-источник)

### Сценарий 1 — Поиск пробела в выписках и запрос недостающего периода

**Триггер:** cron Inspector'a (например, 10:00 МСК ежедневно) или on-demand.

**Шаги:**

| # | Что происходит | Компонент | Язык |
|---|---|---|---|
| 1 | Inspector читает Registry: «по календарю должны быть выписки клиента X за период [Y..Z]» | Inspector | Java/Spring |
| 2 | Inspector сверяет с фактически имеющимися выписками клиента X в Registry | Registry + Inspector | Java/Spring |
| 3 | Inspector обнаруживает пробел: «есть выписки до 15.MM, нет с 15.MM по 01.MM+1» | Inspector | Java/Spring |
| 4 | Inspector создаёт сущность `StatementGap(client, gap_start, gap_end, status=DETECTED)` | Registry | Java/Spring |
| 5 | Scheduler смотрит «нужно ли отправлять запрос» (новый gap? повтор не отправляли последние 48 часов?) | Scheduler | Java/Spring |
| 6 | Scheduler резолвит шаблон `wa/request-statement.ftl` + контекст (период, клиент) | Template engine (Freemarker) | Java/Spring |
| 7 | Scheduler делает HTTP-вызов Agent Caller с собранным сообщением | HTTP-клиент | Java/Spring |
| 8 | Agent Caller отправляет в WhatsApp Таирову | Agent Caller | Node.js |
| 9 | Scheduler обновляет `StatementGap.status = REQUEST_SENT, last_request_at = now()` | Registry | Java/Spring |

**Состояние после шага 9:** запрос ушёл, ожидание ответа Таирова.

### Сценарий 2 — Приём ответа Таирова с выпиской

**Триггер:** входящее письмо.

**Шаги:**

| # | Что происходит | Компонент | Язык |
|---|---|---|---|
| 1 | Mail-service ловит входящее письмо | mail-service | Python |
| 2 | Attachment-service скачивает вложение | attachment-service | Python |
| 3 | Parser-service извлекает текст вложения (выписка Сбер XLSX → text+таблицы) | parser-service | Python |
| 4 | Summary-service делает резюме письма + **Intent Tagger** в том же промпте проставляет теги: `tags: ["statement_received", "bank: sberbank", "period: 15.MM-30.MM"]` | summary-service + Intent Tagger | Python |
| 5 | Orchestrator получает результат mail-stack, видит тег `statement_received` → формирует `ComplianceEvent` | Orchestrator | Go |
| 6 | Orchestrator вызывает `POST /compliance-event` на Spring tier с типизированным DTO | Orchestrator HTTP client | Go |
| 7 | Spring tier принимает событие, валидирует DTO, **Document Classifier** определяет: «это выписка Сбер за 15-30.MM, sha256=X» | Spring controller + Document Classifier | Java/Spring |
| 8 | Spring tier ищет соответствующий `StatementGap` в Registry → находит | Registry | Java/Spring |
| 9 | Spring tier создаёт `Statement(client, period, source_message_id, sha256, status=RECEIVED)` | Registry | Java/Spring |
| 10 | Spring tier обновляет `StatementGap.status = RECEIVED` | Registry | Java/Spring |
| 11 | Hibernate Envers автоматически пишет историю изменений в audit-таблицы | Envers | Java/Spring |
| 12 | Filer-логика: вложение копируется в Drive в папку `Выписки/MM.YYYY` | Filer | Python (внутри mail-stack) или Go |
| 13 | Spring tier публикует событие «statement.received» (внутри Spring tier) | Spring events / Outbox | Java/Spring |

**Состояние после шага 13:** выписка в Registry, gap закрыт, цикл сценария 1 для этого периода — закрыт. На следующем cron Inspector видит — пробелов нет.

### Сценарий 3 — Сверка операций с основаниями

**Триггер:** новая выписка появилась в Registry (событие `statement.received` из сценария 2).

**Шаги:**

| # | Что происходит | Компонент | Язык |
|---|---|---|---|
| 1 | Reconciler подписан на событие `statement.received` | Reconciler | Java/Spring |
| 2 | Reconciler парсит структурированные данные выписки (приходит из parser-service в JSON: список операций с контрагентом, ИНН, суммой, датой, назначением) | Reconciler + parser data | Java/Spring |
| 3 | Для каждой операции Reconciler ищет в Registry: контрагент (по ИНН), договор с этим контрагентом, акты выполнения | Registry | Java/Spring |
| 4 | Reconciler применяет правила и поднимает флаги:<br>— `missing_contract` (нет договора с этим контрагентом)<br>— `draft_only` (договор есть, но статус DRAFT, не подписан)<br>— `expired` (договор истёк до даты операции)<br>— `unsigned_act` (платёж есть, акта приёмки нет)<br>— `amount_mismatch` (сумма операции не совпадает с суммой по договору) | Reconciler engine | Java/Spring |
| 5 | Reconciler создаёт сущности `ReconciliationFlag(operation, type, severity, raised_at)` | Registry | Java/Spring |
| 6 | Для каждого флага Scheduler решает «нужен ли алерт Таирову?» | Scheduler | Java/Spring |
| 7 | Если нужен — шаблон + Agent Caller (как в сценарии 1 шаги 6-8) | Templates + Agent Caller | Java/Spring + Node.js |

### Сценарий 4 — Запрос банка по 115-ФЗ → генерация ответа

**Триггер:** входящее письмо с тегом `bank_request_115fz`.

**Шаги:**

| # | Что происходит | Компонент | Язык |
|---|---|---|---|
| 1-7 | Аналогично сценарию 2: mail-stack + Intent Tagger тегирует как `bank_request_115fz` | mail-stack | Python |
| 8 | Spring tier принимает событие, Document Classifier определяет: «запрос Сбера, требуют пояснения по операциям с ИНН X за период Y..Z» | Spring + Classifier | Java/Spring |
| 9 | Spring tier собирает контекст ответа из Registry: операции, договоры, акты по ИНН X | Registry | Java/Spring |
| 10 | Spring tier формирует структурированный JSON-payload и **вызывает Reporting-service** через HTTP | Spring HTTP client | Java/Spring |
| 11 | Reporting-service рендерит DOCX по Word-шаблону `bank-response-115fz-sberbank.docx` через docxtpl + Jinja | reporting-service | Python |
| 12 | Reporting-service конвертирует DOCX → PDF через LibreOffice headless | reporting-service | Python |
| 13 | Reporting-service отдаёт пути к файлам + Markdown-зеркало для audit | reporting-service | Python |
| 14 | Spring tier сохраняет ссылки на файлы в Registry, маркирует ответ как `READY_FOR_REVIEW` | Registry | Java/Spring |
| 15 | Scheduler шлёт Таирову алерт: «готов ответ Сберу по запросу 115-ФЗ, проверь и отправь» с ссылкой на файлы | Scheduler + Agent Caller | Java/Spring + Node.js |

**Принципиально:** система **не отправляет** ответ банку автоматически. Только готовит. Решение об отправке — за Таировым. См. принципы.

### Сценарий 5 — Сводная по платежам / реестр

**Триггер:** on-demand (Таиров жмёт кнопку «свод за месяц» в Telegram) или cron (ежемесячный отчёт).

**Шаги:**

| # | Что происходит | Компонент | Язык |
|---|---|---|---|
| 1 | Triggering event приходит в orchestrator (Telegram кнопка через Agent Caller) или Spring tier cron | Orchestrator / Spring | Go / Java |
| 2 | Spring tier собирает агрегат: операции за период, разбивка по контрагентам, флаги Reconciler'a | Registry | Java/Spring |
| 3 | Spring tier зовёт Reporting-service для рендера XLSX-отчёта | reporting-service | Python |
| 4 | Reporting рендерит по Excel-шаблону через openpyxl: лист «Сводка», лист «Детали», лист «Флаги» | reporting-service | Python |
| 5 | Файл отдаётся Таирову через Agent Caller (Telegram attachment) | Agent Caller | Node.js |

## Принципы поведения системы

### 1. Человек подписывает всегда

Система **никогда не отправляет** ответ банку или контрагенту автоматически. Только готовит документ → шлёт Таирову → Таиров проверяет → Таиров отправляет (либо командой системе «отправь от моего имени», либо вручную из своего почтового клиента).

### 2. Audit trail обязателен

Любое изменение Registry (создание/обновление/удаление сущности) автоматически попадает в audit-таблицы (Hibernate Envers). Это требование 115-ФЗ — банковский проверяющий получит SQL-запрос «история изменений договора № X» без дополнительной разработки.

### 3. Алерты дедуплицируются

Один и тот же gap не рассылается каждый день. Если запрос ушёл — следующий не раньше чем через 48 часов (настраиваемо). Дедупликация в Scheduler + state-service.

### 4. Шаблоны — в Git, не в DB

Все WA/email/документные шаблоны живут в отдельном репо `Compliance-Templates`, версионируются, ревьюятся, синкаются на coo через кнопку (по образцу `sync-dsl.command`). Spring Boot перечитывает шаблоны без рестарта (Freemarker hot-reload).

### 5. Идемпотентность входящих

Одно и то же письмо не обрабатывается дважды. Идемпотентность по `sha256(messageId+from+date)` через state-service v2.

### 6. Multi-tenant ready с первого дня

Все сущности Registry имеют `client_id`. Даже на одном клиенте (Таиров) — фильтрация по `client_id` работает. Приход второго клиента — это конфигурация, не рефакторинг.

### 7. Source of truth — наша БД, не внешний сервис

Postgres на coo + filesystem `/var/lib/compliance-files/<inn>/` — единственный авторитетный источник данных и документов. Внешние источники (Google Drive, email-архив, 1С) — это **transport-механизмы** для bootstrap'а и обмена, но не источник правды. Принципиально:

- 152-ФЗ compliance: ПДн физически в РФ на coo, не у внешних провайдеров
- Контроль аудита: Hibernate Envers пишет всю историю изменений Registry
- Backup-стратегия: своя, не зависим от Google/Apple
- Vendor lock-in: нет (можем сменить любой external transport без миграции данных)
- Drive — опциональный mirror (опционально синхронизируем туда snapshots для удобства Таирова), не runtime-зависимость

### 8. Контракты "OpenAPI first"

Все внешние HTTP-endpoints Spring tier описаны через OpenAPI 3 (генерация автоматическая через springdoc). Это даёт:

- Документированный контракт между orchestrator и Spring tier
- Готовность к будущему переходу на gRPC (есть конвертеры OpenAPI → Protobuf)
- Возможность сгенерировать client-stub'ы для Python/Go без ручной работы

JSON через HTTP RPC сейчас — рабочий выбор. gRPC появится только при триггере (performance bottleneck или строгие типизированные контракты на горизонте roadmap).

## Что НЕ делает система (явно)

- **Не парсит банковские API** — у МСП этого обычно нет, выписки приходят CSV/XLSX по почте
- **Не ведёт бухучёт** — это 1С работа, мы потребитель данных из 1С / выписок, не источник
- **Не подписывает документы** — Таиров подписывает сам (если ЭП — отдельная функция за пределами v1)
- **Не отправляет** документы внешним контрагентам и банкам — только готовит
- **Не зависит от Google Drive runtime** — Drive только как опциональный transport для bootstrap

## Маппинг сценариев на ADR

| Сценарий | Базовый ADR | Связанные ADR |
|---|---|---|
| **Сценарий 0 (Bootstrap из архива)** | **DEC-023 v1.5** | **DEC-014 (orchestrator workflow), DEC-022 (two-tier)** |
| Сценарий 1 (поиск пробела + запрос) | DEC-023 (Compliance Logic) | DEC-022, DEC-025 |
| Сценарий 2 (приём входящего) | DEC-005, DEC-008, DEC-009, DEC-014 (mail-stack) | DEC-023 (приём compliance-event), DEC-021 (state) |
| Сценарий 3 (сверка) | DEC-023 (Reconciler) | DEC-025 |
| Сценарий 4 (ответ банку) | DEC-023 + future ADR Reporting | DEC-025 |
| Сценарий 5 (сводная) | DEC-023 + future ADR Reporting | DEC-025 |

## Что описано в Blueprint, но не имеет ADR

- **Reporting-service** (Python, docxtpl + Jinja + openpyxl + LibreOffice headless) — отдельный микросервис рядом с mail-stack. Future ADR.
- **Document Classifier** (Python) — расширение parser-service или новый микросервис. Future ADR.
- **Filer** (Python или Go, тонкая прослойка) — раскладка вложений по папкам. Future ADR.
- **Intent Tagger** — на v1 живёт внутри `summary-service` как расширение промпта, не отдельный сервис. Может вырасти в отдельный сервис при росте сложности тегирования.
- **Event Bus** (Go + Redis Streams) — внутренняя шина между Spring tier и mail-stack. Future ADR, на горизонте после Reconciler.
- **Webhook gateway** (Go) — при появлении внешних callback (банковские API, платёжки). Future ADR.

См. DEC-025 для полной карты будущих ADR.
