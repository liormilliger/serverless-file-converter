#!/usr/bin/env bash
# ================================================================
#  deploy.sh — CloudWatch Lambdas stack automation
#  Usage:
#    ./deploy.sh           → deploy (or update) the stack
#    ./deploy.sh destroy   → tear down the stack
#
#  Reads config from cloudwatch-lambdas.env (auto-created on
#  first run if missing). Edit that file to change any values.
# ================================================================

set -euo pipefail

# ── Colour helpers ───────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}▶  $*${RESET}"; }
success() { echo -e "${GREEN}✔  $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠  $*${RESET}"; }
error()   { echo -e "${RED}✖  $*${RESET}" >&2; exit 1; }
header()  { echo -e "\n${BOLD}$*${RESET}"; echo "────────────────────────────────────────"; }

# ── Config file ──────────────────────────────────────────────
ENV_FILE="cloudwatch-lambdas.env"

write_default_env() {
  cat > "$ENV_FILE" <<'EOF'
# ── CloudWatch Lambdas — deployment config ────────────────────
# Edit these values, then re-run ./deploy.sh

STACK_NAME=cloudwatch-lambdas
REGION=us-east-1
TEMPLATE_FILE=cloudwatch-lambdas.yaml

# Alert email (must confirm SNS subscription after deploy)
ALERT_EMAIL=lior.milliger@polustech.com

# Comma-separated Lambda function names (no spaces)
LAMBDA_FUNCTION_NAMES=3-tier-data-digestion-identifier,3-tier-data-digestion-converter,3-tier-data-digestion-uploader

# Comma-separated Step Function ARNs (no spaces)
STEP_FUNCTION_ARNS=arn:aws:states:us-east-1:704505749045:stateMachine:3-tier-data-digestion-pipeline

# Alarm thresholds
ERROR_ALARM_THRESHOLD=1
THROTTLE_ALARM_THRESHOLD=3

# Log retention in days
LOG_RETENTION_DAYS=30

# Environment tag: development | staging | production
ENVIRONMENT=development
EOF
  warn "Created default config: ${ENV_FILE}"
  warn "Review it, then re-run ./deploy.sh"
  exit 0
}

if [[ ! -f "$ENV_FILE" ]]; then
  write_default_env
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

# ── Preflight checks ─────────────────────────────────────────
header "Preflight"

command -v aws &>/dev/null  || error "AWS CLI not found. Install it first."

if ! aws sts get-caller-identity &>/dev/null; then
  error "AWS credentials not configured. Run: aws configure"
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
success "AWS account: ${ACCOUNT_ID}  region: ${REGION}"

[[ -f "$TEMPLATE_FILE" ]] || error "Template not found: ${TEMPLATE_FILE}"
success "Template found: ${TEMPLATE_FILE}"

# ── Mode: destroy ────────────────────────────────────────────
if [[ "${1:-}" == "destroy" ]]; then
  header "Destroy — ${STACK_NAME}"
  warn "This will permanently delete all alarms, log groups, roles,"
  warn "the dashboard, and the SNS topic. Log data will be lost."
  echo
  read -rp "$(echo -e "${RED}Type the stack name to confirm deletion [${STACK_NAME}]: ${RESET}")" CONFIRM
  [[ "$CONFIRM" == "$STACK_NAME" ]] || error "Confirmation did not match. Aborting."

  info "Deleting stack…"
  aws cloudformation delete-stack \
    --stack-name "$STACK_NAME" \
    --region "$REGION"

  info "Waiting for deletion to complete…"
  aws cloudformation wait stack-delete-complete \
    --stack-name "$STACK_NAME" \
    --region "$REGION"

  success "Stack deleted successfully."
  exit 0
fi

# ── Step 1: Validate ─────────────────────────────────────────
header "Step 1 — Validate template"
aws cloudformation validate-template \
  --template-body "file://${TEMPLATE_FILE}" \
  --region "$REGION" \
  --output text &>/dev/null
success "Template is valid."

# ── Step 2: Deploy ───────────────────────────────────────────
header "Step 2 — Deploy stack: ${STACK_NAME}"
info "Environment : ${ENVIRONMENT}"
info "Region      : ${REGION}"
info "Alert email : ${ALERT_EMAIL}"
info "Lambdas     : ${LAMBDA_FUNCTION_NAMES}"
info "Step Fn ARNs: ${STEP_FUNCTION_ARNS}"

aws cloudformation deploy \
  --template-file "$TEMPLATE_FILE" \
  --stack-name "$STACK_NAME" \
  --parameter-overrides \
      AlertEmail="$ALERT_EMAIL" \
      Environment="$ENVIRONMENT" \
      LambdaFunctionNames="$LAMBDA_FUNCTION_NAMES" \
      StepFunctionArns="$STEP_FUNCTION_ARNS" \
      ErrorAlarmThreshold="$ERROR_ALARM_THRESHOLD" \
      ThrottleAlarmThreshold="$THROTTLE_ALARM_THRESHOLD" \
      LogRetentionDays="$LOG_RETENTION_DAYS" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION"

success "Stack deployed."

# ── Step 3: Fetch outputs ────────────────────────────────────
header "Step 3 — Stack outputs"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs" \
  --output table \
  --region "$REGION"

LAMBDA_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='LambdaObservabilityRoleArn'].OutputValue" \
  --output text \
  --region "$REGION")

DASHBOARD_URL=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='DashboardUrl'].OutputValue" \
  --output text \
  --region "$REGION")

# ── Step 4: Attach role + enable X-Ray on each Lambda ────────
header "Step 4 — Attach observability role & enable X-Ray on Lambdas"

IFS=',' read -ra LAMBDAS <<< "$LAMBDA_FUNCTION_NAMES"
for FN in "${LAMBDAS[@]}"; do
  FN="${FN// /}"   # trim any spaces
  info "Configuring Lambda: ${FN}"

  aws lambda update-function-configuration \
    --function-name "$FN" \
    --role "$LAMBDA_ROLE_ARN" \
    --region "$REGION" \
    --output text &>/dev/null

  # Wait for update to complete before chaining next update
  aws lambda wait function-updated \
    --function-name "$FN" \
    --region "$REGION"

  aws lambda update-function-configuration \
    --function-name "$FN" \
    --tracing-config Mode=Active \
    --region "$REGION" \
    --output text &>/dev/null

  aws lambda wait function-updated \
    --function-name "$FN" \
    --region "$REGION"

  success "  ${FN} — role attached, X-Ray active."
done

# ── Step 5: Extra SNS email subscriptions ───────────────────
header "Step 5 — Extra SNS subscriptions"

if [[ -n "${EXTRA_ALERT_EMAILS:-}" ]]; then
  SNS_TOPIC_ARN=$(aws sns list-topics \
    --region "$REGION" \
    --query "Topics[?contains(TopicArn,'cloudwatch-lambda-alerts-${ENVIRONMENT}')].TopicArn" \
    --output text)

  [[ -z "$SNS_TOPIC_ARN" ]] && error "Could not find SNS topic for environment: ${ENVIRONMENT}"

  IFS=',' read -ra EXTRA_EMAILS <<< "$EXTRA_ALERT_EMAILS"
  for EMAIL in "${EXTRA_EMAILS[@]}"; do
    EMAIL="${EMAIL// /}"
    info "Subscribing: ${EMAIL}"
    aws sns subscribe \
      --topic-arn "$SNS_TOPIC_ARN" \
      --protocol email \
      --notification-endpoint "$EMAIL" \
      --region "$REGION" \
      --output text &>/dev/null
    success "  Subscription confirmation sent to ${EMAIL}"
  done
else
  info "No extra emails configured — skipping."
fi

# ── Step 6: Enable X-Ray + logging on each Step Function ─────
header "Step 6 — Enable X-Ray & logging on Step Functions"

SF_LOG_GROUP_ARN="arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/aws/states/observability-${ENVIRONMENT}:*"

IFS=',' read -ra STEP_FNS <<< "$STEP_FUNCTION_ARNS"
for SF_ARN in "${STEP_FNS[@]}"; do
  SF_ARN="${SF_ARN// /}"
  info "Configuring Step Function: ${SF_ARN}"

  aws stepfunctions update-state-machine \
    --state-machine-arn "$SF_ARN" \
    --tracing-configuration enabled=true \
    --logging-configuration \
      "level=ERROR,includeExecutionData=true,destinations=[{cloudWatchLogsLogGroup={logGroupArn=${SF_LOG_GROUP_ARN}}}]" \
    --region "$REGION" \
    --output text &>/dev/null

  success "  $(basename "$SF_ARN") — X-Ray enabled, logging active."
done

# ── Done ─────────────────────────────────────────────────────
header "All done"
success "Stack is live and fully configured."
echo
warn "ACTION REQUIRED: Confirm SNS subscription(s) via email:"
warn "  Primary : ${ALERT_EMAIL}"
if [[ -n "${EXTRA_ALERT_EMAILS:-}" ]]; then
  IFS=',' read -ra _EXTRAS <<< "$EXTRA_ALERT_EMAILS"
  for _E in "${_EXTRAS[@]}"; do
    warn "  Extra   : ${_E// /}"
  done
fi
warn "Alarms won't notify until every recipient clicks the confirmation link."
echo
info "Dashboard → ${DASHBOARD_URL}"