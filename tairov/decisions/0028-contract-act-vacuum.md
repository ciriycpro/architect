# 28. Contract/Act vacuum — реестр договоров и актов через единый пылесос

Date: 2026-06-12 (drafted) / 2026-06-23 (filed in repo)

## Status

**Drafted, not implemented.**

Phase 1 Java-правки (Reconciler, ContractService, MoneyOperationRepository) выполнены локально в working tree `~/compliance-assistant-repo` 12.06.2026, `mvn compile` прошёл чисто, но **на coo не задеплоено** (`compliance-logic.jar` собран 04.06.2026, не пересобирался). Остальная часть Phase 1 (parser-service `/parse-document`, GDrive adapter, `/contracts/ingest`, `/acts/ingest`, MISSING_ACT enum, workflow `contracts_vacuum_v1.go`) — спроектирована, не написана.

ADR зафиксирован в репо архитектуры 23.06.2026 в рамках санации канона (см. cleanup_backlog_v2.md).

## Context

После DEC-0027 (statement-vacuum) реестр выписок и операций наполняется автоматически. Следующий пробел — **реестр договоров и актов**:

Реестры `Contract` и `Act` реализованы структурно в Commit 4 compliance-logic (31.05.2026) — entity, repository, service, controller, ReconcilerService. Но **без потока данных**.

**Состояние на 10.06.2026** (подтверждено сверкой БД):

| Таблица | Записей |
|---|---|
| `contracts` | 0 |
| `acts` | 0 |
| `reconciliation_flags (MISSING_CONTRACT, DETECTED)` | 26 |
| `money_operations` без `linked_contract_id` | 936 |

**Источники документов:**
- **Договоры** — Google Drive (папка «От Полины (ДОГОВОРЫ)») + опционально email.
- **Акты** — ЭДО (электронный документооборот: Контур.Диадок / СБИС / 1С-ЭДО, выбор отложен).

`ReconcilerService.reconcile()` алгоритм готов: извлекает номер договора из `MoneyOperation.purpose` через regex, группирует по (counterparty + contract_number), создаёт `MISSING_CONTRACT` если договора нет. `rescanAll()` закрывает флаги при появлении договора. Алгоритм проверен на 26 текущих флагах — работает, ждёт наполнения `contracts`.

**Архитектурный пробел:** `linkToContract()` вызывается только вручную через REST. Автоматической линковки нет. Это блокирует закрытие 26 флагов и привязку 936 операций.

## Decision

### 1. Единый pylesos workflow для contract+act

Один Go workflow `contracts_vacuum_v1` в orchestrator с тремя source-адаптерами:

```
[GDrive adapter]  ──┐
[Mail adapter]    ──┼─→ parser-service /parse-document → routes by type:
[EDO adapter] ────┘                                       ├─ contract → /contracts/ingest
   (placeholder)                                          ├─ act      → /acts/ingest
                                                          └─ unknown  → skip + log
```

Архитектурный приоритет: **одна машина, три источника, два endpoint'а**. Не дублируем pipeline.

### 2. parser-service: новый endpoint `/parse-document`

Определяет тип файла (`contract` | `act` | `unknown`), парсит реквизиты.

- PDF с текстовым слоем → детерминированный (regex + template).
- Скан / фото / DOCX → vision-LLM fallback (модель выбирается в open issue #2).
- Возвращает `{type, bank?, payload: {contract_number, contract_date, counterparty_inn, amount, period, signing_status, ...}}`.

Существующий `/parse-statement` не трогаем (DEC-0027). Новый endpoint независимый.

### 3. compliance-logic: два новых endpoint'а

- **`POST /contracts/ingest`** (multipart: `file` + `meta`) — шаблон точно как `/statements/ingest`. Meta содержит: `contract_number, contract_date, counterparty_inn, counterparty_name, amount, valid_from, valid_to, subject, subject_category, signing_status, source_document_id`.
- **`POST /acts/ingest`** (multipart: `file` + `meta`) — meta обязательно содержит `contract_number + contract_date` ИЛИ `linked_contract_id` для привязки к договору. Если контракт не найден → 422 (создаём ReconciliationFlag.PENDING_CONTRACT_FOR_ACT в будущем; пока — drop).

Используется существующая идемпотентность через sha256 `documentService.createFromBytes(...)`.

### 4. ReconcilerService: расширение

Добавляется метод **`reconcileActs(clientId)`**:
- Берёт `money_operations` где `linked_contract_id IS NOT NULL`.
- Группирует по `linked_contract_id`, считает `sum(amount)`.
- Сравнивает с `sum(acts.amount)` под тем же договором.
- Если `sum_ops - sum_acts > tolerance` → создаёт `ReconciliationFlag(MISSING_ACT)` с деталями.

Алгоритм по аналогии с существующим `reconcile()`, но второй уровень (после того как contract уже привязан).

В `ReconciliationFlagType` enum добавляется значение **`MISSING_ACT`** (additive — не ломает миграции).

### 5. Alerting policy: двухуровневая

| Flag | Алёрт | Когда активен |
|---|---|---|
| `MISSING_CONTRACT` | WA Таирову через gap-alert-loop | сразу после Phase 1 |
| `MISSING_ACT` | **молчит** до Phase 2 | активируется при подключении ЭДО |

Реализация: фильтр `flagType IN (MISSING_CONTRACT)` в `GapAlertOrchestrator` SQL-запросе. Когда придёт время — фильтр снимается одной строкой.

**Принцип:** алгоритм работает в фоне (флаги создаются, считаются), но нет шума пока нет полной картины (нет потока актов из ЭДО → 100% операций будут "missing act" → false positive ливень).

### 6. orchestrator: новые компоненты

- `activities/gdrive.go` — клиент к Google Drive (через rclone CLI или прямой API — open issue #4).
- `activities/edo.go` — placeholder, реализация в Phase 2.
- `activities/parse_document.go` — клиент к parser-service `/parse-document`.
- `activities/contract_ingest.go` — клиент к compliance-logic `/contracts/ingest`.
- `activities/act_ingest.go` — клиент к `/acts/ingest`.
- `workflow/contracts_vacuum_v1.go` — workflow.
- `cmd/orchestrator/main.go` — cron (реже чем выписки, например `0 8,18 * * *` UTC = 11/21 МСК, договоры приходят редко).
- env-переменные: `CONTRACTS_VACUUM_SCHEDULE`, `GDRIVE_FOLDER_ID`, `GDRIVE_AUTH_*`.

## Phases

### Phase 1 — Contracts (drafted, not implemented)

**Java часть (выполнено локально 12.06.2026, не в проде):**
- `MoneyOperationRepository.findByClientIdAndCounterpartyIdAndLinkedContractIdIsNull(...)` — новый метод (+2 строки).
- `ReconcilerService.rescanAll()` — расширен с bulk-линковкой через `saveAll`, cross-client defense, `MAX_LINK_BATCH=1000` (+102 строки).
- `ReconcilerService.rescanForContract(savedContractId)` — новый узкий-scope rescan для post-ingest hook.
- `ReconcilerService.RescanResult` — расширен до 3 полей.
- `ContractService.create()` — post-ingest hook `reconcilerService.rescanForContract(savedContractId)` после `contractRepository.save(c)` (+11 строк).
- `mvn compile` прошёл, тесты не запускались, jar не пересобирался.

**Не выполнено (планируется):**
- GDrive adapter (rclone-based).
- Mail adapter (label "contracts-*").
- parser-service `/parse-document` (contract path; act path возвращает unknown пока).
- compliance-logic: `/contracts/ingest` + `MISSING_ACT` enum + `reconcileActs()` (метод работает, при `acts.empty` молча возвращает empty).
- orchestrator: `contracts_vacuum_v1` workflow + cron.

**Ожидаемый эффект после полного Phase 1:** наполнение `contracts` → автоматический `rescanAll()` закрывает N из 26 `MISSING_CONTRACT` флагов → проставление `linked_contract_id` в 936 операциях.

### Phase 2 — Acts via EDO (later)
- Выбор EDO провайдера (#1).
- EDO adapter (OAuth/API).
- Активация `/acts/ingest` поток.
- Включение `MISSING_ACT` алертов (снять фильтр в GapAlertOrchestrator).
- `reconcileActs()` начинает реально работать.

## Consequences

- **Симметрия с DEC-0027:** контур договоров строится по той же модели что выписок.
- **Архитектурная зрелость:** acts инфраструктура заложена сразу, потом не разбираем.
- **Тихий запуск:** Phase 1 не генерит false-positive алёртов про акты.
- **Лёгкая Phase 2:** только Go-адаптер для EDO + одна строка снятия фильтра в Java. Никаких миграций, перестройки entity, изменения reconciler.
- **Прокси-выгода:** после первого contract-vacuum прогона видна реальная сумма работ — сколько из 26 флагов реально закроется vs останется (= договоры физически отсутствуют, не только в БД).

## Open Issues

1. **EDO provider selection** — Контур.Диадок / СБИС / 1С-ЭДО. Решение в Phase 2.
2. **Vision-LLM model для парсера** — Claude Sonnet 4 vs GPT-4V vs локальный OCR + LLM. Тестировать на реальных сканах договоров от Полины.
3. **PENDING_CONTRACT_FOR_ACT** — что делать если акт пришёл раньше договора? Сейчас drop. Альтернатива: ставить в pending queue, дожидаться договора. Решение после первого реального потока актов.
4. **GDrive auth** — переиспользовать существующий OAuth token из N8N credential (как в DEC-023 backfill) или новый.
5. **`MoneyOperation.linked_contract_id` через какой триггер обновляется** — сейчас Reconciler только создаёт `ReconciliationFlag`, но не виду в коде reconcile() где `linked_contract_id` проставляется. Возможно отдельный метод `linkOperationsToContracts(clientId)` нужен — проверить в Phase 1.

## Related

- **DEC-0021** — state-service (отдельный backlog cleanup).
- **DEC-0023** — Compliance Logic Layer (Commit 4: Contract/Act/Reconciler заложены).
- **DEC-0027** — statement-vacuum (закрыт 10.06.2026; симметричная модель источник→parser→ingest→reconciler).
- **cleanup_backlog_v2.md** — 21 пункт техдолга, в т.ч. 4.7 post-ingest hook (исполнено локально в Phase 1 Java правках).
