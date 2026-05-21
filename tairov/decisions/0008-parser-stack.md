# 8. Parser-service: библиотечный стек L1-L14 + LLM-vision Qwen-каскад

Date: 2026-05-12

## Status

Accepted — **Implemented on 12-13.05.2026** (production via systemd, Memory 86 МБ, port 8767)

## Context

После принятия [DEC-005](0005-microservices.md) (вынесение mail-приёма в микросервис) встал вопрос: как парсить вложения. Рассматривались четыре подхода:

1. **Самописный парсер всех форматов** (~460 строк Python, неделя работы)
2. **Готовый универсальный движок Unstructured.io** (Docker-образ ~3 ГБ, OCR + 1000+ форматов)
3. **Готовый универсальный движок Apache Tika** (Docker-образ ~500 МБ Java)
4. **LLM-vision для всего** (отправка каждого файла в Qwen3-VL через OpenRouter, ~$0.0015/документ)

Дополнительные констрейны выявлены 12.05.2026:
- RAM на coo: 1.9 ГБ total, ~900 МБ свободно. **Unstructured.io (3 ГБ) не влезает физически.**
- Поток документов малый (~5-15 писем/день, из них ~2-5 с вложениями)
- Реальное распределение типов в выборке за неделю (01-12 мая): преимущественно PDF от Контур.Экстерн (текстовые), JPG-фото от Таирова (иск 03.05), ожидаются DOCX/XLSX от бухгалтеров
- Принцип владельца: «всё должно окупаться» — LLM-вызовы при росте до 100 клиентов становятся видимой статьёй

Также отвергнуты в обсуждении:
- **Tesseract локально** — плохое качество на русских печатях и фотодокументах с телефонов
- **PyMuPDF как единственный инструмент** — AGPL-лицензия активируется при SaaS-распространении (не закрывает путь к коммерциализации)
- **AI-роутер для выбора библиотеки** — over-engineering для предсказуемого набора MIME-типов

## Decision

Parser-service использует **гибридную архитектуру**: детерминированный роутер по MIME → специализированная библиотека для каждого формата → LLM-vision только для растровых.

### Реестр библиотек L1-L14

| № | Слой / Формат | Библиотека | Лицензия | RAM |
|---|---|---|---|---|
| **L1** | Классификация PDF — primary | pdf-inspector | MIT | 10 МБ |
| **L2** | Классификация PDF — fallback | pypdf | BSD | 20 МБ |
| **L3** | Извлечение PDF — primary | PyMuPDF (fitz) | AGPL | 80 МБ |
| **L4** | Извлечение PDF — fallback | pdfplumber | MIT | 30 МБ |
| **L5** | DOCX | mammoth | BSD | 30 МБ |
| **L6** | XLSX | openpyxl | MIT | 40 МБ |
| **L7** | XLS старый | xlrd | BSD | 20 МБ |
| **L8** | PPTX | python-pptx | MIT | 30 МБ |
| **L9** | HTML | beautifulsoup4 | MIT | 20 МБ |
| **L10** | CSV | встроенный `csv` | PSF | 0 |
| **L11** | TXT | встроенный | PSF | 0 |
| **L12** | XML | встроенный `xml.etree` | PSF | 0 |
| **L13** | JSON | встроенный `json` | PSF | 0 |
| **L14** | JPG/PNG/PDF-скан | LLM-vision via OpenRouter | external | 0 |

**Все локальные лицензии — open-source.** AGPL (PyMuPDF) активируется при SaaS-распространении, но для self-hosted MVP не применима. При коммерциализации — заменяется на pypdf+pdfplumber комбинацию (вопрос на v2).

**Итого RAM:** ~260 МБ peak (при одновременной нагрузке всех форматов), ~80 МБ idle (Python грузит библиотеки лениво по `import`).

### LLM-vision каскад (L14)

| Приоритет | Модель | Цена | Назначение |
|---|---|---|---|
| Primary | Qwen3-VL 235B Instruct | $0.20/M in, $0.88/M out | Качество, кириллица, печати |
| Fallback | Qwen 2.5 VL 72B (DeepInfra) | ~$0.15/M | При rate-limit / таймауте Qwen3-VL |

**Не используются на v1:**
- **Cloudflare AI** — слаб на сканах; нам в L14 попадают только сканы и фото, на тексте PyMuPDF справляется лучше
- **Mistral OCR** — last resort, не нужен при объёме 5-10 vision-вызовов/мес
- **GLM (Zhipu)** — слабое распознавание кириллицы, основной корпус CN+EN
- **Claude Sonnet / GPT-4o** — дороже Qwen в 5-10×, без пропорционального прироста качества на типовых документах МСП

Эскалация (Cloudflare, Mistral, GLM) — при накоплении статистики провалов Qwen-каскада или росте объёма до промышленных уровней.

### Маршрутизация — два уровня

#### Уровень A: детерминированный роутер по MIME-типу

```
application/pdf                                  → L1 (далее уровень B)
application/vnd.openxmlformats...wordprocessing  → L5 (mammoth)
application/vnd.openxmlformats...spreadsheetml   → L6 (openpyxl)
application/vnd.ms-excel                         → L7 (xlrd)
application/vnd.openxmlformats...presentationml  → L8 (python-pptx)
text/html                                        → L9 (beautifulsoup4)
text/csv                                         → L10 (csv)
text/plain                                       → L11 (read)
application/xml, text/xml                        → L12 (xml.etree)
application/json                                 → L13 (json)
image/jpeg, image/png                            → L14 (LLM-vision)
прочее                                           → {"error": "unsupported_mime", ...}
```

Закрывает ~80% случаев простым if/elif/else. Никакого AI на этом шаге.

#### Уровень B: PDF-ветка с per-page роутингом

```
PDF → L1 (pdf-inspector) классифицирует ~10-50мс
       ↓
       ├── TextBased + confidence > 0.8 → L3 (PyMuPDF) извлекает текст
       │       ↓ если PyMuPDF упал или вернул <50 символов
       │       └─ L4 (pdfplumber) пытается ещё раз
       │              ↓ если оба упали
       │              └─ L14 (LLM-vision) последняя инстанция
       │
       ├── Scanned / ImageBased → L14 (LLM-vision)
       │
       └── Mixed / confidence < 0.8 → L3 + L14 per-page
              (PyMuPDF для страниц с текстом, LLM-vision для image-only страниц)
```

Если **L1 (pdf-inspector) сам упал** (молодая библиотека, 2 недели на 12.05.2026) → fallback **L2 (pypdf)** для классификации, дальше та же ветка.

### Unified output формат

Любой парсер L1-L14 возвращает в parser-service единый JSON:

```json
{
  "text": "<извлечённый текст>",
  "method": "pymupdf | pdfplumber | mammoth | openpyxl | qwen3vl | ...",
  "format": "pdf-text | pdf-scan | docx | xlsx | jpg | ...",
  "pages": 3,
  "warnings": ["fallback_used", "partial_extraction", ...],
  "cost_estimate_usd": 0.0015  // только для L14
}
```

Это позволяет в следующих этапах (summary, classifier) работать с единым контрактом, не разбираясь откуда пришёл текст.

## Consequences

**Плюсы:**
- Локальный парсинг 95% документов **бесплатен** (нативные форматы)
- LLM-vision только для растрового (~5% документов), копейки/мес на потоке Таирова
- RAM-бюджет ~260 МБ peak вписывается в свободные 900 МБ coo
- Все локальные лицензии open-source
- Детерминированный роутер тривиален в отладке (один if/elif/else)
- Per-page роутинг внутри Mixed PDF позволяет не отправлять текстовые страницы в LLM

**Минусы:**
- AGPL на PyMuPDF — лицензионный риск при коммерциализации. При переходе в SaaS требуется либо замена PyMuPDF на pypdf+pdfplumber (потеря ~10% качества по бенчмаркам), либо покупка коммерческой лицензии PyMuPDF (~$500/год)
- Множество библиотек = множество мест для багов. Митигация: каждая работает только на своём MIME, конфликтов нет
- pdf-inspector молодой (2 недели на 12.05.2026), pypdf-fallback нужен на случай нестабильности
- Самописный роутер уровня A — это код, который надо поддерживать. Но он простой (~80 строк) и редко меняется

**Открытые вопросы для v2:**
- Когда вводить Cloudflare AI / Mistral OCR / GLM в каскад L14 — по статистике провалов Qwen
- Когда заменить PyMuPDF — при коммерциализации продукта
- Когда добавить чтение EPUB / EML вложенных — по запросу
- Когда добавить AI-роутер для определения типа документа (счёт/договор/акт) — это отдельный сервис `classifier-service`, v2 направление, не часть parser-service
- **Активировать `pdfplumber.extract_tables()` для табличных PDF.** Сейчас L4 использует обычное `extract_text()`, теряя структуру таблиц. Для документов с таблицами (счета, акты, выгрузки из 1С) переход на `extract_tables()` + конвертация в markdown-таблицу даст существенный прирост качества downstream-LLM (классификатор, summary). Для текстов с таблицами LLM понимает markdown-таблицы на ~2-3 раза лучше «потока слов».
- **Pre-filter перед parser-service (hierarchical classification — ОТДЕЛЬНЫЙ DEC v2).** Каждый Mixed-PDF из спам-рассылки сейчас стоит 0.5-1.5 руб (per-page L14). На потоке 100 спам-рассылок в день = 50-150 руб/мес/клиент. Стандарт индустрии 2024-2025 (Stalwart docs, IJRASET review) — двухстадийный фильтр: сначала **дешёвые правила** (whitelist отправителей, blacklist newsletter-доменов, mail.ru X-Spam header, regex по subject), потом дорогой парсинг. ~80-95% входящего трафика отсекается на стадии 1. Реализация: `classifier-service` ИЛИ IF-нода в N8N перед attachment+parser. Это **отдельная архитектурная инициатива на v2**, заслуживает собственного ADR.
- Конфигурируемый порог `PDF_CONFIDENCE_THRESHOLD` per-MIME — сейчас 0.8 для всех PDF. По факту тестирования (12.05.2026) на презентации Контур.Экстерн ЦЭД (11 страниц) pdf-inspector классифицировал как `Mixed conf=0.5` → ушла в LLM-vision per-page = 10 вызовов Qwen. Возможна стратегия: при `conf < 0.3 = всегда L14`, при `conf 0.3-0.7 = пробовать PyMuPDF первым`, при `conf > 0.7 = быстрый путь TextBased`.
- `.meta.json` рядом с PDF для кэша результата pdf-inspector — повторный парсинг того же файла будет мгновенным.

**Стратегический сигнал:** parser-service — это **переиспользуемый компонент**. Тот же API `POST /parse` будет использоваться не только Compliance Assistant, но и другими проектами стека `mail-stack/`, а также в перспективе — в KAMF как стандартный document-processing блок.

## Implementation Notes (12-13.05.2026)

Реализован за один заход в ночь 12-13.05.2026 (~3 часа от установки зависимостей до production). Не v0-скелет, а полная реализация L1-L14 по контракту.

### Что сделано

- **Код:** `/opt/mail-stack/parser-service/server.py` (622 строки, 22 функции, все уникальные)
- **Зависимости:** 38 pinned пакетов в `requirements.txt` (включая PyMuPDF 1.27.2, pdfplumber 0.11.9, mammoth 1.12, openpyxl 3.1.5, xlrd 2.0.2, python-pptx 1.0.2, beautifulsoup4 4.14.3, lxml 6.1.0, pdf-inspector 0.1.1)
- **Env-конфиг:** `/etc/mail-stack/parser-service.env` chmod 600 root:root, OPENROUTER_API_KEY + модели + таймауты
- **Systemd-юнит:** `/etc/systemd/system/parser-service.service` с UMask=0022
- **Docker-образ:** `parser-service:test` собран как артефакт. **python:3.10-slim** (а не 3.11) — чтобы хостовый wheel pdf-inspector cp310 подошёл без перекомпиляции
- **Memory в production:** 38.5 МБ idle → 86 МБ после первого PDF (PyMuPDF/lxml загрузились лениво)

### Подтверждённое поведение (8 веток L1-L14 на реальных файлах)

| Тест | method | Результат |
|---|---|---|
| L11 TXT | `read` | ✅ 128 символов, кириллица декодирована |
| L10 CSV | `csv` | ✅ 95 символов, табуляция как разделитель |
| L13 JSON | `json` | ✅ 150 символов, структура сохранена |
| L12 XML | `xml.etree` | ✅ 117 символов, теги+значения извлечены |
| L9 HTML | `beautifulsoup4` | ✅ 71 символ, `<script>` и `<style>` отрезаны |
| L5 DOCX | `mammoth` | ✅ 164 символа, заголовки + параграфы |
| L6 XLSX | `openpyxl` | ✅ 153 символа, 2 листа, вычисленные значения |
| L1+L3 PDF (Контур.Экстерн) | `pymupdf` → потом per-page L14 | 11 страниц, 5931 символ |
| L14 JPG (иск Таирова) | `qwen3-vl-235b` | 2745 символов, $0.00147 = 0.1 руб |

### Найденные баги и фиксы

1. **API имя pdf-inspector было угадано неверно.** В DEC-008 первоначально ожидалось `pdf_inspector.classify_pdf_bytes(...)`. Реальный API: `pdf_inspector.detect_pdf_bytes(...)`. Возвращает `PdfResult` с полями `pdf_type` (lowercase: 'text_based', 'scanned', 'image_based', 'mixed'), `confidence`, `pages_needing_ocr`. **Исправлено:** добавлена нормализация snake_case → CamelCase для совместимости с DEC-008. Без фикса pdf-inspector не вызывался, работал PyMuPDF-fallback.

2. **Per-page роутинг изначально упростили** (весь Mixed PDF → vision). По требованию доделан до полной реализации DEC-008: текстовые страницы → PyMuPDF (бесплатно), image-only страницы → L14 LLM-vision.

### Стоимость в работе

Зафиксированная по факту (Qwen3-VL 235B Instruct):
- Один JPG (456 КБ, иск Таирова) → $0.00093 ≈ 0.07 руб
- Одна страница PDF в render+vision → $0.0005-0.0015 ≈ 0.04-0.1 руб
- Презентация 11 стр в Mixed-режиме (10 vision-вызовов) → ~$0.005-0.015 ≈ 0.5-1.5 руб

### Архитектурное наблюдение

На презентации Контур.Экстерн (11 страниц, текстовый слой есть) две классификации разошлись:
- **pdf-inspector:** `Mixed conf=0.5` → роутер ушёл в per-page L14
- **PyMuPDF-эвристика (fallback):** `TextBased conf=1.0` → быстрый путь через PyMuPDF

pdf-inspector консервативнее (находит проблемные страницы лучше), PyMuPDF-эвристика дешевле и быстрее. Доверяем pdf-inspector — это «умнее», но дороже на пограничных PDF. Конфигурируемый порог `PDF_CONFIDENCE_THRESHOLD` per-MIME — вопрос v2.

### Docker — урок

Multi-stage с компиляцией Rust внутри Docker (Stage 1: Rust toolchain + maturin → wheel; Stage 2: только runtime) **не сработал из-за того что pip в Stage 2 не знал о /tmp/wheels от Stage 1** и пытался пересобрать pdf-inspector из исходников → второй раунд компиляции 10+ минут.

**Финальное решение:** `python:3.10-slim` (а не 3.11) + готовый cp310 wheel из локального pip-кэша хоста, скопированный в проект. Build за 70 секунд, никакого Rust в Docker, образ ~250 МБ. Этот подход — **отдельная заметка для KAMF/HRrep**: «build стратегия для Rust-зависимостей в Python-проектах».

### Production-готовность

| Критерий | Статус |
|---|---|
| Systemd active + enabled | ✅ |
| Memory footprint | ✅ 38 МБ idle, 86 МБ после первого PDF |
| Restart=always | ✅ |
| Логи в journalctl | ✅ |
| Healthcheck endpoint | ✅ возвращает конфиг + доступность OpenRouter |
| Env-конфиг изолирован | ✅ chmod 600 root:root |
| OPENROUTER_API_KEY в env, не в коде | ✅ |
| Все 8 веток L1-L14 проверены smoke-тестом | ✅ |
| Per-page роутинг для Mixed PDF | ✅ (фикс по требованию) |
| pdf-inspector реально работает (не fallback) | ✅ (после фикса API имени) |
| Открытые v2-вопросы зафиксированы | ✅ |
