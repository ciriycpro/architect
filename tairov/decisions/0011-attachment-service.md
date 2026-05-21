# 11. Attachment-service: путь к файлу + кэш через файловую систему

Date: 2026-05-13

## Status

Accepted — **Implemented on 12.05.2026** (production via systemd, Memory 28 МБ, port 8766)

## Context

Attachment-service — второй кирпич стека `mail-stack/` после mail-service. Из [DEC-010](0010-n8n-email-digest-v1.md): «N8N Email Digest v1 → HTTP POST attachment-service/download → HTTP POST parser-service/parse». Сервис должен принимать `messageId + filename`, выкачивать вложение из IMAP, отдавать parser-service.

При проектировании контракта возникли три развилки:

1. **Формат возврата:** двоичный стрим в HTTP body vs временный файл с путём
2. **Кэширование:** скачивать каждый раз заново vs кэшировать на диск
3. **Лимит размера:** какой максимум закладывать

### Профиль использования

Из реальной выборки писем с вложениями (mail.ru `5458508@mail.ru`, период 01-12 мая):
- Преимущественно PDF (счета, договоры, требования из ФНС): ~50-500 КБ каждый
- JPG-фото документов с телефона (иск Таирова 03.05): ~2-5 МБ × 5 шт в одном письме
- Иногда DOCX (~100-200 КБ)
- XLSX/CSV редко (~100 КБ)

**Реалистичный максимум одного вложения** — сканированный многостраничный иск или фотоальбом из 10 кадров высокого разрешения. **Не больше 10-15 МБ в реальной практике.**

### Ограничение mail.ru

mail.ru SMTP/IMAP позволяет вложения до **25 МБ** (стандарт). Больше через эту почту физически не приходит.

### Стратегический горизонт: эволюция в агента

Из принципа [DEC-007](0007-deployment-form.md): сервисы стека эволюционируют в агенты при накоплении state, decision-making, autonomous retry. Контракт attachment-service должен быть **готов к этому**, не требовать архитектурной переделки на v2.

Конкретно — будущий attachment-agent захочет:
- Идемпотентность вызовов (ретраи без повторных IMAP-запросов)
- Persistent state (история скачиваний для аудита)
- Параллелизм (несколько consumers одного вложения)
- Дедупликацию (один документ от двух контрагентов = один файл на диске)

## Decision

### 1. Возврат: путь к файлу на диске, не двоичный стрим

`POST /download` сохраняет вложение в **постоянное хранилище** и возвращает путь + метаданные.

**Хранилище:** `/var/lib/mail-stack/attachments/<messageId>/<filename>`

Структура иерархическая — все вложения одного письма лежат в одном каталоге. Это даёт:
- Простую навигацию глазами при отладке
- Атомарность очистки (rm -rf одного каталога удаляет все вложения письма)
- Естественное группирование для будущего classifier-service (всё письмо как контекст)

**Контракт endpoint:**

```
POST /download
Content-Type: application/json

Request:
{
  "messageId": "69f656b3274d33c484154f92@mail.kontur.ru",
  "filename": "счёт.pdf"
}

Response (success):
{
  "path": "/var/lib/mail-stack/attachments/69f656b3274d33c484154f92@mail.kontur.ru/счёт.pdf",
  "size_bytes": 245678,
  "size_mb": 0.23,
  "sha256": "a3f5...",
  "mime": "application/pdf",
  "from_cache": false,
  "downloaded_at": "2026-05-13T09:15:23+00:00"
}

Response (size limit exceeded):
{
  "error": "attachment_too_large",
  "size_mb": 31.4,
  "limit_mb": 25
}

Response (not found):
{
  "error": "attachment_not_found",
  "messageId": "...",
  "filename": "...",
  "reason": "message exists but no part matches filename" | "message not found"
}
```

### 2. Кэш через файловую систему

Перед FETCH-запросом к mail.ru — проверка существования `/var/lib/mail-stack/attachments/<messageId>/<filename>`:
- **Файл есть** → возвращаем сразу с флагом `from_cache: true`. SHA256 проверяется на чтении (защита от повреждения)
- **Файла нет** → FETCH с IMAP, сохранение, возврат с `from_cache: false`

**Без отдельной БД таблицы кэша.** Файловая система = source of truth. Метаданные (sha256, size, downloaded_at) можно либо хранить в `.meta.json` рядом с файлом, либо считать на лету при каждом ответе (sha256 для 1 МБ — ~10 мс, не критично).

**На v1 — считаем на лету.** На v2 — рядом с файлом `.meta.json` для ускорения повторных вызовов.

### 3. TTL 7 дней + cleanup-cron

Вложения хранятся 7 дней с момента последнего обращения (atime, не ctime — это критично для активно используемых файлов).

**Cleanup-cron** `/etc/cron.daily/mail-stack-attachments-cleanup`:

```bash
#!/bin/bash
find /var/lib/mail-stack/attachments -type f -atime +7 -delete
find /var/lib/mail-stack/attachments -type d -empty -delete
```

Порядок важен: сначала удаляем старые файлы, потом пустые каталоги.

**Параметр TTL** в `/etc/mail-stack/attachment-service.env`:
```
ATTACHMENT_TTL_DAYS=7
ATTACHMENT_STORAGE_DIR=/var/lib/mail-stack/attachments
```

При желании TTL можно увеличить (для аудита) или уменьшить (для экономии диска) без правки кода.

### 4. Лимиты размера

| Уровень | Значение | Действие |
|---|---|---|
| **Hard limit** | 25 МБ | Отказ с `error: attachment_too_large` |
| **Soft warning** | 10 МБ | Скачивание выполняется, в логи INFO с пометкой `large_attachment` |

Hard limit = ограничение mail.ru, нет смысла поддерживать больше.
Soft warning нужен для **накопления статистики**: если в логах много `large_attachment` — значит коммерческая работа уходит в сторону тяжёлых документов, и в v2 надо подумать о chunked streaming.

### Технические детали реализации

**IMAP-логика** — переиспользуем из mail-service v1, ~80% кода уже написано:
- Подключение по `IMAP_HOST` / `IMAP_USER` / `IMAP_PASS` (через env)
- `UID SEARCH` по `messageId` (находит UID письма)
- `FETCH UID BODYSTRUCTURE` (узнаём структуру MIME)
- `FETCH UID BODY[N]` где `N` — индекс нужной части по `filename`
- Декодирование `Content-Transfer-Encoding` (base64 / quoted-printable)
- Декодирование имени части (если `=?utf-8?b?...?=`)

**FastAPI endpoints:**

```python
@app.post("/download")
async def download(req: DownloadRequest) -> DownloadResponse:
    ...

@app.get("/health")
def health():
    return {"status": "ok", "service": "attachment-service-v1"}
```

**Зависимости** (по образцу mail-service v1, тот же требник):
- fastapi
- uvicorn
- pydantic
- (стандартный `imaplib` для IMAP — не нужен в requirements.txt)

**Размещение по [DEC-007](0007-deployment-form.md):**
- Каталог: `/opt/mail-stack/attachment-service/`
- Env-файл: `/etc/mail-stack/attachment-service.env`
- Systemd-юнит: `/etc/systemd/system/attachment-service.service`
- Порт: **8766** (mail-service 8765, attachment 8766, parser 8767, summary 8768 — последовательная нумерация)

### Зачем именно так — обоснование «как для будущего агента»

| Архитектурный признак | Зачем агенту |
|---|---|
| Возврат пути, не байтов | Persistent state, повторное чтение, hash-based identity |
| Файл сохраняется при первом запросе | Каждое скачивание — атомарная операция, фиксированная во времени |
| Кэш встроен в FS | Idempotence: повторный вызов = no-op для IMAP, без отдельной БД |
| TTL через atime | Самоочистка без явного управления, файл «живёт» пока используется |
| sha256 в ответе | Дедупликация на уровне consumer (parser-service может проверять «уже парсил такой документ?») |
| Hard limit 25 МБ | Защита от resource exhaustion, граф вызовов предсказуем |
| Иерархия `<messageId>/<filename>` | Группирование, удобный аудит, простой grep по почтовому ящику |

Это **готовая модель данных для будущего agent-orchestration**, не требующая переделки. При переходе сервиса в агент-режим (например, добавится background-задача «follow-up на письма без ответа») — структура каталога и контракт endpoint остаются.

## Consequences

**Плюсы:**
- Идемпотентность из коробки (повторный вызов — не дёргает mail.ru)
- Простая отладка (файлы видны глазами, любой инструмент Unix их понимает)
- Естественный аудит (видно что было скачано, когда, какого размера)
- 90% кода переиспользуется из mail-service v1 (MIME-парсинг)
- Готовность к параллелизму (любой consumer может прочитать тот же файл)
- Cleanup автоматический (cron + atime, никакой ручной работы)
- 25 МБ — реалистичный максимум, не over-engineering

**Минусы:**
- Файлы на диске → нужно следить за свободным местом. Митигация: cleanup-cron + soft monitoring через `df -h` (можно добавить в healthcheck endpoint в v2)
- IMAP-сессия открывается на каждый запрос. Митигация v2: connection pool через `imapclient` библиотеку
- Нет защиты от race condition при параллельных запросах одного файла. Митигация: lockfile per messageId+filename. На v1 не критично — параллелизм маленький
- sha256 считается на лету → +10 мс на каждый ответ. Митигация v2: `.meta.json` рядом с файлом

**Открытые вопросы для v2:**
- Когда добавить connection pooling для IMAP — при росте до 50+ запросов/час
- Когда добавить `.meta.json` кэш метаданных — после первой жалобы на скорость повторных вызовов
- Когда вводить chunked streaming (для вложений > 25 МБ) — если mail.ru или другая почта начнёт принимать большие, ИЛИ при подключении других почтовых backend'ов (Gmail/IMAP с большими лимитами)
- Когда переходить на S3 для долгосрочного хранения вместо локального FS — при росте до 100+ ГБ совокупного объёма attachments

**Стратегический сигнал:** attachment-service в этой архитектуре — **универсальный коннектор почтовых вложений**, не привязанный к Compliance Assistant. Тот же контракт `POST /download` с messageId+filename переиспользуется в любом проекте `mail-stack/` или KAMF.

## Implementation Notes (12.05.2026)

Сервис реализован за один заход в ночь 12-13.05.2026 (примерно 1 час чистой работы) по полному контракту, без брака. Не v0-скелет, а сразу v1 в production.

### Что сделано

- **Код:** `/opt/mail-stack/attachment-service/server.py` (332 строки)
- **Хранилище:** `/var/lib/mail-stack/attachments/` создано, `iakshin77:iakshin77`, chmod 755
- **Зависимости:** те же 14 pinned пакетов что у mail-service (FastAPI 0.136.1, uvicorn 0.46.0, pydantic 2.13.4)
- **Dockerfile + .dockerignore:** по шаблону DEC-007, валидирован реальным запуском
- **Env-конфиг:** `/etc/mail-stack/attachment-service.env` chmod 600 root:root
- **Systemd-юнит:** `/etc/systemd/system/attachment-service.service` с UMask=0022
- **Docker-образ:** `attachment-service:test` собран как артефакт для будущего docker-compose

### Подтверждённое поведение

Smoke-тест прошёл на двух реальных вложениях из почты Таирова (письмо «Исковое решение суда к инспектуру инспектору» от 03.05.2026):

| Сценарий | Время | Результат |
|---|---|---|
| Cache miss → IMAP fetch (`Рисунок (31).jpg`, 456 КБ) | ~4 сек | `from_cache: false`, sha256=`a3b0f10…` |
| Cache hit (тот же файл) | ~30 мс | `from_cache: true`, **тот же sha256**, IMAP не дёрнут |
| Cache miss → IMAP fetch (`Рисунок (33).jpg`, 885 КБ) | ~2 сек | `from_cache: false`, sha256=`4a79f23…` |

Кэш ускорил повторный запрос в ~130 раз. IMAP-логика переиспользует MIME-парсинг mail-service v1 (decode_str для кириллицы, BODYSTRUCTURE для поиска части).

### Переиспользованный код mail-service

| Функция | Назначение |
|---|---|
| `decode_str()` | MIME-encoded строки (`=?utf-8?b?...?=`) |
| `imaplib.IMAP4_SSL` + login/select/search | IMAP-сессия (тот же паттерн с finally-logout) |

### Что не вошло в v1 (отложено на v2)

- `.meta.json` рядом с файлом для кэша метаданных (sha256 считается на лету, ~10 мс)
- Lockfile per messageId+filename для защиты от race condition при параллельных запросах одного файла
- Cleanup-cron `/etc/cron.daily/mail-stack-attachments-cleanup` — каркас в DEC-011 есть, не установлен (отложено до накопления данных на диске)
- Connection pooling для IMAP — на v1 каждый запрос открывает новую сессию

### Production-готовность

| Критерий | Статус |
|---|---|
| Systemd active + enabled | ✅ |
| Memory footprint | ✅ 27.9 МБ (меньше mail-service) |
| Restart=always + RestartSec=5 | ✅ переживёт reboot и panic |
| Логи в journalctl | ✅ |
| Healthcheck endpoint | ✅ возвращает конфиг для дебага |
| Env-конфиг изолирован | ✅ chmod 600 root:root |
| Path traversal защита | ✅ `safe_filename` + `safe_messageid_path` |
| Hard limit 25 МБ работает | ⚠️ не проверен на реальном кейсе (нет вложений > 25 МБ в почте) |
| Cleanup-cron | ❌ не установлен (v2) |
