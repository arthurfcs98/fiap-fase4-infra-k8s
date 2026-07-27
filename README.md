# Infra K8s (LOCAL) — Fase 4 Tech Challenge FIAP

Branch **`local`** — orquestra o ambiente de desenvolvimento em Kubernetes local via [k3d](https://k3d.io/) (K3s rodando em Docker). Zero custo, roda offline.

Para infra AWS (EKS + Helm charts), veja a branch [`aws`](../../tree/aws).

## O que sobe

| Componente | Namespace | Como | Imagem |
|---|---|---|---|
| PostgreSQL 16 | `data` | StatefulSet + PVC | `postgres:16-alpine` (oficial) |
| MongoDB 7 | `data` | StatefulSet + PVC | `mongo:7` (oficial) |
| RabbitMQ 3.13 + management UI | `messaging` | StatefulSet + PVC | `rabbitmq:3.13-management-alpine` (oficial) |
| OS Service (2 réplicas + HPA) | `oficina` | Deployment | build local via `docker build` |
| Billing Service (2 réplicas + HPA) | `oficina` | Deployment | build local |
| Execution Service (2 réplicas + HPA) | `oficina` | Deployment | build local |

Ingress via Traefik (default do k3d) → hosts `os.localhost`, `billing.localhost`, `execution.localhost`, `rabbitmq.localhost` na porta `8081`.

## Setup completo em 1 comando

```bash
./k3d/setup.sh
```

Faz tudo: cria o cluster, aplica infra, builda as imagens dos 3 serviços, importa no cluster e aplica os manifestos. Termina imprimindo os endpoints.

**Pré-requisitos:**
```bash
brew install k3d helm kubectl docker
```

**Antes de rodar:** adiciona os hosts locais em `/etc/hosts`:
```bash
echo "127.0.0.1 os.localhost billing.localhost execution.localhost rabbitmq.localhost" | sudo tee -a /etc/hosts
```

E cria `../.env` na raiz do monorepo (ou nesse repo) com as creds do Mercado Pago:
```
MERCADO_PAGO_ACCESS_TOKEN=APP_USR-...
MERCADO_PAGO_PUBLIC_KEY=APP_USR-...
```

## Comandos úteis

```bash
# Reset total do cluster
./k3d/setup.sh --clean

# Re-deploy dos apps sem rebuildar
./k3d/setup.sh --skip-build

# Ver todos os pods
kubectl get pods -A

# Logs de um serviço
kubectl logs -n oficina -l app=os-service -f

# Escalar manualmente (o HPA vai devolver pra 2-5)
kubectl scale deployment/os-service -n oficina --replicas=4

# Ver HPA em ação
kubectl get hpa -n oficina -w

# Deletar cluster
k3d cluster delete fiap-fase4
```

## Repositórios relacionados (Fase 4)

- [fiap-fase4-os-service](https://github.com/arthurfcs98/fiap-fase4-os-service) (branch `local`)
- [fiap-fase4-billing-service](https://github.com/arthurfcs98/fiap-fase4-billing-service) (branch `local`)
- [fiap-fase4-execution-service](https://github.com/arthurfcs98/fiap-fase4-execution-service) (branch `local`)
- [fiap-fase4-infra-db](https://github.com/arthurfcs98/fiap-fase4-infra-db) (branch `local` = docker apenas, sem RDS)
