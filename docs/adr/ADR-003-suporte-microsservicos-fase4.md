# ADR-003 — Suporte aos Microsserviços da Fase 4 no Cluster EKS

**Status:** Aceito
**Data:** 2025-01
**Repositório:** siase-infra-k8s

## Contexto

A Fase 4 decompõe o monólito em três microsserviços independentes (`siase-os-service`, `siase-billing-service`, `siase-execution-service`), cada um com seu próprio banco de dados e participando do Saga Coreografado via SQS. O cluster EKS provisionado na Fase 3 precisa suportar este novo modelo sem alterações estruturais na infraestrutura.

## Decisão

Reutilizar o cluster EKS da Fase 3 para hospedar os três microsserviços da Fase 4, com as seguintes adaptações:

### Namespace e isolamento

- Os três microsserviços são implantados no namespace `siase`, junto com a aplicação monolítica legada (que permanece para referência).
- Cada microsserviço tem seu próprio `Deployment`, `Service` e `HorizontalPodAutoscaler`.

### Acesso ao SQS e DynamoDB (IRSA)

- As policies IAM provisionadas pelo `siase-infra-messaging` são anexadas às roles IRSA de cada service account.
- Cada pod acessa apenas as filas e tabelas que lhe competem (menor privilégio).
- **Restrição do Learner Lab**: o OIDC provider customizado não está disponível no AWS Academy. As credenciais AWS são injetadas via `secretRef` no Deployment como variáveis de ambiente (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`).

### Observabilidade dos microsserviços

- Cada microsserviço expõe `/actuator/prometheus` na porta de management (8081).
- O `ServiceMonitor` existente é estendido para cobrir os três novos serviços.
- A métrica `siase_saga_eventos_total{servico,evento,direcao}` permite rastrear o fluxo do Saga no Grafana.
- O `correlationId` é propagado via header HTTP `X-Correlation-Id` e message attribute SQS, permitindo correlação ponta a ponta nos logs do Loki.

### Portas dos serviços

| Serviço | Porta App | Porta Management |
|---|---|---|
| siase-os-service | 8081 | 8081 (via `/actuator`) |
| siase-billing-service | 8082 | 8082 (via `/actuator`) |
| siase-execution-service | 8083 | 8083 (via `/actuator`) |

## Alternativas Consideradas

| Alternativa | Motivo da Rejeição |
|---|---|
| Cluster EKS separado por microsserviço | Custo proibitivo no Learner Lab; complexidade desnecessária |
| Namespaces separados por microsserviço | Complexidade adicional sem benefício para o escopo do trabalho |
| ECS Fargate para os microsserviços | Inconsistência com a infraestrutura já provisionada na Fase 3 |

## Consequências

- **Positivo**: reutilização total da infraestrutura da Fase 3 — sem custo adicional de cluster
- **Positivo**: stack de observabilidade (Prometheus, Grafana, Loki, Alloy) já disponível para os microsserviços
- **Negativo**: restrição do Learner Lab impede uso de IRSA nativo — credenciais temporárias precisam ser renovadas manualmente a cada sessão de 4h
- **Mitigação**: o CI/CD atualiza os secrets do GitHub a cada sessão; os pods são reiniciados com as novas credenciais via `kubectl rollout restart`
