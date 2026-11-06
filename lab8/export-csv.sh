#!/usr/bin/env bash
# The query results as plain CSV, without the cost footer, for uploading.
#
# Each .txt under results/ is the Athena result followed by a two-line summary of what
# the query scanned. The CSV keeps the rows; costs.csv keeps the summaries.
set -euo pipefail
cd "$(dirname "$0")/results"

: > costs.csv
echo "query,format,data_scanned_mb,run_time_s,query_id" >> costs.csv

for file in *.txt; do
  name="${file%.txt}"
  # Everything before the blank line that precedes the footer.
  sed -n '1,/^$/p' "$file" | sed '/^$/d' > "${name}.csv"

  scanned=$(grep -oE 'data scanned: [0-9.]+' "$file" | awk '{print $3}')
  seconds=$(grep -oE 'run time: [0-9.]+' "$file" | awk '{print $3}')
  identifier=$(grep -oE 'id: [0-9a-f-]+' "$file" | awk '{print $2}')
  case "$name" in
    *-parquet) format=parquet ;;
    *-json)    format=json ;;
    *)         format=json ;;
  esac
  echo "${name%%-json},${format},${scanned},${seconds},${identifier}" >> costs.csv
done

echo "wrote $(ls -1 ./*.csv | wc -l) csv files:"
ls -1 ./*.csv
