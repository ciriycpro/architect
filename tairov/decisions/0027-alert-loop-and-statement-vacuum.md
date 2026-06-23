# DEC-0027 — Commit 5: Alert-петля (детект → живой outbound) + Statement-vacuum (авто-ингест выписок)

## Status

In progress (03.06.2026). Часть **в бою**, часть в активной разработке. Версия `compliance-logic` — v0.0.7-SNAPSHOT (после Commit 4 / DEC-023 v0.0.6).

- **Alert-петля — на проде, выстрелила вживую** 03.06.2026 09:00/09:02 МСК: 2 WhatsApp двум ИП.
- **Statement-vacuum — серверная сторона (ingest-endpoint) задеплоена и проверена**; оркестратор-опрос почты — в работе.

## Context

### A — точка старта (после DEC-023 Commit 4, v0.0.6, 31.05.2026)

К началу этой работы система уже умела:
- Registry (12 `@Audited`-сущностей), **Inspector v2** — детект пробелов в выписках по `StatementCalendar` (включая недельную частоту), **Reconciler** — матч операции на `Contract` по № договора из назначения платежа, **547+ операций** двух ИП (Таиров/ВТБ, Веретенникова/Альфа) на проде.

Но два контура отсутствовали:
1. **Исходящий** — дыры только **детектировались** (статус `DETECTED`), наружу не уходило ничего.
2. **Входящий** — выписки заливались **вручную** (внешний loader / GDrive-backfill); авто-приёма из почты не было.

Архитектурный разрыв: система видела проблему, но не действовала и не принимала входящие сама. Переход «реестр → ассистент» требует обоих контуров.

### B — точка финала этой сессии (03.06.2026)

- **Исходящий контур — живой**: детект дыры → WhatsApp клиенту, самоходно по расписанию МСК.
- **Входящий контур** — серверная склейка приёма выписки готова и проверена; осталось подключить опрос почты оркестратором.

## Decision

### 1. Alert-петля (исходящий контур)

- `GapAlertOrchestrator` — детерминированный **two-phase outbox**: фаза 1 (короткая транзакция) клеймит дыры `SKIP LOCKED`, заводит `Notification(PENDING)`, двигает статус дыры (`REQUEST_SENT/ESCALATED`); фаза 2 (без локов) шлёт через `CallerPort.sendWhatsApp`, метит `SENT/FAILED`. Self-invocation обходится `TransactionTemplate`.
- **Канал — WhatsApp клиенту.** Эскалации-пинга Артёму нет (`ESCALATED` — статус, не сообщение).
- **Расписание** — `OrchestratorScheduler`, cron `0 0 9,21`, зона **`Europe/Moscow` задаётся явно** (зафиксированный урок: cron без зоны исполняется в UTC → «21:00» падало на 00:00 МСК).
- **Политика per-tenant** (`Tenant.policy` JSONB): `sending_enabled`, `reminder_interval_hours=12`, `max_reminders`, `channel_order`.

### 2. Statement-vacuum (входящий контур) — вариант A

- **Тонкий серверный координатор** `StatementIngestService` + `POST /statements/ingest` — НЕ новый ингестор, а склейка **уже существующих** сервисов (`DocumentService` → `StatementService` → `MoneyOperationService` → `scanClient`). Отвергнут вариант B (оркестратор склеивает endpoint'ы loader'а в Go: 3-4 вызова + ручной multipart — размазывает логику).
- **Резолв клиента — гибрид «счёт-первичный, имя-бутстрап»:** (1) по `account_number` — если счёт уже встречался в `statements` (точная обученная связка); (2) иначе по **фамилии** владельца → `Client.fullName`, и счёт привязывается этой выпиской. **Маршрут по ИНН отвергнут** — находка по данным: ВТБ-выписки (pdf и xlsx) **ИНН владельца не содержат** (только имя); симметричный ключ по ИНН невозможен.
- **Новую сущность `Account` не плодим** (лишний реестр-костыль) — номер счёта полем `account_number` на `Statement` (миграция 0023 + зеркало в `statements_aud` для Envers).
- **Опрос почты — poll, не push** (mail.ru IMAP не пушит): оркестратор спрашивает 5458508 (`?label=compliance-5458508`) **4×/день** (09/13/17/21 МСК) — щадяще, один IMAP-логин на опрос.
- **Идемпотентность:** sha256 файла (`createFromBytes` → null при дубле) + `source_message_id` письма.
- **Синхронный ингест, не async-`ComplianceEvent`:** у события `clientInn` NOT NULL, а ВТБ ИНН владельца не несёт — резолв обязан произойти на сервере **до** появления INN; синхронный резолв снимает курицу-яйцо.

### 3. Встраивание в существующую цепочку

Vacuum пишет `operation_class` + `purpose` — ровно то, чем кормится **Reconciler** (Commit 4). Пылесос встаёт в существующий поток (выписка → операции → сверка с договорами по № из назначения), **не сбоку**.

## Implementation Notes (v0.0.7-SNAPSHOT, 02–03.06.2026)

### Alert-петля (02.06, на проде)

| Блок | Суть |
|---|---|
| Схема (миграции 0018–0022) | `Tenant`(policy JSONB), `Notification`(idempotency_key, status, attempts, caller_response), поля долбёжки на `StatementGap` (reminder_no, next_action_at) |
| `GapAlertOrchestrator` | two-phase outbox, `TransactionTemplate`, программный обход self-invocation |
| `OrchestratorScheduler` | cron `0 0 9,21` **zone=Europe/Moscow** |
| `CallerPort` / `HttpCallerClient` | транспорт WhatsApp, увеличенный timeout |
| Канал | переведён Telegram → WhatsApp-only |

**Боевой прогон 03.06.2026 09:00 МСК:** `RunResult[groups=2, notificationsCreated=2, sent=1, dryRun=0, failed=1, escalated=0]`. Оба сообщения **доставлены** (ВТБ/Таиров — 9 недель 30.03–31.05; Альфа/Веретенникова — 8 недель 06.04–31.05). `failed=1` — **ложный**: Caller вернул `request timed out` на втором сообщении при фактической доставке (см. Open Issues #3).

### Statement-vacuum (02–03.06)

| Слой | Что сделано |
|---|---|
| mail-service (Python) | `/mail/since/{date}?label=&group=` — ящик 5458508 в группе `compliance` (`default:false` → digest его не видит) |
| parser-service (Python) | `POST /parse-statement` — структурный разбор (ВТБ pdf/xlsx, Альфа pdf → счёт/период/операции/владелец) + `owner_inn` (Альфа) |
| compliance-logic (Java) | `account_number` на `Statement` (миграция 0023 + `_aud`); `StatementIngestService` + `StatementIngestController` (`POST /statements/ingest`, multipart); `StatementRepository.findByAccountNumber`; перегрузка `StatementService.create(..., accountNumber)` |

**Smoke 03.06.2026:** endpoint жив (HTTP 200), резолв по фамилии → правильный клиент (Таиров, INN `050900147847`), sha256-дедуп отрабатывает на повторном файле.

### Метрики прогресса

| Метрика | Commit 4 (v0.0.6) | Commit 5 (v0.0.7) | Δ |
|---|---|---|---|
| Schedulers | 2 (Inspector, Reconciler) | 3 (+Orchestrator) | +1 |
| Каналы наружу | 0 (только `DETECTED`) | 1 (WhatsApp, живой) | +1 |
| REST endpoints | 40 | 41 (+`/statements/ingest`) | +1 |
| Миграции | 0017 | 0023 | +6 |
| Операций на проде | 547 | 882 | +335 |

## Open Issues (следующее, по приоритету)

1. **Оркестратор-опрос почты (Go).** Прокинуть `label` в mail-активность, workflow `statement-vacuum`, ingest-активность (multipart → `/statements/ingest`), cron 4×/день МСК. Без этого входящий контур не замкнут.
2. **Альфа-xlsx.** Парсер xlsx пока только ВТБ; закрыть для симметрии (все клиенты/форматы ровно).
3. **Caller — ложный FAILED.** Поднять таймаут `HttpCallerClient`: доставленное сообщение помечается FAILED при медленной Chrome-отправке (даёт риск дубля алерта).
4. **Ингест договоров (документ → `Contract`).** Reconciler-матчер готов, но таблица `contracts` пуста → всё флагается `MISSING_CONTRACT`. Нужен путь документ→Contract, чтобы флаги закрывались.
5. **Резолв при одинаковых фамилиях** — тай-брейк по счёту/ИНН (на масштаб).
6. **Расхождение ИНН Таирова** — реестр `050900147847` vs `050401330914` в строках самопереводов; выверить источник правды.

## Consequences

**Положительные:**
- Переход «реестр → ассистент»: система впервые **действует наружу** (просит недостающие выписки) и готова **принимать входящие** сама.
- Vacuum переиспользует сервисный слой и встраивается в цепочку Reconciler — без дублей сущностей и костыльных таблиц.
- Резолв самообучается: счёт после первой выписки резолвится точно, имя нужно лишь для бутстрапа.

**Отрицательные / риски:**
- Бутстрап по фамилии хрупок при коллизии фамилий — нужен тай-брейк (Open #5).
- Caller (Chrome-per-message) даёт ложные FAILED при медленной отправке — частичная доработка (Open #3).
- Входящий контур не замкнут до оркестратор-опроса (Open #1).

**Что НЕ делаем сейчас:** внешний оркестратор как отдельный сервис — отложен (DEC-025); ингест договоров — отдельным шагом (Open #4).

## References

- **DEC-023** — Compliance Logic Layer (Commit 1–4: Registry / Inspector / Reconciler), базовый слой, к которому пристроены оба контура.
- **DEC-025** — полная архитектура комплаенс-ассистента, языковая раскладка, отложенный внешний оркестратор.
- **DEC-022** — Mail-stack as Platform: mail-service как domain-tool (переиспользован как label-адресуемый источник).
- **DEC-017** — Secure by Design: mTLS, rate-limit (наследуются compliance-logic).
- **DEC-014** — Orchestrator (Go): источник опроса почты для входящего контура.

## Implementation Notes (23.06.2026, post-deploy status check)

После санации архитектурного канона зафиксирован фактический статус компонентов на coo (read-only скан 23.06.2026 11:53 UTC).

### Что в проде (deployed)

**Java compliance-logic** — jar собран 04.06.2026, активен:
- `StatementIngestService` (Commit 5, 02-03.06).
- `GapAlertOrchestrator` с SQL-фильтром по типу флага.
- `CallerPort` (HttpCallerClient) — gap-alerts в WhatsApp Таирову.
- БД-факты: `notifications=38`, `statement_gaps=23`, `reconciliation_flags=26` (MISSING_CONTRACT), `money_operations=936`, `clients=2`, `counterparties=34`, `documents=39`, `statements=6`.

**Python mail-stack** — `/opt/mail-stack/` (Jun 2 — Jun 7):
- `mail-service`: endpoint `GET /mail/since/{since_date}?label=&group=` с реальным фильтром MAILBOXES (DEC-022 parity, см. также DEC-0022 addendum).
- `parser-service`: endpoint `POST /parse-statement` + модули `statement_parser.py` (ВТБ/Альфа PDF) и `statement_xlsx.py` (ВТБ-only, см. также DEC-0008 addendum).
- `attachment-service`: label/group filtering в `_imap_find_message` (фикс 07.06.2026, замыкает DEC-022 parity на attachment-service).

### Что НЕ в проде (working tree only)

**orchestrator Go-часть** — лежит в `~/compliance-assistant-repo/`, не собрана, не задеплоена:
- `workflow/statement_vacuum_v1.go` — workflow (untracked).
- `activities/ingest.go` — клиент к `/statements/ingest` (untracked).
- `activities/{mail,parser,attachment}.go` — модифицированы для label-проброса (modified).
- `cmd/orchestrator/main.go` — добавлен второй cron `c2` для statement-vacuum (+88 строк, modified).
- `config/config.go` — добавлена `STATEMENT_VACUUM_SCHEDULE` (+8 строк, modified).

env-файл `/etc/mail-stack/orchestrator.env` содержит `STATEMENT_VACUUM_SCHEDULE=0 6,10,14,18 * * *` — заготовлен под будущий деплой.

`MailboxLabel: "compliance-5458508"` зашит как хардкод в `main.go` строка 119 (см. cleanup_backlog_v2.md п. 2.4 — вынести в env). Цепочка label-routing замкнута: orchestrator → mail-service `?label=` → attachment-service `?label=` → IMAP boxes.

**Запущенный orchestrator-bin** — старый, без statement_vacuum workflow. Бинарь strings → `orchestrator-v1.2`.

### Open Issues — обновление статуса

- **Open #1 (оркестратор-опрос почты для входящего контура)** — остаётся открытым: код в working tree, не задеплоен. Входящий контур не замкнут.
- **Open #2 (Альфа-xlsx парсинг)** — остаётся открытым: `statement_xlsx.py` содержит только `bank_name="ВТБ (ПАО)"`, Альфа-xlsx не реализована (см. также DEC-0008 addendum).
- **Open #3 (ложный FAILED при медленной Chrome в Caller)** — **RESOLVED 12.06.2026**: `HttpCallerClient.java` timeout на `/send-wa` увеличен с 120с до 300с (правка в working tree, не задеплоена; jar на coo 04.06 имеет старый timeout).
- **Open #4 (ингест договоров)** — переведён в **DEC-0028** (Drafted, not implemented).
- **Open #5 (тай-брейк при одинаковых фамилиях)** — остаётся открытым, ждёт коллизии в проде.
- **Open #6 (расхождение ИНН Таирова 050900147847 vs 050401330914)** — остаётся открытым, ждёт ревизии исходных данных.

### Зеркалирование кода в репо

Все Python-правки (`/opt/mail-stack/mail-service`, `/parser-service`, `/attachment-service`) **не закоммичены** в `~/compliance-assistant-repo` — последний sync с coo 03.06.2026. Java и Go правки **в working tree, не закоммичены**. Зеркалирование выполняется отдельным шагом санации (см. cleanup_backlog_v2.md, раздел 1.2).
