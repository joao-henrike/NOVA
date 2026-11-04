# NOVA — auditoria estrutural IaC e dependências (04/11/2026)

Escopo: inspeção do repositório \`main\` (Terraform raiz, bootstrap de State, GitHub OIDC, Docker/Compose, backend, scripts e workflows de CI/CD) e evidências da AWS CloudShell fornecidas pelo operador. **Este documento não afirma aceitação de deploy real**; a CI é principalmente estática e com serviços simulados.

## Evidência real de AWS

- Conta: 760396521507, região: us-east-1.
- State canônico: \`cloudstart/dev/terraform.tfstate\`, VPC \`vpc-02e700222521a3c71\`.
- State legado: \`cloudstart/terraform.tfstate\`; Target Groups e DB Subnet Groups vivos da VPC \`vpc-060907935831aae05\`.
- Target Groups legados (frontend/backend/Grafana) têm **zero ALBs associados**, mas ainda existem e impedem criação com os mesmos nomes.
- ALB atual \`cloudstart-dev-alb\` pertence à VPC canônica. Dois NAT Gateways atuais estavam disponíveis; cluster ECS atual ACTIVE com zero serviços; nenhum DB RDS do projeto foi listado na última auditoria.
- Algumas IAM Roles, o segredo de Grafana e repositórios ECR aparecem em mais de um histórico de State. O State legado pode ter referências desatualizadas a recursos que já não existem. **Não importar nem destruir apenas pelo nome**.
- Backups confirmados pelo operador em \`~/nova-state-backup-20261104T194459Z/\`; são sensíveis e não devem ser anexados a tickets ou versionados.

## P0 — bloqueadores reais

| Item | Causa raiz | Situação/correção |
|---|---|---|
| CR-01: State legado e canônico com nomes sobrepostos | Recursos antigos com mesmo nome e VPCs distintas; o State canônico não possui as associações dos objetos antigos | NOVO: preflight leitura apenas por AWS/State, obrigatório no deploy local e em CD, antes de provisionar credenciais; permissões S3 do OIDC ampliadas somente para leitura dos dois States legados; bloqueia antes do apply |
| CR-02: baseline parcial | O script anterior pulava o baseline ao encontrar qualquer State, ainda que incompleto | Corrigido anteriormente por reconciliação refresh=true e guard fail-closed; a preflight agora antecede o apply |
| CR-03: migração de propriedade não provisionada | Não há procedimento IaC único e autorizado para remover vínculos legados, migrar IAM/segredos sem dois donos e descartar objetos de outra VPC | PENDENTE: migração única com inventário e autorização; não automatizar exclusão baseada somente em State antigo |

## P1 — divergências e cobertura

| Item | Constatação | Ação |
|---|---|---|
| WF-01: guard de aplicação duplicado | \`deploy-dev.yml\`, \`rebuild-dev.yml\` e CloudShell usavam allowlists diferentes | AJUSTADO: workflows passam a chamar \`scripts/check-application-plan.sh\` |
| WF-02: rebuild destrutivo | Workflow podia iniciar \`terraform plan -destroy\` sem invocar o snapshot helper usado pelo fluxo local | AJUSTADO: snapshot RDS obrigatório antes de qualquer etapa destrutiva; falha impede rebuild |
| WF-03: não há aceitação AWS ponta a ponta na CI | \`terraform validate\`, linters, backend tests e Docker smoke não comprovam ALB, RDS, ECS, NAT, IAM, Zabbix, shutdown/resume e teardown em conta AWS real | PENDENTE: job isolado em conta de sandbox com custo, ambiente e aprovação |
| RT-01: versões PostgreSQL diferentes | Compose local usa PostgreSQL 17; RDS e monitoring usam major 16 | PENDENTE: padronização após definir migração dos volumes locais (não fazer downgrade de volume 17 para 16) |
| RT-02: TLS | Default \`acm_certificate_arn=""\` produz ALB HTTP; OAuth/cookies de sessão seguros exigem HTTPS público | PENDENTE: certificado/domínio e configuração HTTPS antes do uso público do login |
| RT-03: stack monitoring em runtime real | Docker Compose valida YAML, mas o teste de container na CI cobre principalmente backend/frontend | PENDENTE: aceitar Grafana, Zabbix e plugins em Fargate real |
| RT-04: custo de baseline | Duas NAT Gateways, ALB ativo, possível storage/snapshots ECR e segredos geram custos mesmo com aplicação parada | PENDENTE: alertas/orçamento e auditoria de orfandade pós-migração |

## P2 — dependências e legados

- \`httpx2==2.16.0\` removido de \`requirements-dev.txt\`: não apareceu nos imports/uso dos testes e código inspecionados; \`httpx\` legítimo é dependência direta do backend e permanece.
- Mantidos \`requests\` (utilizado por \`google.auth.transport.requests\`), \`starlette\` (importação direta), \`httpx\`, \`psycopg\`, \`SQLAlchemy\`, \`alembic\`, FastAPI, PyJWT, \`google-auth\` e \`python-multipart\`, cujos usos são comprováveis no código.
- \`rebuild-dev.yml\` é uma ferramenta operacional destrutiva, **não** substitui o \`make deploy\`; deve permanecer manual, com proteção e revisão.
- Estado local \`.deploy/\`, segredos, State remoto e backups não devem ser comprometidos no Git.

## Mapa de infraestrutura esperado (código Terraform)

- Identidade/state: AWS provider, S3 state com versionamento e lockfile; bootstrap de bucket S3 protegido; tabela DynamoDB de compatibilidade (avaliar necessidade de manutenção).
- Rede: VPC, duas AZs, sub-redes pública/app/db, IGW, NAT por AZ, rotas, SGs e regras explícitas.
- Entrada: ALB HTTP/HTTPS condicionado ao certificado, listener rules e TGs frontend/backend/Grafana.
- Imagens: dois repositórios ECR com tags imutáveis e lifecycle.
- Aplicação: ECS cluster Fargate, serviços frontend/backend, monitoramento, task definitions adicionais de bootstrap/Alembic, IAM roles e políticas.
- Dados: dois RDS PostgreSQL (app e monitoring), dois DB subnet groups, Master Secrets Manager, segredos separados de runtime/migrator/auth/Grafana.
- Operação: Auto Scaling frontend/backend (CPU e memória), logs CloudWatch com retenção, health/smoke, orquestrador de custos e shutdown/resume, snapshots antes de teardown.

## Contratos de segurança da recuperação

1. Um State canônico por ambiente e nenhuma propriedade dupla de recursos.
2. Nunca importar TG/DB Subnet Group da VPC antiga para a canônica.
3. Reaproveitar recursos globais somente após verificar identidade, dependências, tags, conta e exclusividade do State; nunca alterar segredos sem consentimento e recuperação segura.
4. Descarte de recursos órfãos exige revisão de dependências reais (listeners, ENIs, DBs, serviços, versões de State) e autorização explícita; não é um side effect de \`make deploy\`.
5. Nunca substituir deleções incertas por \`terraform apply\` manual fora dos guards.
6. Exigir account/region check, State lock, backups e plano revisável na migração.
7. Evidência CI PASS ≠ aceitação AWS PASS; marcar testes reais não executados como pendentes.

## Critério de pronto

\`make deploy\` em ambiente novo deve funcionar sem correções locais. Em ambiente legado, o comando deve primeiro gerar diagnóstico claro sem mutar recursos e oferecer **um procedimento de migração dirigido e reproduzível** com aprovação única, após o qual deploy/redeploy devem ser idempotentes. Testar repetição e destroy seguro em AWS real antes de alegar 100%.

## Inspeção automatizada sem efeitos colaterais

Execute `make audit-cloud` com credenciais AWS autorizadas para ler a conta 760396521507 e os três States. A auditoria aborta se detectar quaisquer recursos vivos com propriedade em States legados. Para GitHub CD, o papel OIDC deve receber `s3:GetObject` **apenas** nos dois objetos legados adicionados em `bootstrap/github-oidc/main.tf`. Atualizar o repositório não atualiza automaticamente uma IAM Role já provisionada; a atualização do bootstrap de identidade deve ser aplicada pelo fluxo autorizado, sem ampliar direitos de escrita nos States legados.
