# ADR-001 — Escolha do EKS como Plataforma de Orquestracao

**Status:** Aceito
**Data:** 2026
**Repositorio:** siase-infra-k8s

## Contexto

A aplicacao SIASE precisa de uma plataforma de orquestracao de containers que suporte escalabilidade automatica (HPA), alta disponibilidade, deploy automatizado via CI/CD e integracao com o ecossistema AWS (IAM, ALB, Secrets Manager).

## Decisao

Adotar **Amazon EKS** (Elastic Kubernetes Service) como plataforma de orquestracao, com managed node group em duas zonas de disponibilidade.

## Justificativa

- **Kubernetes padrao:** EKS executa Kubernetes upstream sem modificacoes proprietarias, garantindo portabilidade dos manifestos.
- **Managed node group:** a AWS gerencia patches do sistema operacional e atualizacoes dos nodes, reduzindo overhead operacional.
- **Integracao nativa com AWS:** VPC CNI e suportado nativamente. IRSA e AWS Load Balancer Controller sao suportados pelo EKS, mas nao utilizados neste projeto devido a restricoes do AWS Academy Learner Lab (ausencia de permissao para criar IAM roles e OIDC provider customizados).
- **HPA nativo:** o Horizontal Pod Autoscaler do Kubernetes escala os pods da aplicacao com base em CPU/memoria, sem necessidade de ferramentas adicionais.
- **Ecossistema de observabilidade:** compativel com kube-prometheus-stack, Loki e Grafana Alloy para coleta de metricas e logs.
- **Multi-AZ:** nodes distribuidos em duas AZs garantem disponibilidade mesmo em falha de uma zona.

## Alternativas Consideradas

| Alternativa     | Motivo da Rejeicao                                                              |
|-----------------|---------------------------------------------------------------------------------|
| ECS Fargate     | Menor controle sobre o scheduling; ecossistema de observabilidade mais limitado |
| EC2 direto      | Sem orquestracao nativa; escalabilidade manual; maior overhead operacional      |
| App Runner      | Nao suporta HPA baseado em metricas customizadas; menos flexivel                |

## Consequencias

- O cluster EKS e provisionado com `endpoint_public_access = true` e `endpoint_private_access = true` para permitir acesso do CI/CD e dos nodes.
- O `metrics-server` e instalado via Helm para habilitar o HPA.
- O acesso externo e exposto via `Service` do tipo `LoadBalancer`, que provisiona um load balancer nativo AWS, sem necessidade do AWS Load Balancer Controller (incompativel com as restricoes de IAM do Learner Lab).
- O namespace `siase` e criado pelo Terraform; os manifestos da aplicacao sao aplicados pelo repositorio `15SOAT`.
