# Enable the EventBridge notification setting on your manually managed bucket via the CLI (or Console):
aws s3api put-bucket-notification-configuration \
    --bucket liorm-bronze-bucket \
    --notification-configuration '{ "EventBridgeConfiguration": {} }'

# DEPLOY STACK
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name data-digestion-3-tier \
  --capabilities CAPABILITY_NAMED_IAM \
  --tags Name=3-tier-data-digestion User=liorm-at-polus

# DELETE STACK
aws cloudformation delete-stack --stack-name data-digestion-3-tier