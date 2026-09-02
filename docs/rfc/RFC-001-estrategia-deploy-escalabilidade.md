# RFC-001 — Estrategia de Deploy e Escalabilidade no EKS

**Status:** Implementado
**Data:** 2026
**Repositorio:** siase-infra-k8s

## Resumo

Este documento descreve a estrategia de deploy da aplicacao SIASE no EKS, incluindo a configuracao do HPA, as probes de saude, o fluxo de CI/CD e as decisoes de rede.

## Arquitetura de Deploy

```
GitHub Actions (CI/CD)
        │
        ▼
  Build + Test
        │
        ▼
  Docker Build + Push → ECR
        │
        ▼
  terraform apply (siase-infra-k8s)
        │
        ▼
  kubectl apply (manifestos da aplicacao)
        │
        ▼
  ALB Ingress → EKS → Pods siase-app
```

## Horizontal Pod Autoscaler (HPA)

O HPA monitora o consumo medio de CPU dos pods e escala automaticamente:

| Parametro                    | Valor   |
|------------------------------|---------|
| Minimo de replicas           | 2       |
| Maximo de replicas           | 4       |
| Gatilho de scale up          | CPU > 70% |
| Janela de estabilizacao up   | 60s     |
| Janela de estabilizacao down | 300s    |

A janela de scale down de 300s evita flapping em picos curtos de carga.

## Probes de Saude

A aplicacao expoe endpoints dedicados via Spring Boot Actuator na porta de management (8081):

| Probe       | Endpoint                              | Delay Inicial | Periodo |
|-------------|---------------------------------------|---------------|---------|
| Readiness   | `/actuator/health/readiness` (8081)   | 60s           | 15s     |
| Liveness    | `/actuator/health/liveness` (8081)    | 90s           | 30s     |

O uso de porta separada (8081) para management garante que o ALB nao exponha os endpoints de saude e metricas publicamente.

## Estrategia de Rede

- **Subnets publicas:** nodes EKS e ALB. As subnets publicas tem `map_public_ip_on_launch = true` para o Learner Lab (sem NAT Gateway).
- **Subnets privadas:** RDS PostgreSQL e Lambda de autenticacao.
- **NAT Gateway:** desabilitado nesta entrega para reducao de custo no Learner Lab. Em producao real, os nodes devem estar em subnets privadas com NAT.
- **VPC Endpoint para Secrets Manager:** provisionado para que a Lambda (em subnet privada) acesse o Secrets Manager sem trafegar pela internet.

## Recursos de Compute

| Recurso    | Request  | Limit    | Justificativa                                      |
|------------|----------|----------|----------------------------------------------------|
| CPU        | 250m     | 500m     | Suficiente para carga media; HPA escala horizontalmente |
| Memoria    | 512Mi    | 768Mi    | JVM com `-XX:MaxRAMPercentage=75.0` respeita o limite |

## Ordem de Aplicacao dos Repositorios

1. `siase-infra-k8s` — cria VPC, EKS, stack de observabilidade e publica parametros SSM.
2. `siase-infra-database` — le parametros SSM do passo 1 e cria o RDS.
3. `siase-auth-lambda` — le parametros SSM dos passos 1 e 2 e cria as Lambdas e o API Gateway.
4. `15SOAT` — aplica os manifestos Kubernetes da aplicacao no cluster criado no passo 1.

## Consideracoes de Seguranca

- O endpoint do cluster EKS tem `endpoint_private_access = true`, permitindo acesso interno dos nodes.
- O RDS nao e publicamente acessivel (`publicly_accessible = false`).
- O acesso ao banco e restrito ao Security Group `db-clients`, associado apenas aos nodes EKS e a Lambda.
- Secrets sao injetados nos pods via `secretRef` (Kubernetes Secret), nunca em variaveis de ambiente hardcoded.
