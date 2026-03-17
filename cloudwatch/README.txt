IAM Roles (3):

LambdaObservabilityRole — assign this to your Lambda functions; grants CloudWatch Logs, X-Ray, and custom metrics write access
StepFunctionsObservabilityRole — assign to your State Machines; grants log delivery and X-Ray permissions
CloudWatchReadOnlyRole — for ops/dev team members to view dashboards and alarms without write access

Alarms (6):

Lambda Errors, Throttles, and P99 Duration
Step Functions Failed, Timed Out, and Throttled executions

Other resources:

SNS Topic + email subscription for all alert notifications
Two Log Groups (Lambda + Step Functions) with configurable retention
Two Metric Filters scanning logs for ERROR/Exception keywords and timeouts
A full CloudWatch Dashboard with Lambda metrics, Step Function metrics, and a live Log Insights query panel