#!/usr/bin/env bash
# Queries 3-5 against JSON and against Parquet, so the two costs sit side by side.
#
# The Parquet variants are the same text with the table name swapped: the point of the
# comparison is that nothing about the query changes, only what it has to read.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p results sql/parquet

for name in 04-turnover 05-failure-rate 06-peak-hours; do
  sed 's/^FROM payments$/FROM payments_parquet/' "sql/${name}.sql" > "sql/parquet/${name}.sql"

  echo "================ ${name} =================="
  echo "---- JSON ----"
  ./athena.sh "sql/${name}.sql" | tee "results/${name}-json.txt"
  echo "---- PARQUET ----"
  ./athena.sh "sql/parquet/${name}.sql" | tee "results/${name}-parquet.txt"
  echo
done
