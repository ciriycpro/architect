# Tairov Compliance Assistant

Автоматизация документооборота ИП Таирова на сервере coo: приём документов по email/Drive → распознавание → запись в реестр Google Sheets → алерты по 3 типам проблем (отсутствие договора, только драфт, просрочка) в Telegram/WhatsApp/Email.

## Service Blueprint реальности (на 12.05.2026)

### Что работает в продакшене

- **Agent Caller** (`/home/iakshin77/agent-caller/`, Node.js, systemd, coo:3000). Транспорт алертов в три канала: Telegram (бот @CallerBaby666Bot), WhatsApp (whatsapp-web.js, аккаунт `+79266143959`), Email (SMTP). Аптайм с 27.04.2026 непрерывно.

- **Mail Service v1** (`/opt/mail-stack/mail-service/`, Python 3.11 + FastAPI, systemd, coo:8765). Endpoint `GET /mail/since/<YYYY-MM-DD>?limit=50` отдаёт массив писем с корректным парсингом MIME, кириллицы, ФИО, ISO-дат, имён вложений. Запущен в production-режиме 12.05.2026, RAM 39 МБ. Docker-friendly код, env-конфиг изолирован в `/etc/mail-stack/mail-service.env` (chmod 600 root:root). См. [DEC-007](../decisions/0007-deployment-form.md). Параллельно собран Docker-образ `mail-service:test` как артефакт для будущего переключения на контейнеризацию.

- **Attachment Service v1** (`/opt/mail-stack/attachment-service/`, Python 3.11 + FastAPI, systemd, coo:8766). Endpoint `POST /download` принимает `{messageId, filename}` → скачивает вложение из IMAP → сохраняет в `/var/lib/mail-stack/attachments/<messageId>/<filename>` → возвращает путь + sha256 + size + mime. Кэш через файловую систему: повторный запрос отдаётся из FS за ~30 мс без обращения к IMAP (ускорение ~130×). Запущен 12.05.2026 ночью, RAM 28 МБ. Smoke-тест прошёл на двух JPG-вложениях из иска Таирова. См. [DEC-011](../decisions/0011-attachment-service.md). Docker-образ `attachment-service:test` собран.

- **Parser Service v1** (`/opt/mail-stack/parser-service/`, Python 3.10 + FastAPI, systemd, coo:8767). Endpoint `POST /parse` принимает `{path: "/var/lib/mail-stack/attachments/.../file.ext"}` → детерминированный роутер по MIME (уровень A) + per-page роутинг внутри PDF (уровень B) → возвращает unified JSON с текстом, методом, форматом, стоимостью. Реализованы все 8 веток L1-L14: TXT, CSV, JSON, XML, HTML, DOCX, XLSX, PDF (с pdf-inspector классификацией + PyMuPDF/pdfplumber извлечением), JPG/PNG/PDF-скан (через Qwen3-VL 235B primary + Qwen 2.5 VL 72B fallback по OpenRouter). Запущен 13.05.2026 ночью, RAM 38 МБ idle / 86 МБ после первого PDF. Smoke-тест прошёл на 8 ветках. Стоимость L14: ~$0.001 за JPG, ~$0.0005-0.0015 за страницу PDF в Mixed-режиме. См. [DEC-008](../decisions/0008-parser-stack.md). Docker-образ `parser-service:test` собран.

- **Summary Service v1** (`/opt/mail-stack/summary-service/`, Python 3.11 + FastAPI, systemd, coo:8768). Endpoint `POST /summary` принимает массив писем с распарсенными вложениями → возвращает JSON с двумя форматами: `summary_markdown` для Google Sheets + `summary_telegram` до 1000 символов для бота. Промпт v2 (живой разговорный тон, без канцелярита, с применением best practices индустрии: Anthropic XML-tags, few-shot example на реальных данных Таирова, action verbs, length constraints, plain terms). Primary: Claude Haiku 4.5 через OpenRouter. Fallback: DeepSeek-chat (alias OpenRouter на актуальную DeepSeek V3.1+). Запущен 13.05.2026 днём, RAM 30.6 МБ (рекорд стека — stateless transformer). Smoke-тест прошёл на 2 реальных письмах Контур.Экстерн от ФНС — Haiku сам пометил аномалию (5 минут между «решение о выездной проверке» и «приостановление»). Стоимость: ~$0.005 за дайджест на 2 письмах. См. [DEC-009](../decisions/0009-summary-haiku.md). Docker-образ `summary-service:test` собран.

- **Orchestrator v1.0** (`/opt/mail-stack/orchestrator/`, Go 1.22, systemd, coo:8769). Координатор полного workflow mail-stack. Endpoints: `POST /digest-now` (с X-API-Key auth + rate limit token bucket), `POST /check-mail` (заглушка для DEC-013 на v2), `GET /health` (без auth), `GET /metrics` (Prometheus format). Структура: `activities/` (HTTP-клиенты к 4 микросервисам + Telegram + WhatsApp, переиспользуется на 80%+ на v2/v3) + `workflow/` (оркестрация цепочки, переписывается под Temporal/KAMF). Structured logs (slog JSON) с trace_id (UUID v7), пробрасывается через весь стек. Запущен 13.05.2026 15:57, ~1100 строк production-Go + 380 строк тестов (13 тестов, все PASS), бинарник 8.6 МБ статичный, RAM 10 МБ (минимум стека). Workflow полная цепочка: **12 секунд** без WA / **93 секунды** с WA pre-alert. Реализация заняла **45-50 минут** vs планировавшихся 3 часа (4× быстрее благодаря отлаженной связке ADR → код → smoke). См. [DEC-014](../decisions/0014-orchestrator-go-temporal-kamf.md).

- **Multi-channel notification: WhatsApp pre-alert + Telegram content delivery**. Двухканальный паттерн: WA-уведомление "Привет, открой Telegram, я подготовил обзор" + Telegram-дайджест с полным контентом. Через Agent Caller (Node.js + whatsapp-web.js + Telegram Bot API). UX 24/7 — Таиров видит push в WhatsApp (primary мессенджер), читает контент в Telegram. На v1.0 sequential delay 80 сек на WA из-за hard limit whatsapp-web.js destroy timing (зафиксировано в DEC-018), на v1.3 — parallel goroutine. См. [DEC-018](../decisions/0018-multi-channel-notification.md).

### Что работает в режиме полу-заглушки

- **Polygon** (N8N workflow id `1632604d64e14e20`, 14 нод, active=1). Принимает письма по IMAP с ящика `5458508@mail.ru`, раскладывает вложения по папкам отправителей в Google Drive, ведёт два листа в Sheets: «Контакты» и «Лог писем». Работает нестабильно — часть писем теряется в IMAP-ноде N8N. **Будет деактивирован после запуска cron-расписания на Orchestrator v1.0** (Orchestrator уже работает, расписание включится после демо Таирову вечером 13.05.2026).

### Что описано в плане, под реализацию следующими сессиями

Стек микросервисов `mail-stack/` — горизонтальная архитектура взамен монолитного Документоведа v2 — **полностью реализован на v1.0 и v1.1**.

**v1.1 (13.05.2026, вечер) — Implemented:**
- **Telegram-кнопка «🔍 Проверить почту»** в @CallerBaby666Bot. Reply keyboard (persistent внизу чата). Нажатие → `POST /digest-now` orchestrator → workflow → Telegram дайджест в том же чате. Активирована у Артёма (chat_id 249979054). Реализация через Agent Caller (Node.js): polling: true, обработчик `tg.on('message')` ловит текст кнопки, endpoint `/tg/setup-button` для активации у пользователя.
- **Product-grade WA-skip разделение**: cron-расписание получает WA pre-alert + Telegram, on-demand (кнопка) — только Telegram. Реализовано через `RunParams.SkipWAAlert bool` в orchestrator workflow. Принцип: push-уведомление имеет смысл когда пользователь не ждёт результат.
- **Multi-mailbox в mail-service**: env-конфиг `MAILBOXES_JSON` со списком ящиков, backward compatibility сохранена. 3 ящика Артёма работают (artem-mailru, artem-gmail, artem-icloud). Каждое письмо помечено `mailbox_label`/`mailbox_user` для трассировки. Контракт API не сломан.
- **WhatsApp destroy timing fix**: 10 сек → 60 сек после `wa.sendMessage()` (10 сек = silent fail без exception).

Дальнейшее развитие:

- **Orchestrator v1.2** — Google Sheets append через Apps Script для истории дайджестов и аналитики. На этой неделе.
- **Orchestrator v1.3** — WhatsApp pre-alert в parallel goroutine (не блокирует Telegram-доставку) + MAX мессенджер. По росту нагрузки.
- **Orchestrator v2.0** — DEC-013 Mail Check On-Demand + state-service Redis (hot) + Postgres (warm). Триггер: первое требование regulatory или 50+ клиентов.

Документовед v2 (DEC-004, 12 нод) — **не реализуется**, заменяется горизонтальным стеком mail-stack.

### Что описано в плане, под реализацию позже

- **N8N Контроллер**. Schedule + сверка по ИНН → проблемы no_contract / draft_only / expired → триггер Caller. Не существует ни в каком виде. Будет переписан как `controller-service` Python после стабилизации mail-stack.
- **classifier-service / pre-filter перед parser** ([открытый вопрос в DEC-008](../decisions/0008-parser-stack.md)). Сейчас каждое письмо с вложением → parser → потенциально LLM-vision (0.5-1.5 руб за Mixed PDF). Спам-рассылки с PDF-вложениями (от newsletter@, marketing@) попадают в дорогой парсер. Стандарт индустрии 2024-2025 — двухстадийный фильтр: дешёвые правила (whitelist отправителей, blacklist newsletter-доменов, mail.ru X-Spam header, regex по subject) отсекают 80-95% трафика до parser-service. Заслуживает отдельного ADR на v2 (предполагаемый DEC-012).
- **Mail Check On-Demand workflow** ([открытый вопрос в DEC-014](../decisions/0014-orchestrator-go-temporal-kamf.md)). Telegram-кнопка «Проверить почту» в @CallerBaby666Bot → ad-hoc проверка с момента последнего обращения. Требует `state-service` для tracking `last_check_timestamp`. Второй workflow в Orchestrator v1 (в дополнение к ежедневному Email Digest). Mail-stack переиспользуется без изменений — отличается только промпт summary. Заслуживает отдельного ADR на v2 (предполагаемый DEC-013).
- **state-service** — SQLite, дедупликация по messageId, история обработки, tracking `last_check` per-user для on-demand режима. v2 направление.

### Артефакты в БД, не используются

- **Inactive `Документовед`** (id `2b0af1a8c92c424f`, 39 нод, active=0). Реализация отменённого DEC-003 (5-ступенчатый OCR-каскад, 5 разных Sheets, IF не подписан внутри). Сохранён до стабилизации Email Digest v1, затем дамп в `tairov/workflows/archive/` и удаление.

### Вне-проектные артефакты

- **`Telegram Photo to Google Drive`** (N8N workflow id `pvsSCtB0CCpZl50W`, 11 нод, active=1). Telegram-бот фотобудка. Первая успешная сборка владельца в N8N (27.04.2026). К Compliance Assistant не относится.

## Внешние системы

- **mail.ru SMTP/IMAP** — почтовый сервер `5458508@mail.ru`, основной канал входящих документов от Таирова и контрагентов.
- **Google Workspace** — Drive (файловое хранилище, папка `1reHuOVUYwz4OfoX80xzr4nk2kfZ9x1lL` для документов Таирова) + Sheets (реестр, файл `document_registry`, id `13SMWzIiwDVRc1eYKJcGm1a-R__7Hbc1hvChTXvZhfsg`).
- **OpenRouter API** — LLM провайдер: Qwen3-VL 235B + Qwen 2.5 VL 72B (vision для JPG/PDF-сканов в parser-service), Claude Haiku 4.5 + DeepSeek V3 (саммари в summary-service).
- **Telegram + WhatsApp + Email** — каналы доставки алертов.

## Ключевые архитектурные решения

См. полный список в `decisions/`. Краткая сводка:

- [DEC-001](../decisions/0001-n8n-platform.md): N8N как платформа разработки агентов. Accepted.
- [DEC-002](../decisions/0002-imap-trigger.md): IMAP-триггер на 5458508@mail.ru. Superseded by DEC-005.
- [DEC-003](../decisions/0003-39-nodes-cancelled.md): Документовед на 39 нод. Cancelled, реализационный артефакт сохранён в БД.
- [DEC-004](../decisions/0004-simplify-to-12-nodes.md): Упрощение Документоведа до 12 нод. **Superseded by DEC-008.**
- [DEC-005](../decisions/0005-microservices.md): Mail-service как отдельный микросервис. Accepted, реализация v1 закрыта 12.05.2026.
- [DEC-006](../decisions/0006-reality-check-09052026.md): Сверка с реальностью на 09.05.2026 + working principles N8N.
- [DEC-007](../decisions/0007-deployment-form.md): Форма развёртывания mail-stack — docker-friendly код + systemd v1. Accepted, валидировано фактом 12.05.2026.
- [DEC-008](../decisions/0008-parser-stack.md): Parser-service — библиотечный стек L1-L14 + LLM-vision Qwen-каскад. **Implemented 13.05.2026**, в production через systemd, RAM 38-86 МБ. Все 8 веток L1-L14 проверены smoke-тестом.
- [DEC-009](../decisions/0009-summary-haiku.md): Summary-service на Claude Haiku 4.5 + DeepSeek-chat fallback. **Implemented 13.05.2026**, в production через systemd, RAM 30.6 МБ. Промпт v2 с живым разговорным тоном (best practices индустрии). Smoke-тест прошёл на реальных данных Таирова.
- [DEC-010](../decisions/0010-n8n-email-digest-v1.md): N8N workflow Email Digest v1 — оркестратор полной цепочки mail-stack. **Superseded by [DEC-014](../decisions/0014-orchestrator-go-temporal-kamf.md)** 13.05.2026. Архитектурное решение пересмотрено в пользу Go custom orchestrator с трёх-шаговой эволюцией на Temporal headless v2 → KAMF v3. N8N остаётся только в Polygon (под деактивацию).
- [DEC-014](../decisions/0014-orchestrator-go-temporal-kamf.md): Orchestrator — Go custom v1 → Temporal headless v2 → KAMF v3 (трёх-шаговая эволюция). **Implemented v1.0 + v1.1 on 13.05.2026** в production через systemd. v1.0: ~1100 строк Go + 380 строк тестов, RAM 10 МБ, workflow 12 сек / 93 сек с WA, реализация за 45-50 минут. v1.1: Telegram-кнопка через Agent Caller callback + Multi-mailbox (3 ящика Артёма) + product-grade WA-skip для on-demand. Активities переиспользуются на 80%+ через все три runtime.
- [DEC-011](../decisions/0011-attachment-service.md): Attachment-service — контракт возврата пути к файлу + кэш через FS + TTL 7 дней + лимит 25 МБ. **Implemented 12.05.2026**, в production через systemd, RAM 28 МБ.
- [DEC-016](../decisions/0016-kubernetes-manifests.md): Kubernetes-friendly deployment manifests как production-grade артефакты. Accepted, реализация после DEC-014 (оркестратор). 17 файлов YAML, тестируются на minikube. Включает все принципы DEC-017 Уровень 0 (runAsNonRoot, NetworkPolicy, resource limits, Secrets API).
- [DEC-017](../decisions/0017-secure-by-design.md): Secure by Design roadmap по 4 уровням. Accepted, реализация поэтапно. Уровень 0 (input validation, rate limit, CORS) — встраивается в каждый новый кирпич начиная с DEC-014. Уровни 1-3 — на горизонте недель. Перед вторым клиентом — обязательно весь Уровень 3 (152-ФЗ compliance, PenTest, threat model).
- [DEC-018](../decisions/0018-multi-channel-notification.md): Multi-channel notification — WhatsApp pre-alert + Telegram content delivery. **Implemented 13.05.2026** в Orchestrator v1.0; в v1.1 уточнено разделение поведения (cron → WA + Telegram; on-demand кнопка → только Telegram через флаг SkipWAAlert). Архитектурный паттерн «push на одном канале, контент на другом» для UX 24/7. Trade-off на v1.0: 80 секунд sequential delay из-за whatsapp-web.js destroy timing — на v1.3 parallel goroutine. На v3 — переход на WhatsApp Business API (платно, enterprise-grade).
- [DEC-022](../decisions/0022-mail-stack-as-platform.md): Mail-stack as reusable tool platform — **архитектурный roadmap**. Принят 13.05.2026. Принцип: mail-stack микросервисы (mail, attachment, parser, summary) — не «часть orchestrator'a», а domain-platform с переиспользуемыми инструментами. 5 направлений: стабилизация контрактов, observability per-tool, rate limit per-tool, auth per-tool, OpenAPI документация. Реализация **по триггерам** (2-й потребитель, breaking change, multi-tenant), не по календарю. Триггеры будущих ADR: DEC-023 (Compliance Logic), DEC-024 (Observability), DEC-025 (OpenAPI), DEC-026 (Multi-tenant), DEC-027 (MCP-server).

## Контакты для оперативной работы

Для деталей по credentials, токенам, API-ключам, путям на coo, паролям — см. персональную память владельца, не репозиторий. Этот репозиторий публичный.
