# DEC-021 — State-service: отдельный микросервис для incremental workflow

## Status

Accepted (16.05.2026). **Implemented 16.05.2026 (~3 часа кода + canary тестирование)**. Production v1.0 на coo:8770 (Redis DB=0), canary на :8771 (Redis DB=1).

## Context

После реализации DEC-013 «Mail Check On-Demand» (тоже Implemented 16.05.2026) workflow перестал быть stateless. Появилась потребность:

1. **Запоминать timestamp последнего успешного дайджеста** для chat_id (incremental period — «с момента предыдущего обзора»)
2. **Защищаться от двойного клика** на кнопку «Проверить почту» (lock-pattern с TTL)
3. **Активировать новых пользователей** (запись `last_at=now()` при установке кнопки)

В DEC-014 на v1 orchestrator был спроектирован как stateless. State планировался на v2 (Temporal). Но **триггер сработал раньше**: реальный UX потребовал incremental workflow прямо в v1.

**Архитектурное решение из DEC-014**: «State-service как отдельный микросервис на v2 (DEC-021). На v1 orchestrator — stateless.» — реализовано **на v1.2 раньше графика** по факту требований.

## Decision

Создать **state-service** как отдельный Go-микросервис на coo:8770, использующий Redis в качестве hot-storage (память по канону, DEC-014).

### Альтернативы (рассмотрены и отвергнуты)

**1. State внутри orchestrator (in-memory).**
- Плюсы: проще, нет дополнительного сервиса
- Минусы:
  - Теряется при рестарте orchestrator → workflow начинается с fallback
  - При горизонтальном масштабировании (несколько orchestrator instances) state расходится
  - Нет lock-pattern для защиты от двойного клика (race condition между goroutines одного процесса)
- **Отвергнуто.** Не масштабируется на multi-tenant.

**2. State в Postgres.**
- Плюсы: durability, integrated audit log
- Минусы:
  - Latency 5-15ms vs Redis 0.1-1ms — критично для frequent reads (lock checks)
  - Overkill для hot state с TTL (Postgres плохо подходит для expiry-driven ключей)
  - Postgres ещё не развёрнут на coo
- **Отвергнуто.** Hot path = Redis. Postgres на warm path (DEC-014 канон).

**3. State в Agent Caller (Node.js).**
- Плюсы: близко к источнику события (кнопка)
- Минусы:
  - Agent Caller — транспортный слой, не должен хранить бизнес-state
  - In-memory state теряется при рестарте Node.js процесса
  - Нарушение разделения ответственности: Agent Caller отвечает за каналы доставки, state — это orchestration concern
- **Отвергнуто.** State это домен orchestrator'a.

**4. State в существующем сервисе mail-stack (например, mail-service).**
- Плюсы: меньше сервисов в стеке
- Минусы:
  - Mail-stack — это AI/ML tools layer (DEC-022). State — orchestration concern, не tool concern.
  - Нарушает принцип «mail-stack as reusable tool platform» — state per chat_id привязан к workflow Compliance Assistant, не к универсальному mail-tool.
- **Отвергнуто.** State в отдельном микросервисе для чистоты архитектуры.

### Решение — отдельный Go-микросервис

**Стек:**
- **Go 1.22** (тот же что orchestrator — code reuse, не три языка для близких компонент)
- **go-redis/v9** для Redis client
- **chi/v5** для HTTP routing (легче чем gin, fits в state-service scope)
- **caarlos0/env/v10** для env-конфига (единый стиль с orchestrator)
- **stretchr/testify** для тестов

**Решение по типу storage — Redis:**
- 11 МБ RAM суммарно (Redis + state-service)
- Maxmemory 100mb с allkeys-lru policy
- Bind 127.0.0.1 (localhost only)
- Persistence: AOF every-sec (компромисс между durability и latency)

**Структура ключей:**
```
state:{chat_id}:last_at   — persistent, timestamp в RFC3339 UTC
state:{chat_id}:lock      — с TTL (default 300 сек), сам себя удаляет
```

**API endpoints:**
```
GET    /state/{chat_id}/last_at    → { chat_id, last_at }      | 404 если нет
POST   /state/{chat_id}/last_at    body: { timestamp?: string } → ok | 401 без auth
POST   /state/{chat_id}/lock       body: { ttl_seconds?: int } → ok | 409 если занят
DELETE /state/{chat_id}/lock                                    → ok | 200 даже если нет
GET    /state/{chat_id}/status                                  → { last_at, locked, lock_ttl_seconds? }
GET    /health                                                  → { status: "ok" } (без auth)
```

**Auth:** X-API-Key header (как в orchestrator, DEC-017 Уровень 0). Constant-time comparison.

**Изоляция через Redis DB:**
- Production: Redis DB=0
- Canary: Redis DB=1 (для DEC-013 deployment паттерна)

Это позволяет запускать canary-orchestrator параллельно с production без пересечения state.

## Implementation Notes (16.05.2026, v1.0)

### Объём кода

```
state-service/
├── cmd/state-service/main.go    — entry point, ~90 строк
├── server/                       — HTTP handlers, ~270 строк
├── storage/                      — Redis client wrapper, ~140 строк
├── config/                       — env-конфиг, ~60 строк
├── auth/                         — X-API-Key middleware, ~30 строк
└── logging/                      — structured logs, ~20 строк
                              Итого: 579 строк production
                                     438 строк тестов (23 unit + 19 smoke кейсов)
                                     Бинарник 5.6 МБ
                                     RAM 5.9 МБ при работе
```

### Lock semantics (важный нюанс)

Lock — это NOT mutex. Это **idempotent guard** с TTL:

- **AcquireLock** возвращает 200 OK если ключ создан, 409 Conflict если уже существует
- **ReleaseLock** идемпотентен — успешен даже если lock уже истёк по TTL
- **TTL обязателен** — защищает от deadlock'а если orchestrator упадёт между AcquireLock и ReleaseLock

Workflow orchestrator'a:
```
AcquireLock(ttl=300s)
  ↓ 409? → SkippedDueLock, exit (defer release НЕ зарегистрирован — lock первого не трогаем)
  ↓ 200 → продолжаем
defer ReleaseLock() — гарантированно вызовется на любом return (включая panic)
... workflow ...
return
```

Это **defer-pattern** — guarantee cleanup. Критично потому что в Go return-точек много (8 в workflow.Run), забыть про какую-то легко.

### Memory footprint

Redis (allocated): ~11 МБ при стандартной нагрузке (3-10 ключей)
State-service бинарь: ~6 МБ RAM при работе
**Итого:** ~17 МБ суммарно — минимальный overhead.

### Безопасность по DEC-017 Уровень 0

- ✅ X-API-Key header на всех POST/DELETE/GET кроме /health
- ✅ Constant-time comparison через crypto/subtle
- ✅ Bind 127.0.0.1 (no external access)
- ✅ chmod 600 /etc/mail-stack/state-service.env (API key, root:root)
- ✅ systemd hardening: NoNewPrivileges, ProtectSystem=strict, ProtectHome=true, PrivateTmp=true

### Архитектурный принцип подтверждён

**State-service — это infrastructure-tool, не business-logic.** Знает только про:
- chat_id (произвольный int64)
- timestamp
- lock с TTL

**НЕ знает** про:
- mail-stack
- workflow types
- бизнес-смысл «дайджеста»

Это позволит **переиспользовать** state-service на v2 (Compliance Logic Layer, DEC-023) — он может хранить state любых workflow, не только email_digest.

## Consequences

**Плюсы:**

- ✅ **Incremental workflow** — пользователь видит «с момента предыдущего обзора» вместо «за последние 24 часа»
- ✅ **Lock защита** от двойного клика без race conditions
- ✅ **Multi-tenant ready** — state per chat_id означает что N клиентов изолированы автоматически
- ✅ **Переиспользуемый** для будущих workflow (DEC-023 Compliance Logic Layer)
- ✅ **Canary deployment** через Redis DB=1 без отдельной инфраструктуры
- ✅ **Минимальный overhead** — ~17 МБ RAM, ~0.1ms latency

**Минусы:**

- ❌ **+1 микросервис** в стеке — теперь 8 сервисов на coo вместо 7
- ❌ **Зависимость** orchestrator → state-service → Redis. Падение state-service блокирует workflow.
  - Митигация: short timeouts, health checks, automatic systemd restart
- ❌ **Redis нужно мониторить** — maxmemory, AOF size, replication lag (на multi-instance в будущем)

**Открытые вопросы:**

- На v2 (Temporal) — заменится встроенным state Temporal Workflow Execution. State-service может стать unused.
- На v3 (KAMF) — KAMF имеет свой StateGraph storage. State-service интегрируется через адаптер.

## Roadmap

| Версия | Что | Триггер |
|---|---|---|
| **v1.0** ✅ | last_at + lock + X-API-Key | **Implemented 16.05.2026** |
| **v1.1** | Метрики Prometheus per endpoint | 2-й потребитель |
| **v1.2** | Backup в Postgres (warm path) для audit log | DEC-024 Observability |
| **v2.0** | Temporal Workflow State адаптер | DEC-014 v2 миграция |
| **v3.0** | KAMF StateGraph storage интеграция | DEC-014 v3 миграция |
