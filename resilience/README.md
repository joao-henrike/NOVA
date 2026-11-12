# NOVA — Resilience & Chaos Engineering Lab

Laboratório isolado de demonstrações de disponibilidade do `cloudstart/dev` em AWS `us-east-1`.

**Estado:** os testes de leitura verificam a configuração e a saúde real; apenas o modo
`task-recovery`, acionado explicitamente, injeta uma falha **em uma tarefa ECS**.
Não simula desligamento de uma região AWS, não derruba VPC, RDS, ALB, NAT,
nem executa carga agressiva.

## Pré-requisitos

- AWS CLI autenticada na conta **996560371158** em `us-east-1`, Python 3.10+.
- Permissões de leitura para STS, ECS, ELBv2, RDS, EC2 e Application Auto Scaling.
- Somente para `task-recovery`: `ecs:StopTask` limitado ao ambiente de desenvolvimento.
- Não executar em produção nem durante deploys, incidentes ou apresentação que precise de disponibilidade contínua.

## Demonstração sem alterações na AWS (recomendada)

```bash
cd ~/NOVA
git fetch origin main
git show origin/main:resilience/run.py > /tmp/nova-resilience-run.py
python3 /tmp/nova-resilience-run.py all --report-dir "$HOME/nova-resilience-reports"
```

Testes independentes:

```bash
python3 resilience/run.py baseline
python3 resilience/run.py alb
python3 resilience/run.py autoscaling
python3 resilience/run.py az
```

| Cenário | Prova | Limitação |
| --- | --- | --- |
| `baseline` | ECS 2/2 + 2/2 + 1/1, health dos targets, RDS e endpoints HTTP | Não prova fluxos de negócio |
| `alb` | Target groups saudáveis e 12 requisições sequenciais | Não prova distribuição por task nem throughput |
| `autoscaling` | Targets, min/max e políticas de target tracking | Não provoca scale-out; configuração ≠ scaling observado |
| `az` | AZs do ALB, placement atual das tasks, MultiAZ dos RDS | Não é uma interrupção de AZ nem região |

### Injeção controlada: recuperar UMA tarefa ECS

**Opcional; pode causar indisponibilidade temporária.** Executar só em
ambiente próprio e com autorização operacional. Este teste só permite `frontend`
ou `backend`, exige duas tarefas saudáveis e deploy estável, para após **uma**
interrupção, acompanha a substituição até 8 minutos e não repete a falha.

```bash
python3 resilience/run.py task-recovery \
  --service frontend \
  --confirm "STOP ONE FRONTEND TASK"
```

Backend, em outra execução, se necessário:

```bash
python3 resilience/run.py task-recovery \
  --service backend \
  --confirm "STOP ONE BACKEND TASK"
```

O teste não para o monitoramento e não altera DesiredCount, Terraform,
Auto Scaling, balanceador ou configuração dos serviços.
O `ecs:StopTask` solicita o encerramento de **uma** task; o ECS normalmente
repõe essa task conforme a quantidade desejada. Falhas transitórias podem
ocorrer mesmo quando o experimento termina em `PASS`.

### Região indisponível: limitação arquitetural real

A implantação atual está somente em `us-east-1`.
Distribuir recursos em duas AZs da **mesma região** não cria
failover multi-região. Os RDS de desenvolvimento normalmente são Single-AZ.
O teste `az` relata essas limitações como avisos, sem alegar disponibilidade
em outra região. Uma demonstração real de disaster recovery exigiria um
segundo ambiente independente, cópias de dados, roteamento DNS e testes
de recuperação previamente planejados. Não tentar “desligar uma região”.

### Relatórios e custos

Os relatórios JSON são salvos em `.deploy/resilience/` (diretório privado).
Não publique IDs privados ou inventários detalhados sem revisar.
O experimento opcional pode movimentar tarefas ECS, gerar métricas/logs e custos.
Nenhum teste exclui recursos, altera segredos ou roda Terraform.

### Executar testes locais sem AWS

```bash
python3 -m unittest discover -s resilience/tests -v
```

**Critério de aprovação:** `FAIL=0`; `WARN` documenta limitações não
comprovadas. Não confundir prova de configuração com prova de comportamento.
