# DEC-024: Mail-stack v1.1 production fixes — 14.05.2026

Status: Implemented
Date: 2026-05-14 (00:00-04:00 UTC)

## Context

Утром 13.05 кнопка «🔍 Проверить почту» в Telegram возвращала 502: summary-service получал 425k токенов на 19 писем + 5 attachments (Haiku ceiling 200k, DeepSeek 163.8k). Параллельно 7 из 12 запрошенных вложений падали на 404 в attachment-service (single-mailbox в проде, при том что mail-service уже работал на 3 ящика).

## Decomposition виновников 425k токенов

| Источник | Токены |
|---|---|
| Выписка Сбер.xlsx (1941 строка, openpyxl без лимита) | ~205k |
| NO_USN.pdf (4 страницы vision из-за штрихкодов/QR — false-positive OCR) | ~100k |
| 15 фоновых писем body | ~50-80k |
| zhaloba×2 + jpg | ~30-35k |

## Decisions & Implementation

### 1. Mixed PDF — text-first per-page routing

**Файл:** `/opt/mail-stack/parser-service/server.py` функция `parse_pdf_mixed_per_page` (стр.435)
**Бэкап:** `server.py.bak.20260514-mixed-text-first`

pdf_inspector стал hint, не приговор. На каждой странице сначала `page.get_text()`, vision-LLM только если результат < `MIN_EXTRACTED_TEXT_LEN`. Warning `pages_rescued_from_ocr:N` для диагностики.

**Результат на NO_USN.pdf:** ~100k → ~1.1k токенов (≈90× сокращение). 4 страницы из 4 «ocr» → 2 rescued via text-extraction + 1 уже text + 1 реально vision.

### 2. XLSX truncation

**Файл:** `/opt/mail-stack/parser-service/server.py` функция `parse_xlsx` (стр.85)
**Env:** `XLSX_ROW_HARD_LIMIT=200`, `XLSX_KEEP_FIRST=100`, `XLSX_KEEP_LAST=50` в `/etc/mail-stack/parser-service.env`

Если строк >200 → первые 100 + маркер `[ВЫРЕЗАНО N строк из середины]` + последние 50. Warning `xlsx_truncated:sheet=X:total=N`.

**Результат на Выписке Сбер:** 1941 строка → 250 строк → 42k chars → ~14k токенов (было 205k). 14.5× сокращение.

### 3. Краткий vision-промпт

**Файл:** `/etc/mail-stack/parser-service.env` переменная `LLM_VISION_PROMPT`
**Бэкап:** `parser-service.env.bak.20260514-vision-brief`

Заменён жадный промпт («извлеки весь текст, опиши оформление, печати, людей и обстановку») на краткий: тип/стороны/цифры/печать-подпись да-нет/особые отметки, максимум 200 слов.

**Результат на vision:**
- jpg Coca-Cola: 172 токена (было ~3-5k)
- jpg «В джазе только девушки»: 192 токена (было ~3-5k)
- 17-страничный реальный договор Чистоград (SCAN0253, 6.5 МБ): Haiku понял «договор уборки на 7 млн до октября, подписан, печати есть»

### 4. Multi-mailbox в attachment-service (parity с mail-service)

**Файл:** `/opt/mail-stack/attachment-service/server.py` (новая функция `_imap_find_message`, стр.180)
**Env:** `MAILBOXES_JSON` синхронизирован с mail-service (3 ящика)
**Бэкапы:** `server.py.bak.20260514-multibox-loop`, `attachment-service.env.bak.20260514-multibox`

Добавлено чтение `MAILBOXES_JSON` через `_json.loads()`. Новая helper-функция `_imap_find_message(message_id)` с loop по `_build_mailbox_configs()`, short-circuit на первом попадании, fallback к single-mailbox если MAILBOXES пуст. Функция `find_attachment_bytes` рефакторена: вместо хардкоженного SELECT — вызов `_imap_find_message`.

**Результат на Melzack-Wall.pdf (4.5 МБ):** было 404 (single mail.ru) → стало `[artem-gmail] Found message uid=1171` за ~19 сек, файл сохранён в `/var/lib/mail-stack/attachments/`.

### 5. UX-таймеры в agent-caller (Telegram-кнопка)

**Файл:** `/home/iakshin77/agent-caller/server.js` callback кнопки «🔍 Проверить почту» (стр.114)
**Бэкап:** `server.js.bak.20260514-ux-timers`

При нажатии кнопки бот шлёт промежуточные сообщения если workflow долгий:
- 0 сек: «🔄 Проверяю почту за сутки. Сейчас пришлю сводку.»
- 60 сек: «📚 Тут немало документов, разбираюсь. Подожди ещё пару минут.»
- 3 мин: «📑 Серьёзные сканы — читаю внимательно. Скоро вернусь.»
- 6 мин: «⏳ Почти готово, обрабатываю последние документы.»

Все таймеры гасятся на ошибке запуска orchestrator или через 11 минут (страховка от утечки).

## Tests — production smoke

### Тест 1 (00:18-00:21): кнопка на 21 письме за 24 часа

- messages=21, attachments=8 из 12 (4 в iCloud-письме не найдены)
- tokens_in=99 555 (vs 425k раньше) — снижение в 4.3 раза
- tokens_out=2 452, cost=$0.089
- duration=190 сек (3 мин 10 сек, из них ~90 сек WhatsApp Chrome)
- fallback_used=false, Haiku справился
- Telegram доставлен

### Тест 2 (00:45-00:54): реальные деловые сканы

5 деловых писем через gmail:
- Договор ООО Виктория (Scan20260420175837.pdf, 3.19 МБ) — 5 vision-вызовов ~40 сек
- Договор Чистоград (SCAN0253.pdf, 6.51 МБ) — 17 vision-вызовов ~3 минуты
- 2_5427100450224641495.pdf (1.05 МБ) — Mixed, быстро
- Доп.соглашение Монтажпроект (164 КБ) — Mixed, мгновенно
- Исковое решение к инспектору Николаеву — 5 JPG (Рисунок 31-36)

**Цифры:**
- messages=22, attachments=9 из 13 (4 iCloud — известный баг DEC-033)
- tokens_in=43 800 (компактнее теста 1, краткий vision-промпт работает на сканах идеально)
- tokens_out=2 244, cost=$0.044 (~3.5 руб)
- duration=557 сек (9 мин 17 сек)
- fallback_used=false
- Кэш в `/var/lib/mail-stack/attachments/`: 24 МБ в 27 файлах

**Дайджест в Telegram (Тест 2):**

«Привет, разобрал почту за период — есть срочное. ⚠️ ФНС и ООО "АСВИТС" (7717748392): решение о приостановке счётов. Контур.Экстерн требует квитанцию о получении не позднее 15 мая — надо срочно в Экстерн. ⚠️ По твоему ИП: Центральная ГИТ выдала предписание (инспектор Николаев). Ты подал иск в суд РД, и суд 27.04 приостановил исполнение предписания до рассмотрения дела — это хорошо. Можешь подать жалобу в Верховный Суд РД в течение 15 дней. 📎 Три договора в порядке: ООО "Виктория" (услуги, 6.3к руб.), ООО "ЧИСТОГРАД" (уборка, 7 млн руб., до октября), ООО "Монтажпроект" (демонтаж/уборка, 5.17к за смену). Все подписаны, печати есть. 📌 От Артемия 4 файла без пояснений — надо посмотреть. Google Security — 2 уведомления о пароле приложения. n8n — критические уязвимости. Главное — ФНС до 15 мая.»

Haiku корректно различил приоритеты, упомянул iCloud-пропуск («От Артемия 4 файла без пояснений»), вычислил суммы и контрагентов из 17-стр скана.

## Известный неисправленный баг

**iCloud SEARCH HEADER Message-ID возвращает пусто.** Письмо `1778699876.571271182@f523.i.mail.ru` с 4 вложениями (Форма_Заявление юр. лицо.docx, ИТБ_ОСНОВА.txt, ПФР_ЕФС-1.xml, payment-15.pdf) лежит в `armigroup@me.com` Входящие (подтверждено скриншотом iCloud Web). mail-service видит письмо (`mailbox_label=artem-icloud`, attachment_names=[4 файла]). attachment-service в multi-mailbox loop ходит во все 3 ящика, на iCloud `SEARCH HEADER Message-ID "..."` возвращает OK пусто без ошибки. Mail.ru и Gmail работают нормально. Это специфика Apple Mail IMAP.

Зафиксировано как DEC-033 (workaround: UID SEARCH вместо SEARCH, или передавать `imap_uid` в attachment-service через контракт — часть DEC-030).

## Архитектурные обсуждения (для следующих ADR)

### Two-product architecture: Mail Reader vs Compliance Helper

После анализа: комплаенс-помощник = ХАЙЛОАД by design (договоры/выписки/сканы 100-200 МБ/неделю на пике). Mail Reader (digest) и Compliance Helper — два разных продукта на одной mail-stack platform с разными SLA, моделями, форматами output.

- **Mail Reader:** Haiku, до 50k токенов, 1-2 мин, telegram-сводка. Краткий vision-промпт, xlsx-лимит, текущая цепочка mail→attachment→parser→summary.
- **Compliance Helper:** Sonnet/Opus + Qwen-VL глубокий, до 2M токенов, 5-30 мин, structured output + Drive/Sheets реестр + classify/extract/validate. Отдельный workflow `compliance_intake_v1`: event-driven, classify+extract+store+alert.

Развилка стала ясна когда обсуждали «крокодил vs тираннозавр» — сначала строим желудок (любое переваривает), потом кишечник (классификатор).

→ зафиксировать как **DEC-029**.

### Mail-service vs Attachment-service: переразметка контрактов

Текущая логика: mail-service отдаёт письма со всеми вложениями в metadata. Orchestrator идёт за вложениями в attachment-service. Каждый сервис делает свой IMAP-запрос, MAILBOXES_JSON дублируется в env-конфигах обоих сервисов.

vNext контракт:
- mail-service отдаёт **только** письма без вложений (для Mail Reader / digest / статистика)
- attachment-service сам обходит письма с вложениями (для Compliance pipeline)
- передавать `imap_uid` через контракт mail→attachment (страхует от iCloud SEARCH-бага)

Решение: оставить сервисы раздельными как **два независимых тула** (mail = read-only для статистики/дайджеста, attachment = тяжёлые операции download+parse). Multi-mailbox в каждом — shared config, не дублирование.

→ зафиксировать как **DEC-030**.

### Vision-промпт два режима

`LLM_VISION_PROMPT_DIGEST` (кратко, для Mail Reader, текущее prod-состояние) vs `LLM_VISION_PROMPT_COMPLIANCE` (жадно, полный OCR, для Compliance Helper). Mode через env или через mode-параметр в `/parse` запросе.

→ зафиксировать как **DEC-031**.

### XLSX семантический фильтр vNext

Текущий фикс (truncation) — stop-gap. Полное решение для Compliance Helper: парсинг по колонке «Назначение платежа» с учётом разных форматов банков (Сбер/ТКБ/Совкомбанк — разные заголовки колонок). Идея от Артёма.

→ зафиксировать как **DEC-032**.

### iCloud SEARCH workaround

Apple IMAP не отдаёт результат по `SEARCH HEADER Message-ID`. Варианты:
- `UID SEARCH` вместо обычного `SEARCH`
- передавать `imap_uid` в attachment-service через контракт (часть DEC-030)
- перебирать `FETCH 1:* (BODY.PEEK[HEADER])` и руками парсить Message-ID (дорого, работает всегда)

→ зафиксировать как **DEC-033**.

### UX progress indicators в Telegram

Таймеры 60/180/360 сек применены в проде (см. п.5 выше). vNext — orchestrator callback при `step.attachments.done` с inline-расчётом ожидаемого времени по размеру вложений (сейчас бот угадывает по таймеру).

→ зафиксировать как **DEC-034**.

## Бэкапы (для отката)

- `/opt/mail-stack/parser-service/server.py.bak.20260514-mixed-text-first`
- `/etc/mail-stack/parser-service.env.bak.20260514-vision-brief`
- `/opt/mail-stack/attachment-service/server.py.bak.20260514-multibox-loop`
- `/etc/mail-stack/attachment-service.env.bak.20260514-multibox`
- `/home/iakshin77/agent-caller/server.js.bak.20260514-ux-timers`

## Метрики сессии

| | До (425k тест) | Тест 1 (99k) | Тест 2 (реальные сканы) |
|---|---|---|---|
| Письма | 19 | 21 | 22 |
| Attachments | 5 (12 запрошено) | 8 (12 запрошено) | 9 (13 запрошено) |
| Tokens in | 425 881 → 502 | 99 555 | 43 800 |
| Cost | n/a | $0.089 | $0.044 |
| Duration | 502 fail | ~3 мин | ~9 мин |
| TG доставка | нет | да | да |
| Fallback | both failed | Haiku ok | Haiku ok |

## Финальный статус

Желудок построен и работает на реальной деловой нагрузке. Кнопка в Telegram возвращает production-grade дайджест на 24 МБ деловой почты за ~7-9 минут с правильной приоритизацией (срочное/договоры/шум). Один известный баг (iCloud SEARCH) не критичен. Кишечник (classifier+extract+store) — отдельный продукт vNext.

## Уточнения и дополнения

### Время сессии (поправка)
Сессия фактически **00:00-04:00 UTC** (05:00-07:00 МСК и далее), не 02:30 как было указано выше. Финальные действия — патч UX-таймеров в agent-caller (01:06 UTC рестарт сервиса) и smoke-проверки.

### Точные тайминги Теста 2 (реальные сканы)
По логам orchestrator 00:45:21 → 00:54:38:

| Стадия | Время | Заметки |
|---|---|---|
| fetch_mail (3 ящика) | 41 сек | 22 письма |
| attachments + parse | **5 мин 22 сек** | 9 файлов скачано, 17 vision-вызовов на SCAN0253 (~3 мин один файл) |
| summary | 24 сек | Haiku без fallback |
| wa_ping | 2 мин 30 сек | **TIMEOUT FAIL** (`context deadline exceeded`) |
| deliver | 1 сек | TG доставлен несмотря на WA fail |
| **Итого** | **9 мин 17 сек** | |

### WhatsApp pre-alert: graceful degradation
В Тесте 2 `step.wa_ping.fail` (agent-caller таймаут), но `step.deliver.done` прошёл сразу после — Telegram-дайджест доставлен. Архитектура устойчива к падению одного канала уведомлений: WA fail → soft error → продолжаем deliver. Это правильное поведение DEC-018 (multi-channel notification), подтверждено в production.

### Vision-LLM safety policy через OpenRouter (известное ограничение, не баг)
Qwen3-VL через OpenRouter не называет публичных персон / звёзд / кадры из фильмов даже при прямом OCR-промпте — это shared safety policy провайдера. В сегодняшних тестах:

- jpg «В джазе только девушки» с Мэрилин Монро → vision вернул «фото предмета. На пляже три человека... историческое, чёрно-белое, вероятно кадр из фильма или фотосессии» (без имён)
- png с группой людей и Coca-Cola → vision вернул «фото предмета... сцена передаёт атмосферу отдыха и общения» (без идентификации лиц)

Для Mail Reader / Compliance Helper это **не влияет**: рабочие документы (договоры, акты, счёта, выписки, фото удостоверений) распознаются полностью — vision читает текст с документа, а не идентифицирует лица. Известное ограничение фиксируется для прозрачности на собеседованиях / для клиента.

### Test-synthetic директория
В `/var/lib/mail-stack/attachments/test-synthetic/` лежат 7 синтетических файлов (test.docx, test.xlsx, test.pptx, test.html, test.xml, test.txt, test.json, test.csv — суммарно 68 КБ) для smoke-тестов парсера. Не относятся к реальному кэшу attachment-service, используются отдельно при диагностике L1-L9 веток.

### Архитектурное решение: НЕ внедряем Unstructured / chunking / hierarchical / goldset

В ходе сессии параллельно прорабатывалась гипотеза «нужен более продвинутый парсинг»: через второй чат был распарсен канал AI-архитектора Носова (HighLoad++ 2025 материалы про 10 стратегий chunking, hierarchical parsing, tree-search retrieval, LightRAG, gold-set evaluation, Unstructured.io).

**Решение: ничего из перечисленного на pre-MVP не внедряем.** Обоснование:

1. **Существующие L1-L14 уже покрывают 95% задач Mail Reader** — pymupdf + pdfplumber + pdfminer для PDF (text-first per-page после фикса), openpyxl/xlrd для xlsx, python-pptx для pptx, python-docx для docx, LLM-vision Qwen3-VL для сканов/фото. Это уже universal parser, просто явно расписанный по форматам — даёт больше control чем Unstructured-фронтенд.

2. **Замер на реальной нагрузке подтвердил**: после трёх точечных фиксов в существующих парсерах (text-first роутинг для Mixed PDF, xlsx truncation, краткий vision-промпт) **425k → 43k токенов** на ту же деловую почту. Узких мест под Unstructured / chunking — нет.

3. **Gold-set evaluation для регрессии — преждевременно**: нет повторяющегося корпуса (рандом-корреспонденция), нет платящего клиента, нет измеримой цены ошибки. Создание goldset на pre-MVP = «шнурки с позолотой» (формулировка Артёма).

4. **Hierarchical chunking, tree-search, LightRAG** — паттерны для compliance-pipeline (DEC-029 vNext, «кишечник»), не для digest. Сейчас строим «желудок» — pipeline переваривающий любое без потери. Классификация / extraction / hierarchy — отдельный продукт.

5. **Носов сам различает в постах**: дайджест-сторона (Context-Complete / 2M токенов) vs production-сторона (chunking + tree-search для устоявшихся корпусов). У нас pre-MVP — ни тот ни другой кейс. Точечный роутинг бьёт замену библиотек.

**Триггер revisit:** Compliance Helper (DEC-029 vNext) с регулярным потоком 100+ документов/день, или несоответствие парсинга более чем в 5% случаев. До этого — нет.

Зафиксировать как **DEC-035** (Status: Decided).

### vNext-таймер для UX в Telegram (DEC-034 дополнение)
Текущая реализация (60/180/360 сек) — heuristic timer. **Правильное архитектурное решение** обсуждалось: orchestrator после `step.attachments.done` дёргает Agent Caller с inline-расчётом ожидаемого времени по размеру вложений и количеству vision-страниц. Сейчас бот угадывает по таймеру — это работает для среднего сценария, но врёт в крайних (короткие/очень длинные workflows). На vNext — callback от orchestrator с реальной оценкой.
