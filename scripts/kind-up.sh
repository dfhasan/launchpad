#!/usr/bin/env bash
# Local GitOps lab: kind cluster + Argo CD + the Launchpad ApplicationSet.
# Needs: docker, kind, kubectl.   Usage: scripts/kind-up.sh [--build ../safebrief]
set -euo pipefail
cd "$(dirname "$0")/.."

ARGOCD_VERSION="v3.1.8"
REPO_URL="${REPO_URL:-$(git remote get-url origin 2>/dev/null | sed -E 's#git@github.com:#https://github.com/#')}"
: "${REPO_URL:?push this repo to GitHub first (Argo CD pulls from Git), or set REPO_URL}"

if ! kind get clusters | grep -qx launchpad; then
  kind create cluster --config gitops/bootstrap/kind-config.yaml
fi
kubectl config use-context kind-launchpad >/dev/null

# Optional: build SafeBrief locally and load it into kind (no registry needed).
if [ "${1:-}" = "--build" ]; then
  app_dir="${2:?path to the safebrief checkout}"
  tag="local-$(git -C "$app_dir" rev-parse --short=12 HEAD)"
  docker build -f apps/safebrief/Dockerfile -t "ghcr.io/dfhasan/safebrief:$tag" "$app_dir"
  kind load docker-image "ghcr.io/dfhasan/safebrief:$tag" --name launchpad
  echo ">> Built $tag. Put it in gitops/apps/safebrief/overlays/dev/kustomization.yaml (newTag), commit and push."
fi

echo ">> Installing Argo CD $ARGOCD_VERSION"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
kubectl -n argocd patch svc argocd-server -p \
  '{"spec":{"type":"NodePort","ports":[{"name":"https","port":443,"targetPort":8080,"nodePort":30443}]}}'
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-applicationset-controller --timeout=300s

# Secrets are created here, never committed to Git.
# (Production answer: External Secrets Operator pulling from AWS Secrets Manager.)
for env in dev prod; do
  ns="safebrief-$env"
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  if ! kubectl -n "$ns" get secret safebrief-secrets >/dev/null 2>&1; then
    kubectl -n "$ns" create secret generic safebrief-secrets \
      --from-literal=APP_KEY="base64:$(head -c 32 /dev/urandom | base64)" \
      --from-literal=DB_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')" \
      --from-literal=DB_ROOT_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"
  fi
done

echo ">> Registering ApplicationSet for $REPO_URL"
sed "s#REPO_URL#${REPO_URL}#g" gitops/bootstrap/applicationset.yaml | kubectl apply -f -

pass=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
cat <<MSG

  Argo CD UI : https://localhost:8443   (user: admin  password: $pass)
  dev        : http://localhost:8080
  prod       : http://localhost:8081

  Change anything under gitops/apps/, push to main, and watch Argo CD sync it.
  Try: kubectl -n safebrief-dev scale deploy/web --replicas=5   -> self-heal puts it back.
MSG
