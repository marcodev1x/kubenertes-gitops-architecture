#!/usr/bin/env bash
set -euo pipefail

ISTIO_VERSION="${ISTIO_VERSION:-1.28.1}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.19.1}"
ACME_EMAIL="${ACME_EMAIL:-contato@****}"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

echo "==> 1. cert-manager ${CERT_MANAGER_VERSION} (emite o TLS do gateway)"
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s

echo "==> 2. ClusterIssuer do Let's Encrypt — desafio DNS-01 pela Cloudflare"
if ! kubectl -n cert-manager get secret cloudflare-api-token >/dev/null 2>&1; then
  echo "    !! Secret cloudflare-api-token nao existe em cert-manager."
  echo "       Crie-o (comando no comentario acima) e rode este script de novo."
  exit 1
fi

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-account
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
EOF

echo "==> 3. Helm (se ainda não existir)"
command -v helm >/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
helm repo update >/dev/null

kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -

echo "==> 4. istio-base (CRDs)"
helm upgrade --install istio-base istio/base \
  -n istio-system --version "${ISTIO_VERSION}" --wait

echo "==> 5. istiod — afinado para VPS pequena"
helm upgrade --install istiod istio/istiod \
  -n istio-system --version "${ISTIO_VERSION}" --wait \
  --set pilot.resources.requests.cpu=150m \
  --set pilot.resources.requests.memory=384Mi \
  --set pilot.resources.limits.cpu=800m \
  --set pilot.resources.limits.memory=768Mi \
  --set pilot.autoscaleEnabled=false \
  --set pilot.env.ENABLE_NATIVE_SIDECARS=true \
  --set global.proxy.resources.requests.cpu=25m \
  --set global.proxy.resources.requests.memory=48Mi \
  --set global.proxy.resources.limits.cpu=200m \
  --set global.proxy.resources.limits.memory=192Mi \
  --set meshConfig.defaultConfig.concurrency=2 \
  --set meshConfig.defaultConfig.holdApplicationUntilProxyStarts=true \
  --set meshConfig.accessLogFile=""

echo "==> 6. ingressgateway"
helm upgrade --install istio-ingressgateway istio/gateway \
  -n istio-system --version "${ISTIO_VERSION}" --wait \
  --set resources.requests.cpu=75m \
  --set resources.requests.memory=128Mi \
  --set resources.limits.cpu=1 \
  --set resources.limits.memory=384Mi \
  --set autoscaling.enabled=false \
  --set replicaCount=1 \
  --set service.type=LoadBalancer

echo
echo "==> PRONTO. Verificações:"
echo "  kubectl -n istio-system get pods"
echo "  kubectl -n istio-system get svc istio-ingressgateway   # IP externo = IP da VPS"
echo "  kubectl get ns audita -o jsonpath='{.metadata.labels}'  # istio-injection: enabled"
echo
echo "Só então aplique o App of Apps:"
echo "  kubectl apply -f argocd/root-app.yaml"
