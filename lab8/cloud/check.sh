#!/usr/bin/env bash
# What the cloud pipeline did: the alerts the Lambda raised, and the files Firehose wrote.
set -euo pipefail
export AWS_REGION=us-east-1

BUCKET=ucu-lab8-payments-896138901201
GROUP=/aws/lambda/lab8-failure-alerts

echo "== what the Lambda saw (one line per batch)"
stream=$(aws logs describe-log-streams --log-group-name "$GROUP" \
  --order-by LastEventTime --descending --max-items 1 \
  --query 'logStreams[0].logStreamName' --output text)
aws logs get-log-events --log-group-name "$GROUP" --log-stream-name "$stream" \
  --limit 100 --query 'events[].message' --output text \
  | tr '\t' '\n' | grep -oE '\{"records".*\}' | tail -6

echo
echo "== alerts published to SNS"
aws logs get-log-events --log-group-name "$GROUP" --log-stream-name "$stream" \
  --limit 100 --query 'events[].message' --output text \
  | tr '\t' '\n' | grep -oE '"alerts": [0-9]+' | awk -F': ' '{s+=$2} END {print "  alerts raised:", s+0}'

echo
echo "== waiting for Firehose to flush (buffer: 5 MB or 60 s)"
for _ in $(seq 1 18); do
  count=$(aws s3 ls "s3://${BUCKET}/stream/raw/" --recursive | wc -l)
  if [ "$count" -gt 0 ]; then
    echo "  $count file(s) in s3://${BUCKET}/stream/raw/"
    break
  fi
  sleep 10
done
aws s3 ls "s3://${BUCKET}/stream/raw/" --recursive --human-readable | tail -5
