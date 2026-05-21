# Architecture Workspace — СИРИУС ПРО

Репозиторий для архитектурных артефактов (C4 + ADR + Service Blueprint) проектов СИРИУС ПРО.
Свидетельство Роспатент № 202661155

## Точка входа для AI-ассистента

Если ты — новая сессия Claude/Сlaude Code/GLM etc., и тебе только что дали ссылку на этот репо, читай в таком порядке:
1. **Этот файл** — общий контекст и текущее состояние
2. **`<workspace>/STATUS.md`** — детали по конкретному воркспейсу (если есть)
3. **`<workspace>/workspace.dsl`** — архитектура C4
4. **`<workspace>/decisions/`** — история архитектурных решений (ADR)
5. **`<workspace>/docs/`** — Service Blueprint и техническая документация

**Связанные репозитории:**
- **https://github.com/ciriycpro/Compliance-Assistant** — production-код 7 микросервисов mail-stack (зеркало `/opt/mail-stack/` на coo). Зайди туда когда нужно посмотреть актуальный код orchestrator / state-service / mail-stack Python-сервисов / agent-caller.

### Как читать код из Compliance-Assistant без беготни через пользователя

**Правильно (не дёргать Артёма):**

```bash
# Один раз в начале сессии — shallow clone (~10 МБ, секунды):
cd /tmp && git clone --depth 1 https://github.com/ciriycpro/Compliance-Assistant.git

# Потом читать только нужное:
cat /tmp/Compliance-Assistant/orchestrator/workflow/email_digest_v1.go
grep -A 5 "lock_held" /tmp/Compliance-Assistant/orchestrator/workflow/*.go
view /tmp/Compliance-Assistant/agent-caller/server.js
```

**НЕ грузи весь репо в контекст** — он 3+ МБ, разорит токен-бюджет. Клон лежит у тебя на диске, читай файлы поштучно через `cat` / `view` / `grep` когда **конкретно** нужны.

**Антипаттерн — просить Артёма:** "покажи содержимое X на coo" — не нужно. Все production-файлы доступны в репо. Запроси у пользователя только если файл явно отсутствует (например свежее изменение которое ещё не запушено кнопкой `sync-code-from-coo.command`).

### Кнопка `sync-code-from-coo.command` на маке

На рабочем столе Артёма есть скрипт-кнопка которая делает `gcloud compute ssh coo` → `git add/commit/push` из `~/compliance-assistant-repo/` → актуальный snapshot улетает на GitHub. Если код в репо отстаёт от того что Артём делал на coo последние 5 минут — попроси его двойным кликом нажать кнопку.

## Протокол синхронизации артефактов через git-патчи

Когда новая сессия Claude помогает с обновлением архитектурных артефактов (ADR, DSL, docs), используется единый протокол: **один `.patch` файл, одна команда применения на стороне человека**. Это сложилось практикой с 09.05.2026 и применяется во всех последующих sync-итерациях.

### Как Claude готовит патч

```bash
# В своей среде:
git clone https://github.com/ciriycpro/architect.git
cd architect
git config user.email "claude@anthropic.com"
git config user.name "Claude (sync DD.MM.YYYY)"

# Вносит правки в файлы (новые ADR, append к существующим, обновление DSL)
# Коммитит с осмысленным сообщением

git commit -m "Заголовок коммита

Описание блоками — что добавлено / обновлено / решено.
"

# Генерирует один файл-патч с заголовком коммита внутри:
git format-patch -1 --output=/mnt/user-data/outputs/sync-DDMMYYYY-краткое-описание.patch

# ОБЯЗАТЕЛЬНО самопроверка на чистом клоне:
cd /tmp && git clone https://github.com/ciriycpro/architect.git verify && cd verify
git apply --check /path/to/patch  # должен вернуть 0
git am /path/to/patch              # должен применить чисто
```

Файл отдаётся пользователю одной ссылкой `present_files`.

### Как пользователь применяет

**ВАЖНО для AI-сессии:** локальный клон у Артёма лежит в `~/dev/architecture/` (не `~/architect`, не `~/Documents/...`, не угадывать). Если в новой сессии путь неизвестен — **не гадать**, спросить или искать в истории прежних чатов.

Канонический поток (Артём, мак):

```bash
cd ~/dev/architecture
git pull origin main
git am < ~/Downloads/sync-DDMMYYYY-XXX.patch
```

После этого — **двойной клик `~/Desktop/sync-dsl.command`** (это shell-скрипт-кнопка, делает `git add . && git commit && git push`). Изменения улетают на GitHub.

Альтернатива без кнопки — финальная команда вручную:

```bash
git push origin main
```

**Заголовок коммита уже внутри `.patch`** — отдельно `git commit -m "..."` писать не нужно. Это даёт `git am`.

### Если несколько патчей за раз

```bash
cd ~/dev/architecture
git pull origin main
git am < ~/Downloads/sync-DDMMYYYY-A.patch
git am < ~/Downloads/sync-DDMMYYYY-B.patch
```

После — двойной клик `~/Desktop/sync-dsl.command` (или `git push origin main`).

Каждый патч = один коммит. Применяются последовательно.

### Куда падают .patch файлы при скачивании

`~/Downloads/` — стандартная папка Safari/Chrome на маке. Когда Claude отдаёт файл через `present_files`, Артём кликает по нему в чате — файл скачивается именно туда.

### Кнопка для синхронизации кода с coo

Production-код в `Compliance-Assistant` репо обновляется через отдельную кнопку на маке:

**`~/Desktop/sync-code-from-coo.command`** — ssh на coo, делает `git add/commit/push` из `~/compliance-assistant-repo/`. Двойной клик → актуальный snapshot production-кода улетает на GitHub.

### Именование патчей

`sync-DDMMYYYY-<короткое описание>.patch`

Примеры из истории:
- `sync-09052026.patch` — первая итерация sync
- `sync-13052026-dec014-orchestrator.patch` — отдельный ADR
- `sync-13052026-v1.0-implemented.patch` — отметка реализации
- `sync-14052026-dec022-springboot-option.patch` — обновление существующего ADR
- `sync-16052026-dec013-dec021-v1.2.2.patch` — несколько ADR в одном патче
- `sync-16052026-readme-sync-protocol.patch` — обновление README с протоколом
- `sync-16052026-readme-paths-and-button.patch` — конкретизация путей и push-кнопки

### Что НЕ делать (антипаттерны)

- ❌ **Гадать путь к клону.** У Артёма `~/dev/architecture/`. Если новый пользователь — спросить, не предполагать `~/architect` или `~/Documents/...`.
- ❌ Отдавать несколько отдельных `.md` файлов и просить руками скопировать в репо
- ❌ Просить пользователя писать `git add` + `git commit` самостоятельно — заголовок коммита уже в `.patch`
- ❌ Архивы с инструкциями `cp` / `cat >> file` — это шаг назад от git-протокола
- ❌ Раздельные патчи без необходимости — если изменения логически связаны, один патч лучше двух
- ❌ **Команды с inline-комментариями** типа `cd ~/architect  # или твой путь` — zsh интерпретирует `#` непредсказуемо, плюс лишние слова сбивают пользователя. Команда должна быть **точная и пригодная к копи-пейсту одной строкой**.

### Если конфликт при применении

```bash
git am --abort                              # откат
git apply --check /path/to/patch            # проверка точки рассинхрона
git apply --3way /path/to/patch             # с автомерджем
# если всё ещё конфликт — править вручную и:
git add -A && git commit -m "Sync ..."
```

## Текущие воркспейсы

### `kamf/` — мультиагентный фреймворк KAMF
Основной R&D-проект СИРИУС ПРО. Свидетельство Роспатента №2026611550.
- C4: 3 уровня (System Context, Container, Component для Orchestrator)
- ADR: пока не оформлены
- Status: архитектура спроектирована, MVP-кода нет

### `tairov/` — compliance assistant для ИП Таирова
Production v1.2.2. Автоматизация документооборота через email digest.
- C4: 3 уровня (System Context, Container, Component)
- ADR: 19 решений (DEC-001 ... DEC-024), последние v1.2.x — DEC-013 (incremental + event-driven progress) + DEC-021 (state-service)
- Status: 7 микросервисов на coo в production. Cron ежедневно в 10:00 МСК. Кнопка on-demand у пользователя.
- Production-код: https://github.com/ciriycpro/Compliance-Assistant

### `test/` — учебная песочница
Не использовать. Тестовые DSL-файлы.

## Текущий фокус (16.05.2026)

- **Tairov в production**: Compliance Assistant работает. Orchestrator v1.2.2 + state-service v1.0 + 5 микросервисов на coo. Cron 10:00 МСК ежедневно, кнопка у Таирова активна.
- **Production-код**: зеркало в отдельном репо `ciriycpro/Compliance-Assistant` — для AI-сессий доступен код всех 7 сервисов параллельно с архитектурой.
- **Следующее**: DEC-026 multi-tenant (параллельный mail-service для второго клиента), DEC-023 Compliance Logic Layer (Spring Boot business-tier).

## Контекст работы с архитектурой

### Связка артефактов
- **`workspace.dsl`** = текущее состояние архитектуры (рендерится Structurizr Lite)
- **`decisions/*.md`** = история решений с причинами (ADR, методология Майкла Найгарда)
- **`docs/*.md`** = процессная документация (Service Blueprint по Шостак, не CJM)
- **`STATUS.md`** = операционный снимок (что работает / в работе / pending)

### Как обновлять при разворотах архитектуры
1. Поправить `workspace.dsl` под новое состояние
2. Создать новый `decisions/000N-*.md` с причиной разворота
3. Если процесс затронут — обновить Service Blueprint в `docs/`
4. Обновить `STATUS.md`

### Принципы
- DSL хранит только **текущее** состояние, не историю
- ADR хранит **всю** историю, включая отменённые решения (статус `Cancelled` или `Superseded by`)
- Документация догоняет потребность, не предвосхищает (Саймон Браун)

## Контакты владельца

- Артём Якшин, основатель СИРИУС ПРО
- Сайт: ciriyc.ru
- Email: inbox@ciriyc.ru
- Telegram: @Economexer
