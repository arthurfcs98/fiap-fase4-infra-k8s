# Infra K8s — Fase 4 Tech Challenge FIAP

Terraform que provisiona a **infraestrutura Kubernetes** compartilhada pelos 3 microsserviços:

- **VPC** dedicada (`10.30.0.0/16`) com 2 subnets públicas em AZs distintas
- **Amazon EKS** v1.30 com managed node group (2× t3.small)
- **NGINX Ingress Controller** (via Helm, expõe NLB internet-facing)
- **RabbitMQ** self-hosted no cluster (Helm chart bitnami, namespace `messaging`)
- **MongoDB** self-hosted (Helm chart bitnami, namespace `data`, standalone)

RDS Postgres fica no repo separado [`fiap-fase4-infra-db`](https://github.com/arthurfcs98/fiap-fase4-infra-db).

## Estratégia

- Blitz mode AWS Academy: `terraform apply` → gravação vídeo → `terraform destroy` (mesmo padrão da Fase 3, ~$15-20/dia)
- Ingress único NLB atende os 3 serviços (`/os`, `/billing`, `/execution`)
- Broker (RabbitMQ) e NoSQL (Mongo) rodam no próprio cluster — economiza recurso AWS e mostra "microsserviço mesh completo" no vídeo
- Postgres fica gerenciado (RDS) porque atende requisito de "banco relacional" com backup automático

## Rodando

```bash
cd terraform
export AWS_PROFILE=fiap  # STS Academy
terraform init
terraform apply
```

Depois:
```bash
aws eks update-kubeconfig --name fiap-fase4-eks --region us-east-1
kubectl apply -f ../../fiap-fase4-os-service/k8s/
kubectl apply -f ../../fiap-fase4-billing-service/k8s/
kubectl apply -f ../../fiap-fase4-execution-service/k8s/
```

## Destroy

Ordem reversa das dependências (mesmo padrão Fase 3):
```bash
cd ~/dev/fiap-fase4/fiap-fase4-infra-db/terraform && terraform destroy -auto-approve
cd ~/dev/fiap-fase4/fiap-fase4-infra-k8s/terraform && terraform destroy -auto-approve
```

## CI/CD

`.github/workflows/terraform.yml` — fmt + init + validate + plan em PR, apply em push na main. STS creds via GitHub Secrets (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`).

## Backend

State: `s3://fiap-fase4-tfstate/infra-k8s/terraform.tfstate` com lock via DynamoDB `fiap-fase4-tflock`. Bucket e tabela devem ser criados uma vez antes do primeiro apply (via CloudFormation/manual/script auxiliar).
