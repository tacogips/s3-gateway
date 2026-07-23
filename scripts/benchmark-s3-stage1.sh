#!/usr/bin/env bash

set -euo pipefail

: "${S3_ENDPOINT:?Set S3_ENDPOINT to the benchmark target URL}"
: "${S3_BUCKET:?Set S3_BUCKET to an existing isolated bucket}"
: "${TARGET_LABEL:?Set TARGET_LABEL to a storage-model-specific label}"

if [[ $# -ne 1 ]]; then
  echo "Usage: scripts/benchmark-s3-stage1.sh <result-directory>" >&2
  exit 2
fi

command -v aws >/dev/null
command -v hyperfine >/dev/null

result_directory=$1
benchmark_runs=${BENCHMARK_RUNS:-10}
benchmark_warmup=${BENCHMARK_WARMUP:-2}
benchmark_concurrency=${BENCHMARK_CONCURRENCY:-4}
[[ "$benchmark_runs" =~ ^[1-9][0-9]*$ ]]
[[ "$benchmark_warmup" =~ ^[0-9]+$ ]]
[[ "$benchmark_concurrency" =~ ^[1-9][0-9]*$ ]]
if [[ -n ${TARGET_PID:-} ]]; then
  [[ "$TARGET_PID" =~ ^[1-9][0-9]*$ ]]
  kill -0 "$TARGET_PID"
fi
mkdir -p "$result_directory"
work_directory=$(mktemp -d)
rss_stop_file="$work_directory/stop-rss-sampler"
rss_sampler_pid=
cleanup() {
  if [[ -n "$rss_sampler_pid" ]]; then
    touch "$rss_stop_file"
    wait "$rss_sampler_pid" 2>/dev/null || true
  fi
  rm -rf "$work_directory"
}
trap cleanup EXIT

{
  echo "target_label=$TARGET_LABEL"
  echo "s3_endpoint=$S3_ENDPOINT"
  echo "aws_cli=$(aws --version 2>&1)"
  echo "hyperfine=$(hyperfine --version 2>&1)"
  echo "operating_system=$(uname -srm)"
  echo "benchmark_runs=$benchmark_runs"
  echo "benchmark_warmup=$benchmark_warmup"
  echo "benchmark_concurrency=$benchmark_concurrency"
} >"$result_directory/environment.txt"

if [[ -n ${TARGET_PID:-} ]]; then
  (
    maximum_rss_kib=0
    while [[ ! -e "$rss_stop_file" ]] && kill -0 "$TARGET_PID" 2>/dev/null; do
      current_rss_kib=$(ps -o rss= -p "$TARGET_PID" | tr -d ' ')
      if [[ "$current_rss_kib" =~ ^[0-9]+$ ]] &&
         (( current_rss_kib > maximum_rss_kib )); then
        maximum_rss_kib=$current_rss_kib
      fi
      sleep 0.05
    done
    echo "$maximum_rss_kib" >"$result_directory/maximum-rss-kib.txt"
  ) &
  rss_sampler_pid=$!
fi

dd if=/dev/zero of="$work_directory/small.bin" bs=4096 count=1 2>/dev/null
dd if=/dev/zero of="$work_directory/large.bin" bs=1048576 count=64 2>/dev/null

aws_args=(--endpoint-url "$S3_ENDPOINT" --no-cli-pager)
small_key="benchmark/${TARGET_LABEL}/small.bin"
large_key="benchmark/${TARGET_LABEL}/large.bin"

aws "${aws_args[@]}" s3api put-object --bucket "$S3_BUCKET" --key "$small_key" --body "$work_directory/small.bin" >/dev/null
aws "${aws_args[@]}" s3api put-object --bucket "$S3_BUCKET" --key "$large_key" --body "$work_directory/large.bin" >/dev/null
aws "${aws_args[@]}" s3api get-object --bucket "$S3_BUCKET" --key "$large_key" "$work_directory/verified.bin" >/dev/null
cmp "$work_directory/large.bin" "$work_directory/verified.bin"

endpoint_shell=$(printf '%q' "$S3_ENDPOINT")
bucket_shell=$(printf '%q' "$S3_BUCKET")
small_key_shell=$(printf '%q' "$small_key")
large_key_shell=$(printf '%q' "$large_key")
small_file_shell=$(printf '%q' "$work_directory/small.bin")
large_file_shell=$(printf '%q' "$work_directory/large.bin")
download_shell=$(printf '%q' "$work_directory/download.bin")
concurrent_get="worker=0; while [ \$worker -lt $benchmark_concurrency ]; do aws --endpoint-url $endpoint_shell --no-cli-pager s3api get-object --bucket $bucket_shell --key $large_key_shell $download_shell.concurrent-\$worker >/dev/null & worker=\$((worker + 1)); done; wait"
concurrent_put="worker=0; while [ \$worker -lt $benchmark_concurrency ]; do aws --endpoint-url $endpoint_shell --no-cli-pager s3api put-object --bucket $bucket_shell --key $large_key_shell.concurrent-\$worker --body $large_file_shell >/dev/null & worker=\$((worker + 1)); done; wait"

hyperfine --warmup "$benchmark_warmup" --runs "$benchmark_runs" \
  --export-json "$result_directory/warm-operations.json" \
  --command-name get-large "aws --endpoint-url $endpoint_shell --no-cli-pager s3api get-object --bucket $bucket_shell --key $large_key_shell $download_shell >/dev/null" \
  --command-name put-large "aws --endpoint-url $endpoint_shell --no-cli-pager s3api put-object --bucket $bucket_shell --key $large_key_shell --body $large_file_shell >/dev/null" \
  --command-name put-small "aws --endpoint-url $endpoint_shell --no-cli-pager s3api put-object --bucket $bucket_shell --key $small_key_shell --body $small_file_shell >/dev/null" \
  --command-name head-small "aws --endpoint-url $endpoint_shell --no-cli-pager s3api head-object --bucket $bucket_shell --key $small_key_shell >/dev/null" \
  --command-name list-prefix "aws --endpoint-url $endpoint_shell --no-cli-pager s3api list-objects-v2 --bucket $bucket_shell --prefix benchmark/$TARGET_LABEL/ --max-keys 1000 >/dev/null" \
  --command-name "get-large-concurrent-$benchmark_concurrency" "$concurrent_get" \
  --command-name "put-large-concurrent-$benchmark_concurrency" "$concurrent_put"

if [[ -n "$rss_sampler_pid" ]]; then
  touch "$rss_stop_file"
  wait "$rss_sampler_pid" 2>/dev/null || true
  rss_sampler_pid=
fi

echo "Wrote $result_directory/warm-operations.json"
