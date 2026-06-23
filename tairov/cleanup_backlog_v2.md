# cleanup_backlog_v2.md — техдолг Compliance Assistant

Date: 2026-06-12 (drafted) / 2026-06-23 (filed in repo)

Single source of truth для **известного, явно зафиксированного** технического долга по системе. Не делаем сейчас, но не забываем. Каждый пункт имеет триггер revisit (когда вернуться).

Структура: 5 разделов по слоям системы. 21 пункт.

---

## Раздел 1: Архитектура / Канон / Зеркалирование

### 1.1 Решение по `state-service` (Phase 1.1 / 1.2)
state-service сейчас Redis-only. Будущие задачи (lock contention при K8s replica orchestrator, distributed lock для post-ingest hook) могут потребовать Postgres advisory lock или вынос в отдельный consensus-tier. **Триггер revisit:** появление второй реплики orchestrator или Reconciler.

### 1.2 Прод-копии vs git: расходятся
- `/opt/mail-stack/mail-service/server.py` — поддержка label/group (DEC-022 parity) НЕ в git.
- `/opt/mail-stack/parser-service/` — `statement_parser.py`, `statement_xlsx.py`, `/parse-statement` endpoint в server.py НЕ в git.
- `/opt/mail-stack/attachment-service/server.py` — label/group filtering НЕ в git.
- `~/compliance-assistant-repo` working tree: 9 файлов M + 2 файла ?? (orchestrator + compliance-logic) НЕ в commit.

**Решение:** snapshot прода + working tree → commit в git → закрепить ссылки в ADR (DEC-022, DEC-0008, DEC-0027, DEC-0028).

### 1.3 Каталоги `orchestrator.bak.v1.1.20260516-*` × 2
14.2 MB бэкапов от 16.05.2026 в `/opt/mail-stack/`. На текущий контур не влияют.

**Решение:** `diff -rq` против `/opt/mail-stack/orchestrator/` → если расхождения только в orchestrator-bin → `sudo rm -rf` обоих каталогов.

### 1.4 Формализация деплой-формы Go-сервисов
Зафиксировано в DEC-0014 Implementation Notes (23.06.2026): build → cp → systemctl restart. Открытый пункт: deploy form ещё для state-service (он на 99% повторяет orchestrator, но формально не описан).

### 1.5 sync-all.command мастер-скрипт
Мак содержит две кнопки: `sync-dsl.command` (architect → GitHub) и `sync-code-from-coo.command` (coo → architect/Compliance-Assistant). Нужен `sync-all.command` который дёргает обе + `rsync` для Python-файлов `/opt/mail-stack/*.py` (вне `~/compliance-assistant-repo/`).

---

## Раздел 2: DEC-0027 follow-up (statement-vacuum)

### 2.1 Курсор `last_polled_at`
Сейчас `FALLBACK_PERIOD_HOURS=24` — каждый прогон читает почту за 24 часа назад. Цена: лишний IMAP traffic + sha256-dedup нагрузка на compliance-logic.

**Решение:** таблица `vacuum_cursor(label PRIMARY KEY, last_polled_at TIMESTAMPTZ)` в Postgres compliance. Атомарный update после успешного прогона. Workflow читает last_polled_at вместо `now - 24h`. **Триггер revisit:** после первого недельного прогона statement_vacuum в проде.

### 2.2 Observability/alerts для пылесоса
Сейчас алёрты на orchestrator-уровне отсутствуют. Тихие отказы не видны до утра.

**Алёрты добавить:**
- если `errors > 0` в прогоне → telegram/WA Артёму.
- если за 24ч нет писем от ожидаемого клиента → подозрительно.
- если `attachments_total > 0` но `ingested + skipped == 0` → всё упало в парсере.

### 2.3 Graceful shutdown для второго cron
В `main.go` блок `c.Stop()` в shutdown останавливает только digest-cron. Для `c2` (statement-vacuum) нужен `c2.Stop()` рядом. Не критично (kill процесса остановит всё), но архитектурно корректно. **Триггер revisit:** при деплое statement_vacuum_v1 (одновременно).

### 2.4 Конфиг `MailboxLabel` через env
Сейчас в `main.go` строка 119 жёстко зашит `MailboxLabel: "compliance-5458508"`. Должен быть env-переменная `STATEMENT_VACUUM_MAILBOX_LABEL=compliance-5458508`. Дефолт сохранится для backward compatibility.

### 2.5 Бинарь stripped+static в стандартизированный build
DEC-0014 Notes 23.06 описал ручную команду. Нужен `Makefile`:

```makefile
build:
	cd orchestrator && GOOS=linux CGO_ENABLED=0 go build \
		-trimpath -ldflags="-s -w" -o orchestrator-bin ./cmd/orchestrator
	file orchestrator/orchestrator-bin
```

---

## Раздел 3: DEC-0028 implementation (Contracts/Acts vacuum)

### 3.1 EDO provider selection
Контур.Диадок / СБИС / 1С-ЭДО — выбор отложен. Сравнительный анализ API, лицензий, тарифов. **Триггер revisit:** старт Phase 2 (после Phase 1 в проде + реального потока договоров).

### 3.2 Vision-LLM модель для парсера договоров
Claude Sonnet 4 vs GPT-4V vs локальный OCR + LLM. Тестировать на реальных сканах от Полины (некоторые могут быть фото с телефона). **Триггер revisit:** при реализации parser-service `/parse-document`.

### 3.3 GDrive adapter архитектура
Через rclone CLI или прямой Google API. Переиспользование OAuth token из существующего N8N credential (как в DEC-023 backfill) или новый. **Триггер revisit:** при реализации `activities/gdrive.go`.

### 3.4 PENDING_CONTRACT_FOR_ACT
Что делать если акт пришёл раньше договора? Сейчас drop. Альтернатива: ставить в pending queue, дожидаться договора. **Триггер revisit:** Phase 2, после первого реального потока актов.

### 3.5 Act-Contract merge при backfill
Если в одном multi-page PDF есть и договор, и акт — `/parse-document` должен вернуть массив, не один объект. **Триггер revisit:** при первом реальном многостраничном PDF.

---

## Раздел 4: Hardening compliance-logic

### 4.1 Cross-client защита в Reconciler bulk
`ReconcilerService.rescanForContract(contractId)` (Phase 1 DEC-0028 working tree) находит unlinked ops через `findByClientIdAndCounterpartyIdAndLinkedContractIdIsNull` — учитывает clientId, но в K8s replica есть теоретический race. **Решение:** distributed lock через state-service. **Триггер:** появление второй реплики.

### 4.2 MAX_LINK_BATCH=1000
Текущий cap в `rescanAll`. При накопленном backlog 10k+ операций нужны несколько прогонов. **Решение:** chunking через `Pageable` или Hibernate Stream. **Триггер:** реальный backlog > 1000.

### 4.3 K8s replica lock contention
При двух репликах compliance-logic — Reconciler/Inspector schedulers запустятся параллельно. Сейчас работает на одной реплике без замков. **Решение:** Spring `ShedLock` или Postgres advisory lock. **Триггер:** scale-up.

### 4.4 Chunking + pagination при >10k unlinked operations
Аналог 4.2 для других find-методов. Применять единый pattern через Pageable.

### 4.5 `trace_id` propagation orchestrator → compliance-logic
Orchestrator шлёт `X-Trace-Id` HTTP-header в активити (mail/parser/summary/attachment/notify) — подтверждено сканом 23.06. **Compliance-logic side:** `MDC.put` в Slf4j не реализован — grep пусто. Trace-склейка orchestrator↔compliance-logic нет.

**Решение:** добавить Spring `OncePerRequestFilter` который читает `X-Trace-Id`, кладёт в MDC, очищает в finally. Logback pattern должен включить `%X{traceId}` в JSON output.

### 4.6 Unique partial index на reconciliation_flags
Защита от дублей в случае конкурентных reconcile() с K8s replica.

```sql
CREATE UNIQUE INDEX uk_recflags_open ON reconciliation_flags
  (client_id, counterparty_id, flag_type, COALESCE(contract_ref, ''))
  WHERE status != 'RESOLVED';
```

Сейчас 7 обычных индексов на `reconciliation_flags`, partial unique НЕТ. **Триггер:** scale-up или замеченные дубли.

### 4.7 Post-ingest hook в `ContractService.create`
Phase 1 DEC-0028 working tree: после `contractRepository.save(c)` вызывается `reconcilerService.rescanForContract(savedContractId)` — узкий scope rescan только для связи флагов этого contract. **Mirrors паттерн** `inspectorService.scanClient(client.getId())` после statement ingest. ✅ Сделано локально, ждёт деплоя.

---

## Раздел 5: Прочее

### 5.1 Caller-таймаут extended 120→300с
DEC-0027 Open Issue #3 (ложный FAILED при медленной Chrome): `HttpCallerClient.java` timeout extended 120 → 300с. ✅ В working tree 12.06, ждёт деплоя в составе jar.

### 5.2 Альфа-xlsx парсер
DEC-0027 Open Issue #2: `statement_xlsx.py` только ВТБ. Альфа-Банк xlsx layout не реализован. **Триггер revisit:** при первой реальной xlsx-выписке от Альфы.

### 5.3 ИНН Таирова расхождение
DEC-0027 Open Issue #6: реестр `050900147847` vs `050401330914` в строках самопереводов. Выверить источник правды через ЕГРИП/банк. **Триггер revisit:** при ревизии исходных данных или при первом расхождении в проде.

### 5.4 Тай-брейк при одинаковых фамилиях
DEC-0027 Open Issue #5: при коллизии фамилий контрагентов — резолв по счёту/ИНН. На двух текущих клиентах коллизий нет. **Триггер revisit:** появление коллизии в проде.

### 5.5 mTLS интеграция orchestrator → compliance-logic
В `/etc/mail-stack/orchestrator.env` присутствуют env-переменные `COMPLIANCE_LOGIC_URL`, `COMPLIANCE_LOGIC_API_KEY`, `COMPLIANCE_LOGIC_CA_CERT`. **Кода нет** (`activities/compliance.go` отсутствует). Заготовка под будущий DEC прямого вызова compliance-logic из orchestrator. **Триггер revisit:** после деплоя statement_vacuum_v1 и оценки эффекта косвенного вызова через `activities/ingest.go`.

---

## Сводка по триггерам

| Когда вернуться | Пункты |
|---|---|
| **Сразу после деплоя statement_vacuum_v1** | 2.3, 2.4, 4.7 |
| **Сразу при пересборке jar** | 5.1 (Caller-timeout) |
| **После первого недельного прогона vacuum** | 2.1, 2.2 |
| **При реализации Phase 1 остатка DEC-0028** | 3.2, 3.3, 4.5 |
| **Phase 2 DEC-0028 / ЭДО** | 3.1, 3.4, 3.5 |
| **При scale-up (K8s replica)** | 4.1, 4.3, 4.4, 4.6 |
| **При реальном backlog > 1000** | 4.2 |
| **При первой Альфа-xlsx** | 5.2 |
| **Когда дойдут руки** | 1.1, 1.3, 1.5, 2.5, 5.3, 5.4, 5.5 |

---

## Связанные ADR

- **DEC-0008** — parser stack (Implementation Notes 23.06: `/parse-statement` + два модуля).
- **DEC-0014** — orchestrator (Implementation Notes 23.06: второй cron, форма деплоя, env-заготовка под mTLS).
- **DEC-0022** — mail-stack as platform (Implementation Notes 23.06: label/group parity).
- **DEC-0023** — compliance-logic layer (Implementation Notes v0.0.7: alert-loop + statement-ingest + notifications).
- **DEC-0025** — компонентная карта (Implementation Notes 23.06: фактическая картина на coo).
- **DEC-0027** — alert-loop + statement-vacuum (Implementation Notes 23.06: статус по факту, Open Issues update).
- **DEC-0028** — contract/act vacuum (Drafted, not implemented).
