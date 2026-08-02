#!/usr/bin/env bash
# Build the shared-gateway DP image, push to ECR, and deploy to App Runner.
# The Konnect cluster cert/key go to Secrets Manager (never plaintext env).
# Prereqs: refreshed AWS creds, the shared CP created (01_create_control_plane.py ->
# cp.env + secrets/tls.{crt,key}).
#
#   set -a && source ../.env.konnect && set +a   # not needed here; AWS creds only
#   ./deploy.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SG="$(cd "$HERE/.." && pwd)"            # shared-gateway/
REPO="$(cd "$SG/.." && pwd)"           # kong-plugin-straiker/  (docker build context)
source "$SG/cp.env"                     # SHARED_CP_ID + KONG_CLUSTER_* endpoints

REGION="${AWS_REGION:-us-east-1}"
ACCT="$(aws sts get-caller-identity --query Account --output text)"
ECR="$ACCT.dkr.ecr.$REGION.amazonaws.com"
IMG="straiker-shared-kong-gateway"
SVC="straiker-shared-kong-gateway"
DOMAIN="konggw.dev.straiker.ai"
TAG="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo latest)"

echo "== 1. ECR repo + login =="
aws ecr describe-repositories --repository-names "$IMG" --region "$REGION" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "$IMG" --region "$REGION" >/dev/null
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR"

echo "== 2. build + push (context = repo root so plugins are in scope) =="
docker build --platform linux/amd64 -f "$HERE/Dockerfile" -t "$ECR/$IMG:$TAG" -t "$ECR/$IMG:latest" "$REPO"
docker push "$ECR/$IMG:$TAG"; docker push "$ECR/$IMG:latest"

# NOTE: the Konnect cluster cert/key are passed as RUNTIME ENV VARS (base64), not as
# App Runner RuntimeEnvironmentSecrets. Secrets-based injection failed to start the
# container (CREATE_FAILED in ~19s with NO application log group — App Runner resolves
# secrets before the container runs, so nothing is logged), even though the instance
# role simulated `allowed` for secretsmanager:GetSecretValue. Env vars work and are
# encrypted at rest; the values are a Konnect DP client cert that is rotatable and
# scoped to one control plane. Revisit if App Runner secret resolution is fixed.
echo "== 3. cluster cert/key -> Secrets Manager (base64) [kept for future use] =="
put_secret(){ # name file
  local arn
  arn=$(aws secretsmanager describe-secret --secret-id "$1" --region "$REGION" --query ARN --output text 2>/dev/null || true)
  if [ -n "$arn" ] && [ "$arn" != "None" ]; then
    aws secretsmanager put-secret-value --secret-id "$1" --secret-string "$(base64 < "$2" | tr -d '\n')" --region "$REGION" >/dev/null
  else
    aws secretsmanager create-secret --name "$1" --secret-string "$(base64 < "$2" | tr -d '\n')" --region "$REGION" >/dev/null
  fi
  aws secretsmanager describe-secret --secret-id "$1" --region "$REGION" --query ARN --output text
}
CRT_ARN=$(put_secret konggw/cluster-cert-b64 "$SG/secrets/tls.crt")
KEY_ARN=$(put_secret konggw/cluster-key-b64 "$SG/secrets/tls.key")
echo "  cert secret: $CRT_ARN"

echo "== 4. IAM roles (ECR access + instance secrets access) =="
# NOTE: create these once. access role = ECR pull; instance role = read the two secrets.
ACCESS_ROLE_ARN=$(aws iam get-role --role-name AppRunnerECRAccessRole --query Role.Arn --output text 2>/dev/null || echo "")
INSTANCE_ROLE_ARN=$(aws iam get-role --role-name konggw-instance-role --query Role.Arn --output text 2>/dev/null || echo "")
if [ -z "$ACCESS_ROLE_ARN" ] || [ -z "$INSTANCE_ROLE_ARN" ]; then
  echo "  !! Missing IAM roles. Create them (one-time):"
  echo "     - AppRunnerECRAccessRole  (trust build.apprunner.amazonaws.com, policy AWSAppRunnerServicePolicyForECRAccess)"
  echo "     - konggw-instance-role    (trust tasks.apprunner.amazonaws.com, inline policy: secretsmanager:GetSecretValue on the two ARNs above)"
  echo "     then re-run. See README-DEPLOY.md."
  exit 1
fi

echo "== 5. create/update App Runner service =="
ENV_JSON=$(cat <<EOF
{
 "KONG_ROLE":"data_plane","KONG_DATABASE":"off","KONG_KONNECT_MODE":"on","KONG_CLUSTER_MTLS":"pki",
 "KONG_CLUSTER_CONTROL_PLANE":"$KONG_CLUSTER_CONTROL_PLANE","KONG_CLUSTER_SERVER_NAME":"$KONG_CLUSTER_SERVER_NAME",
 "KONG_CLUSTER_TELEMETRY_ENDPOINT":"$KONG_CLUSTER_TELEMETRY_ENDPOINT","KONG_CLUSTER_TELEMETRY_SERVER_NAME":"$KONG_CLUSTER_TELEMETRY_SERVER_NAME",
 "KONG_LUA_SSL_TRUSTED_CERTIFICATE":"system","KONG_PLUGINS":"bundled,straiker,straiker-coding,straiker-coding-stream",
 "KONG_NGINX_HTTP_LUA_SHARED_DICT":"straiker_coding 32m","KONG_NGINX_HTTP_CLIENT_MAX_BODY_SIZE":"0",
 "KONG_NGINX_HTTP_CLIENT_BODY_BUFFER_SIZE":"16m","KONG_PROXY_LISTEN":"0.0.0.0:8000",
 "KONG_STATUS_LISTEN":"0.0.0.0:8100","KONG_LOG_LEVEL":"notice"
}
EOF
)
SRC=$(cat <<EOF
{ "ImageRepository": {
    "ImageIdentifier":"$ECR/$IMG:$TAG","ImageRepositoryType":"ECR",
    "ImageConfiguration":{ "Port":"8000",
      "RuntimeEnvironmentVariables":$ENV_JSON,
      "RuntimeEnvironmentSecrets":{"KONG_CLUSTER_CERT_B64":"$CRT_ARN","KONG_CLUSTER_CERT_KEY_B64":"$KEY_ARN"} } },
  "AutoDeploymentsEnabled": true,
  "AuthenticationConfiguration": { "AccessRoleArn":"$ACCESS_ROLE_ARN" } }
EOF
)
ARN=$(aws apprunner list-services --region "$REGION" --query "ServiceSummaryList[?ServiceName=='$SVC'].ServiceArn" --output text)
HEALTH='{"Protocol":"TCP","Interval":10,"Timeout":5,"HealthyThreshold":1,"UnhealthyThreshold":5}'
INSTANCE="{\"Cpu\":\"1024\",\"Memory\":\"2048\",\"InstanceRoleArn\":\"$INSTANCE_ROLE_ARN\"}"
if [ -n "$ARN" ]; then
  aws apprunner update-service --service-arn "$ARN" --source-configuration "$SRC" \
    --instance-configuration "$INSTANCE" --region "$REGION" >/dev/null
  echo "  updated $ARN"
else
  ARN=$(aws apprunner create-service --service-name "$SVC" --source-configuration "$SRC" \
    --instance-configuration "$INSTANCE" --health-check-configuration "$HEALTH" \
    --region "$REGION" --query Service.ServiceArn --output text)
  echo "  created $ARN"
fi

echo "== 6. custom domain $DOMAIN =="
aws apprunner associate-custom-domain --service-arn "$ARN" --domain-name "$DOMAIN" --region "$REGION" 2>/dev/null \
  --query 'DNSTarget' --output text || echo "  (already associated or run manually)"
echo "  -> add the CNAME records App Runner returns to the dev.straiker.ai zone, then it validates."
DEFAULT_URL=$(aws apprunner describe-service --service-arn "$ARN" --region "$REGION" --query Service.ServiceUrl --output text)
echo "== DONE ==  default URL: https://$DEFAULT_URL   (custom: https://$DOMAIN once DNS validates)"
