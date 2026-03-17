aws cloudformation deploy \
  --template-file cloudwatch-lambdas.yaml \
  --stack-name cloudwatch-lambdas \
  --parameter-overrides \
      AlertEmail=your@email.com \
      Environment=production \
  --capabilities CAPABILITY_NAMED_IAM

  