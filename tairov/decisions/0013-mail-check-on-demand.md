# DEC-013 — Mail Check On-Demand: incremental workflow + event-driven progress

## Status

Accepted (16.05.2026). **Implemented 16.05.2026** в составе Orchestrator v1.2 + v1.2.2. Production на coo:8769 + state-service на :8770.

История планирования:
- В DEC-014 v1.0 (13.05.2026) — указано как «будущий DEC-013 на v2»
- В DEC-014 v1.1 (13.05.2026 вечер) — Telegram-кнопка реализована но всё ещё **stateless** (period=24h хардкод)
- **Триггер реализации**: после первых нажатий кнопки стало очевидно — UX «за последние 24 часа» каждый раз неуместен. Нужен incremental period.

## Context

После DEC-014 v1.1 Telegram-кнопка «Проверить почту» работала, но **stateless**:

```
Пользователь жмёт кнопку
  → orchestrator: period_hours = 24 (хардкод)
  → fetch mail since (now - 24h)
  → digest всех писем за сутки
```

Проблема: **каждое нажатие возвращало те же самые письма** что уже видел в предыдущем обзоре. Пользователь получал постоянно повторяющийся контент.

**Что нужно:**

1. **Запоминать момент последнего успешного обзора** для каждого chat_id
2. **При каждом нажатии**: показывать **только новое** с момента предыдущего обзора
3. **При первом запуске** (state пустой) — fallback на 24 часа
4. **Не дублировать дайджесты** при двойном клике на кнопку (lock-pattern)
5. **Прогресс-сообщения** должны быть **синхронизированы с реальностью** — не слепые таймеры

Это и есть **DEC-013 Mail Check On-Demand** который был запланирован на v2. Реализован раньше из-за реального UX-feedback.

## Decision

Реализовать **incremental workflow** в Orchestrator v1.2, использующий **state-service** (DEC-021) для хранения `last_at` и `lock`. Добавить **event-driven progress events** (v1.2.2) для синхронизации UX-сообщений с реальным состоянием workflow.

### Incremental period logic

```
1. AcquireLock(chat_id, ttl=300s)
   ↓ 409? → SkippedDueLock, exit (защита от двойного клика)
   ↓ 200 → продолжаем

2. GetLastAt(chat_id)
   ↓ 404 (state empty) → since = now() - FALLBACK_PERIOD_HOURS (default 24h)
   ↓ 200 → since = last_at

3. period = (now - since)
4. period_description = "с момента предыдущего обзора (X назад)" [state]
                       | "за последние X" [fallback]

5. fetch_mail since=YYYY-MM-DDTHH:MM
6. ... workflow ...
7. После УСПЕШНОЙ Telegram-доставки: SetLastAt(chat_id, now())
8. defer ReleaseLock() — гарантированный cleanup
```

### Event-driven progress events (v1.2.2)

Старая логика (v1.0–v1.2): Agent Caller запускал **слепые таймеры** — 60/180/360 секунд → «📚 Разбираюсь с документами» / «📑 Серьёзные сканы» / «⏳ Почти готово». Проблема: при быстром workflow (10 секунд без вложений) сообщения **всё равно приходили** после уже доставленного дайджеста.

Новая логика (v1.2.2): **orchestrator пушит progress events** в Agent Caller, который **сам решает** что показать пользователю.

**Точки emit'а в orchestrator:**

1. **Перед циклом attachments** — только если `count > 0`:
   ```
   POST /workflow-progress
   { step: "attachments_start", meta: { count: N } }
   ```

2. **Перед summary** — всегда (Agent Caller проверит порог):
   ```
   POST /workflow-progress
   { step: "summary_start", meta: { elapsed_ms: X } }
   ```

3. **При завершении** (success / no_messages / failed / lock_held):
   ```
   POST /workflow-done
   { status: "delivered" | "no_messages" | "failed" | "lock_held" }
   ```

**Логика Agent Caller (server.js):**

```javascript
attachments_start + count >= 3   → "📚 Тут немало документов..."
summary_start    + elapsed_ms >= 60000 → "⏳ Почти готово, формирую обзор."
workflow-done    delivered/no_messages → clearUxTimers (cleanup)
workflow-done    lock_held              → "⏳ Уже обрабатываю предыдущий запрос"
                                          (НЕ очищает таймеры первого workflow)
```

**Архитектурный принцип:** **бизнес-логика в orchestrator, UX-логика в Agent Caller**. Пороги (count >= 3, elapsed >= 60000) можно менять без правки Go-кода — только в server.js.

### WhatsApp pre-alert поведение

**Только при `trigger="cron"`** и **только когда есть письма**.
- Кнопка (`trigger="button"`): пользователь уже в Telegram, WA-пинг избыточен → skip
- Cron + 0 писем: алертить не о чем → skip
- Cron + есть письма: WA-пинг + Telegram дайджест

Это соответствует **DEC-018 multi-channel notification**: push-уведомление имеет смысл только когда пользователь не ожидает результата.

### Защита от двойного клика

При нажатии кнопки во время уже идущего workflow:
1. Agent Caller отправляет POST /digest-now → orchestrator
2. Orchestrator пытается AcquireLock → 409 (первый workflow ещё держит lock)
3. Orchestrator возвращает `SkippedDueLock=true`, пушит `/workflow-done {status: "lock_held"}`
4. Agent Caller получает event → пишет пользователю «⏳ Уже обрабатываю предыдущий запрос»
5. **НЕ очищает UX-таймеры** — первый workflow продолжается, его прогресс-сообщения должны приходить

Это **корректное поведение** — пользователь получает понимание что система работает, без дублирования.

## Implementation Notes (16.05.2026)

### Этапы реализации

| Версия | Что добавлено | Дата | Объём |
|---|---|---|---|
| **v1.2** | Incremental workflow + state-service + lock защита + /state/activate endpoint | 16.05.2026 утро | +250 строк production, +204 строк тестов |
| **v1.2.1** | NotifyDone push-уведомление о завершении workflow (Agent Caller отменяет таймеры) | 16.05.2026 день | +96 строк (notify.go) |
| **v1.2.2** | WorkflowProgress events для синхронизированного UX | 16.05.2026 вечер | +59 строк (расширение notify.go) + 130 строк патча Agent Caller |

### Canary deployment

Перед каждой версией — отдельный canary orchestrator на :8779 + state-service-canary на :8771 (Redis DB=1). 5 smoke-сценариев на изолированном state:

1. Первый запуск (state пустой) → fallback 24h, дайджест приходит
2. Второй запуск через 4 минуты → incremental period «за последние 3 минуты»
3. Двойной клик → один дайджест, lock защищает
4. trigger=cron → WA pre-alert + Telegram
5. /state/activate записывает last_at для нового пользователя

После всех 5 кейсов → switchover canary → production. Бэкап v1.1/v1.2 в `/opt/mail-stack/orchestrator.bak.v1.X.YYYYMMDD-HHMM`. Rollback за 30 секунд.

### Контракт API

**Orchestrator endpoints:**

```
POST /digest-now
  body: { chat_id?: string, trigger?: "cron"|"button", force_refresh?: bool }
  ⚠️ period_hours игнорируется (DEPRECATED v1.2) — период вычисляется из state

POST /state/activate
  body: { chat_id: string }
  Записывает last_at = now() для chat_id (используется при установке кнопки)
```

**State-service endpoints:** см. DEC-021.

**Agent Caller endpoints (v1.2.2):**

```
POST /workflow-progress
  body: { chat_id, trace_id, step, meta }
  Decides what (if anything) to show пользователю

POST /workflow-done
  body: { chat_id, trace_id, status }
  Cleanup timers / show lock_held message
```

### Контракт mail-service не менялся

Уже принимал `YYYY-MM-DDTHH:MM` precision (breaking change v1.0 от DEC-014). orchestrator v1.2 использует ту же точность для `since` параметра.

### Защита всех return-точек через defer-pattern

В workflow.Run() **8 точек выхода** (return) — including error paths (invalid chat_id, fetch_mail fail, summary fail, etc). Все покрыты:

```go
defer func() {
    // ReleaseLock (LIFO order — выполняется первым)
}()

defer func() {
    // NotifyDone — выполняется вторым
    // Гарантирует что Agent Caller получит уведомление НА ЛЮБОМ return,
    // включая panic. Status выставляется ПЕРЕМЕННОЙ notifyStatus
    // которая мутируется по ходу workflow.
}()
```

Это **критично** — забыть про NotifyDone на error path = Agent Caller не отменит UX-таймеры → пользователь получит «📚 разбираюсь» после ошибки.

### Тесты

После v1.2.2: **23 юнит-теста активити + 4 теста workflow helpers = 27 PASS**. Все прошли на coo перед canary deployment.

## Consequences

**Плюсы:**

- ✅ **Релевантный контент** — пользователь видит только новое с прошлого обзора
- ✅ **Защита от спама** — двойной клик не создаёт дублей
- ✅ **Адекватный UX** — прогресс-сообщения только когда реально долго работаем
- ✅ **Multi-tenant ready** — state per chat_id (DEC-021)
- ✅ **Архитектурный принцип event-driven подтверждён** — не таймеры, не polling, push

**Минусы:**

- ❌ **Усложнение workflow** — было ~210 строк, стало ~460 (но 80% logic переиспользуется на v2 Temporal)
- ❌ **+1 зависимость** — state-service. Падение state-service блокирует workflow.
- ❌ **Сложнее тестирование** — нужен canary с изолированным Redis DB

**Открытые вопросы:**

- На v2 (Temporal) — incremental logic переедет в Temporal Workflow с встроенным state (state-service может стать unused).
- При multi-tenant — нужен **per-tenant** fallback period (сейчас глобальный FALLBACK_PERIOD_HOURS).
- **Параллелизм обработки вложений** (v1.3) — отложен до реальной нагрузки 25 МБ PDF. См. DEC-014 Roadmap.
- **Kafka/NATS event bus** — рассматривается на DEC-023 при появлении конкретных pub/sub паттернов в compliance workflow. Текущий HTTP push достаточен для 1-to-1 общения.

## Связанные ADR

- **DEC-014** — Orchestrator архитектура (incremental workflow реализован в v1.2)
- **DEC-021** — State-service (новый микросервис для last_at + lock)
- **DEC-022** — Mail-stack as platform (state-service не часть mail-stack, отдельный orchestration tool)
- **DEC-024** — Mail-stack v1.1 production fixes (mail-service контракт YYYY-MM-DDTHH:MM)
