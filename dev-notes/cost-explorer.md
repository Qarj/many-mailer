Cost Explorer quick reference

Purpose
- See costs by day/service and drill into usage types for many-mailer.
- Fast, copy/paste-able commands and a helper script.

Notes
- Cost Explorer data is often “Estimated” for the last 24–48h and can lag.
- Cost Explorer is a global service; using --region us-east-1 is standard and does not limit scope to that region.
- Micro-costs are expected under light testing and Free Tier.
 - We intentionally omit --filter unless excluding credits/refunds/tax; passing an empty filter object ({}) causes a ValidationException.

Helper script (recommended)
- scripts/ce.sh wraps common queries with sensible defaults.
- Make it executable: chmod +x scripts/ce.sh
- Examples:
  - Month-to-date daily by service:
    scripts/ce.sh mtd-service-daily
  - Last 7 days with usage quantities:
    scripts/ce.sh last7-service
  - Drill down by service and usage type (last 7 days):
    scripts/ce.sh drill-service-usage
  - Show current month total:
    scripts/ce.sh total-mtd
  - Include/exclude credits/refunds/tax:
    scripts/ce.sh mtd-service-daily --exclude-credits
  - Custom range:
    scripts/ce.sh last7-service --start 2025-09-01 --end 2025-09-14
  - JSON only (no jq summaries):
    scripts/ce.sh mtd-service-daily --json
  - Debug (echo the aws command):
    scripts/ce.sh last7-service --debug
  - Filter to a single service:
    scripts/ce.sh last7-service --service "Amazon Simple Storage Service"

Raw CLI equivalents
- Daily unblended cost by service (last 7 days):
  aws ce get-cost-and-usage \
    --region us-east-1 \
    --time-period Start=$(date -u -d "7 days ago" +%Y-%m-%d),End=$(date -u +%Y-%m-%d) \
    --granularity DAILY \
    --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=SERVICE

- Month-to-date (MTD) daily by service, with amortized cost:
  aws ce get-cost-and-usage \
    --region us-east-1 \
    --time-period Start=$(date -u -d "$(date +%Y-%m-01)" +%Y-%m-%d),End=$(date -u +%Y-%m-%d) \
    --granularity DAILY \
    --metrics UnblendedCost AmortizedCost \
    --group-by Type=DIMENSION,Key=SERVICE

- Drill down by service and usage type:
  aws ce get-cost-and-usage \
    --region us-east-1 \
    --time-period Start=$(date -u -d "7 days ago" +%Y-%m-%d),End=$(date -u +%Y-%m-%d) \
    --granularity DAILY \
    --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=SERVICE \
    --group-by Type=DIMENSION,Key=USAGE_TYPE

- Exclude credits/refunds/tax:
  ... --filter '{"Not": {"Dimensions": {"Key":"RECORD_TYPE","Values":["Credit","Refund","Tax"]}}}'

Console paths (for completeness)
- Billing home: https://console.aws.amazon.com/billing/home
- Cost Explorer: Billing > Cost Management > Cost Explorer
- Free Tier usage: Billing > Free Tier
- Bills: Billing > Bills

Tip
- If setting alerts, consider an AWS Budget (console) around $5/month for early warning.

Output formatting (script)
- All currency values are prefixed with a $ sign (e.g., $0.0001662). Numbers without $ are not currency.
- Usage quantities display their unit when available (e.g., 59.00 Requests, 0.002 GB-Hours).
- Service names render in a single, fixed-width column (40 chars). This prevents column wobble when the service name has spaces (e.g., “Amazon Simple Storage Service”).
- For drill-service-usage, the label shows “SERVICE | USAGE_TYPE”.
- Days with no groups print a single NO_DATA line with the day’s total UnblendedCost.

Example
  scripts/ce.sh last7-service --start 2025-09-13 --end 2025-09-14
  2025-09-13  Amazon Simple Storage Service             $0.0001662   59.0015439877 Requests
  2025-09-13  Amazon API Gateway                        $0.00000222  2.0000003054 Requests
  2025-09-13  AWS Lambda                                $0           3.04225 Requests
  2025-09-13  AmazonCloudWatch                          $0           0.0000013532 Metrics

Notes on filters
- We only include --filter when needed (e.g., --exclude-credits or --service). Passing an empty object {} causes a ValidationException in CE.

Reminder
- End is exclusive. For a single day, set --start YYYY-MM-DD and --end to the next day.
