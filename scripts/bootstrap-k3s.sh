#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/****/infrastructure.git}"

echo "==> 1. Instalando k3s SEM Traefik"
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644 --disable=traefik" sh -

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo "==> k3s pronto. Nós:"
kubectl get nodes

echo "==> 2. Namespace da aplicação"
kubectl apply -f https://raw.githubusercontent.com/****/infrastructure/main/base/namespace.yaml \
  2>/dev/null || kubectl create namespace audita --dry-run=client -o yaml | kubectl apply -f -

echo "==> 3. Instalando ArgoCD (versão enxuta para VPS pequena)"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "==> Aguardando o ArgoCD subir..."
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

echo
echo "==> PRONTO. Senha inicial do admin do ArgoCD:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d ; echo
echo
echo "Acesse a UI com um túnel a partir da SUA máquina:"
echo "  ssh -L 8080:localhost:8080 root@SEU_IP_DA_VPS"
echo "  # e na VPS:  kubectl -n argocd port-forward svc/argocd-server 8080:443"
echo "  # navegador: https://localhost:8080  (user: admin)"
echo
echo "PRÓXIMO PASSO — a malha, ANTES do root-app:"
echo "  ./scripts/bootstrap-istio.sh"
echo
echo "Os charts de apps/* criam Gateway, VirtualService e DestinationRule. Sem os"
echo "CRDs do Istio no cluster, o ArgoCD falha a sincronizar quase tudo."
echo
echo "Só então o App of Apps (uma vez):"
echo "  kubectl apply -f argocd/root-app.yaml"
