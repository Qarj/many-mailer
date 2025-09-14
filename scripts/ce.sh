#!/usr/bin/env bash
set -euo pipefail

# Cost Explorer helper for many-mailer
# - Defaults to Cost Explorer region us-east-1 (global/supported)
# - Provides concise subcommands and jq-powered summaries
#
# Examples:
#   ./scripts/ce.sh mtd-service-daily
#   ./scripts/ce.sh last7-service
#   ./scripts/ce.sh drill-service-usage --start 2025-09-01 --end 2025-09-14
#   ./scripts/ce.sh total-mtd
#   ./scripts/ce.sh mtd-service-daily --exclude-credits
#   ./scripts/ce.sh mtd-service-daily --json
#
# Prereqs: aws CLI; jq (for summaries; use --json to skip jq).

CE_REGION="${AWS_REGION:-us-east-1}"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_deps() {
  if ! have_cmd aws; then
    echo "error: aws CLI is required" >&2
    exit 1
  fi
  # jq only required when not using --json
  :
}

usage() {
  cat <<'EOF'
Usage: scripts/ce.sh <subcommand> [options]

Subcommands:
  mtd-service-daily      Month-to-date, daily, grouped by SERVICE. Metrics: Unblended, Amortized.
  last7-service          Last 7 days, daily, grouped by SERVICE. Metrics: Unblended, UsageQuantity.
  drill-service-usage    Drill-down by SERVICE and USAGE_TYPE (daily). Default last 7 days.
  total-mtd              Month-to-date total (monthly granularity), UnblendedCost.

Options (common):
  --start YYYY-MM-DD     Start date (inclusive). Default varies by subcommand.
  --end   YYYY-MM-DD     End date (exclusive). Defaults to today (UTC).
  --exclude-credits      Exclude Credit/Refund/Tax record types.
  --json                 Print raw JSON only (skip jq summaries).
  --debug                Echo the aws CLI command before running it.
  -h, --help             Show this help.

Notes:
  - Cost Explorer data is often 'Estimated' for the last 24–48 hours.
  - Region is forced to us-east-1 for CE operations (does not limit cost scope).
EOF
}

parse_common_opts() {
  # shellcheck disable=SC2034
  START_DATE=""
  # shellcheck disable=SC2034
  END_DATE=""
  EXCLUDE_CREDITS=0
  JSON_ONLY=0
  DEBUG_CMD=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --start) START_DATE="${2:?}"; shift 2 ;;
      --end)   END_DATE="${2:?}";   shift 2 ;;
      --exclude-credits) EXCLUDE_CREDITS=1; shift ;;
      --json) JSON_ONLY=1; shift ;;
      --debug) DEBUG_CMD=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
  done
}

today_utc() { date -u +%Y-%m-%d; }
first_of_month_utc() { date -u -d "$(date -u +%Y-%m-01)" +%Y-%m-%d; }
seven_days_ago_utc() { date -u -d "7 days ago" +%Y-%m-%d; }

build_filter_args() {
  # Build an array with --filter only when excluding credits/refunds/tax.
  # Passing an empty JSON object {} to --filter causes a ValidationException.
  FILTER_ARGS=()
  if [[ $EXCLUDE_CREDITS -eq 1 ]]; then
    local json='{"Not":{"Dimensions":{"Key":"RECORD_TYPE","Values":["Credit","Refund","Tax"]}}}'
    FILTER_ARGS=(--filter "$json")
  fi
}

aws_ce() {
  if [[ ${DEBUG_CMD:-0} -eq 1 ]]; then
    # Print the command with proper quoting
    printf 'aws --region %q ce get-cost-and-usage' "$CE_REGION"
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n' >&2
  fi
  aws --region "$CE_REGION" ce get-cost-and-usage "$@"
}

cmd_mtd_service_daily() {
  local start="${START_DATE:-$(first_of_month_utc)}"
  local end="${END_DATE:-$(today_utc)}"
  build_filter_args

  if [[ $JSON_ONLY -eq 1 ]]; then
    aws_ce \
      --time-period "Start=$start,End=$end" \
      --granularity DAILY \
      --metrics UnblendedCost AmortizedCost \
      "${FILTER_ARGS[@]}" \
      --group-by Type=DIMENSION,Key=SERVICE
    return
  fi

  if ! have_cmd jq; then
    echo "warning: jq not found; printing raw JSON. Install jq or use --json." >&2
    aws_ce \
      --time-period "Start=$start,End=$end" \
      --granularity DAILY \
      --metrics UnblendedCost AmortizedCost \
      "${FILTER_ARGS[@]}" \
      --group-by Type=DIMENSION,Key=SERVICE
    return
  fi

  aws_ce \
    --time-period "Start=$start,End=$end" \
    --granularity DAILY \
    --metrics UnblendedCost AmortizedCost \
    "${FILTER_ARGS[@]}" \
    --group-by Type=DIMENSION,Key=SERVICE |
  jq -r '
    .ResultsByTime[] as $day |
    ($day.TimePeriod.Start) as $d |
    if ($day.Groups|length) == 0 then
      [$d, "NO_DATA", 0, 0] | @tsv
    else
      $day.Groups[] | [
        $d,
        (.Keys[0]),
        (.Metrics.UnblendedCost.Amount|tonumber),
        (.Metrics.AmortizedCost.Amount|tonumber)
      ] | @tsv
    end
  ' | column -t
}

cmd_last7_service() {
  local start="${START_DATE:-$(seven_days_ago_utc)}"
  local end="${END_DATE:-$(today_utc)}"
  build_filter_args

  if [[ $JSON_ONLY -eq 1 ]]; then
    aws_ce \
      --time-period "Start=$start,End=$end" \
      --granularity DAILY \
      --metrics UnblendedCost UsageQuantity \
      "${FILTER_ARGS[@]}" \
      --group-by Type=DIMENSION,Key=SERVICE
    return
  fi

  if ! have_cmd jq; then
    echo "warning: jq not found; printing raw JSON. Install jq or use --json." >&2
    aws_ce \
      --time-period "Start=$start,End=$end" \
      --granularity DAILY \
      --metrics UnblendedCost UsageQuantity \
      "${FILTER_ARGS[@]}" \
      --group-by Type=DIMENSION,Key=SERVICE
    return
  fi

  aws_ce \
    --time-period "Start=$start,End=$end" \
    --granularity DAILY \
    --metrics UnblendedCost UsageQuantity \
    "${FILTER_ARGS[@]}" \
    --group-by Type=DIMENSION,Key=SERVICE |
  jq -r '
    .ResultsByTime[] as $day |
    ($day.TimePeriod.Start) as $d |
    if ($day.Groups|length) == 0 then
      [$d, "NO_DATA", 0, 0] | @tsv
    else
      $day.Groups[] | [
        $d,
        (.Keys[0]),
        (.Metrics.UnblendedCost.Amount|tonumber),
        (.Metrics.UsageQuantity.Amount|tonumber)
      ] | @tsv
    end
  ' | column -t
}

cmd_drill_service_usage() {
  local start="${START_DATE:-$(seven_days_ago_utc)}"
  local end="${END_DATE:-$(today_utc)}"
  build_filter_args

  if [[ $JSON_ONLY -eq 1 ]]; then
    aws_ce \
      --time-period "Start=$start,End=$end" \
      --granularity DAILY \
      --metrics UnblendedCost \
      "${FILTER_ARGS[@]}" \
      --group-by Type=DIMENSION,Key=SERVICE \
      --group-by Type=DIMENSION,Key=USAGE_TYPE
    return
  fi

  if ! have_cmd jq; then
    echo "warning: jq not found; printing raw JSON. Install jq or use --json." >&2
    aws_ce \
      --time-period "Start=$start,End=$end" \
      --granularity DAILY \
      --metrics UnblendedCost \
      "${FILTER_ARGS[@]}" \
      --group-by Type=DIMENSION,Key=SERVICE \
      --group-by Type=DIMENSION,Key=USAGE_TYPE
    return
  fi

  aws_ce \
    --time-period "Start=$start,End=$end" \
    --granularity DAILY \
    --metrics UnblendedCost \
    "${FILTER_ARGS[@]}" \
    --group-by Type=DIMENSION,Key=SERVICE \
    --group-by Type=DIMENSION,Key=USAGE_TYPE |
  jq -r '
    .ResultsByTime[] as $day |
    ($day.TimePeriod.Start) as $d |
    if ($day.Groups|length) == 0 then
      [$d, "NO_DATA", "NO_DATA", 0] | @tsv
    else
      $day.Groups[] | [
        $d,
        (.Keys[0]),     # SERVICE
        (.Keys[1]),     # USAGE_TYPE
        (.Metrics.UnblendedCost.Amount|tonumber)
      ] | @tsv
    end
  ' | column -t
}

cmd_total_mtd() {
  local start="${START_DATE:-$(first_of_month_utc)}"
  local end="${END_DATE:-$(today_utc)}"
  build_filter_args

  if [[ $JSON_ONLY -eq 1 ]]; then
    aws_ce \
      --time-period "Start=$start,End=$end" \
      --granularity MONTHLY \
      --metrics UnblendedCost \
      "${FILTER_ARGS[@]}"
    return
  fi

  if ! have_cmd jq; then
    echo "warning: jq not found; printing raw JSON. Install jq or use --json." >&2
    aws_ce \
      --time-period "Start=$start,End=$end" \
      --granularity MONTHLY \
      --metrics UnblendedCost \
      "${FILTER_ARGS[@]}"
    return
  fi

  aws_ce \
    --time-period "Start=$start,End=$end" \
    --granularity MONTHLY \
    --metrics UnblendedCost \
    "${FILTER_ARGS[@]}" |
  jq -r '
    .ResultsByTime[] |
    [.TimePeriod.Start, .Total.UnblendedCost.Amount] | @tsv
  ' | column -t
}

main() {
  ensure_deps
  local cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    usage
    exit 2
  fi
  shift || true

  case "$cmd" in
    mtd-service-daily)
      parse_common_opts "$@"
      cmd_mtd_service_daily
      ;;
    last7-service)
      parse_common_opts "$@"
      cmd_last7_service
      ;;
    drill-service-usage)
      parse_common_opts "$@"
      cmd_drill_service_usage
      ;;
    total-mtd)
      parse_common_opts "$@"
      cmd_total_mtd
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "Unknown subcommand: $cmd" >&2
      usage
      exit 2
      ;;
  esac
}

main "$@"