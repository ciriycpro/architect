# DEC-018 — Multi-channel notification: WhatsApp pre-alert + Telegram content delivery

## Status

Accepted (13.05.2026). **Реализовано на v1.0 orchestrator** (13.05.2026, ~30 минут после основного workflow).

## Context

Email-дайджест без push-уведомления — это контент **который никто не видит вовремя**. Telegram у Таирова открывается **редко** (mobile background notification легко пропустить), WhatsApp — primary мессенджер (открыт 24/7).

Если дайджест приходит **только в Telegram**:
- Утренний дайджест в 9:00 → Таиров увидит в 14:00
- Срочные требования ФНС не попадают в фокус вовремя
- UX-эффект «бот работает» теряется — приходит будто из ниоткуда

**Архитектурный паттерн:** **push на одном канале, контент на другом**:
- **WhatsApp** — короткое уведомление «Привет, проверил почту, открой Telegram»
- **Telegram** — полноценный дайджест с разбором писем и вложений

Это **mirrors classic push-notification pattern** в мобильных приложениях: уведомление приходит в shell ОС, реальный контент — в приложении.

## Decision

Реализовать **двухканальную доставку результата workflow** в orchestrator v1.0:

```
[Workflow: email_digest]
   ↓
   ↓ summary готов
   ↓
1. ⚡ WhatsApp pre-alert (Agent Caller /send-wa)
   Текст: "👋 Привет! На почту пришли письма (N шт), 
           открой Telegram — я подготовил для тебя обзор."
   
2. 📨 Telegram content delivery (Agent Caller /send-tg)
   Текст: summary_telegram от summary-service (живой дайджест)
```

WhatsApp **обязательный pre-alert**, Telegram **обязательный канал контента**. Если WA-номер не задан в env (`WHATSAPP_NUMBER=""`) — pre-alert пропускается, только Telegram.

### Реализация

Activity `activities/whatsapp.go` в orchestrator:
```go
type WhatsAppActivity struct {
    BaseURL string  // http://127.0.0.1:3000 (Agent Caller)
    Timeout time.Duration  // 150 сек на v1.0 (cold Chrome startup + WA sync)
}

func (w *WhatsAppActivity) SendMessage(ctx context.Context, params SendWAParams, opts CallOptions) error
```

Через Agent Caller `/send-wa` (Node.js + `whatsapp-web.js`):
1. Запускает headless Chrome (~40 секунд cold start)
2. Авторизуется по сохранённой сессии в `.wwebjs_auth/`
3. Отправляет через `wa.sendMessage(...)`
4. **Ждёт 60 секунд** перед `wa.destroy()` (см. findings ниже)

### Альтернативы (рассмотрены и отвергнуты)

**1. Только Telegram.**
- Плюсы: простой стек, нет хрупкости WA-Web
- Минусы: пользователь не видит вовремя срочные требования. UX-проблема.
- **Отвергнуто.** Двухканальный подход даёт значительное UX-преимущество для b2b-комплаенс продукта.

**2. SMS вместо WhatsApp.**
- Плюсы: 100% доставка, не зависит от WA-Web
- Минусы: платно (~$0.05 за SMS), требует SMS-gateway аккаунт
- **Отложено на v3** при росте до 10+ клиентов и enterprise-tariff.

**3. WhatsApp Business API (Twilio/официальный).**
- Плюсы: enterprise-grade, не хрупкий
- Минусы: платно ($0.005-0.04 за сообщение), требует регистрацию бизнеса
- **Отложено на v3** для production enterprise scale.

**4. Push-уведомление в Telegram через bot button.**
- Плюсы: один канал, проще
- Минусы: всё равно требует Telegram быть открытым / уведомления настроены
- **Отвергнуто.** WhatsApp — primary мессенджер РФ-аудитории, лучше прорывается.

### Implementation v1.0 findings

В процессе реализации обнаружено **критичное поведение whatsapp-web.js**:

**Bug pattern (silent fail):**
```javascript
await wa.sendMessage(...);
console.log('WA → отправлено');           // ← логи говорят "ok"
await new Promise(r => setTimeout(r, 10000));  // ← 10 сек МАЛО
await wa.destroy();                         // ← убил Chrome до доставки
return { ok: true };                       // ← клиент думает что отправил
```

**Что происходит на самом деле:**
- WhatsApp Web возвращает success как только сообщение **поставлено в очередь** в Chrome
- Реальная **доставка на сервер WhatsApp** требует 30-60 секунд синхронизации
- Destroy Chrome до завершения синхронизации = silent fail
- Никаких exception, никаких ошибок в логах

**Fix:** `setTimeout(r, 60000)` после `wa.sendMessage()` — даёт WhatsApp время на синхронизацию.

**Trade-off:** workflow duration увеличивается с 12 до 93 секунд (8× медленнее) — приемлемо для v1.0 (1 workflow в день), на v1.3 нужно **parallel goroutine**.

## Roadmap эволюции multi-channel

| Версия | Что | Когда |
|---|---|---|
| **v1.0** ✅ | WA pre-alert (whatsapp-web.js через Agent Caller) + Telegram content | **Implemented 13.05.2026** |
| **v1.3** | WA pre-alert в parallel goroutine (не блокирует Telegram, асинхронно) | При первом росте до 5+ workflow/day |
| **v1.4** | MAX мессенджер как third channel (для аудитории с MAX) | По запросу клиентов |
| **v2.0** | Per-client choice какие каналы использовать (config) | Multi-tenant |
| **v3.0** | WhatsApp Business API (платный) вместо WA-Web | При компрометации/бане WA-Web аккаунта |
| **v3.0** | SMS gateway integration для критичных alerts | Enterprise-тариф |

## Consequences

**Плюсы:**

- ✅ **UX 24/7** — Таиров видит push вовремя даже если Telegram закрыт
- ✅ **B2B-сигнал** — двухканальная коммуникация выглядит как продакшен-grade
- ✅ **Архитектурный паттерн** — переиспользуется на v2.0 для multi-tenant (per-client каналы)
- ✅ **Бесплатно на v1** — whatsapp-web.js + Telegram Bot API без расходов на отправку

**Минусы:**

- ❌ **WA-Web хрупкий** — может потерять сессию, требует периодической переавторизации QR. Митигация: монитор + alert если WA fail 3 раза подряд (на v1.3).
- ❌ **80 секунд delay** в текущей реализации — приемлемо на 1 workflow/day, не приемлемо на росте. Митигация: parallel goroutine на v1.3.
- ❌ **Risk бана номера** WhatsApp за автоматизацию (низкий риск для 1 сообщения в день, но растёт с объёмом). Митигация: переход на WhatsApp Business API на v3.

**Открытые вопросы:**

- **WA-Web stability monitoring** — нужен health-check который реально проверяет доставку (не только Chrome ready). На v1.3.
- **WhatsApp Business API costing** — при 30 клиентах × 60 сообщений/мес × $0.01 = $18/мес. Дёшево. При 300 клиентах = $180/мес. На v3 переходим.
- **MAX мессенджер** — растущая audience в РФ, имеет API. Стоит ли инвестировать в integration сейчас или ждать? Триггер: если 20%+ потенциальных клиентов будут просить MAX.
- **Smart routing** — если у клиента **открыт Telegram** в момент дайджеста, WA pre-alert не нужен. Можем определять через Telegram Bot API last_seen? На v3.

**Стратегический сигнал:** Multi-channel notification — это **B2B-killer feature** для compliance-продукта в РФ. Регуляторные требования приходят неожиданно (ФНС, ГИТ, суды), пропустить дайджест = пропустить срок = штраф. **Двухканальная гарантия push** — это часть value proposition продукта, не «опциональная фича».
