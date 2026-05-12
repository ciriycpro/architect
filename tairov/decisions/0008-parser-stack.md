# 8. Parser-service: библиотечный стек L1-L14 + LLM-vision Qwen-каскад

Date: 2026-05-12

## Status

Accepted

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

**Стратегический сигнал:** parser-service — это **переиспользуемый компонент**. Тот же API `POST /parse` будет использоваться не только Compliance Helper, но и другими проектами стека `mail-stack/`, а также в перспективе — в KAMF как стандартный document-processing блок.
