# NOVA TESTE1 — Deploy, shutdown, resume e teardown (03/11/2026)

**Runbook operacional para `main` e `TESTE1` (integrado na `main` em 04/11/2026).** A alteração de scripts passou na [NOVA CI #41690248888](https://github.com/joao-henrike/NOVA/actions/runs/41690248888) (8 checks aprovados; commit `4ff8ebf`). **Não houve provisionamento, desligamento, retomada ou destruição reais na AWS nesta revisão.** A CI não comprova disponibilidade de recursos reais.

Este é o procedimento operacional para a branch `main` e a `TESTE1`. O deploy local aceita `main`, `Joao` e `TESTE1`; o orquestrador de desligamento completo aceita `main` e `TESTE1`. A automação GitHub Actions com OIDC continua intencionalmente restrita à `Joao`: não confunda `make deploy` local com deploy automático via GitHub.

## 0. Fonte de verdade operacional

Este arquivo é **o único roteiro de execução** das branches `main` e `TESTE1`. O [README principal](../README.md) resume os comandos; [deployment.md](deployment.md), [operations.md](operations.md), [configuration-reference.md](configuration-reference.md) e [local-development.md](local-development.md) são referências técnicas. O [README histórico arquivado](archive/README-JOAO-HISTORICO.md) **não deve ser utilizado** para mudanças AWS. Se houver divergência, prevalece o comportamento real do Makefile/scripts/Terraform, e a documentação deve ser corrigida.

## 1. Verificações prévias (CloudShell)

O perfil da conta em `config/dev.env` deve corresponder à conta real. Antes de `make deploy`, `git status --porcelain` precisa estar vazio: alterações de conteúdo ou permissão em arquivos rastreados e arquivos não rastreados bloqueiam o deploy. O helper de state tem bit executável versionado no Git. Não altere os controles de identidade para contornar erros. É preciso AWS CLI, Docker/daemon, jq, Git, Make, unzip, Python 3.12+, região us-east-1 e permissões AWS autorizadas. O `make setup` instala Terraform/TFLint/Python venv, mas não instala automaticamente o Python 3.12 do sistema ou jq. Verifique espaço em disco porque builds Docker e Terraform consomem espaço na CloudShell.

```bash
git clone --branch main https://github.com/joao-henrike/NOVA.git
cd NOVA
git status --short --branch
aws sts get-caller-identity
docker info
df -h "$HOME" /tmp
make setup
make doctor
make validate
make tf-validate
make test-deployment-contracts
make ops-test
```

**Essas verificações não criam infraestrutura AWS.** O `make ops-test` utiliza AWS simulada. Não confunda `make start` (Compose local) com `make deploy` (infraestrutura AWS).

## 2. Deploy completo (com cobranças)

```bash
# Verifique antes a conta e a região.
make deploy
```

O script prepara secrets e state S3; aplica a infraestrutura base; publica imagens frontend/backend no ECR; registra revisões ECS; provisiona os papéis PostgreSQL; roda Alembic e grants; ativa as tarefas e faz smoke checks de ALB/API/Grafana.

**Retomada de deploy parcial:** um State não vazio não prova que VPC, RDS, ECS ou ALB estejam completos. Quando **não existem serviços ECS de aplicação/monitoramento registrados no State**, o deploy sempre planeja uma reconciliação de baseline com refresh real, protegida por `scripts/check-baseline-plan.sh`. O guard permite criar recursos ausentes, atualizar exclusivamente a regra conhecida `alb_http[0]` e retirar somente as regras legadas `frontend_https`, `monitoring_db_all` e `rds_all`; outras modificações, exclusões e substituições abortam. Se já houver serviços ECS registrados, o baseline não será reaplicado automaticamente: alterações não previstas exigem análise. **Não apague nem recrie o State para contornar divergências.**

O segundo plano do Terraform é validado por `scripts/check-application-plan.sh`. Somente mudanças enumeradas são permitidas. Substituições `create,delete` ou `delete,create` são permitidas para **cinco** ECS task definitions; deleções de ECS services, RDS ou recursos fora do escopo são bloqueadas. Planos fora da lista não devem ser contornados com `terraform apply` manual.

Se a implantação falhar no meio, **a AWS pode continuar cobrando por recursos já criados**. Inspecione o state e o inventário antes de repetir o deploy.

## 3. Inspeção, pausa e retomada

```bash
make ops ACTION=overview
make ops ACTION=services
make ops ACTION=costs
make ops ACTION=logs ARGS='backend --since 2h'

# Reversível, mas não representa custo zero:
make ops ACTION=shutdown
make ops ACTION=resume
```

`shutdown` para tarefas ECS e bancos RDS e remove NAT/ALB por plano Terraform estritamente controlado. `resume` recria recursos e reativa serviços. Ambos exigem confirmação manual. Não confundem desligamento temporário com destruição total.

## 4. Exclusão do projeto — operação destrutiva

```bash
make inventory-cloud
make destroy-all
# OU, se deseja também agendar a exclusão dos segredos externos:
make destroy-all-with-secrets
```

Após confirmação exata da conta/região, `destroy-all`:
1. Faz inventário inicial.
2. Para **cada banco RDS nomeado** (`cloudstart-dev-db`, `cloudstart-dev-monitoring-db`), se existente: exige estado `available` (inicia se `stopped`), cria um snapshot manual de nome único e aguarda ficar disponível. **Qualquer erro nessa etapa aborta antes de executar Terraform destroy.**
3. Aplica `terraform destroy` aos estados remoto canônico e legados configurados, registrando falhas separadamente.
4. Limpa as stacks Docker Compose locais e inventaria sobras.
5. Só reporta limpeza satisfatória se não houver falhas de etapas nem sobras inesperadas. Erros ao inspecionar o state não são mais confundidos com sucesso.

**Itens preservados por projeto:** bucket S3 do state (e histórico versionado), snapshots manuais pré-destruição e, por padrão, os três segredos externos da aplicação. Esses elementos podem continuar gerando custos. Não são considerados sobras inesperadas no relatório, mas permanecem visíveis no inventário.

**Exclusão opcional de segredos:** `make destroy-all-with-secrets` solicita a frase de confirmação adicional `DELETE_SECRETS` e agenda a exclusão **apenas** de:
- `cloudstart-dev/database/runtime`
- `cloudstart-dev/database/migrator`
- `cloudstart-dev/backend/authentication`

A exclusão usa **janela de recuperação de 7 dias**, não remoção forçada. Se quiser implantar antes de encerrar essa janela, será necessário restaurar as entradas que estiverem pendentes de exclusão. A exclusão opcional é pulada quando alguma etapa Terraform anterior falhou.

Recursos AWS não gerenciados pelos estados conhecidos **não são removidos de forma arbitrária**. Eles são reportados como sobras e exigem revisão. A rotina não garante uma conta AWS vazia, uma fatura zerada nem exclusão de todos os snapshots existentes.

Os relatórios ficam em `.deploy/destroy-all-<UTC>/`, incluindo `inventory-before.txt`, `inventory-after.txt`, `results.tsv`, logs e `snapshots-preserved.txt`.

**Não execute `terraform destroy` diretamente** como substituto desse fluxo: isso contorna a criação obrigatória de snapshots, e os arquivos de configuração RDS do ambiente `dev` usam `skip_final_snapshot`.

## 5. Evidências do primeiro ciclo real — pendentes

Registre para cada etapa a data/hora, commit, conta/region (nunca credenciais), comando, resultado PASS/FAIL/SKIPPED e link/caminho do relatório. Etapas a comprovar: pré-requisitos e espaço CloudShell; `doctor`/Terraform; deploy (state, VPC, RDS, NAT, ALB, ECR, ECS); saúde HTTP/API/Grafana/Zabbix; custos e sobras; `shutdown`; `resume`; snapshots RDS; `destroy-all`; novo inventário. Uma verificação não executada continua **SKIPPED**, não PASS.

## 6. Cobertura e próximos testes reais

`scripts/test-deployment-contracts.sh` utiliza fixtures JSON de Terraform e AWS simulada para verificar substituição permitida de task definitions, proibição de mudanças fora da lista e falha segura de snapshot. A CI também verifica sintaxe shell, código backend, contêineres e validade estática do Terraform.

Esses testes **não comprovam** IAM real, cotas AWS, inicialização de RDS, lançamento de ECS, resposta ALB, saúde Grafana/Zabbix, ciclo shutdown/resume ou destruição/reconstrução reais. O teste de aceitação no CloudShell deve registrar: identidade/conta, plano baseline, recursos provisionados, saúde dos serviços, comando de pausa/retomada, snapshots, teardown, resíduos e custos.

A metodologia aqui é **KISS**: scripts pequenos, allowlists explícitas, confirmação manual em operações destrutivas, falhar fechado quando houver dúvida e relatórios simples para retomar o diagnóstico.
