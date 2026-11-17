# NOVA — Dashboards e métricas de monitoramento

## 01 — Infrastructure

### 01. NOVA | Global Overview

- Disponibilidade global da aplicação (uptime e downtime).
- Estado operacional do ambiente: ativo, em deploy, em manutenção, em shutdown ou degradado.
- Status de todos os serviços: frontend, backend e monitoring.
- Status do ALB e dos três target groups.
- Tasks ECS desejadas, em execução, pendentes e não saudáveis.
- Status dos dois bancos RDS.
- Status dos NAT Gateways por AZ.
- Quantidade de recursos ativos, indisponíveis e degradados.
- Requisições por segundo, minuto, hora e dia.
- Taxa de sucesso e de erros HTTP 4xx e 5xx.
- Latência global: média, p50, p95 e p99.
- CPU e memória por serviço ECS e banco RDS.
- Tráfego de entrada e saída.
- Incidentes ativos por severidade, duração e componente.
- SLI, SLO, error budget e disponibilidade histórica.
- Último deploy, versão implantada e resultado.
- Último backup de cada banco e resultado.
- Custo diário, mensal acumulado e projeção mensal.
- Consumo do orçamento e anomalias financeiras.
- Saúde do Zabbix, Grafana e datasources.
- Horário da última coleta e métricas sem dados.

### 02. AWS | ECS Cluster

- Status e disponibilidade do cluster.
- Quantidade de serviços ativos, inativos e em falha.
- CPU utilizada, reservada e provisionada (vCPU e percentual).
- Memória utilizada, reservada e provisionada (MiB/GiB e percentual).
- CPU e memória: média, mínimo, máximo e histórico por serviço.
- Quantidade de tasks desejadas, running, pending e stopped.
- Quantidade de tasks saudáveis e não saudáveis.
- Falhas de inicialização e motivos de encerramento de tasks.
- Deployments em andamento, concluídos e com falha.
- Task definitions e revisões em execução.
- Network RX/TX (bytes e bytes/s).
- Operações e bytes de leitura/escrita de armazenamento, quando disponíveis.
- Armazenamento efêmero utilizado, reservado e disponível.
- Distribuição de tasks por Availability Zone e subnet.
- Utilização de quotas de vCPU Fargate e capacidade disponível.
- Eventos operacionais do cluster e erros de coleta.

### 03. AWS | ECS Services

Monitorar individualmente `frontend`, `backend` e `monitoring`.

- Status de cada serviço.
- CPU e memória: uso, capacidade, percentual e histórico.
- DesiredCount, RunningCount e PendingCount.
- Diferença entre quantidade desejada e disponível.
- Tasks saudáveis e não saudáveis; motivos de falhas.
- Container health checks e saúde dos targets no ALB.
- Deployments ativos, concluídos e com falha.
- Rollbacks, deployment circuit breaker e eventos ECS.
- Task definition, revisão, versão e digest da imagem implantada.
- Tempo de execução e idade das tasks.
- Tempo de inicialização e estabilização do serviço.
- Tasks encerradas, exit codes, OOM e falhas de inicialização.
- Bytes recebidos/enviados e taxas de rede.
- Distribuição por AZ e subnet.
- Requisições por task, latência e taxa de erros por serviço, quando instrumentadas.
- Eventos de indisponibilidade e tempo de recuperação.

### 04. AWS | Fargate Containers

Monitorar separadamente `frontend` (Nginx), `backend` (FastAPI), `zabbix-server`, `zabbix-web`, `grafana` e `monitoring-bootstrap`. Incluir também as tasks temporárias `db_bootstrap` e `db_migration` durante o deploy.

- Identificação do container, task, serviço, AZ e versão.
- Status, health status, uptime e duração da execução.
- CPU utilizada e limite de CPU.
- Memória utilizada, limite e percentual de utilização.
- Picos e tendências de CPU e memória.
- OOM, encerramentos, substituições de tasks e reinicializações, quando suportadas.
- Exit codes e motivos de encerramento.
- Tempo de inicialização e falhas de pull da imagem.
- Network RX/TX, quando disponível por container/task.
- Armazenamento efêmero e operações de I/O, quando disponíveis.
- Imagem, tag, digest e revisão da task definition.
- Volume de logs, erros, warnings e exceções.
- Última execução e resultado dos containers de bootstrap e migração.
- Disponibilidade e atualidade da telemetria por container.

### 05. AWS | Application Auto Scaling

Monitorar as políticas de CPU e memória de frontend e backend.

- Quantidade mínima (2), desejada, em execução e máxima (6) de tasks por serviço na configuração ativa de referência.
- Meta configurada de CPU (60%) e memória (70%).
- CPU e memória observadas versus metas configuradas.
- Eventos de scale-out e scale-in.
- Horário, motivo, política e resultado das atividades de escalonamento.
- Falhas de escalonamento e tempo desde a última atividade.
- Tempo até uma nova task estar running e healthy no ALB.
- Diferença entre capacidade desejada e disponível.
- Tempo e frequência no limite mínimo e máximo de tasks.
- Quantidade de tasks adicionadas e removidas.
- Requisições por task e capacidade disponível.
- Latência e erros antes, durante e depois do escalonamento.
- Histórico de alterações de políticas, limites e cooldowns.
- Tempo de recuperação após perda de capacidade.
- Consumo de vCPU/GiB-hora e impacto financeiro do scaling.

### 06. AWS | Application Load Balancer (ALB)

- Estado do ALB, listeners, regras e AZs associadas.
- `RequestCount` — total de requisições.
- `RequestCountPerTarget` — requisições por target.
- `ActiveConnectionCount` — conexões ativas.
- `NewConnectionCount` — novas conexões.
- `RejectedConnectionCount` — conexões rejeitadas.
- `TargetResponseTime` — média, p50, p90, p95 e p99.
- `HTTPCode_ELB_4XX_Count` e `HTTPCode_ELB_5XX_Count`.
- `HTTPCode_Target_2XX_Count`, `HTTPCode_Target_3XX_Count`, `HTTPCode_Target_4XX_Count` e `HTTPCode_Target_5XX_Count`.
- Taxa percentual de erros 4xx/5xx e de respostas bem-sucedidas, com denominador e volume mínimo adequados.
- `TargetConnectionErrorCount` — erros de conexão com targets.
- `ProcessedBytes` — volume processado.
- `ConsumedLCUs` — unidades de capacidade consumidas.
- `RuleEvaluations` — avaliações de regras.
- `HealthyHostCount` e `UnHealthyHostCount` — saúde dos targets.
- `ClientTLSNegotiationErrorCount` — falhas TLS, quando HTTPS estiver habilitado.
- Distribuição de tráfego, latência e erros por AZ e target group, conforme dimensões suportadas.
- Disponibilidade HTTP/HTTPS do endpoint público.
- Access logs: requisições, rotas, códigos HTTP, tempos e erros, quando habilitados.
- Custo por hora e consumo de LCUs.

### 07. AWS | Target Groups

Monitorar os target groups de frontend (`80`), backend (`8000`) e Grafana (`3000`).

- Quantidade de targets registrados, saudáveis e não saudáveis.
- Estado e motivo de saúde de cada target (API de target health).
- Targets em registro, inicialização, draining e indisponíveis.
- Eventos de registro e remoção.
- Tempo para registro e transição para healthy.
- Tempo de drenagem e deregistration delay configurado.
- Falhas consecutivas de health check.
- Configuração de path, intervalo, timeout, thresholds e códigos esperados.
- Saúde de targets por AZ.
- Requisições por target e por target group.
- Distribuição de tráfego e erros por target, quando houver logs ou instrumentação.
- Latência média e percentis por target group.
- Falhas de conexão entre ALB e targets.
- Diferença entre quantidade de targets saudáveis e tasks esperadas.
- Disponibilidade durante deploys, scaling e recuperação.

### 08. AWS | VPC & Network Overview

- Estado e inventário da VPC, CIDR e associações.
- Inventário das seis subnets públicas, privadas de aplicação e privadas de banco.
- IPs disponíveis, ocupados e percentual de utilização por subnet.
- Distribuição de serviços, ENIs e recursos por AZ/subnet.
- Estado, associações e rotas das route tables.
- Rotas ausentes, inválidas, blackhole e divergências do baseline.
- Estado e associação do Internet Gateway.
- Estado e associação dos NAT Gateways.
- Elastic IPs alocados, associados e ociosos.
- Inventário, estado e quantidade de ENIs.
- Security Groups: quantidade, regras, alterações e conformidade.
- Network ACLs: associações, regras e alterações.
- VPC Flow Logs: bytes, pacotes, fluxos aceitos/rejeitados e tendências (quando habilitados).
- Conectividade entre ALB, ECS e RDS por sondas autorizadas.
- Conectividade de saída para dependências externas por sondas.
- DNS: sucesso de resolução, latência, timeouts e falhas.
- Tráfego entre AZs e saída para internet, conforme as fontes disponíveis.
- Quotas de VPC, subnets, ENIs, EIPs e NAT Gateways.
- Eventos AWS Health relacionados à região e às AZs.
- Conformidade do isolamento das subnets de banco e ausência de IP público nas tasks.

### 09. AWS | NAT Gateways

Monitorar cada NAT Gateway individualmente e por AZ.

- Status operacional, associação e idade do recurso.
- `ActiveConnectionCount`.
- `ConnectionAttemptCount`.
- `ConnectionEstablishedCount`.
- `ErrorPortAllocation`.
- `PacketsDropCount` e proporção de pacotes descartados.
- `IdleTimeoutCount`.
- `BytesInFromSource` e `BytesOutToDestination`.
- `BytesInFromDestination` e `BytesOutToSource`.
- `PacketsInFromSource` e `PacketsOutToDestination`.
- `PacketsInFromDestination` e `PacketsOutToSource`.
- `PeakBytesPerSecond` e `PeakPacketsPerSecond`.
- Taxa de sucesso das conexões.
- Conectividade de saída para dependências HTTPS.
- Volume processado por AZ e período, sem dupla contagem.
- Horas de funcionamento e custo estimado por NAT.
- Custo de processamento de dados e anomalias de tráfego.

## 02 — Applications

### 10. Frontend | Nginx & Web Experience

- Uptime, downtime, status HTTP e health check `/health`.
- Disponibilidade das páginas `/`, `/login.html`, `/register.html`, `/quote.html`, `/checkout.html` e `/confirmation.html`.
- Status, latência, tamanho e integridade dos recursos estáticos JS, CSS, SVG e imagens.
- Requisições por segundo/minuto, método, rota e status.
- Conexões ativas, aceitas, tratadas, reading, writing e waiting (se instrumentadas).
- Taxa de sucesso e erros HTTP 400, 401, 403, 404, 429 e 5xx, incluindo 502/503/504.
- Latência média, p50, p95, p99 e tempo de carregamento.
- DNS lookup, tempo de conexão, TTFB e tempo de download em sondas.
- Consumo de CPU, memória e rede das tasks frontend.
- Access logs, error logs e falhas de inicialização Nginx.
- Versão, build, tag e digest da imagem.
- Presença e conformidade dos headers de segurança (CSP, X-Content-Type-Options, X-Frame-Options, Referrer-Policy e Permissions-Policy).
- Erros JavaScript, erros de carregamento e recursos indisponíveis (RUM adicional).
- Core Web Vitals: LCP, INP e CLS (RUM adicional).
- Taxa de sucesso dos fluxos de navegação sintéticos.
- Disponibilidade e validade TLS, quando habilitado.

### 11. Backend | FastAPI & Application Performance

- Liveness `/health`, disponibilidade `/api/health` e prontidão/dependência de banco `/api/health/db`.
- Volume de requisições por segundo, rota, método e status (RED: Rate, Errors, Duration).
- Latência média, p50, p90, p95, p99 e máxima por rota.
- Taxas de sucesso, erro, timeout e requisições canceladas.
- Requisições simultâneas e saturação de workers.
- CPU, memória e rede das tasks backend.
- Processos/workers Uvicorn: estado, quantidade, tempo de execução e encerramentos.
- Memória Python, garbage collection e exceções, quando instrumentados.
- Erros de validação, HTTP 4xx/5xx e exceções por categoria.
- Operações SQLAlchemy: volume, duração, erros e timeouts.
- Connection pool: conexões em uso, livres, overflow, espera, timeouts e saturação.
- Latência, disponibilidade e erros das dependências externas OAuth e PostgreSQL.
- Volume de logs, erros, warnings e stack traces sanitizados.
- Traces distribuídos: duração dos spans, dependências e correlação por trace ID (instrumentação adicional).
- Versão da aplicação, revisão da task e digest implantado.

### 12. API | Endpoint Monitoring

#### Endpoints

- `GET /` — raiz do backend; verificar diretamente no backend, pois a rota pública padrão do ALB aponta para o frontend.
- `GET /health` — health do backend; verificar diretamente no backend pelo mesmo motivo.
- `GET /api/health`.
- `GET /api/health/db`.
- `GET /api/info`.
- `GET /api/auth/google/login`.
- `GET /api/auth/google/callback`.
- `GET /api/auth/apple/login`.
- `POST /api/auth/apple/callback`.
- `POST /api/auth/refresh`.
- `POST /api/auth/logout`.
- `GET /api/auth/me`.
- `GET /api/items`.
- `POST /api/items`.
- `GET /api/items/{item_id}`.
- `PATCH /api/items/{item_id}`.
- `DELETE /api/items/{item_id}`.

#### Métricas para cada endpoint

- Disponibilidade, resultado do teste sintético, status HTTP observado versus esperado e conteúdo esperado.
- Requisições por período, método e template de rota (não por ID individual).
- Latência média, p50, p95, p99 e máxima.
- Taxas de sucesso, falha, 4xx, 5xx e timeout.
- Tamanho de requisição/resposta, quando instrumentado.
- Dependências, erros de validação e falhas de autenticação/autorização.
- Horário da última execução bem-sucedida e duração da indisponibilidade.
- Sucesso de operações CRUD completas com dados de teste descartáveis e isolados.
- Sucesso de fluxos autenticados somente com identidade de teste autorizada; status esperados de redirecionamentos e callbacks OAuth, quando configurados.

### 13. AWS | RDS Application Database

Monitorar a instância PostgreSQL da aplicação (`cloudstart-dev-db`).

- Estado da instância, classe, versão do engine e configuração Single-AZ/Multi-AZ.
- `CPUUtilization`, `CPUCreditBalance`, `CPUCreditUsage`, `CPUSurplusCreditBalance` e `CPUSurplusCreditsCharged`.
- `FreeableMemory` e `SwapUsage`.
- `DatabaseConnections` e percentual do limite de conexões.
- `FreeStorageSpace`, armazenamento alocado, utilizado e percentual livre.
- Crescimento do armazenamento, projeção de esgotamento e limite de autoscaling de storage.
- `ReadIOPS`, `WriteIOPS`, `ReadLatency`, `WriteLatency`, `ReadThroughput` e `WriteThroughput`.
- `DiskQueueDepth`.
- `NetworkReceiveThroughput` e `NetworkTransmitThroughput`.
- `TransactionLogsDiskUsage`.
- DB Load, waits e consultas principais, quando a telemetria adicional estiver habilitada.
- Sucesso de conexão SQL e latência do health check do banco.
- Eventos de manutenção, reinicialização, falha e alterações de configuração.
- Backup retention, último ponto restaurável e snapshots.
- Criptografia, exposição pública e conformidade de rede.
- Estado da credencial gerenciada, sem leitura do valor secreto.
- Custo da instância, armazenamento, backups e I/O adicional.

### 14. AWS | RDS Monitoring Database

Monitorar a instância PostgreSQL de monitoramento (`cloudstart-dev-monitoring-db`).

- Estado da instância, classe, versão do engine e configuração Single-AZ/Multi-AZ.
- `CPUUtilization`, `CPUCreditBalance`, `CPUCreditUsage`, `CPUSurplusCreditBalance` e `CPUSurplusCreditsCharged`.
- `FreeableMemory` e `SwapUsage`.
- `DatabaseConnections` e percentual do limite de conexões.
- `FreeStorageSpace`, armazenamento alocado, utilizado e percentual livre.
- Crescimento do armazenamento, projeção de esgotamento e limite de autoscaling de storage.
- `ReadIOPS`, `WriteIOPS`, `ReadLatency`, `WriteLatency`, `ReadThroughput` e `WriteThroughput`.
- `DiskQueueDepth`.
- `NetworkReceiveThroughput` e `NetworkTransmitThroughput`.
- `TransactionLogsDiskUsage`.
- DB Load, waits e consultas principais, quando a telemetria adicional estiver habilitada.
- Conectividade e latência entre Zabbix Server/Web e PostgreSQL.
- Volume/crescimento de tabelas de histórico, trends e eventos do Zabbix.
- Impacto de housekeeping, inserções e consultas de histórico no banco.
- Eventos de manutenção, reinicialização, falha e mudanças de configuração.
- Backup retention, último ponto restaurável e snapshots.
- Criptografia, exposição pública e conformidade de rede.
- Estado da credencial gerenciada, sem leitura do valor secreto.
- Custo da instância, armazenamento, backups e I/O adicional.

### 15. PostgreSQL | Database Performance

Aplicar aos dois bancos, conforme permissões e fontes de coleta disponíveis.

- Disponibilidade, latência de conexão e execução de consulta de saúde.
- Commits, rollbacks, TPS, QPS e taxa de rollbacks.
- Conexões totais, ativas, idle, idle in transaction e espera por conexão.
- Utilização de `max_connections`.
- Transações longas e idade da transação mais antiga.
- Locks, sessões bloqueadas, tempo de espera, deadlocks e wait events.
- Buffer cache hit ratio, blocos lidos e encontrados em cache.
- Tamanho de bancos, schemas, tabelas e índices; crescimento por período.
- Live tuples, dead tuples, inserts, updates, deletes e HOT updates.
- Sequential scans, index scans e utilização de índices.
- Vacuum, autovacuum, analyze, autoanalyze, atraso e risco de transaction ID wraparound.
- WAL: volume, taxa de geração e retenção.
- Checkpoints, buffers escritos e tempos de escrita/sincronização.
- Arquivos e bytes temporários.
- Consultas mais lentas, mais frequentes e mais custosas; duração e chamadas (com `pg_stat_statements` habilitado e acesso restrito).
- Replication lag e slots de replicação, somente quando aplicáveis.
- Erros SQL, falhas de autenticação e alterações de roles/privilégios.
- Versão do schema Alembic, integridade das migrações e privilégios esperados do runtime/migrator (por tarefa de auditoria autorizada).
- Atualidade da coleta e falhas de consultas de monitoramento.

### 16. CloudStart | Business Intelligence

Métricas de comportamento e negócio a instrumentar; carrinho e partes do checkout atuais usam `localStorage`. Indicadores financeiros reais dependem de processamento e persistência adicionais.

- Usuários ativos por período, novos usuários e recorrência.
- Logins bem-sucedidos e taxa de sucesso de autenticação.
- Visualizações de páginas, sessões e duração agregada.
- Produtos visualizados, comparados e adicionados à lista de desejos.
- Carrinhos iniciados, itens adicionados/removidos e carrinhos abandonados.
- Solicitações de orçamento iniciadas e concluídas.
- Checkouts iniciados e concluídos, distinguindo demonstrações de transações reais.
- Taxa de conversão por etapa do funil.
- Abandono por etapa e falhas dos fluxos comerciais.
- Operações CRUD de itens por período e taxa de sucesso.
- Pedidos, pagamentos aprovados/recusados e cancelamentos, somente após integração real.
- Receita confirmada, ticket médio e reembolsos, somente após persistência financeira real.
- Custo por usuário ativo e por conversão, quando houver dados confiáveis.

## 03 — SRE & Observability

### 17. Zabbix | Internal Performance

- Disponibilidade do Zabbix Server, Zabbix Web e API.
- Conectividade com o PostgreSQL de monitoramento.
- Uptime, versão e estado do servidor.
- Hosts monitorados, habilitados, indisponíveis e descobertos.
- Templates aplicados e cobertura por serviço.
- Itens habilitados, desabilitados, unsupported e sem dados.
- Triggers habilitadas, problemáticas, resolvidas e por severidade.
- Eventos ativos, duração, reconhecimentos e recuperação.
- Queue size e atraso de coleta por faixa de tempo.
- New values per second e throughput de processamento.
- Utilização de pollers, HTTP pollers e demais processos internos relevantes.
- History cache, trend cache, configuration cache e value cache.
- Preprocessing queue, utilização de workers e falhas de preprocessing.
- Housekeeper: utilização, frequência e duração.
- Performance de inserção e consulta no banco.
- Cenários web: sucesso, etapa com falha, código de resposta, tempo e velocidade de download.
- Volume de dados e crescimento do histórico/trends.
- Ações de notificação: sucesso, falha, fila e latência de entrega.
- CPU, memória, rede e logs dos containers Zabbix.
- Última coleta bem-sucedida por fonte; erros de credenciais, throttling e dados obsoletos.

### 18. Grafana | Internal Performance

- Disponibilidade interna e externa de `/grafana/api/health`.
- Estado da aplicação, versão, uptime e reinicializações/substituições de task.
- CPU, memória, rede e logs do Grafana.
- Status do plugin Zabbix, versão, carregamento e erros.
- Disponibilidade dos datasources Zabbix e CloudWatch e dos adicionais quando implantados.
- Latência e taxa de sucesso/falha de consultas por datasource.
- Erros de autenticação, permissões, timeouts e throttling.
- Dashboards provisionados, disponibilidade e falhas de carregamento.
- Quantidade de painéis sem dados, com dados obsoletos ou erro de consulta.
- Latência de carregamento e execução de queries.
- Usuários, sessões e falhas de autenticação (agregados).
- Alertas: estado, avaliação, falhas e notificação (quando configurados).
- Resultado, duração e última execução do monitoring-bootstrap.
- Sucesso de criação/atualização idempotente de dashboards e datasources.
- Persistência das configurações, dashboards e dados após substituição da task.
- Alterações administrativas, permissões e auditoria, quando disponível.
- Disponibilidade do monitoramento aferida também por sonda independente.

### 19. SRE | Global Availability, SLA, SLO & SLI

Monitorar frontend, backend, API de banco, ALB, Grafana, Zabbix e dependências críticas.

- Disponibilidade por serviço, endpoint, AZ (quando mensurável) e período.
- Uptime, downtime e histórico de interrupções.
- SLI de disponibilidade, latência e sucesso de requisições.
- SLO configurado versus resultado observado.
- SLA aplicável, se formalmente definido.
- Error budget total, consumido e restante.
- Burn rate do error budget em janelas curtas e longas.
- Quantidade, frequência, duração e severidade de incidentes.
- MTTD (tempo médio de detecção).
- MTTA (tempo médio de reconhecimento).
- MTTR (tempo médio de recuperação).
- MTBF (tempo médio entre falhas, quando mensurável).
- Disponibilidade percebida por sondas externas e internas.
- Latência p95/p99, taxa de erros e impacto durante incidentes.
- Disponibilidade por janelas de 24h, 7, 30 e 90 dias.
- Períodos de manutenção/shutdown planejados, identificados separadamente.
- Lacunas de coleta e proporção de sondas executadas versus esperadas.

### 20. SRE | Disaster Recovery & Resilience

- RTO e RPO definidos versus observados em testes autorizados.
- Tempo de detecção e recuperação de falhas de tasks.
- Tempo para task substituta estar running e healthy.
- Desired/running/pending tasks durante experimentos e recuperação.
- Targets saudáveis antes, durante e depois de incidentes.
- Disponibilidade, latência e taxa de erros durante a recuperação.
- Distribuição de tasks, ALB e recursos por AZ.
- Configuração Single-AZ/Multi-AZ e cobertura regional real.
- Failover e replication lag, somente quando implementados e testados.
- Resultados de testes de restore e integridade dos dados restaurados.
- Quantidade de experimentos, status PASS/FAIL/WARN/SKIP e duração.
- Último teste, idade da evidência e cobertura por cenário.
- Resultados do baseline, ALB, autoscaling, AZ e task recovery do módulo `resilience`.
- Incidentes recorrentes e ações corretivas pendentes.
- Custo/consumo adicional dos experimentos, quando mensurável.

### 21. SRE | Backup & Restore

- Estado de backups automatizados dos dois RDS.
- Último backup/ponto restaurável disponível e idade da evidência.
- Janela de backup, retenção configurada e mudanças.
- Snapshots manuais e automatizados: quantidade, idade, estado, tamanho e custo.
- Falhas, duração e conclusão dos backups, conforme eventos disponíveis.
- Disponibilidade e cobertura de point-in-time recovery.
- Último teste de restore, resultado e tempo de restauração.
- RTO e RPO efetivamente aferidos em testes.
- Integridade e validação dos dados restaurados.
- Terraform State no S3: disponibilidade, versionamento e última versão.
- Backup/exportação das configurações, dashboards e datasources Grafana.
- Backup/exportação de templates, hosts, triggers e configurações Zabbix.
- Backup, integridade e persistência do SQLite FinOps.
- Snapshots preservados após teardown e gastos associados.
- Indicadores de criptografia e retenção dos backups.

## 04 — Security

### 22. SOC | Security Operations Center

- Incidentes por severidade, estado, componente, horário e duração.
- Eventos administrativos AWS e alterações de configuração (CloudTrail, quando disponível).
- Eventos IAM: criação, exclusão e alterações de roles, policies e permissões.
- STS: falhas de autenticação, sessões e eventos de acesso relevantes.
- Alterações de Security Groups, NACLs, rotas e exposição pública indevida.
- Fluxos de rede aceitos/rejeitados e anomalias agregadas (VPC Flow Logs habilitados).
- Alterações de acesso público, políticas, versionamento e criptografia do S3.
- RDS: exposição pública, criptografia, alterações de configuração e falhas de autenticação.
- Secrets Manager: idade de rotação, alterações, exclusões programadas e falhas de acesso, sem valores secretos.
- ECS/ECR: integridade de imagens, mudanças inesperadas de revisões e vulnerabilidades.
- Aplicação: violações de autorização, erros de autenticação e eventos de rate limit.
- Headers de segurança, HTTPS habilitado e validade/expiração de certificados TLS.
- Findings do GuardDuty e Security Hub, quando habilitados.
- Métricas de eventos e bloqueios WAF, quando implementado.
- Estado de AWS Config e conformidade, quando habilitado.
- Atualidade, cobertura e falhas das fontes de auditoria.
- MTTD, MTTA, MTTR e incidentes pendentes por severidade.

### 23. SOC | Authentication & Identity Security

- Logins bem-sucedidos, falhas e taxa de sucesso por provedor OAuth.
- Disponibilidade, latência, timeouts e erros dos provedores Google e Apple.
- Sucesso/falha de início do OAuth e callbacks.
- Eventos de OAuth state inválido, origem inválida e redirecionamento rejeitado.
- JWT inválido, expirado ou rejeitado.
- Refresh tokens: sucessos, falhas e eventos de reutilização/revogação, quando observáveis.
- Logouts e falhas de encerramento de sessão.
- HTTP 401, 403 e 429 por período e template de rota.
- Rate limiting: eventos, frequência e erros da infraestrutura de controle.
- Tentativas de acesso não autorizado e violações de isolamento entre usuários.
- Falhas de autenticação PostgreSQL.
- Falhas de acesso IAM e STS associadas aos serviços.
- Idade de rotação e estado das credenciais/secrets.
- Falhas de autenticação e alterações administrativas do Grafana e Zabbix.
- Volume de eventos e tendências anômalas agregadas; nunca incluir senhas, tokens, cookies, chaves privadas ou dados pessoais desnecessários.

### 24. SOC | Vulnerability & Compliance Management

- ECR: findings por imagem, digest, pacote e severidade; status e idade do scan.
- Trivy: vulnerabilidades de imagens e dependências, com histórico.
- Checkov: violações IaC por controle, recurso e severidade.
- Gitleaks: número e estado de detecções, sem revelar conteúdo secreto.
- Dependabot: dependências vulneráveis, alertas abertos e resolvidos.
- TFLint: problemas Terraform e resultados de execução.
- GitHub Actions: resultado dos checks de segurança.
- Imagens ou dependências afetadas e em execução.
- Findings críticos, altos, médios e baixos; novos, corrigidos, aceitos e vencidos.
- Idade das vulnerabilidades, tempo para correção, reincidências e backlog.
- Exceções de segurança documentadas, validade e responsáveis.
- Conformidade IAM com privilégios mínimos e segregação de roles.
- RDS/S3: criptografia, acesso público, backups e controles esperados.
- Security Groups: conformidade com regras autorizadas.
- TLS: configuração, validade e expiração de certificados.
- Containers: usuário não root e demais controles declarados/aplicáveis.
- ECR: imutabilidade de tags, scan on push e lifecycle policy.
- Cobertura de verificações e última execução bem-sucedida.

## 05 — DevOps & Governance

### 25. DevOps | GitHub Actions & CI/CD

Monitorar CI, deploy, rebuild, extreme-validation, finops-unit-tests e resilience-unit-tests.

- Status dos workflows, jobs e steps.
- Execuções em fila, em andamento, aprovadas, reprovadas e canceladas.
- Taxa de sucesso, falha e cancelamento por workflow.
- Tempo de fila, build, testes, análise de segurança e deploy.
- Última execução bem-sucedida e última falha.
- Testes aprovados, reprovados, warnings, skips e taxa de aprovação.
- Cobertura de testes, quando relatada.
- Resultados de Terraform validate/fmt e checks de segurança.
- Frequência de deploy (DORA).
- Lead time for changes (DORA).
- Change failure rate (DORA).
- Failed deployment recovery time (DORA).
- Rollbacks e falhas de deployment circuit breaker.
- Falhas de autenticação/autorização OIDC e permissões AWS.
- Commit SHA, branch, workflow run, imagem/digest e revisão implantada.
- Diferença entre versão do código e versão em execução.
- Aprovações pendentes, tempo de espera e resultados de deploy.
- Histórico de releases e anotações de deploy para correlação de incidentes.

### 26. AWS | ECR Container Registry

Monitorar separadamente os repositórios frontend e backend.

- Estado dos repositórios e quantidade de imagens.
- Imagens tagged/untagged, tags, digests e idade.
- Tamanho por imagem e armazenamento total sem dupla contagem de camadas compartilhadas quando mensurável.
- Último push, último pull observado e histórico de publicações.
- Scan status, idade do último scan e findings por severidade.
- Imagens vulneráveis e imagens atualmente implantadas.
- Imagens antigas, não utilizadas e elegíveis para lifecycle cleanup.
- Lifecycle policy e conformidade da retenção.
- Tag immutability e scan on push.
- Falhas de push, pull, autenticação e permissões.
- Digest publicado versus digest em execução no ECS.
- Custo de armazenamento, transferência e scans, quando aplicável.

### 27. DevOps | Terraform & Cloud Governance

- Disponibilidade do backend S3 do Terraform State.
- Caminho do state canônico, última atualização, versão e disponibilidade do locking.
- Locks ativos, idade e falhas de aquisição/liberação.
- Quantidade e tipos de recursos gerenciados.
- Inventário de recursos AWS existentes versus state esperado.
- Drift: divergências de configuração e recursos ausentes/inesperados.
- Plan: quantidade de criações, atualizações, substituições e remoções previstas.
- Resultados, duração e falhas de plan, apply, validate e operações de teardown autorizadas.
- Estados legados e conflitos de ownership/bindings.
- Recursos órfãos, recursos remanescentes e custos residuais após teardown.
- Tags obrigatórias e conformidade (`Project`, `Environment`, `ManagedBy`, `Repository`, `Owner`, `CostCenter`).
- Quotas de serviços AWS: limite, consumo e capacidade restante, quando disponível.
- Estado das operações de deploy, baseline recovery, shutdown, resume e destroy.
- Resultado, exit code, duração e última execução do DB bootstrap.
- Resultado, exit code, duração e versão do schema da última migração Alembic.
- Resultado de health checks e validações de deploy.
- Estado das roles e políticas IAM esperadas.
- Eventos de alteração de infraestrutura e auditorias de conformidade.

## 06 — FinOps

### 28. AWS FinOps | Global Cost

- Custo diário, semanal, mensal acumulado e anual histórico/projetado.
- Custo médio diário e evolução por período.
- Custos da conta inteira versus custos atribuídos ao NOVA.
- Custos por serviço, ambiente, região, AZ e recurso, conforme dimensões/atribuição disponíveis.
- Custos por tags de alocação e custos não etiquetados.
- Orçamento mensal, consumo percentual, saldo e projeção.
- Comparação entre gasto real, orçamento e previsão.
- Anomalias de custo, variação absoluta e percentual diária/mensal.
- Créditos, descontos, impostos e outros componentes, quando disponíveis e apresentados separadamente.
- Custo por requisição e por usuário ativo, quando houver denominadores confiáveis.
- Custo por período de operação e shutdown.
- Atualidade do Cost Explorer, atraso e dias de faturamento incompletos.
- Estado e última coleta do módulo FinOps.

### 29. AWS FinOps | Resource Cost Breakdown

Monitorar uso operacional, unidades de cobrança, preços unitários, estimativas e custos atribuídos para cada componente, distinguindo o faturamento real das estimativas.

- **ECS Fargate:** horas de tasks, vCPU-hora, GiB-hora, armazenamento efêmero adicional; separação por frontend, backend e monitoring.
- **RDS Application e Monitoring:** horas de instância, classe, GB-mês de armazenamento, IOPS/throughput adicionais quando cobrados, backups, snapshots e créditos excedentes de CPU quando aplicáveis.
- **NAT Gateways:** horas por gateway/AZ, GB processados e preço unitário.
- **ALB:** horas em execução, LCU-hora, bytes processados e custo por requisição estimado.
- **ECR:** GB-mês armazenados, scans e transferências cobradas, quando aplicáveis.
- **CloudWatch Logs:** volume ingerido/armazenado, consultas, retenção e custos por grupo (quando atribuíveis).
- **CloudWatch Metrics:** métricas personalizadas, Container Insights, chamadas de API, alarmes e custos associados.
- **S3 Terraform State:** GB-mês, versões, requisições e transferência quando cobrada.
- **Secrets Manager:** quantidade de secrets cobrados, chamadas de API e custo atribuído.
- **Rede:** GB transferidos entre AZs e para internet; outros tipos cobrados quando aplicáveis.
- **IPv4 público:** endereços alocados/em uso, horas e custo.
- **Serviços adicionais:** custos AWS Health/observabilidade/segurança e outros serviços somente quando efetivamente cobrados.
- Comparação por recurso: quantidade, unidade, preço oficial, custo estimado e custo faturado quando disponível.
- Cobertura de atribuição de custos e itens sem correspondência de preço.

### 30. FinOps | Optimization & Forecasting

- Previsão diária, mensal e anual com premissas explícitas.
- Projeção do fechamento do mês versus orçamento e gasto acumulado.
- Diferença entre custos estimados e faturados em períodos/escopos equivalentes.
- Histórico de preços oficiais AWS Price List API e estimativas existentes do AWS Pricing Calculator.
- Atualidade da tabela de preços e correspondência de SKUs; preços indisponíveis.
- Tasks ociosas, utilização baixa de CPU/memória e oportunidades de rightsizing.
- RDS subutilizados, consumo de créditos, armazenamento livre e crescimento previsto.
- NAT/EIP ociosos, tráfego e oportunidades de otimização de rede.
- ECR: imagens antigas e armazenamento potencialmente recuperável.
- Logs: volumetria, retenção, ingestão, consultas e oportunidades de redução de custo.
- Recursos sem tags, órfãos e custos residuais após shutdown/teardown.
- Horas de capacidade ativa e despesas durante shutdown versus operação.
- Economia potencial, economia efetivamente realizada e histórico de recomendações.
- Custo incremental de scaling, alta disponibilidade, Multi-AZ e disaster recovery por cenário.
- Cenários de quantidade de tasks e horas de execução.
- Custo da coleta/monitoramento e relação custo-benefício.
- Anomalias, projeções acima do orçamento e tendências de crescimento.
- Atualidade da coleta, falhas de APIs, lacunas de atribuição e confiança das estimativas.
