#!/usr/bin/env bash
# Why has Firehose written nothing? Ask it, rather than guessing.
set -euo pipefail
export AWS_REGION=us-east-1
DELIVERY=lab8-payments-firehose
START=$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

for metric in IncomingRecords DeliveryToS3.Records DeliveryToS3.Success; do
  echo "== $metric"
  aws cloudwatch get-metric-statistics \
    --namespace AWS/Firehose --metric-name "$metric" \
    --dimensions "Name=DeliveryStreamName,Value=${DELIVERY}" \
    --start-time "$START" --end-time "$END" --period 300 \
    --statistics Sum --query 'Datapoints[].[Timestamp,Sum]' --output text | sort | tail -4
done

echo
echo "== firehose error logs"
for group in $(aws logs describe-log-groups --log-group-name-prefix /aws/kinesisfirehose \
               --query 'logGroups[].logGroupName' --output text); do
  echo "  group: $group"
  for stream in $(aws logs describe-log-streams --log-group-name "$group" \
                  --query 'logStreams[].logStreamName' --output text); do
    aws logs get-log-events --log-group-name "$group" --log-stream-name "$stream" \
      --limit 10 --query 'events[].message' --output text | tr '\t' '\n' | tail -5
  done
done
echo "(no output above means Firehose logged no errors)"
