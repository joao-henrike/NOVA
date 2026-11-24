> **AWS persistence update:** see [Recovery and clean deployment](RECOVERY_AND_CLEAN_DEPLOY.md) for the new PostgreSQL Grafana storage, non-destructive provisioning, and current limitations. Older AWS descriptions below reflect the original architecture.

# NOVA Monitoring — Zabbix, Grafana e CloudWatch

**Branch desta implementação:** main. **Escopo:** apenas monitoramento e integrações necessárias.

O serviço do monitoramento já existia com Zabbix Server, Zabbix Web, Grafana e PostgreSQL RDS/Compose. Nesta revisão, adicionei o bootstrap idempotente, criação automática de recursos de monitoramento e dashboards, acesso somente leitura a métricas CloudWatch e health checks alinhados ao caminho /grafana.

**Atenção:** CI verde valida código e contratos; não comprova disponibilidade, configuração de APIs nem métricas reais na AWS. O ciclo de aceitação em cloud continua obrigatório.

## Componentes

| Ambiente | Componentes |
| --- | --- |
| Local | Compose com PostgreSQL persistente, Zabbix Server/Web, Grafana e monitoring-bootstrap |
| AWS | ECS/Fargate com Zabbix Server/Web, Grafana e sidecar monitoring-bootstrap; banco RDS privado |
| Grafana | Plugin Zabbix instalado e habilitado pelo bootstrap; dashboards e datasources via HTTP API |
| Zabbix | Host, grupo, cenário web e trigger configurados automaticamente |
| CloudWatch | Datasource de métricas AWS, usando credenciais temporárias do ECS task role |

O bootstrap (monitoring/bootstrap.py) utiliza somente a biblioteca padrão do Python. Ele aguarda as APIs ficarem prontas, autentica/rotaciona uma vez a senha inicial de Zabbix, configura o monitoramento e atualiza o dashboard. É **idempotente**: uma nova execução reutiliza e atualiza os objetos existentes, não cria duplicatas.

### Objetos Zabbix

- Grupo: NOVA Monitoring
- Host: NOVA-Monitoring
- Cenário web: NOVA internal health, a cada 1 minuto
- Etapas: Zabbix Web e API de saúde do Grafana
- Trigger: NOVA internal HTTP monitoring failed

A trigger detecta falhas do cenário, mas **não envia notificações externas** sem ações e canais de alerta configurados em Zabbix.

### Objetos Grafana

- Plugin: alexanderzobnin-zabbix-app
- Datasource Zabbix: NOVA Zabbix, UID nova-zabbix
- Datasource CloudWatch (apenas AWS): NOVA CloudWatch, UID nova-cloudwatch
- Dashboard: NOVA | Monitoring, UID nova-monitoring
- Duas séries Zabbix: falhas HTTP e tempo de resposta
- Seis séries CloudWatch (AWS): CPU/memória ECS, conexões RDS

As séries mostram dados reais apenas após a coleta. O dashboard gerenciado é atualizado a cada inicialização; edições manuais nele podem ser sobrescritas. Crie dashboards separados para personalizações.

## Uso local

Requer Docker Engine/Compose, acesso às imagens públicas e portas locais livres.

~~~bash
docker compose -f docker-compose.monitoring.yml config --quiet
docker compose -f docker-compose.monitoring.yml up -d
docker compose -f docker-compose.monitoring.yml ps -a
docker compose -f docker-compose.monitoring.yml logs -f monitoring-bootstrap
~~~

A primeira inicialização pode levar alguns minutos (criação do schema Zabbix e instalação do plugin). Procure a mensagem **NOVA monitoring bootstrap complete** nos logs.

- Grafana: http://127.0.0.1:3000
- Zabbix Web: http://127.0.0.1:8081
- Os ports públicos locais foram restritos a loopback. As senhas no Compose são exclusivamente de desenvolvimento.

Para testar idempotência novamente:

~~~bash
docker compose -f docker-compose.monitoring.yml run --rm monitoring-bootstrap
~~~

Para parar e manter os volumes:

~~~bash
docker compose -f docker-compose.monitoring.yml down
~~~

Não use down -v se deseja preservar os dados locais do PostgreSQL Zabbix e do Grafana.

## AWS e IaC

A stack declarada em monitoring.tf usa uma tarefa ECS Fargate com quatro containers: zabbix-server, zabbix-web, grafana e monitoring-bootstrap. O bootstrap roda com imagem pública Python Alpine, código embutido como base64 não sigiloso na task definition, sem precisar publicar imagem adicional no ECR. Ele é essencial e só fica saudável após concluir o provisionamento; erros de bootstrap impedem a tarefa de ser considerada saudável.

O ALB publica o Grafana em /grafana/; tanto a verificação do target group quanto a saúde do container usam /grafana/api/health. O Zabbix Web permanece privado na task ECS.

O PostgreSQL RDS do monitoramento continua privado, com senha gerenciada pela AWS. A senha Grafana é injetada via ECS Secrets Manager. A senha Zabbix é derivada por SHA-256 com prefixo distinto a partir dessa credencial, para evitar reutilizar literalmente a mesma senha e não criar outro segredo cobrado. Ao trocar a senha Grafana, é necessário planejar a atualização correspondente da senha Zabbix persistida; o bootstrap falha de forma segura quando as credenciais não coincidem. Em produção, prefira credenciais independentes com rotação dedicada.

A role de monitoramento recebeu exclusivamente acesso para consulta a CloudWatch Metrics e metadados mínimos de logs/regiões; não são usadas access keys de longa duração. O ambiente mantém as configurações de rede, segurança e RDS existentes.

**Mudança de capacidade:** a task agora usa 1 vCPU e 3 GiB em vez de 2 GiB. Isso pode aumentar o custo do ECS Fargate. Consultas CloudWatch e snapshots/armazenamento podem gerar custos separados.

**Branches e deploy:** apenas a main recebeu estas mudanças. Os scripts locais do projeto ainda restringem o deploy a Joao ou TESTE1; o workflow CD/OIDC do GitHub continua restrito à Joao. Portanto, este commit **não implanta o monitoramento automaticamente na conta AWS**. A role AWS do GitHub CD também requer aplicação autorizada do bootstrap IAM atualizado para permitir a nova política de métricas da task de monitoramento. Não contorne proteções de branch, estado Terraform ou IAM.

## Testes automáticos

~~~bash
python3 -m compileall -q monitoring
python3 -m unittest discover -s monitoring/tests -v
docker compose -f docker-compose.monitoring.yml config --quiet
~~~

A CI também verifica Terraform fmt/validate, segurança e os testes existentes. Os testes simulam APIs e validam criação/atualização idempotente; não substituem testes de container e integração AWS.

## Critérios de aceitação real

1. O serviço ECS de monitoramento estabiliza com quatro containers e bootstrap HEALTHY.
2. O log monitoring-bootstrap registra NOVA monitoring bootstrap complete sem expor senhas.
3. O target group Grafana fica healthy; /grafana/api/health responde 200 no ALB.
4. Plugin Zabbix habilitado; datasource Zabbix responde a consultas.
5. Zabbix mostra host, cenário e trigger sem duplicatas após reiniciar a task.
6. Dashboard nova-monitoring tem dados, e o datasource CloudWatch lê métricas de ECS/RDS pela role.
7. Shutdown/resume do ambiente e repetição do deploy não introduzem mudanças Terraform inesperadas.
8. Evidências e custos são registrados antes de declarar produção homologada.

**Fora do escopo atual:** TLS público por padrão, alta disponibilidade Zabbix, canais SMTP/Slack de alertas, auditoria de produção, monitoramento externo ponta a ponta de frontend/API e confirmação de deploy real na AWS.

Fontes de API: Zabbix 7.4 https://www.zabbix.com/documentation/7.4/en/manual/api ; Grafana Zabbix https://grafana.com/docs/plugins/alexanderzobnin-zabbix-app/latest/configure/ ; Grafana HTTP API https://grafana.com/docs/grafana/latest/developer-resources/api-reference/http-api/ ; CloudWatch https://grafana.com/docs/grafana/latest/datasources/aws-cloudwatch/configure/ .


## Continuous Zabbix collection (AWS)

The existing monitoring-bootstrap container now runs `collector.py` after its original bootstrap. No new container, internet ingress, static AWS keys or database privileged credentials. Terraform builds a compressed query catalog from the 30 Grafana templates and injects actual AWS dimension identifiers. The collector deduplicates identical CloudWatch queries, collects closed five-minute samples every 15 minutes, and sends timestamped numeric values to Zabbix trappers using the loopback sender protocol. It creates the **NOVA Extended** host group, `NOVA-AWS`, `NOVA-Dxx`, `NOVA-Collector`, and a separate **NOVA | Zabbix Live** Grafana folder with 30 managed dashboards (`zbx-nova-...`). Original dashboard JSONs and the original `nova-monitoring` dashboard stay intact.

Supported current sources: all 458 native CloudWatch panel definitions (deduplicated; metric availability depends on AWS configuration/traffic), existing internal Zabbix web checks, selected RDS inventory and automated snapshot ages, VPC subnet capacity/routes, NAT availability and aligned packet-drop ratio, ELB target health inventory, ECR image inventory, Zabbix problem/unsupported-item counts, optional HTTPS frontend probe. The exact custom keys with real producers are `IMPLEMENTED` in collector.py. All remaining contracts are provisioned but deliberately receive no data; their panels are labeled PENDENTE. No revenue, payment, billing, tracing, PostgreSQL SQL internals, full security events, CI or resilience report numbers are fabricated. HTTPS probes run only when an ACM certificate and domain are configured; they originate from the monitoring task, not an independent external probe.

The AWS role adds read-only Describe permissions and ECR image inventory for the two project repositories; no secret-read permissions or resource mutations. The original authentication model is unchanged. The collector keeps bounded seven-day history and 90-day trends, retries failures, tracks successful sender acknowledgments, and exposes heartbeat/source errors; it does not send notifications externally. New live dashboards are regenerated at boot, so edit copies rather than managed versions. CloudWatch API calls and RDS history can cost money. The 900-second interval is a deliberate default; overlapping data windows are deduplicated, but CloudWatch still charges for queried metrics where applicable. A third AZ NAT is inventoried; template panels currently describe the first two NATs.

### Acceptance (real AWS required)

1. Run `python3 -m unittest discover -s monitoring/tests -v`, `python3 monitoring/grafana/validate.py`, `terraform fmt -check` and `terraform validate` in a configured checkout.
2. Follow the protected deployment runbook. Review IAM, task-definition revision and service update in the actual plan; do not bypass existing guards. No deployment was executed by this change.
3. Confirm log entry `NOVA Zabbix collector ready`, then `NOVA collection: series=.../..., samples=..., errors=...`. A zero or absent series is not proof of operation.
4. In Zabbix Latest data verify NOVA-AWS and NOVA-Collector: fresh values/timestamps; check supported contracts and investigate missing metrics. Confirm Grafana folder NOVA | Zabbix Live has the 30 dashboards and data from `nova-zabbix`. Compare samples to CloudWatch for the same period and dimensions.
5. Monitoring remains a single task; independently monitor its health and establish alert delivery before relying on it operationally. Local Compose continues the original bootstrap only; AWS-specific collector requires ECS credentials.

Limitations: runtime Zabbix/Grafana API and AWS integration are not yet homologated. Collection of all 506 composite requirements needs instrumentation and additional data sources; existing contract definitions alone do not provide them.
