# Cost Explorer output formatting notes

This documents the column layout used by scripts/ce.sh for “pretty” output.

Columns
- Date: width 10 (YYYY-MM-DD)
- Service: width 40, left-aligned (keeps full service name in a single column)
- $Cost(USD): width 15, right-aligned, full precision string from AWS (no rounding), always prefixed with “$”. This ensures tiny fractional costs are visible.
- Usage: width 40, right-aligned (numeric value only). This is intentionally wide (expanded by an additional 20 chars from the earlier version) so large-precision quantities line up cleanly.
- Unit: left-aligned (e.g., Requests, GB, GB-Hours, or N/A)

Reminder
- If you see $0 where you expect micro-costs, re-run with --debug and/or --json to inspect the raw AWS amounts. We print the amount exactly as returned by AWS; no rounding is applied in the script.

Notes
- End date for all queries is exclusive (AWS Cost Explorer convention).
- When UsageQuantity is not present for a row/day, both Usage and Unit columns are left blank.
- We never pass an empty --filter to Cost Explorer (avoids ValidationException).
- The --service flag filters by an exact SERVICE name (Dimensions: SERVICE, MatchOptions: EQUALS).

Example

Date        Service                                     $Cost(USD)                                      Usage  Unit
2025-09-13  Amazon Simple Storage Service               $0.0001662                          59.0015439877  N/A
2025-09-13  Amazon API Gateway                          $0.00000222                          2.0000003054  N/A
2025-09-13  AWS Lambda                                  $0                                              3.04225  N/A
2025-09-02  NO_DATA                                     $0

Tips
- Use --debug to see the AWS CLI command being executed.
- Use --json to output the raw AWS response (no formatting).
- Use --exclude-credits to exclude Credit/Refund/Tax record types.
- Use --service "Amazon Simple Storage Service" to narrow to a single service.
- If you’d like to hide Unit when it is “N/A”, or change column widths (Service/Usage), Buddy can add flags like --hide-na-unit, --service-width, and --usage-width.
Changelog
- 2025-09-14: Cost column now shows full precision (no rounding) right-aligned in 15 chars and prefixed with $; Usage column widened to 40 chars and Unit separated, per DevLead request.

