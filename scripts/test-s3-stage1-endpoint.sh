#!/usr/bin/env bash

set -euo pipefail

: "${S3_ENDPOINT:?Set S3_ENDPOINT to the gateway URL}"
: "${S3_BUCKET:?Set S3_BUCKET to an existing isolated bucket}"

command -v aws >/dev/null
command -v curl >/dev/null

work_directory=$(mktemp -d)
cleanup() {
  rm -rf "$work_directory"
}
trap cleanup EXIT

export AWS_EC2_METADATA_DISABLED=true
export AWS_REQUEST_CHECKSUM_CALCULATION=${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}
export AWS_RESPONSE_CHECKSUM_VALIDATION=${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}
aws_arguments=(--endpoint-url "$S3_ENDPOINT" --no-cli-pager)
curl_arguments=(--silent --show-error --fail)
if [[ -n ${S3_CA_BUNDLE:-} ]]; then
  export AWS_CA_BUNDLE=$S3_CA_BUNDLE
  curl_arguments+=(--cacert "$S3_CA_BUNDLE")
fi

input_file="$work_directory/input.bin"
output_file="$work_directory/output.bin"
range_file="$work_directory/range.bin"
presigned_file="$work_directory/presigned.bin"
dd if=/dev/zero of="$input_file" bs=1024 count=256 2>/dev/null

primary_key=compatibility/object.bin
secondary_key=compatibility/second.bin
aws "${aws_arguments[@]}" s3api put-object \
  --bucket "$S3_BUCKET" \
  --key "$primary_key" \
  --body "$input_file" \
  --content-type application/octet-stream \
  --metadata suite=aws-cli \
  --checksum-algorithm SHA256 \
  >"$work_directory/put.json"
etag=$(jq -r '.ETag' "$work_directory/put.json")
[[ "$etag" != null && -n "$etag" ]]

aws "${aws_arguments[@]}" s3api put-object \
  --bucket "$S3_BUCKET" \
  --key "$secondary_key" \
  --body "$input_file" \
  >/dev/null

aws "${aws_arguments[@]}" s3api head-object \
  --bucket "$S3_BUCKET" \
  --key "$primary_key" \
  >"$work_directory/head.json"
jq -e '
  .ContentLength == 262144 and
  .ContentType == "application/octet-stream" and
  .Metadata.suite == "aws-cli"
' "$work_directory/head.json" >/dev/null

aws "${aws_arguments[@]}" s3api get-object \
  --bucket "$S3_BUCKET" \
  --key "$primary_key" \
  --if-match "$etag" \
  "$output_file" \
  >/dev/null
cmp "$input_file" "$output_file"

if aws "${aws_arguments[@]}" s3api get-object \
  --bucket "$S3_BUCKET" \
  --key "$primary_key" \
  --if-none-match "$etag" \
  "$work_directory/not-modified.bin" \
  >"$work_directory/not-modified.stdout" \
  2>"$work_directory/not-modified.stderr"; then
  echo "If-None-Match unexpectedly returned an object." >&2
  exit 1
fi
grep -Eq 'Not Modified|304' "$work_directory/not-modified.stderr"

aws "${aws_arguments[@]}" s3api get-object \
  --bucket "$S3_BUCKET" \
  --key "$primary_key" \
  --range bytes=0-1023 \
  "$range_file" \
  >/dev/null
[[ $(wc -c <"$range_file") -eq 1024 ]]

aws "${aws_arguments[@]}" s3api list-objects-v2 \
  --bucket "$S3_BUCKET" \
  --prefix compatibility/ \
  --max-keys 1 \
  >"$work_directory/page-one.json"
jq -e '.IsTruncated == true and (.Contents | length) == 1' "$work_directory/page-one.json" >/dev/null
continuation_token=$(jq -r '.NextContinuationToken' "$work_directory/page-one.json")
[[ "$continuation_token" != null && -n "$continuation_token" ]]
aws "${aws_arguments[@]}" s3api list-objects-v2 \
  --bucket "$S3_BUCKET" \
  --prefix compatibility/ \
  --max-keys 1 \
  --continuation-token "$continuation_token" \
  >"$work_directory/page-two.json"
jq -e '.IsTruncated == false and (.Contents | length) == 1' "$work_directory/page-two.json" >/dev/null

presigned_url=$(aws "${aws_arguments[@]}" s3 presign \
  "s3://$S3_BUCKET/$primary_key" \
  --expires-in 60)
curl "${curl_arguments[@]}" "$presigned_url" --output "$presigned_file"
cmp "$input_file" "$presigned_file"

if aws "${aws_arguments[@]}" s3api create-multipart-upload \
  --bucket "$S3_BUCKET" \
  --key compatibility/unsupported.bin \
  >"$work_directory/multipart.stdout" \
  2>"$work_directory/multipart.stderr"; then
  echo "Stage 2 multipart unexpectedly became available." >&2
  exit 1
fi
grep -q 'NotImplemented' "$work_directory/multipart.stderr"

for key in "$primary_key" "$secondary_key"; do
  aws "${aws_arguments[@]}" s3api delete-object \
    --bucket "$S3_BUCKET" \
    --key "$key" \
    >/dev/null
  if aws "${aws_arguments[@]}" s3api head-object \
    --bucket "$S3_BUCKET" \
    --key "$key" \
    >/dev/null 2>&1; then
    echo "Deleted object remained visible: $key" >&2
    exit 1
  fi
done

echo "Stage 1 endpoint matrix passed: $(aws --version 2>&1)"
