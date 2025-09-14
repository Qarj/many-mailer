AWS doesn’t expose full billing data via the standard AWS CLI the same way it does for service APIs, but you can get most of what you want via these services:

- AWS Billing console (best overview)
- AWS Cost Explorer API (costs by service/day)
- AWS Budgets API (budgets/alerts)
- AWS Marketplace Entitlements (if you subscribed to marketplace products)
- AWS Organizations (if applicable)

First, a quick console path (most comprehensive):

- Billing home: https://console.aws.amazon.com/billing/home
- Cost Explorer: Billing > Cost Management > Cost Explorer
- Free Tier usage: Billing > Free Tier
- Bills: Billing > Bills
- Payment methods, tax settings: Billing > Payment methods/Tax settings

CLI and API examples

Set region for Cost Explorer (us-east-1 is used for CE and some billing APIs):

```sh
export AWS_REGION=us-east-1
```

- or pass --region us-east-1 for these commands.

1. Enable and query Cost Explorer (one-time enable happens in console or first API call may fail if not enabled)

- If not enabled, go to console > Cost Explorer and enable. After enabling, try the CLI.

Daily unblended cost by service (last 7 days):

```
aws ce get-cost-and-usage --region us-east-1 --time-period Start=$(date -u -d "7 days ago" +%Y-%m-%d),End=$(date -u +%Y-%m-%d) --granularity DAILY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE
```

Monthly cost by service (current month to date):

```
aws ce get-cost-and-usage --region us-east-1 --time-period Start=$(date -u -d "$(date +%Y-%m-01)" +%Y-%m-%d),End=$(date -u +%Y-%m-%d) --granularity MONTHLY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE
```

Current month total cost:

```
aws ce get-cost-and-usage --region us-east-1 --time-period Start=$(date -u -d "$(date +%Y-%m-01)" +%Y-%m-%d),End=$(date -u +%Y-%m-%d) --granularity MONTHLY --metrics UnblendedCost
```

Amortized and net unblended (include discounts, RI/SP):

```
aws ce get-cost-and-usage --region us-east-1 --time-period Start=$(date -u -d "$(date +%Y-%m-01)" +%Y-%m-%d),End=$(date -u +%Y-%m-%d) --granularity MONTHLY --metrics AmortizedCost,NetUnblendedCost --group-by Type=DIMENSION,Key=SERVICE
```

2. Cost and usage by usage type (more detail, e.g., “Lambda-GB-Second”)

```
aws ce get-cost-and-usage --region us-east-1 --time-period Start=$(date -u -d "7 days ago" +%Y-%m-%d),End=$(date -u +%Y-%m-%d) --granularity DAILY --metrics UnblendedCost --group-by Type=DIMENSION,Key=USAGE_TYPE
```

3. Cost forecast (if enabled)

```
aws ce get-forecast --region us-east-1 --time-period Start=$(date -u +%Y-%m-01) --time-period End=$(date -u -d "+1 month" +%Y-%m-%d) --metric UNBLENDED_COST --granularity MONTHLY
```

4. Budgets (to set alerts and check)
   List budgets:

```
aws budgets describe-budgets --account-id 381354916781 --region us-east-1
```

Create a simple monthly budget (example: $5):

```
aws budgets create-budget --account-id 381354916781 --budget '{
  "BudgetName": "many-mailer-monthly",
  "BudgetLimit": {"Amount": "5", "Unit": "USD"},
  "CostFilters": {},
  "CostTypes": {"IncludeTax": true, "IncludeSubscription": true, "UseAmortized": false},
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST",
  "TimePeriod": {"Start": "'$(date -u +%Y-%m-%dT00:00:00Z)'" }
  }'
  Add an email alert at 80% (replace with your email):
- aws budgets create-notification --account-id 381354916781 --budget-name many-mailer-monthly --notification '{
  "NotificationType": "FORECASTED",
  "ComparisonOperator": "GREATER_THAN",
  "Threshold": 80,
  "ThresholdType": "PERCENTAGE"
  }' --subscribers '[{"SubscriptionType":"EMAIL","Address":"you@example.com"}]'
```

5. Free Tier usage (no simple CLI; use console)

- In the console: Billing > Free Tier shows usage against free limits.

6. What “subscriptions” are active?

- AWS doesn’t have a single “subscriptions” list like Azure. You mainly pay per service. But check:
  - Support plan:
    - Console: https://console.aws.amazon.com/support/plans/home
    - Default is Basic (free). CLI doesn’t expose plan; the support API is limited.
  - Marketplace subscriptions (if any):
    - Console: https://console.aws.amazon.com/marketplace/home
    - CLI (entitlement for a given product, needs product code): aws marketplace-entitlement get-entitlements --product-code <code>
    - Listing all marketplace subscriptions via CLI isn’t straightforward; use console.

7. Per-service usage APIs (if you want raw counts)

- Lambda usage metrics: use CloudWatch metrics (Invocations, Duration, Errors).
- API Gateway: CloudWatch metrics (Count, 4XX, 5XX).
- DynamoDB: CloudWatch metrics (ConsumedReadCapacityUnits, ConsumedWriteCapacityUnits).
  Example CloudWatch metrics fetch (last hour, Lambda invocations):

```
aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Invocations --dimensions Name=FunctionName,Value=many-mailer-api --statistics Sum --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) --period 300 --region eu-west-1
```

8. Cost Explorer: granular filter for just your services
   Filter by services (Lambda, API Gateway, DynamoDB) this month, daily:

```
aws ce get-cost-and-usage --region us-east-1 --time-period Start=$(date -u -d "$(date +%Y-%m-01)" +%Y-%m-%d),End=$(date -u +%Y-%m-%d) --granularity DAILY --metrics UnblendedCost --filter '{
  "Dimensions": {
  "Key": "SERVICE",
  "Values": ["Amazon DynamoDB","AWS Lambda","Amazon API Gateway"]
  }
  }'
```

Notes and tips

- Cost Explorer data is delayed by up to 24 hours (sometimes a bit more).
- For a rarely used site, expect near $0.00. API Gateway HTTP APIs, Lambda (free tier may cover), and DynamoDB on-demand with no traffic will be pennies at most.
- The warning you saw about “dynamodb_table is deprecated” comes from Terraform backend lock messaging; S3 + DynamoDB locking remains the standard pattern and is fine.
- Consider setting a budget with an alert (step 4) to notify if something unexpectedly spikes.
