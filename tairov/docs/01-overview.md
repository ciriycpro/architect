# Tairov Compliance Helper

Автоматизация документооборота ИП Таирова на сервере coo: приём документов по email/Drive → распознавание → запись в реестр Google Sheets → алерты по 3 типам проблем (отсутствие договора, только драфт, просрочка) в Telegram/WhatsApp/Email.

## Service Blueprint реальности (на 09.05.2026)

### Что работает в продакшене

- **Agent Caller** (`/home/iakshin77/agent-caller/`, Node.js, systemd, coo:3000). Транспорт алертов в три канала: Telegram (бот @CallerBaby666Bot), WhatsApp (whatsapp-web.js, аккаунт `+79266143959`), Email (SMTP). Аптайм с 27.04.2026 непрерывно.

### Что работает в режиме полу-заглушки

- **Polygon** (N8N workflow id `1632604d64e14e20`, 14 нод, active=1). Принимает письма по IMAP с ящика `5458508@mail.ru`, раскладывает вложения по папкам отправителей в Google Drive, ведёт два листа в Sheets: «Контакты» и «Лог писем». Работает нестабильно — часть писем теряется в IMAP-ноде N8N, часть пишется в Sheets, часть нет. Не предназначен для production-нагрузки. Ждёт замены mail-service'ом.

### Что есть как working code, но не в продакшене

- **mail-service v1** (`/opt/mail-stack/mail-service/`, Python 3.10 + FastAPI). Endpoint `GET /mail/since/<YYYY-MM-DD>` отдаёт массив писем с корректным парсингом MIME, кириллицы, ФИО, ISO-дат, имён вложений. Без скачивания вложений, без OCR, без саммари. Реализован 03.05.2026, успешно протестирован end-to-end. На 09.05.2026 не оформлен в systemd, не докеризован, запускается только foreground для проверок. Решение по форме развёртывания — открытая развилка (см. DEC-006).

### Что описано в плане, но не реализовано

- **N8N Документовед v2** (12 нод по DEC-004). OCR+LLM extract+Switch по 5 типам документов. Не собрано ни одной ноды.
- **N8N Контроллер**. Schedule + сверка по ИНН → проблемы no_contract / draft_only / expired → триггер Caller. Не существует ни в каком виде — ни workflow в N8N, ни cron-задание, ни самостоятельный сервис.
- **Стек микросервисов `mail-stack/`** в полном объёме: `attachment-service` (скачивание вложений по messageId+filename), `ocr-service` (PDF/DOCX/JPG → текст через pdfplumber/mammoth/Tesseract или Cloudflare AI), `summary-service` (LLM-саммари через OpenRouter), `classifier-service` (тип документа), `state-service` (SQLite, дедупликация по messageId).

### Артефакты в БД, не используются

- **Inactive `Документовед`** (id `2b0af1a8c92c424f`, 39 нод, active=0). Реализация отменённого DEC-003 (5-ступенчатый OCR-каскад, 5 разных Sheets, IF не подписан внутри). Сохранён до выхода mail-service в прод, затем дамп и удаление.

### Вне-проектные артефакты

- **`Telegram Photo to Google Drive`** (N8N workflow id `pvsSCtB0CCpZl50W`, 11 нод, active=1). Telegram-бот фотобудка. Первая успешная сборка владельца в N8N (27.04.2026). К Compliance Helper не относится. Может быть вынесен в отдельный workspace.

## Внешние системы

- **mail.ru SMTP/IMAP** — почтовый сервер `5458508@mail.ru`, основной канал входящих документов от Таирова и контрагентов.
- **Google Workspace** — Drive (файловое хранилище, папка `1reHuOVUYwz4OfoX80xzr4nk2kfZ9x1lL` для документов Таирова) + Sheets (реестр, файл `база_документов_таиров`, id `13SMWzIiwDVRc1eYKJcGm1a-R__7Hbc1hvChTXvZhfsg`).
- **OpenRouter API** — LLM провайдер для OCR (Qwen3-VL) и извлечения структурированных полей (DeepSeek V3) — будет использоваться при реализации Документоведа v2.
- **Telegram + WhatsApp + Email** — каналы доставки алертов.

## Ключевые архитектурные решения

См. полный список в `decisions/`. Краткая сводка:

- [DEC-001](../decisions/0001-n8n-platform.md): N8N как платформа разработки агентов. Accepted.
- [DEC-002](../decisions/0002-imap-trigger.md): IMAP-триггер на 5458508@mail.ru. Superseded by DEC-005.
- [DEC-003](../decisions/0003-39-nodes-cancelled.md): Документовед на 39 нод. Cancelled, реализационный артефакт сохранён в БД.
- [DEC-004](../decisions/0004-simplify-to-12-nodes.md): Упрощение Документоведа до 12 нод. Accepted, не реализовано.
- [DEC-005](../decisions/0005-microservices.md): Mail-service как отдельный микросервис. Accepted, реализация на паузе на архитектурной развилке.
- [DEC-006](../decisions/0006-reality-check-09052026.md): Сверка с реальностью на 09.05.2026 + working principles N8N + открытая развилка по форме развёртывания `mail-stack/`.

## Контакты для оперативной работы

Для деталей по credentials, токенам, API-ключам, путям на coo, паролям — см. персональную память владельца, не репозиторий. Этот репозиторий публичный.
