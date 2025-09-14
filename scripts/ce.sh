#!/usr/bin/env bash
set -euo pipefail

# Cost Explorer helper
# - Clear formatting: money values prefixed with $; usage shows unit.
# - Fixed-width service column to avoid wobble when names contain spaces.
# - Subcommands:
#     mtd-service-daily
#     last7-service
#     drill-service-usage
#     total-mtd
# - Options:
#     --start YYYY-MM-DD
#     --end   YYYY-MM-DD
#     --exclude-credits     (excludes Credit/Refund/Tax)
#     --service "SERVICE NAME" (filter to a single SERVICE dimension)
#     --json   (print raw JSON and exit)
#     --debug  (echo AWS CLI command before execution)
#
# Examples:
#   scripts/ce.sh mtd-service-daily
#   scripts/ce.sh last7-service --start 2025-09-01 --end 2025-09-14
#   scripts/ce.sh drill-service-usage --start 2025-09-13 --end 2025-09-14
#   scripts/ce.sh total-mtd --exclude-credits
#   scripts/ce.sh last7-service --service "Amazon Simple Storage Service"

die() { echo "ERROR: $*" >&2; exit 1; }

SUBCMD="${1:-}"; shift || true

START_DATE=""
END_DATE=""
EXCLUDE_CREDITS="false"
ONLY_SERVICE=""
RAW_JSON="false"
DEBUG="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start) START_DATE="${2:?}"; shift 2;;
    --end) END_DATE="${2:?}"; shift 2;;
    --exclude-credits) EXCLUDE_CREDITS="true"; shift;;
    --service) ONLY_SERVICE="${2:?}"; shift 2;;
    --json) RAW_JSON="true"; shift;;
    --debug) DEBUG="true"; shift;;
    -h|--help)
      cat <<EOF
Usage: scripts/ce.sh <subcommand> [options]
Subcommands:
  mtd-service-daily         Month-to-date, daily, grouped by SERVICE
  last7-service             Custom range (default last 7 days), grouped by SERVICE
  drill-service-usage       Custom range, grouped by SERVICE and USAGE_TYPE
  total-mtd                 Month-to-date totals (no grouping)

Options:
  --start YYYY-MM-DD        Start date (inclusive)
  --end   YYYY-MM-DD        End date (exclusive)
  --exclude-credits         Exclude Credit/Refund/Tax record types
  --service "SERVICE NAME"  Filter to a single SERVICE (dimension filter)
  --json                    Print raw JSON (no pretty formatting)
  --debug                   Echo the AWS CLI command before executing
  -h, --help                Show this help
EOF
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

# Defaults
if [[ -z "$START_DATE" || -z "$END_DATE" ]]; then
  case "$SUBCMD" in
    mtd-service-daily|total-mtd)
      # Month-to-date
      START_DATE="$(date -u -d "$(date +%Y-%m-01)" +%Y-%m-%d)"
      END_DATE="$(date -u +%Y-%m-%d)"
      ;;
    last7-service|drill-service-usage|*)
      # Last 7 days by default
      START_DATE="${START_DATE:-$(date -u -d "7 days ago" +%Y-%m-%d)}"
      END_DATE="${END_DATE:-$(date -u +%Y-%m-%d)}"
      ;;
  esac
fi

region="us-east-1" # CE is global; region selects API endpoint only

build_filter_json() {
  local parts=()
  if [[ "$EXCLUDE_CREDITS" == "true" ]]; then
    parts+=('{"Not":{"Dimensions":{"Key":"RECORD_TYPE","Values":["Credit","Refund","Tax"]}}}')
  fi
  if [[ -n "$ONLY_SERVICE" ]]; then
    # Filter to one service
    # Note: Filtering on SERVICE while grouping by SERVICE is allowed; it just narrows the results.
    parts+=("{\"Dimensions\":{\"Key\":\"SERVICE\",\"Values\":[\"$ONLY_SERVICE\"]}}")
  fi

  if [[ ${#parts[@]} -eq 0 ]]; then
    echo "" # No filter flag
  elif [[ ${#parts[@]} -eq 1 ]]; then
    echo "${parts[0]}"
  else
    # Combine multiple with And
    local joined
    joined=$(printf ",%s" "${parts[@]}")
    joined="[${joined:1}]"
    echo "{\"And\": $joined}"
  fi
}

run_ce() {
  local granularity="$1"; shift
  local metrics=("$@")

  local cmd=(aws ce get-cost-and-usage
    --region "$region"
    --time-period "Start=${START_DATE},End=${END_DATE}"
    --granularity "$granularity"
  )
  for m in "${metrics[@]}"; do
    cmd+=(--metrics "$m")
  done

  local filter_json
  filter_json="$(build_filter_json)"
  if [[ -n "$filter_json" ]]; then
    cmd+=(--filter "$filter_json")
  fi

  if [[ "$DEBUG" == "true" ]]; then
    echo "+ ${cmd[*]}" >&2
  fi
  "${cmd[@]}"
}

run_ce_grouped() {
  local granularity="$1"; shift
  local group_bys=("$1"); shift
  local metrics=("$@")

  local cmd=(aws ce get-cost-and-usage
    --region "$region"
    --time-period "Start=${START_DATE},End=${END_DATE}"
    --granularity "$granularity"
  )
  for m in "${metrics[@]}"; do
    cmd+=(--metrics "$m")
  done
  # support one or two group-bys (e.g., SERVICE and USAGE_TYPE)
  for gb in "${group_bys[@]}"; do
    cmd+=(--group-by "Type=DIMENSION,Key=${gb}")
  done

  local filter_json
  filter_json="$(build_filter_json)"
  if [[ -n "$filter_json" ]]; then
    cmd+=(--filter "$filter_json")
  fi

  if [[ "$DEBUG" == "true" ]]; then
    echo "+ ${cmd[*]}" >&2
  fi
  "${cmd[@]}"
}

format_money() {
  # Prefix with $
  # Input: numeric string (may be "0" or "0.0000123" etc.)
  local amount="$1"
  if [[ -z "$amount" || "$amount" == "null" ]]; then
    printf "%s" ""
  else
    printf "\$%s" "$amount"
  fi
}

pretty_print_grouped_service() {
  # Input: JSON from CE with group-by SERVICE (and optionally USAGE_TYPE)
  local include_usage="$1"    # "true" or "false"
  local include_usage_type="$2" # "true" if second group key is USAGE_TYPE

  # We will emit tab-separated fields from jq: date, label, cost_amount, usage_amount, usage_unit
  # Then printf with fixed widths and with $ for money.
  jq -r --argjson include_usage "$([[ "$include_usage" == "true" ]] && echo true || echo false)" \
        --argjson include_usage_type "$([[ "$include_usage_type" == "true" ]] && echo true || echo false)" '
    .ResultsByTime[] as $day
    | if (($day.Groups | length) > 0) then
        $day.Groups[]
        | . as $g
        | $day.TimePeriod.Start as $date
        | ($g.Keys[0] // "UNKNOWN") as $service
        | ($g.Keys[1] // null) as $usageType
        | ($g.Metrics.UnblendedCost.Amount // "0") as $costAmt
        | (if $include_usage then ($g.Metrics.UsageQuantity.Amount // null) else null end) as $usageAmt
        | (if $include_usage then ($g.Metrics.UsageQuantity.Unit // null) else null end) as $usageUnit
        | if $include_usage_type and ($usageType != null) then
            [$date, ($service + " | " + $usageType), $costAmt, ($usageAmt // ""), ($usageUnit // "")]
          else
            [$date, $service, $costAmt, ($usageAmt // ""), ($usageUnit // "")]
          end
        | @tsv
      else
        # No groups for that day; print a NO_DATA line using totals
        ($day.Total.UnblendedCost.Amount // "0") as $costAmt
        | [$day.TimePeriod.Start, "NO_DATA", $costAmt, "", ""]
        | @tsv
      end
  ' | awk -F'\t' '
      BEGIN { OFS="\t"; }
      {
        date=$1; label=$2; cost=$3; usageAmt=$4; usageUnit=$5;
        # Prefix cost with $
        if (cost == "" || cost == "null") cost_str="";
        else cost_str="$" cost;
        # Usage with unit (if present)
        usage_str="";
        if (usageAmt != "" && usageAmt != "null") {
          usage_str=usageAmt;
          if (usageUnit != "" && usageUnit != "null") usage_str=usage_str " " usageUnit;
        }
        # Print with fixed widths: date (10), label (40), cost (12), usage (rest)
        printf "%-10s  %-40s  %12s  %s\n", date, label, cost_str, usage_str;
      }
  '
}

pretty_print_total() {
  # Input: JSON with no groups, just Totals by day (or overall depending on request)
  jq -r '
    .ResultsByTime[] as $day
    | $day.TimePeriod.Start as $date
    | ($day.Total.UnblendedCost.Amount // "0") as $costAmt
    | ($day.Total.UnblendedCost.Unit // "USD") as $unit
    | [$date, $costAmt, $unit]
    | @tsv
  ' | awk -F'\t' '
      BEGIN { OFS="\t"; }
      {
        date=$1; cost=$2; unit=$3;
        cost_str="";
        if (cost != "" && cost != "null") cost_str="$" cost;
        printf "%-10s  %12s  %s\n", date, cost_str, unit;
      }
  '
}

case "$SUBCMD" in
  mtd-service-daily)
    if [[ "$RAW_JSON" == "true" ]]; then
      run_ce_grouped "DAILY" "SERVICE" "UnblendedCost" "UsageQuantity"
      exit 0
    fi
    run_ce_grouped "DAILY" "SERVICE" "UnblendedCost" "UsageQuantity" \
      | pretty_print_grouped_service "true" "false"
    ;;

  last7-service)
    if [[ "$RAW_JSON" == "true" ]]; then
      run_ce_grouped "DAILY" "SERVICE" "UnblendedCost" "UsageQuantity"
      exit 0
    fi
    run_ce_grouped "DAILY" "SERVICE" "UnblendedCost" "UsageQuantity" \
      | pretty_print_grouped_service "true" "false"
    ;;

  drill-service-usage)
    if [[ "$RAW_JSON" == "true" ]]; then
      run_ce_grouped "DAILY" "SERVICE" "UnblendedCost" "UsageQuantity" \
        -- "USAGE_TYPE"
      exit 0
    fi
    # Manual call because run_ce_grouped signature is simpler; emulate two group-bys here.
    {
      cmd=(aws ce get-cost-and-usage
        --region "$region"
        --time-period "Start=${START_DATE},End=${END_DATE}"
        --granularity DAILY
        --metrics UnblendedCost
        --metrics UsageQuantity
        --group-by "Type=DIMENSION,Key=SERVICE"
        --group-by "Type=DIMENSION,Key=USAGE_TYPE"
      )
      filter_json="$(build_filter_json)"
      if [[ -n "$filter_json" ]]; then
        cmd+=(--filter "$filter_json")
      fi
      if [[ "$DEBUG" == "true" ]]; then
        echo "+ ${cmd[*]}" >&2
      fi
      "${cmd[@]}"
    } | pretty_print_grouped_service "true" "true"
    ;;

  total-mtd)
    if [[ "$RAW_JSON" == "true" ]]; then
      run_ce "DAILY" "UnblendedCost"
      exit 0
    fi
    run_ce "DAILY" "UnblendedCost" | pretty_print_total
    ;;

  *)
    die "Unknown subcommand: ${SUBCMD}. Try -h."
    ;;
esac