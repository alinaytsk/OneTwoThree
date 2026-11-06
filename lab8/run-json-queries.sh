#!/usr/bin/env bash
# Queries 3-6 against the JSON table, with their results and costs kept for the report.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p results

for name in 04-turnover 05-failure-rate 06-peak-hours 07-late-events; do
  echo "================ ${name} (JSON) ================"
  ./athena.sh "sql/${name}.sql" | tee "results/${name}-json.txt"
  echo
done
