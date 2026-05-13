# DEC-016 — Kubernetes-friendly deployment manifests for mail-stack

## Status

Accepted (13.05.2026) — реализация запланирована **после DEC-014 (оркестратор)**, в одной фазе подготовки production-grade артефактов.

## Context

Mail-stack v1 запущен на одном инстансе coo через systemd. Это работает для **первого клиента (Таиров)**, но не масштабируется на:

- Второго-десятого клиента (нужна изоляция per-tenant)
- Развёртывание на другой инфраструктуре (GKE, EKS, любой managed K8s)
- Recovery после полного отказа coo (восстановление = воспроизведение systemd-юнитов вручную, нет declarative описания)
- Демонстрацию архитектуры на собеседованиях AI Architect

Также есть **карьерный сигнал**: возможность сказать «**развернул mail-stack как декларативные K8s-манифесты, тестируется на minikube, готов к GKE**» — это senior-уровень, не «развернул через systemd скрипты».

## Decision

Написать **РАБОЧИЕ** Kubernetes manifests для mail-stack как **deployment artifacts** в репо. Не псевдокод-заглушки, а реально применяемые на minikube/kind YAML, поднимающие полный стек.

**Ключевое:** манифесты живут в git как **артефакты будущей реализации**, не как production-конфиг текущей инсталляции. Текущий продакшен (Таиров) остаётся на systemd на coo. K8s-манифесты применяются для:

1. **Тестирования архитектуры локально** на minikube (`kubectl apply -f deploy/kubernetes/`)
2. **Развёртывания на managed K8s** (GKE/EKS) на v3 для мульти-клиентов
3. **Документации** — это «как сейчас выглядит распределённая mail-stack»

### Структура

```
deploy/kubernetes/
├── namespace.yaml                     # mail-stack namespace
├── secrets.yaml.example               # шаблон для OPENROUTER_API_KEY и IMAP creds
├── configmap.yaml                     # SUMMARY_TEMPERATURE, PARSE_THRESHOLD и т.д.
├── pvc.yaml                           # PersistentVolumeClaim для /var/lib/mail-stack/attachments
├── network-policy.yaml                # NetworkPolicy: только orchestrator → микросервисы
├── mail-service/
│   ├── deployment.yaml                # 1 replica, resources, healthcheck, secrets refs
│   └── service.yaml                   # ClusterIP, port 8765
├── attachment-service/
│   ├── deployment.yaml                # 1 replica + volume mount PVC
│   └── service.yaml                   # ClusterIP, port 8766
├── parser-service/
│   ├── deployment.yaml                # 1 replica + volume mount PVC read-only
│   └── service.yaml                   # ClusterIP, port 8767
├── summary-service/
│   ├── deployment.yaml                # 2-3 replicas (stateless transformer)
│   └── service.yaml                   # ClusterIP, port 8768
└── orchestrator/                      # для оркестратора по DEC-014
    ├── deployment.yaml
    └── service.yaml
```

~17 файлов, ~300 строк YAML.

### Принципы (применяемые во всех манифестах)

**Каждое решение DEC-017 «Secure by design Уровень 0» встроено сразу:**

- ✅ **runAsNonRoot: true** + **runAsUser: 1000** — никаких процессов под root в подах
- ✅ **readOnlyRootFilesystem: true** для всех контейнеров где не нужна запись (mail/summary)
- ✅ **resources: limits + requests** на всех — защита от DoS и для honest scheduling
- ✅ **Secrets через Kubernetes Secrets API** (не envFrom configMap для секретов)
- ✅ **NetworkPolicy** — orchestrator → mail/attachment/parser/summary, всё остальное запрещено
- ✅ **Liveness + Readiness probes** на /health endpoint каждого сервиса
- ✅ **Resource requests** реалистичные на основе production-метрик: mail-service 50Mi, attachment 50Mi, parser 100Mi, summary 50Mi
- ✅ **Image pull policy: Always** для production (имя :latest никогда не используется, всегда :git-sha-tag)
- ✅ **Pod anti-affinity** для summary-service (если 2+ replicas — на разные ноды)
- ✅ **TopologySpreadConstraints** для multi-AZ когда дойдём до GKE

### Что НЕ делаем на v1

- ❌ Helm-чарты (over-engineering для нашего размера)
- ❌ Kustomize overlays (per-tenant — на v3)
- ❌ ServiceMesh (Istio/Linkerd) — на v3 после второго клиента
- ❌ Operator-pattern (custom resources) — over-engineering
- ❌ Argo CD / FluxCD — на v3 для GitOps

### Тестирование

Манифесты **должны быть проверены** локально перед коммитом в репо:

```bash
# На маке через kind или minikube
kind create cluster --name mail-stack
kubectl apply -f deploy/kubernetes/
kubectl get pods -n mail-stack
# Все поды должны быть Running, healthcheck зелёный
kubectl logs -f -n mail-stack -l app=summary-service
```

Если манифесты не запускаются — не коммитим, фиксим. **Артефакт = production-grade**, не «когда-нибудь доделаем».

## Consequences

**Плюсы:**

- ✅ Declarative описание архитектуры в git — единый source of truth
- ✅ Воспроизводимость — `kubectl apply` на чистой ноде поднимает стек за 5 минут
- ✅ Готовность к мульти-клиентам через namespace-per-tenant на v3
- ✅ Карьерный сигнал AI Architect — настоящий K8s в портфолио, не «писал на словах»
- ✅ Secure by design «Уровень 0» применяется сразу при написании каждого манифеста

**Минусы:**

- ❌ Дополнительная работа сейчас (~40 минут) — не критично
- ❌ Манифесты могут устареть относительно реальной production-инсталляции (она на systemd). Митигация: на v3 при миграции на GKE — манифесты становятся primary, systemd-юниты архивируются
- ❌ Тестирование требует minikube/kind локально — но это стандарт индустрии, минимальная цена входа

**Открытые вопросы для v2-v3:**

- **Helm-чарты** при росте per-tenant конфигурации (на 5+ клиентах)
- **Kustomize overlays** для dev/staging/prod различий (на v3)
- **Argo CD / FluxCD** для GitOps-deployment (после CI/CD-пайплайна)
- **Service Mesh (Istio)** для mTLS и observability (на v3, после второго клиента)
- **HPA (Horizontal Pod Autoscaler)** для summary-service на основе CPU/memory metrics
- **VPA (Vertical Pod Autoscaler)** для рекомендаций по resources на основе actual usage

**Стратегический сигнал:** K8s-манифесты — это **архитектурный артефакт**, не «деплоймент tool». Они описывают как mail-stack устроен и как взаимодействует **независимо от платформы**. Через год при переходе на GKE/EKS — манифесты применяются как есть. Сейчас они **документация в коде**, через год — **production-deployment**.

## Время реализации

~40 минут после оркестратора (DEC-014). Не блокирует демо вечером Таирова (демо идёт на systemd-стеке).
