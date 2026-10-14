#!/usr/bin/env bash
# Thin wrapper used by every workflow (and by you locally) so CI and laptops run
# Terraform exactly the same way.
#
#   scripts/tf.sh <stack-dir> <plan|apply|destroy> [extra terraform args]
#
# Reads: TF_STATE_BUCKET, AWS_REGION (required)
#        BASE_DOMAIN, CLOUDFLARE_ZONE_ID, CLOUDFLARE_API_TOKEN,
#        DATADOG_API_KEY_SSM_NAME, DATADOG_API_URL, DD_NOTIFY (optional)
set -euo pipefail

stack="${1:?stack dir, e.g. live/platform}"
action="${2:?plan|apply|destroy}"
shift 2

: "${TF_STATE_BUCKET:?set TF_STATE_BUCKET}"
: "${AWS_REGION:?set AWS_REGION}"

export TF_IN_AUTOMATION=1
export TF_VAR_state_bucket="$TF_STATE_BUCKET"
export TF_VAR_region="$AWS_REGION"

# Only export optional inputs when they are set: an empty string is NOT null in Terraform.
opt() { [ -n "${2:-}" ] && export "TF_VAR_$1=$2" || true; }
opt base_domain              "${BASE_DOMAIN:-}"
opt cloudflare_zone_id       "${CLOUDFLARE_ZONE_ID:-}"
opt cloudflare_api_token     "${CLOUDFLARE_API_TOKEN:-}"
opt datadog_api_key_ssm_name "${DATADOG_API_KEY_SSM_NAME:-}"
opt datadog_api_url          "${DATADOG_API_URL:-}"
opt notify                   "${DD_NOTIFY:-}"

cd "$stack"
terraform init -input=false -reconfigure \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="region=$AWS_REGION" >/dev/null

case "$action" in
  plan)    terraform plan -input=false -no-color -detailed-exitcode "$@" ;;
  apply)   terraform apply -input=false -auto-approve "$@" ;;
  destroy) terraform destroy -input=false -auto-approve "$@" ;;
  *) echo "unknown action: $action" >&2; exit 2 ;;
esac
