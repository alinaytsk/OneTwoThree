#!/usr/bin/env bash
# Pack the submission into the five files the form allows.
#
#   1  lab8-report.md      Parts 1-4: every answer, number and explanation
#   2  lab8-pipeline.svg   the Part 4 diagram
#   3  lab8-queries.sql    every Athena query, in the order they were run
#   4  lab8-code-and-results.zip   the producers and consumer, the query results as CSV,
#                                  and the consumer output of every experiment
#   5  (a screenshot of the Athena query, taken in the console by hand)
set -euo pipefail
cd "$(dirname "$0")"
OUT=upload
rm -rf "$OUT"
mkdir -p "$OUT"

# 1. One report: the Uklon answers first, then the three hands-on parts.
{
  cat part1-uklon.md
  printf '\n\n---\n\n'
  cat submission.md
} > "$OUT/lab8-report.md"

# 2. The diagram.
cp cloud/pipeline.svg "$OUT/lab8-pipeline.svg"

# 3. Every query in one file, each under the name it ran as.
: > "$OUT/lab8-queries.sql"
for file in sql/*.sql sql/parquet/*.sql; do
  {
    printf -- '-- ============================================================\n'
    printf -- '-- %s\n' "$file"
    printf -- '-- ============================================================\n'
    cat "$file"
    printf '\n\n'
  } >> "$OUT/lab8-queries.sql"
done

# 4. Code and results: Part 4 asks for the producer, Part 3 for the consumer output.
python3 - <<'PY'
import pathlib, zipfile

root = pathlib.Path(".")
target = root / "upload" / "lab8-code-and-results.zip"
with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
    for path in sorted((root / "results").glob("*.csv")):
        archive.write(path, f"athena-csv/{path.name}")
    for path in sorted((root / "results").glob("*.txt")):
        archive.write(path, f"athena-raw/{path.name}")
    for path in sorted((root / "results" / "stream").glob("*.txt")):
        archive.write(path, f"part3-experiments/{path.name}")
    for name in ("stream/producer.py", "stream/consumer.py", "stream/docker-compose.yml",
                 "stream/experiments.sh", "stream/requirements.txt",
                 "cloud/producer.py", "cloud/alerts.py", "cloud/setup.sh",
                 "cloud/teardown.sh", "cloud/check.sh", "athena.sh"):
        archive.write(root / name, f"code/{name}")
print("zip entries:", len(zipfile.ZipFile(target).namelist()))
PY

echo
ls -la "$OUT"
