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
