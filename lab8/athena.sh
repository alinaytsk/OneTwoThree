#!/usr/bin/env bash
# Run one Athena query and report what it cost.
#
#   ./athena.sh sql/03-turnover.sql        -- a file
#   ./athena.sh -q "SELECT 1"              -- a one-liner
#
# Prints the result rows, then the two numbers the lab asks for: data scanned and
# engine run time. Athena bills scanned bytes, so that first number is the price.

set -euo pipefail

BUCKET="${LAB8_BUCKET:-ucu-lab8-payments-896138901201}"
OUTPUT="s3://${BUCKET}/athena-results/"
DATABASE="${LAB8_DATABASE:-payments_raw}"
export AWS_REGION="${AWS_REGION:-us-east-1}"

if [ "${1:-}" = "-q" ]; then
  QUERY="$2"
  LABEL="(inline)"
else
  QUERY="$(cat "$1")"
  LABEL="$1"
fi

ID=$(aws athena start-query-execution \
  --query-string "$QUERY" \
  --query-execution-context "Database=${DATABASE}" \
  --result-configuration "OutputLocation=${OUTPUT}" \
  --query QueryExecutionId --output text)

while true; do
  read -r STATE REASON <<<"$(aws athena get-query-execution --query-execution-id "$ID" \
    --query '[QueryExecution.Status.State, QueryExecution.Status.StateChangeReason]' \
    --output text)"
  case "$STATE" in
    SUCCEEDED) break ;;
    FAILED|CANCELLED)
      echo "$LABEL -> $STATE"
      echo "$REASON"
      exit 1
      ;;
  esac
  sleep 2
done

read -r SCANNED MILLIS <<<"$(aws athena get-query-execution --query-execution-id "$ID" \
  --query '[QueryExecution.Statistics.DataScannedInBytes, QueryExecution.Statistics.EngineExecutionTimeInMillis]' \
  --output text)"

aws s3 cp "${OUTPUT}${ID}.csv" - 2>/dev/null || echo "(no result file: a DDL statement returns none)"

awk -v s="$SCANNED" -v m="$MILLIS" -v l="$LABEL" -v i="$ID" 'BEGIN {
  printf "\n%s\n  data scanned: %.2f MB   run time: %.2f s   id: %s\n", l, s/1048576, m/1000, i
}'
