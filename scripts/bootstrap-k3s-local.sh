#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-audita-local}"
REPO_URL="${REPO_URL:-https://github.com/****/infrastructure.git}"
REVISION="${REVISION:-main}"
GIT_USER="${GIT_USER:-git}"
GIT_TOKEN="${GIT_TOKEN:-}"
GHCR_USER="${GHCR_USER:-}"
GHCR_TOKEN="${GHCR_TOKEN:-}"
SECRET_FILE="${SECRET_FILE:-}"
MONGODB_URL="${MONGODB_URL:-mongodb://host.k3d.internal:27017}"
REDIS_PASSWORD="${REDIS_PASSWORD:-****}"
TOKEN_SECRET="${TOKEN_SECRET:-****}"
EMAIL_PASSWORD="${EMAIL_PASSWORD:-****}"
STAGING="${STAGING:-0}"
MINIMAL="${MINIMAL:-0}"
ISTIO_VERSION="${ISTIO_VERSION:-1.28.1}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.19.1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."

NAMESPACES=(audita)
[[ "${STAGING}" == "1" ]] && NAMESPACES+=(audita-staging)

say() { printf '\n==> %s\n' "$*"; }

command -v docker  >/dev/null || { echo "ERRO: docker não encontrado."; exit 1; }
command -v kubectl >/dev/null || { echo "ERRO: kubectl não encontrado."; exit 1; }

if [[ "${MINIMAL}" != "1" && -z "${GIT_TOKEN}" ]]; then
  echo "ERRO: o repo de infra é privado e GIT_TOKEN não foi definido."
  echo "      Crie um PAT no GitHub (leitura no repo) e rode:"
  echo "        GIT_TOKEN=ghp_**** ./scripts/bootstrap-k3s-local.sh"
  echo "      (ou MINIMAL=1 para subir só cluster + ArgoCD)"
  exit 1
fi

if [[ -n "${SECRET_FILE}" && ! -f "${SECRET_FILE}" ]]; then
  echo "ERRO: SECRET_FILE='${SECRET_FILE}' não existe."
  exit 1
fi

if ! command -v k3d >/dev/null; then
  say "Instalando k3d (k3s em Docker)..."
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi

if [[ "${MINIMAL}" != "1" ]] && ! command -v helm >/dev/null; then
  say "Instalando helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

if k3d cluster list 2>/dev/null | grep -q "^${CLUSTER_NAME}\b"; then
  say "Cluster '${CLUSTER_NAME}' já existe — reutilizando."
  k3d cluster start "${CLUSTER_NAME}" --wait
else
  say "Criando cluster k3s local '${CLUSTER_NAME}'..."
  k3d cluster create "${CLUSTER_NAME}" \
    --k3s-arg "--disable=traefik@server:0" \
    --port "8080:80@loadbalancer" \
    --port "8443:443@loadbalancer" \
    --wait
fi

kubectl config use-context "k3d-${CLUSTER_NAME}"
kubectl get nodes

if kubectl -n kube-system get deploy traefik >/dev/null 2>&1; then
  echo "    AVISO: este cluster tem Traefik (criado pelo script antigo). O"
  echo "    ingressgateway pode ficar sem porta. Recrie com:"
  echo "      k3d cluster delete ${CLUSTER_NAME} && ./scripts/bootstrap-k3s-local.sh"
fi

if [[ "${MINIMAL}" != "1" ]]; then
  say "cert-manager ${CERT_MANAGER_VERSION}..."
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s

  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  selfSigned: {}
EOF

  say "Istio ${ISTIO_VERSION}..."
  helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
  helm repo update >/dev/null
  kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install istio-base istio/base \
    -n istio-system --version "${ISTIO_VERSION}" --wait

  helm upgrade --install istiod istio/istiod \
    -n istio-system --version "${ISTIO_VERSION}" --wait \
    --set pilot.resources.requests.cpu=150m \
    --set pilot.resources.requests.memory=384Mi \
    --set pilot.autoscaleEnabled=false \
    --set pilot.env.ENABLE_NATIVE_SIDECARS=true \
    --set global.proxy.resources.requests.cpu=25m \
    --set global.proxy.resources.requests.memory=48Mi \
    --set global.proxy.resources.limits.cpu=200m \
    --set global.proxy.resources.limits.memory=192Mi \
    --set meshConfig.defaultConfig.concurrency=2 \
    --set meshConfig.defaultConfig.holdApplicationUntilProxyStarts=true \
    --set meshConfig.accessLogFile=""

  helm upgrade --install istio-ingressgateway istio/gateway \
    -n istio-system --version "${ISTIO_VERSION}" --wait \
    --set resources.requests.cpu=75m \
    --set resources.requests.memory=128Mi \
    --set autoscaling.enabled=false \
    --set replicaCount=1 \
    --set service.type=LoadBalancer

  for ns in "${NAMESPACES[@]}"; do
    say "Namespace '${ns}' + Secrets..."
    kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace "${ns}" name="${ns}" istio-injection=enabled --overwrite

    if [[ -n "${SECRET_FILE}" ]]; then
      sed -E "s#^(\s*namespace:).*#\1 ${ns}#" "${SECRET_FILE}" | kubectl apply -f -
    else
      literals=()
      for key in $(sed -n '/^stringData:/,$p' "${REPO_DIR}/base/secret.example.yaml" \
                     | grep -oE '^\s+[a-z0-9-]+:' | tr -d ' :'); do
        case "${key}" in
          mongodb-url)    literals+=("--from-literal=${key}=${MONGODB_URL}") ;;
          redis-password) literals+=("--from-literal=${key}=${REDIS_PASSWORD}") ;;
          token-secret)   literals+=("--from-literal=${key}=${TOKEN_SECRET}") ;;
          email-password) literals+=("--from-literal=${key}=${EMAIL_PASSWORD}") ;;
          *)              literals+=("--from-literal=${key}=****") ;;
        esac
      done
      kubectl create secret generic audita -n "${ns}" "${literals[@]}" \
        --dry-run=client -o yaml | kubectl apply -f -
    fi

    if [[ -n "${GHCR_USER}" && -n "${GHCR_TOKEN}" ]]; then
      kubectl create secret docker-registry ghcr -n "${ns}" \
        --docker-server=ghcr.io \
        --docker-username="${GHCR_USER}" \
        --docker-password="${GHCR_TOKEN}" \
        --dry-run=client -o yaml | kubectl apply -f -
    else
      echo "    (sem GHCR_USER/GHCR_TOKEN: imagens privadas vão dar ImagePullBackOff)"
    fi
  done
fi

say "Instalando o ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side --force-conflicts -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

say "Aguardando o ArgoCD subir..."
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-applicationset-controller --timeout=300s

if [[ "${MINIMAL}" == "1" ]]; then
  say "MINIMAL=1: cluster + ArgoCD prontos. Pulando Istio, Secrets e GitOps."
  echo
  echo "Senha inicial do admin do ArgoCD:"
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d ; echo
  echo
  echo "UI (user: admin): kubectl -n argocd port-forward svc/argocd-server 8081:443"
  echo "Para destruir: k3d cluster delete ${CLUSTER_NAME}"
  exit 0
fi

say "Registrando o repo privado '${REPO_URL}' no ArgoCD..."
kubectl apply -n argocd -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-infra
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${REPO_URL}
  username: ${GIT_USER}
  password: ${GIT_TOKEN}
EOF

if kubectl -n argocd get application root >/dev/null 2>&1; then
  say "Removendo o root-app antigo (sem cascata)..."
  kubectl -n argocd patch application root --type merge -p '{"metadata":{"finalizers":null}}'
  kubectl -n argocd delete application root --wait=false
fi

ARGO_FILES=(project.yaml applicationset.yaml base-app.yaml)
if [[ "${STAGING}" == "1" ]]; then
  ARGO_FILES+=(applicationset-staging.yaml base-staging-app.yaml)
else
  kubectl -n argocd delete applicationset audita-services-staging --ignore-not-found
  kubectl -n argocd delete application base-staging --ignore-not-found
fi

say "Aplicando argocd/ -> ${REPO_URL}@${REVISION}..."
for f in "${ARGO_FILES[@]}"; do
  sed -E \
    -e "s#https://github.com/****/infrastructure.git#${REPO_URL}#g" \
    -e "s#^(\s*(targetRevision|revision):)\s*main\s*\$#\1 ${REVISION}#" \
    "${REPO_DIR}/argocd/${f}" | kubectl apply -f -
done

say "PRONTO. O ArgoCD está sincronizando '${REPO_URL}@${REVISION}'."
echo
echo "Senha inicial do admin do ArgoCD:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d ; echo
echo
echo "UI (user: admin):"
echo "  kubectl -n argocd port-forward svc/argocd-server 8081:443"
echo "  # navegador: https://localhost:8081"
echo
echo "Acompanhar:"
echo "  kubectl get applications -n argocd -w"
echo "  kubectl get pods -n audita -w"
echo "  kubectl -n argocd annotate app <nome> argocd.argoproj.io/refresh=hard --overwrite"
echo
echo "Bater no gateway (hosts em apps/mesh/values.yaml; cert auto-assinado):"
echo "  curl -k --resolve <host>:8443:127.0.0.1 https://<host>:8443/"
echo
echo "Trocar de branch: rode de novo com outro REVISION."
echo "Destruir tudo (não deixa resíduo no host): k3d cluster delete ${CLUSTER_NAME}"
