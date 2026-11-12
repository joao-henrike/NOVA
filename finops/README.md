# NOVA FinOps — custos e telemetria AWS

Sistema independente, em Python/Bash, com Cost Explorer, CloudWatch, ECS, RDS, NAT, ALB, Logs, histórico SQLite, API e dashboard HTML local.

**Escopo:** conta AWS `996560371158`, região `us-east-1`, projeto `cloudstart/dev`.

## Dados reais vs estimados

- **Faturamento:** AWS Cost Explorer / `UnblendedCost` diário por serviço, consultando conta inteira e filtrando por `Project=cloudstart` + `Environment=dev`. Valores podem ter atraso, serem estimados ou sofrer revisões. **Não são custos em tempo real.**
- **Operação quase em tempo real:** ECS running/desired, vCPU/GiB alocados, médias CPU/memória CloudWatch, classes RDS, conexões, NAT, ALB e grupos CloudWatch Logs.
- **Logs opcionais:** com `--logs`, conta até 100 eventos com texto `ERROR` por grupo em 15 minutos. **Não grava conteúdo dos eventos**, apenas contagens e avisos de truncamento.
- **Correlação:** snapshots com timestamp guardados em SQLite, duração das tarefas ECS atuais, vCPU-h e GiB-h provisionados, e custos diários para cruzamento por data. As horas da coorte atual não equivalem a histórico completo de execução. *Não* inventa custo monetário por container: para valores exatos por recurso, configure CUR 2.0/Data Exports, IDs e cost allocation tags.
- **Previsão:** gasto marcado do mês + média dos dias completos × dias restantes. É uma projeção simples, não um orçamento AWS nem previsão garantida.

## Execução (CloudShell)

Use um clone atualizado ou baixe só a pasta do repositório. A branch local divergiu antes; evite rebases se houver commits próprios.

```bash
cd ~/NOVA
git fetch origin main
# Em um checkout atualizado com pasta finops:
bash finops/run.sh collect --days 30 --logs
bash finops/run.sh report --days 30
bash finops/run.sh watch --days 30 --interval 300 --logs
```

O `watch` consulta ECS/CloudWatch a cada >=5 minutos e limita leituras do Cost Explorer a uma por hora (por banco SQLite). **Isso não é streaming AWS.** O script é somente leitura e não instala recursos na conta; chamadas de APIs AWS podem ter custos.

Em outro terminal:

```bash
bash finops/run.sh serve --port 8766
# Abra http://127.0.0.1:8766 no mesmo ambiente (ou use túnel privado).
```

Interface e API `/api/summary`, `/api/history`, `/healthz` ficam restritas ao localhost. **Não publique este serviço em ALB/internet**: não há autenticação própria nem TLS. A interface se atualiza a cada 60s, mas os dados AWS só mudam após coleta do processo separado. CloudShell não garante processos de longa duração.

Exportação CSV:

```bash
bash finops/run.sh export --days 90 --file "$HOME/nova-costs.csv"
```

O histórico fica em `.deploy/finops/data.sqlite3`, pasta protegida por permissões Unix. Pode ser perdido se o ambiente CloudShell for descartado; copie-o com segurança ou planeje armazenamento durável.

## Permissões mínimas (somente leitura)

`sts:GetCallerIdentity`, `ce:GetCostAndUsage`, `ecs:DescribeServices`, `ecs:DescribeTaskDefinition`, `cloudwatch:GetMetricStatistics`, `rds:DescribeDBInstances`, `ec2:DescribeNatGateways`, `elasticloadbalancing:DescribeLoadBalancers`, `logs:DescribeLogGroups`, e opcionalmente `logs:FilterLogEvents`. Necessário habilitar **cost allocation tags** no AWS Billing para atribuição completa.

## Precisão, cobertura e custos

- Cost Explorer é atualizado com atraso. Valores do dia corrente podem estar incompletos.
- Tags no Terraform não garantem visibilidade histórica em Cost Explorer. Custos não etiquetados, compartilhados e de outras contas não são rateados.
- `account_billed_usd` inclui todos os gastos da conta, não apenas NOVA.
- A captura de logs usa correspondência literal `ERROR`; falhas com outros textos não são contadas.
- Nem CloudWatch Logs `storedBytes` nem média `IncomingBytes` representam custo faturado exato.
- Métricas ECS/RDS refletem utilização; não multiplique diretamente por valores monetários sem uma tabela de preços e modelo de cobrança válidos.
- API de Cost Explorer pode ser cobrada por solicitação; polling frequente de API não é gratuito por definição.
- O módulo não provisiona CUR, S3, Lambda, EventBridge, budgets, alertas externos, IAM ou Grafana.
- Para produção, faltam coleta gerenciada, armazenamento durável, autenticação, alertas e CUR 2.0.

## Testes

```bash
python3 -m compileall -q finops
python3 -m unittest discover -s finops/tests -v
bash -n finops/run.sh
```

Orçamento opcional: `export NOVA_FINOPS_MONTHLY_BUDGET_USD=100` (alerta apenas na API, nenhum AWS Budget é criado).


## Preços oficiais e AWS Pricing Calculator API

O comando abaixo consulta **AWS Price List Query API** em `us-east-1` e procura SKUs públicos On-Demand compatíveis com o inventário atual; registra somente correspondências não ambíguas.

```bash
bash finops/run.sh pricing
bash finops/run.sh report
```

Para consultar uma **estimativa de workload já existente** na AWS Pricing Calculator (somente leitura):

```bash
bash finops/run.sh pricing --calculator-id SEU_ID_EXISTENTE --force
```

Ou: `export NOVA_FINOPS_CALCULATOR_ID=SEU_ID_EXISTENTE` e execute `pricing --force`.

- IAM adicional: `pricing:GetProducts` e opcionalmente `bcm-pricing-calculator:GetWorkloadEstimate`.
- A região da consulta de preços é `us-east-1`, com localização do produto `US East (N. Virginia)`.
- São usados preços públicos sob demanda (quando um SKU exato e unidade são confirmados); valores sem correspondência são **indisponíveis**, nunca inventados. Os exemplos com 4 e 6 tarefas são **cenários parciais** de 730 horas por mês, não garantias de cobrança.
- A Pricing Calculator API é um serviço distinto da Price List API. A integração consulta estimativas **já criadas**; **não cria** workloads automaticamente, evitando operações de escrita ou cobrança inesperada por estimativa.
- Há custos **não cobertos**, entre eles NAT, ALB/LCU, RDS storage/IOPS, transferência de dados, logs, IPv4, ECR e outros. Portanto, nenhum subtotal desta ferramenta deve ser apresentado como custo total da aplicação.
- A comparação com Cost Explorer só faz sentido para períodos e escopos equivalentes. Uma projeção de 730 horas não equivale a uma fatura acumulada de 30 dias.
- `pricing` usa cache no SQLite por 24 horas. `pricing --force` força atualização e pode gerar novas consultas às APIs; `collect` e `watch` continuam independentes.
