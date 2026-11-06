#!/usr/bin/env bash
# The other half of setup.sh. A Kinesis shard bills by the hour whether anything flows
# through it or not, so this is not optional housekeeping.
#
# What it keeps: the S3 data (it costs cents a month and the Athena tables read it) and
# the Glue crawler. What it deletes: everything billed by time.
set -euo pipefail
export AWS_REGION=us-east-1

STREAM=lab8-payments-stream
DELIVERY=lab8-payments-firehose
LAMBDA=lab8-failure-alerts
TOPIC_NAME=lab8-payment-alerts
FIREHOSE_ROLE=lab8-firehose-role
LAMBDA_ROLE=lab8-alerts-role

gone() { echo "  gone: $1"; }

echo "== Lambda and its trigger"
for uuid in $(aws lambda list-event-source-mappings --function-name "$LAMBDA" \
              --query 'EventSourceMappings[].UUID' --output text 2>/dev/null || true); do
  aws lambda delete-event-source-mapping --uuid "$uuid" >/dev/null 2>&1 || true
  gone "mapping $uuid"
done
aws lambda delete-function --function-name "$LAMBDA" 2>/dev/null && gone "$LAMBDA" || true

echo "== Firehose"
aws firehose delete-delivery-stream --delivery-stream-name "$DELIVERY" --allow-force-delete \
  2>/dev/null && gone "$DELIVERY" || true

echo "== Kinesis"
aws kinesis delete-stream --stream-name "$STREAM" --enforce-consumer-deletion \
  2>/dev/null && gone "$STREAM" || true

echo "== SNS"
arn=$(aws sns list-topics --query "Topics[?ends_with(TopicArn, ':${TOPIC_NAME}')].TopicArn" \
      --output text)
[ -n "$arn" ] && aws sns delete-topic --topic-arn "$arn" && gone "$arn"

echo "== IAM roles"
for role in "$FIREHOSE_ROLE" "$LAMBDA_ROLE"; do
  aws iam list-attached-role-policies --role-name "$role" \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null \
    | tr '\t' '\n' | while read -r policy; do
        [ -n "$policy" ] && aws iam detach-role-policy --role-name "$role" --policy-arn "$policy"
      done
  aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text 2>/dev/null \
    | tr '\t' '\n' | while read -r inline; do
        [ -n "$inline" ] && aws iam delete-role-policy --role-name "$role" --policy-name "$inline"
      done
  aws iam delete-role --role-name "$role" 2>/dev/null && gone "$role" || true
done

echo
echo "Still there on purpose: the S3 bucket, the Athena tables, the Glue crawler."
echo "Check nothing is left billing by the hour:"
aws kinesis list-streams --query StreamNames --output text
aws firehose list-delivery-streams --query DeliveryStreamNames --output text
