# CloudStart — Terraform Frontend

Infraestrutura Terraform do frontend CloudStart.

## Escopo

Este módulo cobre as 15 tasks de frontend relacionadas à infraestrutura/release:

- ECR do frontend
- Tags imutáveis
- Scan-on-push
- Lifecycle do ECR
- Target Group HTTP :80
- Health check `/health`
- ECS Fargate Task Definition
- Endpoint `/health` no container
- ECS Service
- Subnets privadas
- Desired/min 2 tasks
- Publicação da imagem via CI
- Validação da rota `/`
- Validação de ausência de IP público

A infraestrutura foi organizada para receber a VPC, subnets, ECS Cluster, Security Group e ALB já criados pelo projeto principal.

## Estrutura

```text
cloudstart-terraform/
├── environments/
│   └── dev/
│       ├── backend.tf
│       ├── main.tf
│       ├── providers.tf
│       ├── variables.tf
│       ├── terraform.tfvars.example
│       └── outputs.tf
│
├── modules/
│   └── frontend/
│       ├── ecr.tf
│       ├── ecs.tf
│       ├── iam.tf
│       ├── logs.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── versions.tf
│
├── apps/
│   └── frontend/
│       ├── Dockerfile
│       └── nginx.conf
│
└── .gitignore
```

## Boas práticas utilizadas

- Variáveis em vez de valores hardcoded.
- Tags padronizadas.
- `IMMUTABLE` no ECR.
- Scan-on-push habilitado.
- Lifecycle para limpeza de imagens antigas.
- Tasks ECS em subnets privadas.
- `assign_public_ip = false`.
- Duas tasks como capacidade mínima.
- Health check no ALB e no container.
- Deployment circuit breaker com rollback.
- CloudWatch Logs.
- IAM separado entre execution role e task role.
- `secrets` não ficam no Terraform.
- Imagem recomendada por digest para releases.
- `terraform.tfvars` fora do Git.
- Backend remoto preparado para S3 + locking.
- Outputs para facilitar integração com CI/CD.

## Fluxo

```text
GitHub
   |
   | CI/CD
   v
ECR frontend
   |
   | image digest
   v
ECS Fargate Service
   |
   +---- Task 1 ----+
   |                |
   +---- Task 2 ----+---- Target Group :80
                         |
                         v
                       ALB
                         |
                         v
                    Internet
```

## Deploy

Na primeira execução:

```bash
cd environments/dev

terraform init
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

### Importante

O módulo espera que estes recursos já existam no projeto principal:

- VPC
- ECS Cluster
- ALB
- Security Group do frontend
- Subnets privadas de aplicação
- Listener HTTP/HTTPS

Os IDs/ARNs são recebidos por variável para evitar acoplamento.

## Publicação da imagem

O Terraform cria o ECR, mas a publicação da imagem deve ser responsabilidade do CI/CD.

Exemplo:

```bash
docker build -t cloudstart-frontend:local ./apps/frontend

aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin <ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com

docker tag cloudstart-frontend:local \
  <ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com/cloudstart/frontend:<GIT_SHA>

docker push \
  <ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com/cloudstart/frontend:<GIT_SHA>
```

Depois, o pipeline deve atualizar a Task Definition usando o digest da imagem aprovada.

## Por que não usar `latest`?

O ECR está configurado como `IMMUTABLE`. Releases devem utilizar uma referência rastreável, preferencialmente:

```text
repository@sha256:<digest>
```

Isso facilita rollback, auditoria e identificação exata do artefato executado.
