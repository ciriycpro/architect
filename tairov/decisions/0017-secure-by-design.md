# DEC-017 — Secure by Design для mail-stack: roadmap по уровням

## Status

Accepted (13.05.2026). **Реализация поэтапная**: Уровень 0 — встраивается в каждый следующий шаг кода начиная с DEC-014 (оркестратор) и DEC-016 (K8s manifests). Уровни 1-3 — на горизонте недель.

## Context

Mail-stack обрабатывает чувствительные данные ИП Таирова:

- **Персональные данные** (отправители писем, контрагенты, ФИО)
- **Платёжные документы** (счета, договоры, акты, банковские реквизиты)
- **Юридические документы** (иски, требования ФНС, постановления судов)

Для **B2B-продукта в РФ** это требует:

1. **152-ФЗ** — закон о персональных данных. Обработка ПДн без согласия и без соответствия = штрафы до 18 млн руб (новая редакция).
2. **HSM/Secrets management** — API-ключи OpenRouter в env-файлах plain-text — это **не production-grade** даже для одного клиента.
3. **Защита от path traversal / injection** — `/parse` endpoint принимает путь к файлу. Если кто-то получит доступ к localhost — может прочитать любой файл на сервере. Critical уязвимость.

Принцип «**secure by design**» означает: безопасность вшита в архитектуру **с самого начала**, не «прикручивается потом».

«Прикручивается потом» = **минимум в 10 раз дороже** чем «вшито с начала». Каждая retrofit-итерация требует:
- Полного code review всех сервисов
- Изменения контрактов API
- Миграции данных (если изменилось шифрование)
- Обучения пользователей новым процедурам

Лучше **по микро-шагу** на каждом этапе разработки, чем «security project» через год.

## Decision

Принять **поэтапный roadmap безопасности** разделённый на 4 уровня. Каждый уровень — отдельный sub-ADR при реализации (`0017-1-...`, `0017-2-...`, `0017-3-...`, `0017-4-...`), чтобы не плодить мегадокумент.

### Уровень 0 — Минимум сегодня (на демо вечером 13.05.2026)

Уже есть:
- ✅ Все микросервисы слушают **только 127.0.0.1** — недоступны извне coo
- ✅ env-файлы **chmod 600 root:root** — читает только root
- ✅ Файрвол GCP — открыт только SSH (22), N8N через VPN
- ✅ Сервисы под пользователем `iakshin77`, не под root

**Добавить за 30 минут перед демо:**

1. **Input validation на `/parse` path** в parser-service:
   ```python
   ALLOWED_PREFIX = "/var/lib/mail-stack/attachments/"
   if not str(path).startswith(ALLOWED_PREFIX):
       raise HTTPException(403, "path outside allowed dir")
   if ".." in str(path):
       raise HTTPException(403, "path traversal detected")
   ```
   Защита от: «прочитай мне /etc/passwd через POST /parse».

2. **Rate limit на все endpoints** через slowapi (~10 строк на сервис):
   ```python
   from slowapi import Limiter
   limiter = Limiter(key_func=get_remote_address)
   @limiter.limit("60/minute")  # mail-service
   @limiter.limit("30/minute")  # parser-service (дороже на LLM)
   @limiter.limit("20/minute")  # summary-service
   ```
   Защита от: DoS через flood `/summary` → разорят OpenRouter-баланс.

3. **CORS-policy** — закрыт по дефолту, разрешён только origin оркестратора:
   ```python
   from fastapi.middleware.cors import CORSMiddleware
   app.add_middleware(CORSMiddleware, allow_origins=["http://orchestrator:8769"])
   ```
   Защита от: cross-origin запросы из браузеров пользователей.

**Стоимость:** ~30 минут, ~30 строк кода на 4 сервиса. Делается **в одной фазе** с оркестратором.

### Уровень 1 — Внутренняя сеть (на этой неделе)

**API-ключи между микросервисами.** Каждый сервис проверяет `X-API-Key` header:

```python
@app.middleware("http")
async def auth(request, call_next):
    if request.headers.get("X-API-Key") != SERVICE_API_KEY:
        return JSONResponse(status_code=401, content={"error": "unauthorized"})
    return await call_next(request)
```

Защита от: компрометация одного сервиса не даёт автоматического доступа к другим. Каждый сервис генерирует свой API-key, хранит в env, проверяет у входящих.

**mTLS между сервисами через localhost** (self-signed CA на coo):
- Генерируем CA через `openssl`
- Каждый сервис получает свой сертификат + ключ
- httpx-клиент в оркестраторе использует CA для верификации
- uvicorn запускается с `--ssl-certfile + --ssl-keyfile`

Защита от: man-in-the-middle на localhost (если кто-то получит доступ через iptables к loopback).

**Структурированный audit log:**
- Отдельный systemd-юнит `mail-stack-audit` принимает structured logs через journald
- Каждый «значимый» вызов (parse, summary, telegram-message) пишет JSON-запись: `{timestamp, service, action, user_id, parameters_hash, outcome}`
- Logrotate на 30 дней + сжатие
- На v2 — пересылка в SIEM (Splunk/ELK)

Защита от: невозможность реконструировать инцидент. **152-ФЗ требует** audit log для обработки ПДн.

**Стоимость:** ~3-4 часа работы. Делается после стабилизации оркестратора.

### Уровень 2 — Secrets management (на следующей неделе)

**HashiCorp Vault в Docker на coo:**
- Vault поднимается как ещё один Docker-контейнер
- env-файлы заменяются на `vault read secret/mail-stack/openrouter_api_key`
- Каждый сервис получает свой Vault-token (не shared)
- Audit log Vault — отдельный канал для security-инцидентов

Защита от: компрометация хоста coo не даёт автоматического доступа к ключам.

**Ротация ключей OpenRouter:**
- Скрипт `rotate-secrets.sh` раз в 30 дней генерирует новый ключ через OpenRouter API
- Атомарная замена в Vault + рестарт затронутых сервисов
- Старый ключ remains valid 24 часа (graceful rotation)

Защита от: длительное время жизни секрета увеличивает поверхность атаки.

**Шифрование attachments at-rest через `age`:**
- Современный (2019) PGP-заменитель, рекомендован для production
- Каждый attachment шифруется при сохранении в `/var/lib/mail-stack/attachments/`
- Parser-service расшифровывает при чтении
- Master-key в Vault

Защита от: получение доступа к диску coo не даёт автоматического доступа к содержимому документов.

**Стоимость:** ~6-8 часов работы. Делается после первой стабильной недели работы Mail Check On-Demand workflow.

### Уровень 3 — Production-grade (перед вторым клиентом)

**Threat model formal (STRIDE-методология):**
- **S**poofing — может ли кто-то выдать себя за легитимный сервис?
- **T**ampering — может ли модифицировать данные в transit или at-rest?
- **R**epudiation — может ли отказаться от факта совершения действия?
- **I**nformation disclosure — какие данные могут утечь и куда?
- **D**enial of Service — DoS-векторы и митигации
- **E**levation of privilege — может ли получить больше прав чем должно?

Документ ~20-30 страниц с матрицей угроз и митигаций. Обязательное чтение перед PenTest.

**Penetration testing:**
- Вариант A: внутренний — Артём + Claude симулируют атаки по threat model
- Вариант B: внешний — bug bounty через HackerOne / Bug Bash (стоимость ~50-200к руб)
- Документация уязвимостей + план патчей

**152-ФЗ compliance audit** для обработки ПДн в РФ:
- Согласие на обработку у клиента
- Реестр операторов ПДн (уведомление в Роскомнадзор)
- Технические меры защиты (СЗИ / СКЗИ от ФСТЭК?)
- Контракт DPA (Data Processing Agreement) с клиентом

**Backups с шифрованием:**
- Daily snapshot `/var/lib/mail-stack/` в encrypted-формате
- Replicate в облако (GCS Coldline) с другой регионом
- Recovery testing — раз в месяц **реально восстановить** из backup в test-окружении

**Стоимость:** ~1-2 недели работы. Делается **перед привлечением второго клиента**, не «когда-нибудь».

## Decision — что делаем сейчас в каждом следующем шаге

### При написании оркестратора (DEC-014 — Go или N8N) — сразу:

- ✅ **API-key между оркестратором и микросервисами** (Уровень 1, частично)
- ✅ **Rate limit на webhook /digest-now** через slowapi (защита от спама извне)
- ✅ **Path traversal validation** если оркестратор передаёт пути в parser
- ✅ **Audit log структурированный** с самого начала, не «потом»
- ✅ **Cors policy** для Telegram-callback'ов

### При написании K8s manifests (DEC-016) — сразу:

- ✅ **NetworkPolicy** — только orchestrator может звонить mail/attachment/parser/summary, всё остальное запрещено
- ✅ **readOnlyRootFilesystem: true** где можно (mail, summary)
- ✅ **runAsNonRoot: true** + **runAsUser: 1000** на всех контейнерах
- ✅ **Secrets через Kubernetes Secrets API** (не envFrom configMap для секретов)
- ✅ **Resource limits на всех** (защита от DoS и от runaway pods)
- ✅ **Pod Security Standards** в namespace: restricted profile
- ✅ **seccompProfile: RuntimeDefault** для всех контейнеров

### При multi-account email — сразу:

- ✅ **Credentials в отдельном Secret per-account** (mail-service-icloud-secret, mail-service-gmail-secret и т.д.)
- ✅ **Каждый mail-service-instance видит только свой Secret** (RBAC в K8s + ServiceAccount)
- ✅ **Audit log per-account** — можно отследить какой аккаунт когда обращался
- ✅ **Separate API-keys** — компрометация одного не даёт доступа к другим

## Consequences

**Плюсы:**

- ✅ Безопасность вшита **с момента написания каждого нового кирпича**, не retrofit потом
- ✅ 152-ФЗ compliance планируется заранее — не блокирует второго клиента
- ✅ Карьерный сигнал AI Architect — реальное понимание enterprise-grade security, не «слышал что есть Vault»
- ✅ Поэтапный подход — нет «security project на месяц». Каждая итерация даёт измеримое улучшение
- ✅ Документация уязвимостей и митигаций — argument для клиентов в SLA

**Минусы:**

- ❌ +10-20% времени на каждый новый кирпич (Уровень 0 каждый раз)
- ❌ Сложность кода растёт — auth, rate limits, audit. Митигация: extract common middleware в shared lib
- ❌ Vault — ещё один компонент в стеке (RAM + Operational complexity). Митигация: Vault в Docker контейнере, ~50 МБ RAM
- ❌ Penetration testing стоит денег или времени. Митигация: внутренний PenTest на v3, внешний на v4 при росте до 10+ клиентов

**Открытые вопросы:**

- **Когда переходить на K8s Secrets / Vault?** Триггер: переход с systemd на K8s (после DEC-016 в production)
- **Когда нужен HSM** (Hardware Security Module)? На v3 при работе с банковскими ключами или биллингом
- **152-ФЗ — оператор ПДн или нет?** Юридический вопрос на консультацию. Если обрабатываем для Таирова (его данные о его клиентах) — могут применяться dual-tenant требования
- **DLP (Data Loss Prevention) системы** — нужны ли на v3? Защита от случайной утечки ПДн в чат или email
- **Soc2 / ISO 27001 сертификация** — на v4 для enterprise-клиентов

**Стратегический сигнал:** Mail-stack для МСП — это **B2B SaaS обработка чувствительных данных**. Без secure-by-design это **тикающая бомба** (один инцидент с утечкой документов клиента = конец репутации продукта). С secure-by-design **с первого дня** — это **дифференциатор** в РФ-рынке где большинство SaaS-стартапов игнорируют 152-ФЗ до первого штрафа.

Применение принципа **«security как фича продукта»** для B2B-клиентов: «У нас все секреты в Vault, mTLS между сервисами, audit log на 90 дней, 152-ФЗ compliance — официально оператор ПДн». Это **продаётся** МСП-клиентам с серьёзным документооборотом, не «у нас open source ничего платить не надо».

## План реализации

| Уровень | Триггер | Время | Sub-ADR |
|---|---|---|---|
| **Уровень 0** | DEC-014 + DEC-016 — встраивается в каждый шаг | +30 мин/сервис | 0017-1-level-0-baseline.md |
| **Уровень 1** | После DEC-014 оркестратора, до DEC-016 K8s | ~3-4 часа | 0017-2-level-1-internal-network.md |
| **Уровень 2** | После 1 недели стабильной работы | ~6-8 часов | 0017-3-level-2-secrets-management.md |
| **Уровень 3** | Перед привлечением второго клиента | 1-2 недели | 0017-4-level-3-production-grade.md |

**Каждый sub-ADR пишется при начале фактической работы над уровнем**, не сейчас.
