#!/usr/bin/env bash
set -euo pipefail
export AWS_PAGER=""

# Cost Explorer helper script
# - Formats output with clear $ for cost and aligned columns.
# - Avoids passing empty --filter (prevents ValidationException).
# - Supports optional service filter and usage drilldown.
#
# Columns (for pretty mode):
#   Date(10) | Service(40, left) | $Cost(15, right, full precision, no rounding) | Usage(40, right) | Unit(left)
# Widths are configurable via the variables below.
#
# Notes:
# - End is exclusive (AWS CE convention).
# - Cost Explorer is global; --region is for the endpoint only.
#
# Dependencies: aws, jq

REGION="${AWS_REGION:-us-east-1}"

# Defaults
CMD=""
START=""
END=""
DEBUG=0
RAW_JSON=0
EXCLUDE_CREDITS=0
SERVICE_FILTER=""
# Column widths (tweakable)
DATE_COL=10
SERVICE_COL=40
COST_COL=15
USAGE_COL=40


print_usage() {
  cat <<EOF
Usage: scripts/ce.sh <command> [options]

Commands:
  last7-service           Show daily UnblendedCost and UsageQuantity grouped by SERVICE for a range (default last 7 days)
  mtd-service-daily       Show month-to-date daily UnblendedCost and UsageQuantity grouped by SERVICE
  drill-service-usage     Show daily UnblendedCost and UsageQuantity grouped by SERVICE and USAGE_TYPE
  total-mtd               Show month-to-date total UnblendedCost (no grouping)

Options:
  --start YYYY-MM-DD      Start date (UTC). For last7-service default is 7 days ago.
  --end   YYYY-MM-DD      End date (UTC, exclusive). Default is today (UTC).
  --service "NAME"        Filter to a single service (exact match, e.g., "Amazon Simple Storage Service").
  --exclude-credits       Exclude Credit/Refund/Tax record types.
  --json                  Output raw JSON from AWS (no pretty formatting).
  --debug                 Print the AWS CLI command before running.
  -h, --help              Show this help.

Examples:
  scripts/ce.sh last7-service
  scripts/ce.sh last7-service --start 2025-09-13 --end 2025-09-14
  scripts/ce.sh last7-service --service "Amazon Simple Storage Service"
  scripts/ce.sh mtd-service-daily --exclude-credits
  scripts/ce.sh drill-service-usage --start 2025-09-13 --end 2025-09-14 --service "Amazon API Gateway"
  scripts/ce.sh total-mtd
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

# Build a CE filter JSON based on flags. Returns empty string if no filters.
build_filter_json() {
  local filters=()

  if [[ -n "$SERVICE_FILTER" ]]; then
    # Exact match on SERVICE
    filters+=("{\"Dimensions\":{\"Key\":\"SERVICE\",\"Values\":[\"$SERVICE_FILTER\"],\"MatchOptions\":[\"EQUALS\"]}}")
  fi

  if [[ "$EXCLUDE_CREDITS" -eq 1 ]]; then
    # Exclude Credit/Refund/Tax
    filters+=("{\"Not\":{\"Dimensions\":{\"Key\":\"RECORD_TYPE\",\"Values\":[\"Credit\",\"Refund\",\"Tax\"]}}}")
  fi

  if [[ "${#filters[@]}" -eq 0 ]]; then
    echo ""
  elif [[ "${#filters[@]}" -eq 1 ]]; then
    # Single filter
    echo "${filters[0]}"
  else
    # Combine via And
    local joined
    joined=$(printf ",%s" "${filters[@]}")
    joined="[${joined:1}]"
    echo "{\"And\":${joined}}"
  fi
}

# Compute default dates if not provided
compute_dates() {
  if [[ -z "$END" ]]; then
    END=$(date -u +%Y-%m-%d)
  fi
  if [[ -z "$START" ]]; then
    case "$CMD" in
      mtd-service-daily|total-mtd)
        START=$(date -u -d "$(date +%Y-%m-01)" +%Y-%m-%d)
        ;;
      *)
        START=$(date -u -d "7 days ago" +%Y-%m-%d)
        ;;
    esac
  fi
}

run_aws_ce() {
  local time_period="Start=$START,End=$END"
  local metrics="$1"       # space-separated metrics (e.g., "UnblendedCost UsageQuantity")
  shift
  local group_bys=("$@")   # each is 'Type=DIMENSION,Key=...'

  local args=(ce get-cost-and-usage --region "$REGION" --output json --no-cli-pager --time-period "$time_period" --granularity DAILY --metrics $metrics)
  for gb in "${group_bys[@]}"; do
    args+=(--group-by "$gb")
  done

  local filter_json
  filter_json="$(build_filter_json)"
  if [[ -n "$filter_json" ]]; then
    args+=(--filter "$filter_json")
  fi

  if [[ "$DEBUG" -eq 1 ]]; then
    # shellcheck disable=SC2145
    echo "+ aws ${args[@]}" >&2
  fi
  aws "${args[@]}"
}
is_valid_json() {
  local payload="${1:-}"
  # Non-empty and parses as JSON
  [[ -n "$payload" ]] && echo "$payload" | jq -e . >/dev/null 2>&1
}


print_header_if_any() {
  # Optional: print header once in pretty mode
  printf "%-*s  %-*s  %*s  %*s  %s\n" \
    "$DATE_COL" "Date" \
    "$SERVICE_COL" "Service" \
    "$COST_COL" "\$Cost(USD)" \
    "$USAGE_COL" "Usage" \
    "Unit"
}

format_amount_or_zero() {
  local amount="$1"
  if [[ -z "$amount" || "$amount" == "null" ]]; then
    echo "0"
  else
    echo "$amount"
  fi
}

pretty_print_service_daily() {
  # Input: full JSON from CE for grouping by SERVICE
  local json="$1"

  # Transform to TSV with jq first; only print header after successful jq.
  local body
  if ! body="$(printf '%s' "$json" | jq -r '
    .ResultsByTime[] as $day
    | if (($day.Groups | length) > 0) then
        $day.Groups[]
        | . as $g
        | $day.TimePeriod.Start as $date
        | ($g.Keys[0] // "UNKNOWN") as $service
        | ($g.Metrics.UnblendedCost.Amount // "0") as $costAmt
        | ($g.Metrics.UsageQuantity.Amount // "") as $usageAmt
        | ($g.Metrics.UsageQuantity.Unit // "") as $usageUnit
        | [$date, $service, $costAmt, $usageAmt, $usageUnit]
        | @tsv
      else
        ($day.Total.UnblendedCost.Amount // "0") as $costAmt
        | [$day.TimePeriod.Start, "NO_DATA", $costAmt, "", ""]
        | @tsv
      end
  ' 2>/dev/null)"; then
    echo "Error: failed to parse AWS JSON in pretty_print_service_daily." >&2
    return 1
  fi
  print_header_if_any
  awk -F'\t' -v date_w="$DATE_COL" -v svc_w="$SERVICE_COL" -v cost_w="$COST_COL" -v usage_w="$USAGE_COL" '
    BEGIN { OFS="\t"; }
    {
      date=$1; label=$2; cost=$3; usageAmt=$4; usageUnit=$5;
      if (cost == "" || cost == "null") cost_str="";
      else cost_str="$" cost;
      usage_str="";
      if (usageAmt != "" && usageAmt != "null") {
        usage_str=usageAmt;
        if (usageUnit != "" && usageUnit != "null") usage_str=usage_str " " usageUnit;
      }
      # Normalize unit placeholders
      gsub(/^(N\/A|None|-|null)$/, "", usageUnit);
      printf "%-*s  %-*s  %*s  %s\n", date_w, date, svc_w, label, cost_w, cost_str, usage_str;
    }
  ' <<< "$body"
}

pretty_print_service_usage_daily() {
  # Input: full JSON from CE for grouping by SERVICE and USAGE_TYPE
  local json="$1"

  local body
  if ! body="$(printf '%s' "$json" | jq -r '
    .ResultsByTime[] as $day
    | if (($day.Groups | length) > 0) then
        $day.Groups[]
        | . as $g
        | $day.TimePeriod.Start as $date
        | ($g.Keys[0] // "UNKNOWN") as $service
        | ($g.Keys[1] // "UNKNOWN_USAGE") as $usageType
        | ($g.Metrics.UnblendedCost.Amount // "0") as $costAmt
        | ($g.Metrics.UsageQuantity.Amount // "") as $usageAmt
        | ($g.Metrics.UsageQuantity.Unit // "") as $usageUnit
        | [$date, ($service + " | " + $usageType), $costAmt, $usageAmt, $usageUnit]
        | @tsv
      else
        ($day.Total.UnblendedCost.Amount // "0") as $costAmt
        | [$day.TimePeriod.Start, "NO_DATA", $costAmt, "", ""]
        | @tsv
      end
  ' 2>/dev/null)"; then
    echo "Error: failed to parse AWS JSON in pretty_print_service_usage_daily." >&2
    return 1
  fi
  print_header_if_any
  awk -F'\t' -v date_w="$DATE_COL" -v svc_w="$SERVICE_COL" -v cost_w="$COST_COL" -v usage_w="$USAGE_COL" '
    BEGIN { OFS="\t"; }
    {
      date=$1; label=$2; cost=$3; usageAmt=$4; usageUnit=$5;
      if (cost == "" || cost == "null") cost_str="";
      else cost_str="$" cost;
      usage_str="";
      if (usageAmt != "" && usageAmt != "null") {
        usage_str=usageAmt;
        if (usageUnit != "" && usageUnit != "null") usage_str=usage_str " " usageUnit;
      }
      gsub(/^(N\/A|None|-|null)$/, "", usageUnit);
      printf "%-*s  %-*s  %*s  %s\n", date_w, date, svc_w, label, cost_w, cost_str, usage_str;
    }
  ' <<< "$body"
}

pretty_print_total_daily() {
  # For total-mtd: we print per-day totals (no groups)
  local json="$1"
  # Simpler header for totals
  local body
  if ! body="$(printf '%s' "$json" | jq -r '
    .ResultsByTime[]
    | [$ .TimePeriod.Start, (.Total.UnblendedCost.Amount // "0"), "USD"]
    | @tsv
  ' 2>/dev/null)"; then
    echo "Error: failed to parse AWS JSON in pretty_print_total_daily." >&2
    return 1
  fi
  printf "%-*s  %*s  %s\n" "$DATE_COL" "Date" "$COST_COL" "\$Cost(USD)" "Unit"
  awk -F'\t' -v date_w="$DATE_COL" -v cost_w="$COST_COL" '
    BEGIN { OFS="\t"; }
    {
      date=$1; cost=$2; unit=$3;
      cost_str="";
      if (cost != "" && cost != "null") cost_str="$" cost;
      printf "%-*s  %*s  %s\n", date_w, date, cost_w, cost_str, unit;
    }
  ' <<< "$body"
}

# Parse args
if [[ $# -lt 1 ]]; then
  print_usage
  exit 1
fi
CMD="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start) START="${2:-}"; shift 2 ;;
    --end) END="${2:-}"; shift 2 ;;
    --exclude-credits) EXCLUDE_CREDITS=1; shift ;;
    --service) SERVICE_FILTER="${2:-}"; shift 2 ;;
    --json) RAW_JSON=1; shift ;;
    --debug) DEBUG=1; shift ;;
    -h|--help) print_usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

compute_dates

case "$CMD" in
  last7-service)
    # SERVICE grouping, include UsageQuantity
    RAW=$(run_aws_ce "UnblendedCost UsageQuantity" "Type=DIMENSION,Key=SERVICE")
    if [[ "$RAW_JSON" -eq 1 ]]; then
      echo "$RAW"
    else
      if ! is_valid_json "$RAW"; then
        echo "Error: AWS response is empty or not valid JSON. Use --debug or --json to investigate." >&2
        exit 1
      fi
      pretty_print_service_daily "$RAW"
    fi
    ;;
  mtd-service-daily)
    RAW=$(run_aws_ce "UnblendedCost UsageQuantity" "Type=DIMENSION,Key=SERVICE")
    if [[ "$RAW_JSON" -eq 1 ]]; then
      echo "$RAW"
    else
      if ! is_valid_json "$RAW"; then
        echo "Error: AWS response is empty or not valid JSON. Use --debug or --json to investigate." >&2
        exit 1
      fi
      pretty_print_service_daily "$RAW"
    fi
    ;;
  drill-service-usage)
    RAW=$(run_aws_ce "UnblendedCost UsageQuantity" "Type=DIMENSION,Key=SERVICE" "Type=DIMENSION,Key=USAGE_TYPE")
    if [[ "$RAW_JSON" -eq 1 ]]; then
      echo "$RAW"
    else
      if ! is_valid_json "$RAW"; then
        echo "Error: AWS response is empty or not valid JSON. Use --debug or --json to investigate." >&2
        exit 1
      fi
      pretty_print_service_usage_daily "$RAW"
    fi
    ;;
  total-mtd)
    RAW=$(run_aws_ce "UnblendedCost")
    if [[ "$RAW_JSON" -eq 1 ]]; then
      echo "$RAW"
    else
      if ! is_valid_json "$RAW"; then
        echo "Error: AWS response is empty or not valid JSON. Use --debug or --json to investigate." >&2
        exit 1
      fi
      pretty_print_total_daily "$RAW"
    fi
    ;;
  *)
    die "Unknown command: $CMD"
    ;;
esac

