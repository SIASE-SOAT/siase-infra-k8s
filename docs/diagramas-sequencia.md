# Diagramas de Sequencia — siase-infra-k8s

## 1. Fluxo de Deploy via CI/CD

```
Actor           GitHub Actions        ECR           EKS Cluster       ALB
  │                   │                │                 │              │
  │  push → main      │                │                 │              │
  │──────────────────►│                │                 │              │
  │                   │                │                 │              │
  │                   │ terraform fmt  │                 │              │
  │                   │ + validate     │                 │              │
  │                   │────────────────┤                 │              │
  │                   │                │                 │              │
  │                   │ AWS OIDC auth  │                 │              │
  │                   │────────────────┤                 │              │
  │                   │                │                 │              │
  │                   │ terraform apply│                 │              │
  │                   │ (VPC, EKS,     │                 │              │
  │                   │  Helm charts,  │                 │              │
  │                   │  SSM params)   │                 │              │
  │                   │────────────────┼────────────────►│              │
  │                   │                │                 │              │
  │                   │                │  EKS provisionado              │
  │                   │                │  Prometheus/Grafana/Loki       │
  │                   │                │  instalados via Helm           │
  │                   │◄───────────────┼─────────────────│              │
  │                   │                │                 │              │
  │                   │ kubectl apply  │                 │              │
  │                   │ (manifestos    │                 │              │
  │                   │  da aplicacao) │                 │              │
  │                   │────────────────┼────────────────►│              │
  │                   │                │                 │              │
  │                   │                │                 │ Ingress cria │
  │                   │                │                 │─────────────►│
  │                   │                │                 │              │
  │                   │ aws ssm put    │                 │  ALB DNS     │
  │                   │ (alb-dns)      │◄────────────────┼──────────────│
  │                   │────────────────┤                 │              │
  │                   │                │                 │              │
  │  Deploy concluido │                │                 │              │
  │◄──────────────────│                │                 │              │
```

## 2. Fluxo de Escalabilidade Automatica (HPA)

```
Pods siase-app    metrics-server       HPA Controller      EKS Scheduler
      │                 │                    │                    │
      │  CPU > 70%      │                    │                    │
      │────────────────►│                    │                    │
      │                 │                    │                    │
      │                 │  metricas de CPU   │                    │
      │                 │───────────────────►│                    │
      │                 │                    │                    │
      │                 │                    │ calcula replicas   │
      │                 │                    │ desejadas          │
      │                 │                    │                    │
      │                 │                    │ aguarda 60s        │
      │                 │                    │ (stabilization)    │
      │                 │                    │                    │
      │                 │                    │ scale up request   │
      │                 │                    │───────────────────►│
      │                 │                    │                    │
      │                 │                    │                    │ novo pod
      │◄────────────────┼────────────────────┼────────────────────│
      │                 │                    │                    │
      │  CPU < 70%      │                    │                    │
      │────────────────►│                    │                    │
      │                 │  metricas de CPU   │                    │
      │                 │───────────────────►│                    │
      │                 │                    │                    │
      │                 │                    │ aguarda 300s       │
      │                 │                    │ (stabilization)    │
      │                 │                    │                    │
      │                 │                    │ scale down request │
      │                 │                    │───────────────────►│
      │                 │                    │                    │
      │                 │                    │                    │ remove pod
      │◄───────────────────────────────────────────────────────── │
```

## 3. Fluxo de Coleta de Metricas e Logs

```
siase-app Pod    Grafana Alloy    Prometheus    Loki    Grafana
     │                │               │          │         │
     │  /actuator/    │               │          │         │
     │  prometheus    │               │          │         │
     │◄───────────────┼───────────────│          │         │
     │  metricas      │               │          │         │
     │────────────────┼──────────────►│          │         │
     │                │               │          │         │
     │  logs JSON     │               │          │         │
     │  (stdout)      │               │          │         │
     │───────────────►│               │          │         │
     │                │               │          │         │
     │                │ processa JSON │          │         │
     │                │ promove labels│          │         │
     │                │ (correlationId│          │         │
     │                │  subject)     │          │         │
     │                │───────────────┼─────────►│         │
     │                │               │          │         │
     │                │               │          │ query   │
     │                │               │◄─────────┼─────────│
     │                │               │          │◄────────│
     │                │               │          │         │
     │                │               │ metricas │         │
     │                │               │──────────┼──────── ►
     │                │               │          │  dashboard
     │                │               │          │  atualizado
```
