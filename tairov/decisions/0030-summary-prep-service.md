# DEC-0030: Summary-prep service — дистилляция смысла длинных документов

**Дата**: 23.06.2026
**Статус**: Accepted
**Связано с**: DEC-0008 (Parser-stack L1-L14), DEC-0009 (Summary-service Haiku), DEC-024 (Mail-stack v1.1 fixes), DEC-0025 (Compliance Assistant architecture), DEC-0028 (Contract/Act vacuum — будущая интеграция), **DEC-035 (revisit, partial close)**

---

## Контекст

### Инцидент 17-18.06.2026

После дайджеста 16.06 ушёл успешно (4 письма, 6650 prompt tokens), на следующих двух прогонах summary-service упал с OpenRouter HTTP 400 `context_length_exceeded`:

- **17.06 07:00 UTC**: 10 писем, **206052 tokens** → Haiku 4.5 (200k context) FAIL → DeepSeek (163k) FAIL → 502.
- **18.06 07:00 UTC**: 15 писем, **253186 tokens** → оба провайдера FAIL → 502.

### Триггер

Пять больших text-based PDF в окне `last_at=2026-06-16T07:00:00Z` → текущий момент:

| Документ | UID | Размер | Источник |
|---|---|---|---|
| Ответ_банку_КЕБ_Таиров_115-ФЗ полный.pdf | 3835 | 2.19 МБ | ЦПОЧТА (16.06) |
| Ответ_банку_КЕБ_Таиров_115-ФЗ полный_compressed.pdf | 3836 | 1.50 МБ | ЦПОЧТА (17.06) |
| Декларация по НДС 1 кв 2026 + протоколы | 3839 | 0.39 МБ | Полина Аксёнова (17.06) |
| Декларация по УСН 2025 | 3839 | 0.28 МБ | Полина Аксёнова |
| Декларация по НДС 4 кв 2025 | 3839 | 0.39 МБ | Полина Аксёнова |

Parser-service классифицировал все 5 как `type=TextBased, conf=1.0` и через `extract_pdf_pymupdf` отдал **весь** plain text. После извлечения text-based PDF разворачивается в plain text в 15-25× относительно размера на диске.

### Что в pipeline есть и работает правильно

- **attachment-service** (`HARD_LIMIT 25 МБ`) корректно фильтрует огромные файлы по байтам на диске. КЕБ-PDF 2.19 МБ — нормальный документ, не должен отвергаться.
- **parser-service / DEC-024 v1.1** — XLSX truncation, Mixed PDF per-page, vision-prompt — всё работает.
- **summary-service / DEC-0009** — один LLM-call на весь массив писем дайджеста, Haiku 4.5 + DeepSeek fallback.

### Что отсутствует — корень инцидента

**Стадия `text → distill → semantic_summary` для длинных документов между parser-service и summary-service.**

Parser-service отдаёт сырой text. Summary-service пытается засунуть всё в один LLM-call с лимитом 200k. На больших документах математика лимита проигрывает.

### Архитектурное наблюдение

Дистилляция смысла — **не parser-функция** (parser = L1-L14, "байты в текст", синтаксис). Дистилляция смысла — **не summary-функция** (summary = "массив писем в дайджест"). Это **третий слой** между ними: "длинный текст в плотный смысл". В корпоративных RAG-системах этот слой обычно выделен отдельно (см. рекомендации Носова в архивных обсуждениях, май 2026: "between parsing and answering").

### DEC-035 — partial close

DEC-035 (внутри DEC-024) принял `pre-MVP отказ от Unstructured / chunking / hierarchical summarization`. Триггер revisit: "100+ док/день или несоответствие в 5%+".

Триггер сработал **не количеством**, а **классом входа**: объёмные text-based PDF от реальных контрагентов (банк, налоговая) стали штатным потоком. Этот ADR закрывает DEC-035 **частично** — вводим двухуровневую map-reduce дистилляцию, не полную hierarchical иерархию. Если документы дальше превысят лимит на стадии reduce — потребуется третий уровень (hierarchical), это поднимается в Open Issues.

---

## Решение

### Новый микросервис `summary-prep` на порту 8772

Между parser-service и summary-service вводится отдельный микросервис `summary-prep`:

```
mail-service → attachment-service → parser-service → summary-prep → summary-service
                                          ↓                  ↓
                                       raw_text     {distilled: structured JSON}
```

Контракт `parser-service` остаётся как есть. Новый эндпоинт **на уровне orchestrator workflow `email_digest_v1`**: после `parse-step` для каждого вложения, перед `summary-step`, добавляется `distill-step` через summary-prep.

### Семантика summary-prep

| Endpoint | Что делает |
|---|---|
| `POST /distill` | принимает `{text, metadata, quality_mode}` → возвращает `DistillResult` (см. ниже) |
| `GET /health` | стандартный health-check |
| `GET /metrics` | счётчики map/reduce calls, токены, cost |

Если `len(text) < DISTILL_CHAR_THRESHOLD` (80000) — возвращается **as-is wrapped** в DistillResult без LLM-call (с флагом `distillation_applied=false`). Это сохраняет единый контракт даунстрим — summary-service всегда получает DistillResult, а не "иногда строку, иногда структуру".

### Pydantic schema контракта

```python
class Amount(BaseModel):
    value: Decimal
    currency: str  # "RUB", "USD", "EUR"
    role: str      # "amount_total" | "tax" | "fine" | "balance" | "monthly" | "other"
    raw_text: str  # дословная цитата из источника

class DateEntry(BaseModel):
    date: date
    role: str      # "document_date" | "due_date" | "period_start" | "period_end" | "other"
    raw_text: str

class Party(BaseModel):
    name: str
    inn: str | None
    role: str      # "sender" | "recipient" | "third_party"

class DistillResult(BaseModel):
    document_type: str     # самотипизация LLM: "bank_response" | "tax_declaration" | "contract" | "act" | "statement" | "letter" | "other"
    summary_brief: str     # 1-2 предложения, что это за документ и для кого
    key_facts: list[str]   # ключевые факты, каждый ≤ 1 предложение
    amounts: list[Amount]
    dates: list[DateEntry]
    parties: list[Party]
    requirements: list[str]    # что требуется сделать получателю
    raw_excerpts: list[str]    # 3-5 дословных цитат для верификации
    confidence: float          # 0-1, самооценка LLM
    distillation_applied: bool # true если был map-reduce, false если as-is
    map_chunks_total: int
    map_chunks_succeeded: int  # для retry/partial-reduce учёта
    contract_strictness: str   # "soft" (для саммари) | "hard" (для compliance, future)
```

### Soft vs Hard контракт

- **`contract_strictness="soft"`** — текущий MVP для саммари. Pydantic валидирует **структуру**, но **разрешает пустые списки** (нет amounts → `amounts=[]`). Цена пропуска: ослабленный дайджест, не катастрофа.
- **`contract_strictness="hard"`** — будущее для compliance-logic (DEC-0028 contracts/acts ingest). Pydantic strict-mode + обязательные поля для типа документа (для `document_type=contract` → `parties.len >= 2`, `dates` содержит `document_date`, `amounts` содержит `amount_total` для возмездного). Если LLM не нашёл → endpoint возвращает HTTP 422 с указанием пропущенного поля → compliance-logic эскалирует в human-review.

В MVP реализуется только `soft`. `hard` зашит в схему как будущее расширение, прописан в Open Issues.

### Map-reduce схема

```
длинный текст (>80000 chars)
        │
        ├─ MAP параллельно (asyncio.gather):
        │     ├─ chunk_1 → LLM (Haiku) → JSON: типизирует + извлекает факты
        │     ├─ chunk_2 → LLM → JSON
        │     └─ chunk_N → LLM → JSON
        │
        ├─ REDUCE: chunks_succeeded > 50% от total → LLM (Haiku) собирает в DistillResult
        │             ├─ принимает metadata письма (from, subject, date) для контекста
        │             └─ JSON-schema-enforced output
        │
        └─ VERIFY: проверочный запрос LLM на REDUCE-результате:
                 "вот первая страница исходника, вот distilled. Чего критически важного нет?"
                 → если ответ непустой → confidence снижается, флаг warning
```

### Чанкование

- Размер чанка `DISTILL_CHUNK_CHARS = 50000` (комфортно с overhead на промпт в один Haiku-call).
- Граница: `\n\n` → `\n` → `. ` → ` ` (поиск назад до 1000 символов от жёсткой границы).
- Если документ < `DISTILL_CHAR_THRESHOLD` — стадия пропускается, DistillResult формируется один MAP-call'ом без reduce.
- Жёсткая граница: даже без границ режется по 50000 chars (терпимая потеря).

### Concurrency MAP-calls — обязательно в MVP

Не Open Issue, а **базовое требование**. Документ 700k chars = 14 chunks. Последовательно: 14 × 3 сек = 42 сек. Параллельно через `asyncio.gather`: 3-5 сек.

Implementation:
```python
async def distill_long_text(text: str, metadata: dict) -> DistillResult:
    chunks = _chunk_text(text)
    map_results = await asyncio.gather(
        *[_map_distill_chunk(c, metadata) for c in chunks],
        return_exceptions=True,
    )
    succeeded = [r for r in map_results if not isinstance(r, Exception)]
    if len(succeeded) / len(chunks) < 0.5:
        return _fallback_metadata_only(metadata, errors=map_results)
    return await _reduce_distillates(succeeded, metadata)
```

OpenRouter rate-limit учитываем через `RateLimiter` (token-bucket по аккаунту), задержка между MAP-call'ами при достижении лимита.

### Retry / partial-reduce

- На MAP-call: 2 retry с exp backoff (1s, 2s). Если оба упали → chunk считается failed.
- Если **<50% chunks succeeded** → fallback: возвращается DistillResult с `distillation_applied=false`, заполненными только метаданными письма (`document_type="other"`, `summary_brief="дистилляция не удалась, см. оригинал во вложении"`, `confidence=0.0`, `key_facts=[имя файла, размер, отправитель]`). Дайджест получает уведомление о документе без потери самого факта его прихода.
- На REDUCE: 2 retry. Если оба упали → возвращается тот же fallback.

### sha256-кэширование — обязательно в MVP

Не Open Issue. Окно дайджеста с `last_at` может тянуться днями (текущий dedlock в `SetLastAt` под `if deliveredOK` в orchestrator). Без кэша КЕБ-PDF дистиллируется каждый день — лишние $0.015 × 7 = $0.1 на один документ за неделю.

Реализация:
- `/var/lib/summary-prep/cache/<sha256[:2]>/<sha256>.json` — структура FS-кэша.
- TTL 30 дней по mtime, GC через cron.
- Если результат в кэше → возвращается без LLM-call'а.
- Race condition между workers: atomic write через `tempfile + os.rename`.

### Промпты

#### MAP prompt (на каждый chunk)

```
Ты — экстрактор фактов из фрагмента документа. Не пересказывай. Не интерпретируй.
Не дополняй знаниями. Не выдумывай. Если факта нет в тексте — не упоминай его.

ВАЖНО: Все факты должны быть подкреплены дословной цитатой из текста.

Метаданные письма:
  От: {from}
  Тема: {subject}
  Дата: {date}

Фрагмент документа (chunk {chunk_idx}/{total_chunks}):
---
{chunk_text}
---

Задачи:
1. Определи тип документа из списка: bank_response, tax_declaration, contract,
   act, statement, letter, other.
2. Извлеки факты: суммы (с ролью), даты (с ролью), стороны (с ИНН если есть),
   требования к получателю.
3. Для каждого факта приведи дословную цитату из текста (поле raw_text).
4. Оцени confidence своей экстракции 0-1.

Ответ — JSON по schema DistillChunkResult. Никакого markdown, никакого префикса
"Вот результат:". Только JSON.
```

#### REDUCE prompt (на собранные дистилляты)

```
Ты собираешь набор дистиллятов фрагментов одного документа в единый отчёт.

Метаданные письма:
  От: {from}
  Тема: {subject}
  Дата: {date}

Дистилляты фрагментов:
{chunk_results_json}

Задачи:
1. Определи итоговый document_type (большинство голосов из чанков, при споре —
   тот тип, который согласован с метаданными письма).
2. Сформируй summary_brief: 1-2 предложения, что это за документ и для кого
   (учитывай from/subject).
3. Объедини key_facts из чанков, убери дубликаты. Каждый факт ≤ 1 предложение.
4. Объедини amounts/dates/parties/requirements, дедуплицируй.
5. Соедини raw_excerpts (выбери 3-5 самых характерных).
6. Итоговый confidence = средневзвешенный по chunks_succeeded.

Не добавляй фактов которых нет в дистиллятах. Не интерпретируй.

Ответ — JSON по schema DistillResult. Только JSON, без префиксов.
```

#### VERIFY prompt (контроль галлюцинаций)

```
Тебе дан фрагмент исходного документа (первая страница) и дистиллят, собранный
из него и других фрагментов.

Исходник (первая страница):
{first_chunk_text[:5000]}

Дистиллят:
{distill_result_json}

Задача: оцени, есть ли в исходнике критически важный факт (сумма, срок,
требование), которого нет в дистилляте.

Ответ — JSON: {"missing_critical_facts": [список или []], "severity": "none"|"low"|"high"}
```

Если `severity=high` → confidence итогового DistillResult снижается на 0.3, в `key_facts` добавляется флаг "ВНИМАНИЕ: возможен пропуск, см. оригинал".

### Sequence сквозного дайджеста

```
orchestrator (workflow email_digest_v1):
  1. fetch_mail → mail-service
  2. download_attachments → attachment-service
  3. parse_attachments → parser-service (raw text + warnings)
  4. distill_attachments → summary-prep (DistillResult per attachment)  ← НОВЫЙ ШАГ
  5. summary → summary-service (массив писем с DistillResult, не raw text)
  6. notify → agent-caller (WhatsApp pre-alert)
  7. deliver → agent-caller (Telegram)
  8. SetLastAt(now) iff deliveredOK    [техдолг dedlock, не покрыт этим ADR]
```

Шаг 4 параллельный — для каждого вложения dist-call в summary-prep делается параллельно через `asyncio.gather` на стороне orchestrator (Go workers).

### Sequence с X-Trace-Id

Сквозной trace_id через все hop'ы — **техдолг, не блокер MVP** (вынесен в cleanup_backlog_v2.md раздел 6.4). В MVP orchestrator пишет trace_id в свои логи, summary-prep пишет свой trace_id. Корреляция через journalctl + timestamp.

### Cost-side эффект

Дистилляция = дополнительные LLM-calls (N MAP + 1 REDUCE + 1 VERIFY).

На один большой документ (КЕБ-PDF 2.19 МБ ≈ 700k chars ≈ 14 chunks):
- 14 MAP × ~50k tokens × Haiku цена ≈ $0.014
- 1 REDUCE × ~20k tokens ≈ $0.003
- 1 VERIFY × ~7k tokens ≈ $0.001
- **~$0.018 на один большой документ**.

На дайджест 17.06 (5 больших PDF) — ~$0.09. С sha256-кэшем на повторных днях — копейки.

Месячный прогноз для Таирова (1 клиент, ~30 больших док/мес) — ~$3/мес. Не критично, бюджет покрывается легко.

### Логирование

Structured logs slog/JSON формата (как в orchestrator). Каждый MAP/REDUCE/VERIFY call пишет:
- `trace_id` (per request)
- `chunk_idx`, `total_chunks`
- `model`, `tokens_in`, `tokens_out`, `cost`
- `cache_hit` boolean
- `duration_ms`

Метрика `/metrics` Prometheus-friendly: `distill_calls_total`, `distill_cache_hit_total`, `distill_failed_total`, `distill_cost_usd_total`.

---

## Альтернативы рассмотренные

### A. Cap по символам (отрезать N первых символов)
**Отвергнуто.** Грубая обрезка теряет смысл. Артём явно: "парсер должен сожрать дракона". Не обрезка — дистилляция.

### B. Дистилляция как модуль внутри parser-service
**Отвергнуто.** Нарушает семантику parser-service ("формат-уровень"). Семантика "длинный текст → плотный смысл" — это другой layer ответственности. Отдельный сервис чище и переиспользуем (compliance-logic тоже захочет дистиллировать contract.text).

### C. Дистилляция как модуль внутри summary-service
**Отвергнуто.** Summary-service отвечает за **дайджест из массива писем** — это финальный layer. Если запихать дистилляцию туда — summary-service превращается в megaservice с N×M LLM-calls внутри одной задачи. Single responsibility нарушен.

### D. Поднять context window до 1M (Gemini, Claude Opus)
**Отвергнуто.** Лимит сам по себе ничего не решает. 250k → 1M расширяет, но 10+ КЕБ-PDF снова упрутся в потолок. Дистилляция — фундаментально правильный путь.

### E. Markdown output вместо JSON
**Отвергнуто.** JSON надёжнее парсится, валидируется через Pydantic, легко идёт в БД (DEC-0028 future). Markdown — для human consumption, не inter-service.

### F. quality_mode={fast,deep} в MVP с двумя моделями (Haiku+Sonnet)
**Отвергнуто на MVP.** В MVP только Haiku 4.5. Контракт `quality_mode` зашит в API схему как поле, но в MVP принимается только `fast`. Расширение под `deep` (Sonnet/Opus) — задел под драфт DEC-029 от мая 2026 (Two-product Mail Reader vs Compliance Helper), когда придёт второй контур.

---

## Open Issues

1. **Промпт-инжиниринг.** MAP/REDUCE/VERIFY промпты выше — стартовая версия. Качество дистиллятов оценивается на реальных КЕБ-PDF после деплоя. Триггер revisit: фидбек Таирова "дайджест не отражает суть документа" → итерация промптов. Возможна type-aware специализация (отдельные промпты для bank_response, tax_declaration, contract).

2. **Hard contract для compliance-logic** (DEC-0028 contracts/acts ingest). Когда DEC-0028 Phase 1 уйдёт в jar, compliance-logic будет дёргать summary-prep с `contract_strictness=hard` и type-specific обязательными полями. Реализация после деплоя DEC-0028.

3. **Hierarchical третий уровень.** Двухуровневый map-reduce ограничен размером REDUCE-input. Если N chunks × 1000 слов > REDUCE context limit (актуально для документов >10 МБ text) — нужен третий уровень: group chunks по 5-7 → mini-reduce → final reduce. Триггер revisit: первый REDUCE-fail по context_length.

4. **Concurrency на orchestrator стороне.** На дайджесте 17.06 — 5 больших PDF параллельно через `asyncio.gather`. На дайджесте с 20+ PDF параллельно может пробить rate-limit OpenRouter. Триггер revisit: первый 429 от OpenRouter в логах summary-prep. Решение — token-bucket в summary-prep с глобальным лимитом per-account.

5. **Кэш-инвалидация при изменении промптов.** sha256 кэша считается от **текста**, не от промпта. Если поменяем MAP/REDUCE промпт — старые дистилляты будут жить. Решение: добавить `prompt_version` в sha256-ключ (например, `sha256(text + ":v2")`). Триггер revisit: первая итерация промпта в проде.

6. **Дистилляция XLSX.** Текущая DEC-024 XLSX truncation работает на структурном уровне (urlimitstr строк в листе). Если в дайджесте будет много больших XLSX (годовые выписки) — может потребоваться отдельная XLSX-дистилляция. Сейчас не покрываем — выписки идут через `/parse-statement` в детерминированный pipeline, dump-text короче чем text-based PDF.

7. **Дистилляция Mixed PDF.** Если документ Mixed (часть text, часть vision) и text-часть длинная — дистилляция применяется к собранному тексту после parser-service. Реализуется по тому же контракту — orchestrator всегда вызывает summary-prep после parser.

---

## Связь с другими ADR

- **DEC-0005** (Microservices): summary-prep — восьмой микросервис (после agent-caller, mail, attachment, parser, summary, orchestrator, state, compliance-logic). Логика по DEC-007 (Docker-friendly + systemd).
- **DEC-0007** (Deployment form): применяется без изменений — Python 3.10/3.11 + FastAPI + uvicorn + venv + systemd + EnvironmentFile в /etc/mail-stack/.
- **DEC-0008** (Parser-stack L1-L14): DEC-0030 не меняет parser. Parser остаётся "формат-уровень".
- **DEC-0009** (Summary Haiku): DEC-0030 переиспользует тот же LLM-стек (Haiku via OpenRouter), без новых провайдеров. Summary-service Implementation Notes: получает массив писем с DistillResult вместо raw text для длинных вложений.
- **DEC-0014** (Orchestrator Go custom): добавляется новый step `distill_attachments` в workflow `email_digest_v1`. Notes 23.06: реализация после деплоя summary-prep.
- **DEC-0021** (State-service): не затрагивается.
- **DEC-024** (Mail-stack v1.1 fixes): DEC-0030 закрывает **четвёртый класс входа** (длинный text-based PDF), не покрытый DEC-024.
- **DEC-0025** (Compliance Assistant architecture): Implementation Notes 23.06 — карта компонентов после деплоя summary-prep, 9 микросервисов.
- **DEC-0028** (Contract/Act vacuum): summary-prep станет потребителем compliance-logic в Phase 2 — с `contract_strictness=hard`.
- **DEC-029** (Two-product Mail Reader vs Compliance Helper, drafted май 2026): `quality_mode={fast,deep}` в summary-prep — задел под Compliance Helper контур.
- **DEC-035** (pre-MVP отказ от chunking, внутри DEC-024): **REVISITED, partially CLOSED** этим ADR. Двухуровневый map-reduce введён. Полный hierarchical и Unstructured-replacement остаются off-scope.

---

## Implementation tracking

Реализация:
1. Каркас сервиса `summary-prep/`: Dockerfile, requirements.txt, server.py, distill.py, schemas.py.
2. env-template `/etc/mail-stack/summary-prep.env.template` — `OPENROUTER_API_KEY`, `DISTILL_MODEL=anthropic/claude-haiku-4.5`, `DISTILL_CHAR_THRESHOLD=80000`, `DISTILL_CHUNK_CHARS=50000`, `DISTILL_MAX_RETRIES=2`, `DISTILL_CACHE_DIR=/var/lib/summary-prep/cache`, `DISTILL_CACHE_TTL_DAYS=30`, `SUMMARY_PREP_HTTP_HOST=127.0.0.1`, `SUMMARY_PREP_HTTP_PORT=8772`, `SUMMARY_PREP_API_KEY=...`.
3. systemd unit `deploy/systemd/summary-prep.service`.
4. Orchestrator workflow `email_digest_v1.go` — добавлен step `distill_attachments` между parse и summary (Go-half, working tree).
5. Summary-service `server.py` — контракт обновлён: принимает массив писем с DistillResult, использует `summary_brief` + `key_facts` + `requirements` для длинных, raw text для коротких.
6. Прогон на КЕБ-PDF и декларациях для верификации.

Параллельно с DEC-0030 реализуется bug-fix `_date_key` в mail-service (DEC-0007 Implementation Notes 23.06.2026) — нормализация naive→aware datetime после `parsedate_to_datetime` для писем с `Date: -0000` (Облако Mail).
