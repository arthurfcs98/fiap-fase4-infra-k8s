#!/bin/bash
# Bootstrap completo do ambiente local Fase 4 em k3d.
# Uso:
#   ./k3d/setup.sh              # cria cluster + infra + builda e importa imagens + deploy
#   ./k3d/setup.sh --clean      # destrói tudo antes
#   ./k3d/setup.sh --skip-build # skip docker build (usa imagens já importadas)

set -e

CLUSTER=fiap-fase4
MONOREPO="$(cd "$(dirname "$0")/.." && pwd)"   # ../ = raiz do monorepo (~/dev/fiap-fase4/fiap-fase4-infra-k8s)
FASE4_ROOT="$(cd "$MONOREPO/.." && pwd)"       # ~/dev/fiap-fase4

if [[ "$1" == "--clean" ]]; then
  echo ">>> Removendo cluster antigo…"
  k3d cluster delete $CLUSTER 2>/dev/null || true
  shift
fi

SKIP_BUILD=false
[[ "$1" == "--skip-build" ]] && SKIP_BUILD=true

if ! k3d cluster list | grep -q "^$CLUSTER "; then
  echo ">>> Criando cluster k3d ($CLUSTER)…"
  k3d cluster create $CLUSTER \
    --port "8081:80@loadbalancer" \
    --port "8444:443@loadbalancer" \
    --agents 1
else
  echo ">>> Cluster $CLUSTER já existe, reutilizando"
fi

kubectl config use-context k3d-$CLUSTER

echo ""
echo ">>> Aplicando namespaces + infra (Postgres + Mongo + RabbitMQ)…"
kubectl create namespace data --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace messaging --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace oficina --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$(dirname "$0")/infra-stack.yaml"

echo ""
echo ">>> Aguardando Postgres/Mongo/RabbitMQ ficarem prontos…"
kubectl wait --for=condition=ready pod/postgres-0 -n data --timeout=180s
kubectl wait --for=condition=ready pod/mongodb-0  -n data --timeout=180s
kubectl wait --for=condition=ready pod/rabbitmq-0 -n messaging --timeout=180s

if [[ "$SKIP_BUILD" == false ]]; then
  echo ""
  echo ">>> Buildando imagens Docker dos 3 serviços…"
  docker build -t fiap-fase4-os-service:local        "$FASE4_ROOT/fiap-fase4-os-service"
  docker build -t fiap-fase4-billing-service:local   "$FASE4_ROOT/fiap-fase4-billing-service"
  docker build -t fiap-fase4-execution-service:local "$FASE4_ROOT/fiap-fase4-execution-service"

  echo ""
  echo ">>> Importando imagens no k3d…"
  k3d image import \
    fiap-fase4-os-service:local \
    fiap-fase4-billing-service:local \
    fiap-fase4-execution-service:local \
    -c $CLUSTER
fi

echo ""
echo ">>> Aplicando manifestos dos serviços…"

# Cria secret do billing com creds MP se .env raiz existir
if [[ -f "$FASE4_ROOT/.env" ]]; then
  echo ">>> Detectado .env — criando billing-service-secrets com creds MP"
  set -a; source "$FASE4_ROOT/.env"; set +a
  kubectl create secret generic billing-service-secrets \
    --from-literal=DB_USERNAME=postgres \
    --from-literal=DB_PASSWORD=postgres \
    --from-literal=MERCADO_PAGO_ACCESS_TOKEN="${MERCADO_PAGO_ACCESS_TOKEN:-CHANGE_ME}" \
    --from-literal=MERCADO_PAGO_PUBLIC_KEY="${MERCADO_PAGO_PUBLIC_KEY:-CHANGE_ME}" \
    -n oficina \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo ">>> WARN: $FASE4_ROOT/.env não encontrado, criando secret com CHANGE_ME"
  kubectl create secret generic billing-service-secrets \
    --from-literal=DB_USERNAME=postgres \
    --from-literal=DB_PASSWORD=postgres \
    --from-literal=MERCADO_PAGO_ACCESS_TOKEN=CHANGE_ME \
    --from-literal=MERCADO_PAGO_PUBLIC_KEY=CHANGE_ME \
    -n oficina \
    --dry-run=client -o yaml | kubectl apply -f -
fi

kubectl apply -f "$FASE4_ROOT/fiap-fase4-os-service/k8s/"
kubectl apply -f "$FASE4_ROOT/fiap-fase4-billing-service/k8s/"
kubectl apply -f "$FASE4_ROOT/fiap-fase4-execution-service/k8s/"

echo ""
echo ">>> Aguardando pods dos apps…"
kubectl -n oficina rollout status deployment/os-service --timeout=180s
kubectl -n oficina rollout status deployment/billing-service --timeout=180s
kubectl -n oficina rollout status deployment/execution-service --timeout=180s

echo ""
echo "=================================================================="
echo "✅ Deploy local concluído!"
echo ""
echo "Endpoints (adicionar em /etc/hosts):"
echo "  127.0.0.1 os.localhost billing.localhost execution.localhost rabbitmq.localhost"
echo ""
echo "  OS Service:        http://os.localhost:8081/api/docs"
echo "  Billing Service:   http://billing.localhost:8081/api/docs"
echo "  Execution Service: http://execution.localhost:8081/api/docs"
echo "  RabbitMQ UI:       http://rabbitmq.localhost:8081  (guest/guest)"
echo ""
echo "Comandos úteis:"
echo "  kubectl get pods -A"
echo "  kubectl logs -n oficina -l app=os-service -f"
echo "  kubectl scale deployment/os-service -n oficina --replicas=5"
echo "=================================================================="
