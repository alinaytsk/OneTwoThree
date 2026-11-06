#!/usr/bin/env bash
# The four experiments from Part 3. Each one starts from an empty topic and runs the
# producer live, because a consumer reading a log that is already complete drains it in
# a second and the experiment measures nothing.
#
#   ./experiments.sh            all four
#   ./experiments.sh restart    one of: restart, split, failures, lateness
set -euo pipefail
cd "$(dirname "$0")"
PY=./.venv/bin/python
OUT=../results/stream
mkdir -p "$OUT"

fresh_topic() {
  docker exec lab8-redpanda rpk topic delete payments >/dev/null 2>&1 || true
  docker exec lab8-redpanda rpk topic create payments -p 3 >/dev/null
}

summary() { grep -E '^(read|rejected|alerts|distinct)' "$1" | sed 's/^/    /'; }

experiment_restart() {
  echo "===== 1. stop the consumer for a while, then start it again ====="
  fresh_topic
  $PY -u producer.py --day 2026-10-01 --limit 20000 --rate 60 > "$OUT/restart-producer.txt" 2>&1 &
  local producer=$!

  echo "  consumer running for 30 s..."
  timeout -s INT 30 $PY -u consumer.py --from-start --group restart-test \
    > "$OUT/restart-part1.txt" 2>&1 || true
  echo "  consumer down for 30 s while the producer keeps sending..."
  sleep 30
  echo "  consumer back up, resuming from its committed offset"
  timeout -s INT 90 $PY -u consumer.py --group restart-test \
    > "$OUT/restart-part2.txt" 2>&1 || true
  wait $producer || true

  echo "  part 1:"; summary "$OUT/restart-part1.txt"
  echo "  part 2:"; summary "$OUT/restart-part2.txt"
  docker exec lab8-redpanda rpk group describe restart-test 2>/dev/null \
    | tee "$OUT/restart-lag.txt" | tail -5
}

experiment_split() {
  echo "===== 2. two consumers in one group ====="
  fresh_topic
  $PY -u producer.py --day 2026-10-01 --limit 20000 --rate 60 > "$OUT/split-producer.txt" 2>&1 &
  local producer=$!

  timeout -s INT 115 $PY -u consumer.py --from-start --group split-test \
    > "$OUT/split-a.txt" 2>&1 &
  local first=$!
  sleep 20
  echo "  a second consumer joins the group"
  timeout -s INT 95 $PY -u consumer.py --group split-test > "$OUT/split-b.txt" 2>&1 &
  local second=$!
  sleep 25
  docker exec lab8-redpanda rpk group describe split-test 2>/dev/null \
    | tee "$OUT/split-assignment.txt" | tail -8
  wait $first $second $producer || true
  echo "  consumer A:"; summary "$OUT/split-a.txt"
  echo "  consumer B:"; summary "$OUT/split-b.txt"
}

experiment_failures() {
  echo "===== 3. 30% of payments fail ====="
  fresh_topic
  $PY -u producer.py --day 2026-10-01 --limit 20000 --rate 60 --fail-rate 0.30 \
    > "$OUT/failures-producer.txt" 2>&1 &
  local producer=$!
  timeout -s INT 130 $PY -u consumer.py --from-start --group failure-test \
    > "$OUT/failures-consumer.txt" 2>&1 || true
  wait $producer || true
  echo "  alerts:"; summary "$OUT/failures-consumer.txt"
  grep -c ALERT "$OUT/failures-consumer.txt" | sed 's/^/    ALERT lines: /'
}

experiment_lateness() {
  echo "===== 4. no grace period for late events ====="
  # The topic from the previous experiment is enough: this one only changes the consumer.
  timeout -s INT 45 $PY -u consumer.py --from-start --group late-zero --lateness 0 \
    > "$OUT/consumer-lateness-0.txt" 2>&1 || true
  echo "  lateness = 0:"; summary "$OUT/consumer-lateness-0.txt"
}

case "${1:-all}" in
  restart)  experiment_restart ;;
  split)    experiment_split ;;
  failures) experiment_failures ;;
  lateness) experiment_lateness ;;
  all)      experiment_restart; echo; experiment_split; echo
            experiment_failures; echo; experiment_lateness ;;
  *)        echo "unknown experiment: $1"; exit 1 ;;
esac
