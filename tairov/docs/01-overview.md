# Tairov Compliance Helper

Автоматизация документооборота ИП Таирова на сервере coo: приём документов по email/Drive → распознавание → запись в реестр Google Sheets → алерты по 3 типам проблем (отсутствие договора, только драфт, просрочка) в Telegram/WhatsApp/Email.

## Service Blueprint реальности (на 12.05.2026)

### Что работает в продакшене

- **Agent Caller** (`/home/iakshin77/agent-caller/`, Node.js, systemd, coo:3000). Транспорт алертов в три канала: Telegram (бот @CallerBaby666Bot), WhatsApp (whatsapp-web.js, аккаунт `+79266143959`), Email (SMTP). Аптайм с 27.04.2026 непрерывно.

- **Mail Service v1** (`/opt/mail-stack/mail-service/`, Python 3.11 + FastAPI, systemd, coo:8765). Endpoint `GET /mail/since/<YYYY-MM-DD>?limit=50` отдаёт массив писем с корректным парсингом MIME, кириллицы, ФИО, ISO-дат, имён вложений. Запущен в production-режиме 12.05.2026, RAM 39 МБ. Docker-friendly код, env-конфиг изолирован в `/etc/mail-stack/mail-service.env` (chmod 600 root:root). См. [DEC-007](../decisions/0007-deployment-form.md). Параллельно собран Docker-образ `mail-service:test` как артефакт для будущего переключения на контейнеризацию.

### Что работает в режиме полу-заглушки

- **Polygon** (N8N workflow id `1632604d64e14e20`, 14 нод, active=1). Принимает письма по IMAP с ящика `5458508@mail.ru`, раскладывает вложения по папкам отправителей в Google Drive, ведёт два листа в Sheets: «Контакты» и «Лог писем». Работает нестабильно — часть писем теряется в IMAP-ноде N8N. **Будет деактивирован одновременно с активацией N8N Email Digest v1** (см. [DEC-010](../decisions/0010-n8n-email-digest-v1.md)).

### Что описано в плане, под реализацию следующими сессиями

Стек микросервисов `mail-stack/` — горизонтальная архитектура взамен монолитного Документоведа v2:

- **attachment-service** ([DEC-008](../decisions/0008-parser-stack.md)) — скачивание вложений по messageId+filename. ~50 строк FastAPI. coo:8766. По шаблону mail-service.
- **parser-service** ([DEC-008](../decisions/0008-parser-stack.md)) — детерминированный роутер по MIME + библиотечный стек L1-L14 (pdf-inspector, PyMuPDF, pdfplumber, mammoth, openpyxl, xlrd, python-pptx, beautifulsoup4) + LLM-vision fallback (Qwen3-VL primary, Qwen 2.5 VL fallback). coo:8767.
- **summary-service** ([DEC-009](../decisions/0009-summary-haiku.md)) — текстовое саммари массива писем через Claude Haiku 4.5 (через OpenRouter), fallback DeepSeek V3. coo:8768.
- **N8N Email Digest v1** ([DEC-010](../decisions/0010-n8n-email-digest-v1.md)) — оркестратор полной цепочки. Triggers: Schedule 09:00 MSK + Webhook /digest-now. Доставка результата в Google Sheets («Дайджест») + Telegram Таирову.

Документовед v2 (DEC-004, 12 нод) — **не реализуется**, заменяется горизонтальным стеком mail-stack.

### Что описано в плане, под реализацию позже

- **N8N Контроллер**. Schedule + сверка по ИНН → проблемы no_contract / draft_only / expired → триггер Caller. Не существует ни в каком виде. Будет переписан как `controller-service` Python после стабилизации mail-stack.
- **classifier-service** — тип документа (счёт/договор/акт/выписка/прочее). v2 направление, после набора статистики.
- **state-service** — SQLite, дедупликация по messageId, история обработки. v2 направление.

### Артефакты в БД, не используются

- **Inactive `Документовед`** (id `2b0af1a8c92c424f`, 39 нод, active=0). Реализация отменённого DEC-003 (5-ступенчатый OCR-каскад, 5 разных Sheets, IF не подписан внутри). Сохранён до стабилизации Email Digest v1, затем дамп в `tairov/workflows/archive/` и удаление.

### Вне-проектные артефакты

- **`Telegram Photo to Google Drive`** (N8N workflow id `pvsSCtB0CCpZl50W`, 11 нод, active=1). Telegram-бот фотобудка. Первая успешная сборка владельца в N8N (27.04.2026). К Compliance Helper не относится.

## Внешние системы

- **mail.ru SMTP/IMAP** — почтовый сервер `5458508@mail.ru`, основной канал входящих документов от Таирова и контрагентов.
- **Google Workspace** — Drive (файловое хранилище, папка `1reHuOVUYwz4OfoX80xzr4nk2kfZ9x1lL` для документов Таирова) + Sheets (реестр, файл `база_документов_таиров`, id `13SMWzIiwDVRc1eYKJcGm1a-R__7Hbc1hvChTXvZhfsg`).
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
- [DEC-008](../decisions/0008-parser-stack.md): Parser-service — библиотечный стек L1-L14 + LLM-vision Qwen-каскад. Accepted, реализация в плане.
- [DEC-009](../decisions/0009-summary-haiku.md): Summary-service на Claude Haiku 4.5. Accepted, реализация в плане.
- [DEC-010](../decisions/0010-n8n-email-digest-v1.md): N8N workflow Email Digest v1 — оркестратор полной цепочки mail-stack. Accepted, реализация в плане.

## Контакты для оперативной работы

Для деталей по credentials, токенам, API-ключам, путям на coo, паролям — см. персональную память владельца, не репозиторий. Этот репозиторий публичный.
