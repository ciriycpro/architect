# architect — Architecture-as-Code, СИРИУС ПРО

Архитектурные артефакты проектов СИРИУС ПРО как код: модели C4, журнал
архитектурных решений (ADR) и сервисные блюпринты в одном версионируемом репозитории.

Свидетельство Роспатент № 2026611550 (МАИФ).

## Что внутри
Два рабочих пространства Structurizr:

- **kamf/ — МАИФ** (kamf — историческое имя каталога). Открытый индустриальный стандарт
  мультиагентных систем СИРИУС ПРО. C4 на трёх уровнях (System Context, Container, Component).
- **tairov/ — Compliance Assistant.** Агентная система комплаенс-документооборота,
  развёрнута в production на GCP. C4 на трёх уровнях + 24 принятых ADR (DEC-0001…0030 с пропусками 0012, 0015, 0019, 0020, 0029) + DEC-0028 Drafted + cleanup_backlog_v2 + Service Blueprint.

## Методология
- C4 (Structurizr DSL) — workspace.dsl хранит текущее состояние архитектуры.
- ADR по Майклу Найгарду — decisions/*.md хранит историю решений с причинами,
  включая отменённые (Superseded / Cancelled).
- Service Blueprint по Линн Шостак — docs/*.md, процессная документация.
- Принцип Саймона Брауна: документация догоняет потребность, не предвосхищает её.

## Как читать
1. <workspace>/workspace.dsl — архитектура C4 (рендерится Structurizr Lite).
2. <workspace>/decisions/ — почему архитектура такая (ADR).
3. <workspace>/docs/ — Service Blueprint и техническая документация.

## Связанные репозитории
- github.com/ciriycpro/MAIF — стандарт МАИФ (спецификация + Go-референс). Вершина:
  то, что моделирует это рабочее пространство.
- github.com/ciriycpro/Compliance-Assistant — production-код системы, чью архитектуру
  описывает воркспейс tairov/ (Java/Spring + Python/FastAPI + Go + Node).

## Контакты
Артём Якшин, основатель СИРИУС ПРО · ciriyc.ru · inbox@ciriyc.ru · Telegram @Economexer
