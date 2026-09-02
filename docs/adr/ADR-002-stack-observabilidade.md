# ADR-002 — Stack de Observabilidade: Prometheus, Grafana, Loki e Alloy

**Status:** Aceito
**Data:** 2026
**Repositorio:** siase-infra-k8s

## Contexto

A Fase 3 exige monitoramento de latencia de APIs, consumo de recursos do Kubernetes, healthchecks, alertas para falhas em ordens de servico e logs estruturados com correlacao entre requisicoes. E necessario escolher uma stack de observabilidade que cubra metricas, logs e alertas de forma integrada.

## Decisao

Adotar a stack **Prometheus + Grafana + Loki + Grafana Alloy**, instalada via Helm no cluster EKS:

- **kube-prometheus-stack:** Prometheus, Grafana e Alertmanager em um unico chart.
- **Loki:** agregacao de logs em modo SingleBinary para esta entrega.
- **Grafana Alloy:** agente de coleta e envio de logs para o Loki (substituto do Promtail).

## Justificativa

- **Stack integrada:** Prometheus e Grafana sao o padrao de facto para observabilidade em Kubernetes. O `kube-prometheus-stack` instala e configura tudo com um unico `helm install`.
- **Micrometer nativo:** a aplicacao Spring Boot expoe metricas via `/actuator/prometheus` com Micrometer, compativel nativamente com o Prometheus.
- **Loki + Alloy:** o Promtail foi descontinuado pela Grafana. O Alloy e o agente atual recomendado, com suporte a processamento de logs JSON e promocao de campos (`correlationId`, `subject`) a labels Loki.
- **Logs estruturados:** a aplicacao ja emite logs JSON com `correlationId` via `CorrelationIdFilter`, permitindo correlacao de requisicoes entre aplicacao e observabilidade.
- **Custo zero de licenca:** toda a stack e open-source.
- **ServiceMonitor:** o `ServiceMonitor` do repositorio `15SOAT` usa o label `release: kube-prometheus-stack`, compativel com o `serviceMonitorSelector` configurado no chart.

## Alternativas Consideradas

| Alternativa          | Motivo da Rejeicao                                                          |
|----------------------|-----------------------------------------------------------------------------|
| Datadog              | Custo elevado de licenca; nao disponivel no AWS Academy Learner Lab         |
| New Relic            | Idem Datadog                                                                |
| CloudWatch           | Menor integracao com Kubernetes; dashboards menos flexiveis que Grafana     |
| Promtail             | Depreciado pela Grafana; Alloy e o substituto oficial recomendado           |
| ELK Stack            | Maior consumo de recursos; complexidade operacional superior ao necessario  |

## Consequencias

- O Grafana recebe a senha administrativa via AWS Secrets Manager (sem exposicao no estado Terraform).
- O dashboard `SIASE - Visao operacional` e provisionado automaticamente via ConfigMap com label `grafana_dashboard=1`.
- Os alertas operacionais sao declarados em `k8s/prometheus-rule.yaml` como `PrometheusRule`.
- O Loki usa armazenamento local nesta entrega; em producao real, recomenda-se S3 como backend de armazenamento.
