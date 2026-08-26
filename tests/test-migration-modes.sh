#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/redash-chart-migrations.XXXXXX")"
trap 'rm -rf -- "$tmp_dir"' EXIT

base_args=(
  --namespace default
  --set postgresql.enabled=false
  --set redis.enabled=false
  --set-string externalPostgreSQL=postgresql://redash:password@postgresql:5432/redash
  --set-string externalRedis=redis://redis:6379/0
  --set redash.secretKey=test
  --set redash.cookieSecret=test
)

default_render="$tmp_dir/default.yaml"
helm template redash "$repo_root" "${base_args[@]}" >"$default_render"
[[ "$(grep -c '^kind: Job$' "$default_render")" -eq 2 ]]
[[ "$(grep -c 'helm.sh/hook: post-' "$default_render")" -eq 2 ]]

legacy_render="$tmp_dir/legacy.yaml"
helm template redash "$repo_root/release/redash-3.0.16.tgz" \
  "${base_args[@]}" >"$legacy_render"
sed -E 's/helm.sh\/chart: redash-[^[:space:]]+/helm.sh\/chart: redash-VERSION/' \
  "$default_render" >"$tmp_dir/default-normalized.yaml"
sed -E 's/helm.sh\/chart: redash-[^[:space:]]+/helm.sh\/chart: redash-VERSION/' \
  "$legacy_render" >"$tmp_dir/legacy-normalized.yaml"
diff -u "$tmp_dir/legacy-normalized.yaml" "$tmp_dir/default-normalized.yaml"

argo_render="$tmp_dir/argocd.yaml"
helm template redash "$repo_root" "${base_args[@]}" \
  --set migration.mode=argocd-job \
  --set tests.enabled=false >"$argo_render"

[[ "$(grep -c '^kind: Job$' "$argo_render")" -eq 1 ]]
grep -Fq 'name: redash-db-migration' "$argo_render"
grep -Fq 'argocd.argoproj.io/sync-wave: "1"' "$argo_render"
grep -Fq 'argocd.argoproj.io/sync-options: Force=true,Replace=true' "$argo_render"
grep -Fq '. /config/dynamicenv.sh && exec /app/manage.py db upgrade' "$argo_render"
grep -Fq 'sidecar.istio.io/inject: "false"' "$argo_render"
grep -Fq 'backoffLimit: 0' "$argo_render"

deployment_count="$(grep -c '^kind: Deployment$' "$argo_render")"
[[ "$deployment_count" -gt 0 ]]
[[ "$deployment_count" -eq "$(grep -c 'argocd.argoproj.io/sync-wave: \"2\"' "$argo_render")" ]]

if grep -Eq 'helm.sh/hook|argocd.argoproj.io/hook|^kind: Pod$|release-database|database-head|sha256:' "$argo_render"; then
  echo "Argo CD migration mode rendered unsupported migration machinery" >&2
  exit 1
fi

if helm template redash "$repo_root" "${base_args[@]}" \
  --set migration.mode=disabled >"$tmp_dir/invalid.out" 2>"$tmp_dir/invalid.err"; then
  echo "invalid migration mode unexpectedly rendered" >&2
  exit 1
fi
grep -Fq 'migration.mode must be one of' "$tmp_dir/invalid.err"

builtin_postgresql_render="$tmp_dir/builtin-postgresql.yaml"
helm template redash "$repo_root" \
  --namespace default \
  --set redash.secretKey=test \
  --set redash.cookieSecret=test \
  --set-string postgresql.postgresqlPassword=test \
  --set migration.mode=argocd-job \
  --set tests.enabled=false >"$builtin_postgresql_render"
grep -Fq 'name: REDASH_DATABASE_HOSTNAME' "$builtin_postgresql_render"
grep -Fq '/app/manage.py db upgrade' "$builtin_postgresql_render"

echo "migration mode render tests passed"
