# SIASE - infraestrutura Kubernetes e observabilidade

Repositório da infraestrutura da Fase 3 para o cluster Kubernetes gerenciado da
aplicação SIASE. O código cria a rede AWS, o EKS, o VPC Endpoint para o
Secrets Manager, o stack de observabilidade e os parâmetros SSM consumidos
pelos repositórios `siase-infra-database` e `siase-auth-lambda`.

O apply deve ser realizado somente em uma conta AWS Student, usando credenciais
temporarias do Learner Lab atualizadas a cada sessão.

## Arquitetura

```mermaid
flowchart TB
  internet[Internet] --> alb[ALB provisionado pelo app-service]
  alb --> app[Service app-service\nnamespace siase]
  app --> eks[EKS gerenciado]
  eks --> nodes[Managed node group\n2 AZs + autoscaling]
  eks --> prometheus[Prometheus\nkube-prometheus-stack]
  eks --> grafana[Grafana]
  eks --> alertmanager[Alertmanager]
  eks --> alloy[Grafana Alloy]
  alloy --> loki[Loki]
  grafana --> prometheus
  grafana --> loki
  alb -. hostname .-> ssm[SSM /siase/production/lb-dns]
  ssm --> lambda[siase-auth-lambda]
  vpc[VPC publica/privada\nsem NAT Gateway\nLearner Lab] --> eks
```

### Componentes

- VPC com duas subnets públicas e duas privadas, distribuídas em duas AZs
  (NAT Gateway desabilitado nesta entrega para o Learner Lab — nodes ficam em subnets públicas com IP público);
- EKS gerenciado com managed node group e escala configurável;
- `metrics-server` para suportar HPA e métricas de pods;
- VPC Endpoint privado para o Secrets Manager (permite acesso das Lambdas sem internet);
- `kube-prometheus-stack`, contendo Prometheus, Grafana e Alertmanager;
- Loki em modo SingleBinary com armazenamento local para esta entrega;
- **Grafana Alloy** como agente de coleta e envio de logs para Loki;
- ConfigMap de dashboard com o label `grafana_dashboard=1`;
- `PrometheusRule` com os alertas operacionais;
- parâmetro SSM `/siase/production/lb-dns` com placeholder até o Load Balancer existir.

## Agente de logs escolhido

O agente é o **Grafana Alloy**, instalado pelo chart `grafana/alloy`. Ele é o
agente mantido pela Grafana para coleta e encaminhamento de telemetria,
incluindo logs para Loki. O Promtail não foi escolhido: a linha do Promtail
entrou em manutenção encerrada/depreciação e não é uma escolha adequada para
uma instalação nova. O Alloy também permite processar os logs JSON da
aplicação e promover `correlationId`, `subject` e `level` a labels Loki.

Os logs do `siase-app` já são JSON e contêm `correlationId` e `subject`, o que
permite correlacionar uma requisição entre aplicação e observabilidade.

## Ordem de aplicação

1. Criar o bucket S3 e a tabela DynamoDB usados pelo backend Terraform, fora
   deste estado ou por um bootstrap separado.
2. Criar no Secrets Manager o segredo do Grafana. O JSON deve conter:

   ```json
   {
     "password": "valor-fora-do-git"
   }
   ```

3. Copiar um arquivo de ambiente:

   ```bash
   cp environments/production.tfvars.example environments/production.tfvars
   ```

   Ajuste região, ARN do segredo e tamanhos dos nodes. Os arquivos `.tfvars`
   reais são ignorados pelo Git.

4. Inicializar e validar o backend:

   ```bash
   terraform init \
     -backend-config="bucket=BUCKET_DO_ESTADO" \
     -backend-config="dynamodb_table=siase-terraform-lock"
   terraform plan -var-file=environments/production.tfvars
   terraform apply -var-file=environments/production.tfvars
   ```

   Em ambiente sem backend, a validação local usa:

   ```bash
   terraform init -backend=false
   terraform validate
   ```

5. O Terraform instala os charts, namespaces, dashboard e publica o parâmetro
   SSM `/siase/production/lb-dns` com o valor inicial `PENDING_LB_DNS`.
6. Aplicar os recursos do Alertmanager e das regras:

   ```bash
   aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME"
   kubectl apply -f k8s/alertmanager-config.yaml
   kubectl apply -f k8s/prometheus-rule.yaml
   ```

7. Aplicar os manifestos da aplicação a partir do repositório `15SOAT`.
   O `app-service` do tipo `LoadBalancer` provisiona o Load Balancer pelo
   cloud controller do EKS.
8. Depois que o hostname estiver preenchido no status do Service, publicar o
   DNS no SSM:

   ```bash
   lb_dns="$(kubectl get svc -n siase app-service \
     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
   aws ssm put-parameter \
     --name "/siase/production/lb-dns" \
     --type String \
     --value "$lb_dns" \
     --overwrite
   ```

   O workflow do repositório `15SOAT` automatiza esta espera e publicação.
   A Lambda de autenticação só deve ser aplicada/atualizada depois dessa etapa,
   salvo uso de `lb_dns_override`.

## Terraform

Os módulos oficiais usados são:

- `terraform-aws-modules/vpc/aws` `6.6.1`;
- EKS provisionado diretamente via `aws_eks_cluster` e `aws_eks_node_group` (sem módulo externo).

Os providers e charts têm versões fixadas nos arquivos Terraform. O node group
possui `min_size`, `desired_size` e `max_size`, e o `metrics-server` habilita
autoscaling baseado em métricas de pods. A aplicação usa o HPA do repositório `15SOAT`.

O parâmetro SSM é declarado com:

- nome: `/siase/production/lb-dns`;
- valor inicial: `PENDING_LB_DNS`;
- `lifecycle.ignore_changes = [value]`.

Isso evita que um `terraform apply` posterior sobrescreva o hostname real
publicado pelo workflow do repositório `15SOAT`.

## Grafana

O Grafana recebe:

- datasource Prometheus provisionado pelo `kube-prometheus-stack`;
- datasource Loki apontando para o gateway interno do Loki;
- senha administrativa obtida do Secrets Manager através de
  `grafana_secret_arn`;
- dashboard `SIASE - Visão operacional` via ConfigMap com
  `grafana_dashboard=1`.

Para acessar sem expor o serviço publicamente:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Acesse `http://localhost:3000`. O usuário padrão é `admin`, salvo alteração em
`grafana_admin_user`; a senha vem do segredo configurado.

O dashboard inclui:

- volume diário de ordens de serviço;
- tempo médio e p95 por status;
- tempo médio e volume de itens iniciados;
- latência p95/p99 das APIs;
- taxa de erro 5xx;
- falhas de integração;
- CPU e memória por pod;
- uptime da aplicação;
- disponibilidade do scrape.

O `Prometheus` captura o `ServiceMonitor` do `siase-app` porque:

- o `ServiceMonitor` existente usa o label
  `release: kube-prometheus-stack`;
- `serviceMonitorSelector` usa o mesmo label;
- `serviceMonitorNamespaceSelector: {}` permite descoberta entre namespaces;
- o endpoint segue sendo `app-service:management` em
  `/actuator/prometheus`.

## PromQL do dashboard

As consultas abaixo foram mantidas conforme o contrato fornecido:

| Painel | Consulta |
| --- | --- |
| Volume diário de OS | `sum(round(increase(siase_ordens_servico_criadas_total{application="siase"}[1d])))` |
| Tempo médio por status | `sum by (status) (rate(siase_ordem_servico_tempo_status_seconds_sum{application="siase"}[$__rate_interval])) / sum by (status) (rate(siase_ordem_servico_tempo_status_seconds_count{application="siase"}[$__rate_interval]))` |
| P95 por status | `histogram_quantile(0.95, sum by (status, le) (rate(siase_ordem_servico_tempo_status_seconds_bucket{application="siase"}[$__rate_interval])))` |
| Tempo médio de item | `sum(rate(siase_execucao_item_tempo_seconds_sum{application="siase"}[$__rate_interval])) / sum(rate(siase_execucao_item_tempo_seconds_count{application="siase"}[$__rate_interval]))` |
| Itens iniciados | `sum(round(increase(siase_execucao_item_iniciadas_total{application="siase"}[1d])))` |
| Latência p95 | `histogram_quantile(0.95, sum by (uri, le) (rate(http_server_requests_seconds_bucket{application="siase"}[$__rate_interval])))` |
| Latência p99 | `histogram_quantile(0.99, sum by (uri, le) (rate(http_server_requests_seconds_bucket{application="siase"}[$__rate_interval])))` |
| Taxa 5xx | `sum(rate(http_server_requests_seconds_count{application="siase",status=~"5.."}[$__rate_interval])) / sum(rate(http_server_requests_seconds_count{application="siase"}[$__rate_interval]))` |
| Falhas de integração | `sum by (integracao) (increase(siase_falhas_integracao_total{application="siase"}[1h]))` |
| CPU por pod | `sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="siase",container!=""}[$__rate_interval]))` |
| Memória por pod | `sum by (pod) (container_memory_working_set_bytes{namespace="siase",container!=""})` |
| Uptime | `process_uptime_seconds{application="siase"}` |
| Scrape | `up{namespace="siase"}` |

## Alertas

O arquivo `k8s/prometheus-rule.yaml` declara `PrometheusRule` com:

- latência p95 acima de 1 segundo por 10 minutos;
- taxa de erro 5xx acima de 5% por 5 minutos;
- falha no processamento de ordens;
- mais de cinco falhas de integração em 15 minutos;
- aplicação sem targets disponíveis;
- pod não pronto;
- CPU acima de 85% do limite;
- memória acima de 90% do limite.


## CI/CD e configuração do GitHub

O workflow reutilizável `.github/workflows/build-test.yml` executa:

```text
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
```

`ci.yml` chama esse workflow em pull requests para `main` e `develop`.
`deploy-prod.yml` roda em push para `main`, exige o job `build-test` e usa
credenciais temporárias do Learner Lab.

**Observação sobre autenticação AWS:** o Learner Lab não suporta OIDC. O workflow
usa credenciais temporárias (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_SESSION_TOKEN`) que expiram a cada sessão de 4h e precisam ser atualizadas
manualmente nos secrets do GitHub.

O `deploy-prod.yml` executa dois `terraform apply` em sequência: primeiro aplica
apenas o cluster EKS e o node group (`-target`), depois aplica o restante
(Helm charts, namespaces, SSM). Ao final, aplica os manifestos
`alertmanager-config.yaml` e `prometheus-rule.yaml` via `kubectl`.

No GitHub Environment `production`, crie:

**Variables**

```text
AWS_REGION
EKS_CLUSTER_NAME
TF_STATE_BUCKET
GRAFANA_SECRET_ARN
LAB_ROLE_ARN
LB_DNS_SSM_PARAMETER
```

**Secrets**

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN
```

As credenciais do Learner Lab são temporárias e devem ser renovadas a cada sessão.

## Validação local

Os comandos esperados antes de uma alteração ser integrada são:

```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
python3 -m json.tool dashboards/siase-overview.json >/dev/null
promtool check rules /tmp/siase-prometheus-rules.yaml
helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 61.7.2 \
  --namespace monitoring \
  -f helm/kube-prometheus-stack-values.yaml
```

Como o arquivo de regras é um CRD `PrometheusRule`, o bloco `spec.groups` é
extraído para um arquivo de regras Prometheus antes do `promtool check rules`.
Isso valida a sintaxe que o Prometheus executará, sem fingir que o `promtool`
valida o envelope Kubernetes.

## Documentacao

- [Diagramas de Sequencia](docs/diagramas-sequencia.md)
- [ADR-001 — Escolha do EKS como Plataforma de Orquestracao](docs/adr/ADR-001-escolha-eks.md)
- [ADR-002 — Stack de Observabilidade: Prometheus, Grafana, Loki e Alloy](docs/adr/ADR-002-stack-observabilidade.md)
- [RFC-001 — Estrategia de Deploy e Escalabilidade no EKS](docs/rfc/RFC-001-estrategia-deploy-escalabilidade.md)
