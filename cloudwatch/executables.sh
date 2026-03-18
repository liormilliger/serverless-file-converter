# ============================================================
#  CloudWatch Lambdas — Command Reference
#  Run these commands manually, one block at a time.
#  Replace ALL placeholders in <angle brackets> before running.
# ============================================================


# ────────────────────────────────────────────────────────────
# STEP 1 — Validate the template before deploying
# ────────────────────────────────────────────────────────────

aws cloudformation validate-template \
  --template-body file://cloudwatch-lambdas.yaml \
  --region us-east-1


# ────────────────────────────────────────────────────────────
# STEP 2 — Deploy the stack
# Fill in your real values below before running.
# ────────────────────────────────────────────────────────────

aws cloudformation deploy \
  --template-file cloudwatch-lambdas.yaml \
  --stack-name cloudwatch-lambdas \
  --parameter-overrides \
      AlertEmail=lior.milliger@polustech.com \
      Environment=development \
      StepFunctionArns=arn:aws:states:us-east-1:704505749045:stateMachine:3-tier-data-digestion-pipeline \
      ErrorAlarmThreshold=1 \
      ThrottleAlarmThreshold=3 \
      LogRetentionDays=30 \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1


# ────────────────────────────────────────────────────────────
# STEP 3 — Wait for the stack to finish deploying
# ────────────────────────────────────────────────────────────

aws cloudformation wait stack-create-complete \
  --stack-name cloudwatch-lambdas \
  --region us-east-1


# ────────────────────────────────────────────────────────────
# STEP 4 — Confirm the SNS email subscription
# Check your inbox for a confirmation email from AWS SNS
# and click "Confirm subscription" — alarms won't notify
# until this is done.
# (No CLI command — must be done manually via email)
# ────────────────────────────────────────────────────────────


# ────────────────────────────────────────────────────────────
# STEP 5 — View stack outputs (role ARNs, dashboard URL, etc.)
# ────────────────────────────────────────────────────────────

aws cloudformation describe-stacks \
  --stack-name cloudwatch-lambdas \
  --query "Stacks[0].Outputs" \
  --output table \
  --region us-east-1


# ────────────────────────────────────────────────────────────
# STEP 6 — Attach the Lambda observability role to each Lambda
# Repeat this command for every Lambda function you monitor.
# ────────────────────────────────────────────────────────────

aws lambda update-function-configuration \
  --function-name 3-tier-data-digestion-identifier,3-tier-data-digestion-converter,3-tier-data-digestion-uploader \
  --role $(aws cloudformation describe-stacks \
    --stack-name cloudwatch-lambdas \
    --query "Stacks[0].Outputs[?OutputKey=='LambdaObservabilityRoleArn'].OutputValue" \
    --output text \
    --region us-east-1) \
  --region us-east-1


# ────────────────────────────────────────────────────────────
# STEP 7 — Enable X-Ray tracing on each Lambda
# Repeat for every Lambda function you monitor.
# ────────────────────────────────────────────────────────────

aws lambda update-function-configuration \
  --function-name 3-tier-data-digestion-identifier,3-tier-data-digestion-converter,3-tier-data-digestion-uploader \
  --tracing-config Mode=Active \
  --region us-east-1


# ────────────────────────────────────────────────────────────
# STEP 8 — Enable X-Ray tracing on each Step Function
# Repeat for every State Machine you monitor.
# ────────────────────────────────────────────────────────────

aws stepfunctions update-state-machine \
  --state-machine-arn arn:aws:states:us-east-1:704505749045:stateMachine:3-tier-data-digestion-pipeline \
  --tracing-configuration enabled=true \
  --logging-configuration \
    level=ERROR,includeExecutionData=true,destinations=[{cloudWatchLogsLogGroup={logGroupArn=$(aws cloudformation describe-stacks \
      --stack-name cloudwatch-lambdas \
      --query "Stacks[0].Outputs[?OutputKey=='StepFunctionsLogGroupName'].OutputValue" \
      --output text \
      --region us-east-1)}}] \
  --region us-east-1


# ────────────────────────────────────────────────────────────
# STEP 9 — Open the dashboard
# Prints the direct URL to the CloudWatch dashboard.
# ────────────────────────────────────────────────────────────

aws cloudformation describe-stacks \
  --stack-name cloudwatch-lambdas \
  --query "Stacks[0].Outputs[?OutputKey=='DashboardUrl'].OutputValue" \
  --output text \
  --region us-east-1


# ============================================================
#  DESTROY — Remove the entire stack
#  WARNING: deletes all alarms, log groups, roles, dashboard,
#  and the SNS topic. Log data will be permanently lost.
# ============================================================

# 1. Delete the stack
aws cloudformation delete-stack \
  --stack-name cloudwatch-lambdas \
  --region us-east-1

# 2. Wait for deletion to complete
aws cloudformation wait stack-delete-complete \
  --stack-name cloudwatch-lambdas \
  --region us-east-1

# 3. Verify it's gone
aws cloudformation describe-stacks \
  --stack-name cloudwatch-lambdas \
  --region us-east-1 2>&1 | grep "does not exist" \
  && echo "Stack deleted successfully."