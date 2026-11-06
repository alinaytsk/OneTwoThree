#!/usr/bin/env bash
# Way B: a Glue Crawler over the same prefix, into its own database, so the schema it
# guesses can be compared with the hand-written one without overwriting it.
set -euo pipefail
export AWS_REGION=us-east-1

BUCKET=ucu-lab8-payments-896138901201
ROLE=AWSGlueServiceRole-lab8
CRAWLER=lab8-payments-crawler
DATABASE=payments_crawler

trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"glue.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$trust" \
    --description "Glue crawler for the lab 8 payments dataset" >/dev/null
  aws iam attach-role-policy --role-name "$ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole
  aws iam put-role-policy --role-name "$ROLE" --policy-name read-the-payments-bucket \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],\"Resource\":[\"arn:aws:s3:::${BUCKET}\",\"arn:aws:s3:::${BUCKET}/*\"]}]}"
  echo "role created: $ROLE"
  # IAM is eventually consistent; Glue rejects a role it cannot assume yet.
  sleep 15
else
  echo "role already there: $ROLE"
fi

aws glue create-database --database-input "{\"Name\":\"${DATABASE}\"}" 2>/dev/null \
  && echo "database created: $DATABASE" || echo "database already there: $DATABASE"

if ! aws glue get-crawler --name "$CRAWLER" >/dev/null 2>&1; then
  aws glue create-crawler --name "$CRAWLER" \
    --role "$ROLE" --database-name "$DATABASE" \
    --targets "{\"S3Targets\":[{\"Path\":\"s3://${BUCKET}/payments/\"}]}" \
    --recrawl-policy '{"RecrawlBehavior":"CRAWL_EVERYTHING"}'
  echo "crawler created: $CRAWLER"
else
  echo "crawler already there: $CRAWLER"
fi

aws glue start-crawler --name "$CRAWLER"
echo "crawler started, waiting..."

while true; do
  state=$(aws glue get-crawler --name "$CRAWLER" --query 'Crawler.State' --output text)
  [ "$state" = "READY" ] && break
  sleep 10
done

aws glue get-crawler --name "$CRAWLER" \
  --query 'Crawler.LastCrawl.{status:Status,message:ErrorMessage,at:StartTime}' --output table
aws glue get-tables --database-name "$DATABASE" --query 'TableList[].Name' --output text
