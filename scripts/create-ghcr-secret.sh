#!/usr/bin/env bash
set -euo pipefail

NAMESPACES=("audita" "audita-staging")
SECRET_NAME="ghcr"

: "${GHCR_USER:?defina GHCR_USER}"
: "${GHCR_TOKEN:?defina GHCR_TOKEN}"

for ns in "${NAMESPACES[@]}"; do
  if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "==> $ns não existe ainda, pulando (o base-app cria)"
    continue
  fi

  echo "==> $ns"

  kubectl create secret docker-registry "$SECRET_NAME" \
    --namespace "$ns" \
    --docker-server=ghcr.io \
    --docker-username="$GHCR_USER" \
    --docker-password="$GHCR_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "    ok — se foi rotação de token, reinicie os deployments:"
  echo "    kubectl -n $ns rollout restart deployment --all"
done

echo
echo "==> conferir"
echo "    kubectl -n audita get sa certificates -o jsonpath='{.imagePullSecrets}'"
