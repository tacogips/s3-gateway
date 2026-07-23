#!/usr/bin/env bash

set -euo pipefail

command -v aws >/dev/null
command -v curl >/dev/null
command -v jq >/dev/null
command -v openssl >/dev/null

gateway_binary=${GATEWAY_BINARY:-.build/debug/swift-s3-gateway}
gateway_port=${GATEWAY_PORT:-18443}
maximum_object_bytes=${MAXIMUM_OBJECT_BYTES:-104857600}
request_timeout_seconds=${REQUEST_TIMEOUT_SECONDS:-30}
streaming_object_mib=${STAGE1_STREAMING_OBJECT_MIB:-0}
streaming_discard_download=${STAGE1_STREAMING_DISCARD_DOWNLOAD:-0}
require_larger_than_physical_memory=${STAGE1_REQUIRE_OBJECT_LARGER_THAN_PHYSICAL_MEMORY:-0}
crash_recovery_mib=${STAGE1_CRASH_RECOVERY_MIB:-0}
[[ "$maximum_object_bytes" =~ ^[1-9][0-9]*$ ]]
[[ "$request_timeout_seconds" =~ ^[1-9][0-9]*$ ]]
[[ "$streaming_object_mib" =~ ^[0-9]+$ ]]
[[ "$streaming_discard_download" =~ ^[01]$ ]]
[[ "$require_larger_than_physical_memory" =~ ^[01]$ ]]
[[ "$crash_recovery_mib" =~ ^[0-9]+$ ]]
if [[ ! -x "$gateway_binary" ]]; then
  echo "Build the gateway first or set GATEWAY_BINARY." >&2
  exit 2
fi

work_directory=$(mktemp -d)
gateway_pid=
upload_pid=
cleanup() {
  if [[ -n "$upload_pid" ]]; then
    kill "$upload_pid" 2>/dev/null || true
    wait "$upload_pid" 2>/dev/null || true
  fi
  if [[ -n "$gateway_pid" ]]; then
    kill -TERM "$gateway_pid" 2>/dev/null || true
    wait "$gateway_pid" 2>/dev/null || true
  fi
  rm -rf "$work_directory"
}
trap cleanup EXIT

root_directory="$work_directory/data"
sidecar_directory="$work_directory/sidecar"
staging_directory="$work_directory/staging"
mkdir -p "$root_directory" "$sidecar_directory" "$staging_directory"
chmod 700 "$sidecar_directory" "$staging_directory"

certificate="$work_directory/certificate.pem"
private_key="$work_directory/private-key.pem"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$private_key" \
  -out "$certificate" \
  -days 1 \
  -subj /CN=localhost \
  -addext subjectAltName=DNS:localhost \
  >/dev/null 2>&1
chmod 600 "$private_key"

access_key=STAGE1CLIENT
client_secret=$(openssl rand -base64 24)
upstream_secret=$(openssl rand -base64 24)
pagination_secret=$(openssl rand -base64 32)
inbound_file="$work_directory/inbound.json"
upstream_file="$work_directory/upstream.json"
pagination_file="$work_directory/pagination.json"

jq -n \
  --arg access_key "$access_key" \
  --arg secret "$client_secret" \
  '{
    version: 1,
    records: [{
      accessKeyID: $access_key,
      secretAccessKey: $secret,
      principalID: "aws-cli-client",
      enabled: true
    }]
  }' >"$inbound_file"
jq -n \
  --arg secret "$upstream_secret" \
  '{
    version: 1,
    active: {
      accessKeyID: "UNUSEDUPSTREAM",
      secretAccessKey: $secret,
      sessionToken: null
    }
  }' >"$upstream_file"
jq -n \
  --arg secret "$pagination_secret" \
  '{
    version: 1,
    activeKeyID: "stage1-page",
    keys: [{
      keyID: "stage1-page",
      secretBase64: $secret,
      enabled: true
    }]
  }' >"$pagination_file"
chmod 600 "$inbound_file" "$upstream_file" "$pagination_file"

configuration="$work_directory/gateway.json"
jq -n \
  --argjson port "$gateway_port" \
  --argjson maximum_object_bytes "$maximum_object_bytes" \
  --argjson request_timeout_seconds "$request_timeout_seconds" \
  --arg certificate "$certificate" \
  --arg private_key "$private_key" \
  --arg inbound "$inbound_file" \
  --arg upstream "$upstream_file" \
  --arg pagination "$pagination_file" \
  --arg root "$root_directory" \
  --arg sidecar "$sidecar_directory" \
  '{
    listener: {
      host: "127.0.0.1",
      port: $port,
      tls: {
        certificateChainPath: $certificate,
        privateKeyPath: $private_key
      },
      developmentPlaintext: false,
      trustedProxyAddresses: []
    },
    limits: {
      maximumHeaderBytes: 32768,
      maximumXMLBytes: 1048576,
      maximumObjectBytes: $maximum_object_bytes,
      maximumChunkBytes: 4096,
      maximumInFlightBytes: 16384,
      maximumConcurrentRequests: 8,
      requestTimeoutSeconds: $request_timeout_seconds
    },
    addressingStyles: ["path"],
    virtualHostSuffixes: [],
    acceptedSigV4Regions: ["us-east-1"],
    health: {
      livenessPath: "/.well-known/swift-s3-gateway/live",
      readinessPath: "/.well-known/swift-s3-gateway/ready"
    },
    telemetry: {enabled: true},
    credentials: {
      inboundPath: $inbound,
      upstreamPath: $upstream,
      paginationPath: $pagination
    },
    authorization: [{
      principalID: "aws-cli-client",
      grants: [{
        operations: [
          "getObject",
          "headObject",
          "putObject",
          "deleteObject",
          "listObjectsV2"
        ],
        bucket: "test-bucket",
        keyPrefix: null
      }]
    }],
    backend: {
      kind: "posix",
      posix: {
        rootPath: $root,
        bucketDirectories: {"test-bucket": "bucket"},
        layoutPolicy: "sharedLocalDirectory",
        sidecarPath: $sidecar,
        durability: "data"
      }
    }
  }' >"$configuration"

endpoint="https://localhost:$gateway_port"
ready_url="$endpoint/.well-known/swift-s3-gateway/ready"
start_gateway() {
  "$gateway_binary" serve --config "$configuration" \
    >>"$work_directory/gateway.stdout" \
    2>>"$work_directory/gateway.stderr" &
  gateway_pid=$!
  for _ in {1..100}; do
    if curl --silent --fail --cacert "$certificate" "$ready_url" >/dev/null; then
      return
    fi
    if ! kill -0 "$gateway_pid" 2>/dev/null; then
      echo "Gateway exited before readiness." >&2
      sed -n '1,80p' "$work_directory/gateway.stderr" >&2
      exit 1
    fi
    sleep 0.05
  done
  curl --silent --fail --cacert "$certificate" "$ready_url" >/dev/null
}
start_gateway

export AWS_ACCESS_KEY_ID=$access_key
export AWS_SECRET_ACCESS_KEY=$client_secret
export AWS_DEFAULT_REGION=us-east-1
export AWS_CA_BUNDLE=$certificate
export AWS_EC2_METADATA_DISABLED=true
if [[ ${AWS_CLI_DEFAULT_CHECKSUMS:-0} != 1 ]]; then
  export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
  export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
fi
aws_arguments=(--endpoint-url "$endpoint" --no-cli-pager)

input_file="$work_directory/input.bin"
output_file="$work_directory/output.bin"
range_file="$work_directory/range.bin"
dd if=/dev/zero of="$input_file" bs=1024 count=256 2>/dev/null

aws "${aws_arguments[@]}" s3api put-object \
  --bucket test-bucket \
  --key compatibility/object.bin \
  --body "$input_file" \
  --content-type application/octet-stream \
  --metadata suite=aws-cli \
  >/dev/null

head_length=$(aws "${aws_arguments[@]}" s3api head-object \
  --bucket test-bucket \
  --key compatibility/object.bin \
  --query ContentLength \
  --output text)
[[ "$head_length" == "262144" ]]

aws "${aws_arguments[@]}" s3api get-object \
  --bucket test-bucket \
  --key compatibility/object.bin \
  "$output_file" \
  >/dev/null
cmp "$input_file" "$output_file"

aws "${aws_arguments[@]}" s3api get-object \
  --bucket test-bucket \
  --key compatibility/object.bin \
  --range bytes=0-1023 \
  "$range_file" \
  >/dev/null
[[ $(wc -c <"$range_file") -eq 1024 ]]

listed_key=$(aws "${aws_arguments[@]}" s3api list-objects-v2 \
  --bucket test-bucket \
  --prefix compatibility/ \
  --query 'Contents[0].Key' \
  --output text)
[[ "$listed_key" == "compatibility/object.bin" ]]

if [[ -n ${STAGE1_BENCHMARK_RESULT_DIR:-} ]]; then
  S3_ENDPOINT=$endpoint \
  S3_BUCKET=test-bucket \
  TARGET_LABEL=swift-s3-gateway-shared \
  TARGET_PID=$gateway_pid \
  scripts/benchmark-s3-stage1.sh "$STAGE1_BENCHMARK_RESULT_DIR"
fi

if (( crash_recovery_mib > 0 )); then
  crash_bytes=$((crash_recovery_mib * 1048576))
  if (( crash_bytes > maximum_object_bytes )); then
    echo "The crash-recovery object exceeds maximumObjectBytes." >&2
    exit 2
  fi
  crash_input="$work_directory/crash-input.bin"
  dd if=/dev/zero of="$crash_input" bs=1 count=0 seek="$crash_bytes" 2>/dev/null
  aws "${aws_arguments[@]}" s3api put-object \
    --bucket test-bucket \
    --key compatibility/interrupted.bin \
    --body "$crash_input" \
    >/dev/null 2>&1 &
  upload_pid=$!
  staging_bucket="$sidecar_directory/.swift-s3-gateway-staging/test-bucket"
  staged_bytes_observed=0
  for _ in {1..4000}; do
    for staged_file in "$staging_bucket"/.swift-s3-gateway-*.tmp; do
      if [[ -f "$staged_file" ]] &&
         [[ $(wc -c <"$staged_file") -gt 1048576 ]]; then
        staged_bytes_observed=1
        break 2
      fi
    done
    if ! kill -0 "$upload_pid" 2>/dev/null; then
      break
    fi
    sleep 0.01
  done
  if (( staged_bytes_observed == 0 )); then
    echo "No staged bytes were observed before the crash exercise ended." >&2
    exit 1
  fi
  kill -KILL "$gateway_pid"
  wait "$gateway_pid" 2>/dev/null || true
  gateway_pid=
  if wait "$upload_pid" 2>/dev/null; then
    echo "The interrupted PUT unexpectedly succeeded." >&2
    exit 1
  fi
  upload_pid=
  start_gateway
  if find "$staging_bucket" -type f -name '.swift-s3-gateway-*.tmp' -print -quit |
     grep -q .; then
    echo "Startup recovery left an abandoned staging file." >&2
    exit 1
  fi
  if aws "${aws_arguments[@]}" s3api head-object \
    --bucket test-bucket \
    --key compatibility/interrupted.bin \
    >/dev/null 2>&1; then
    echo "An interrupted PUT became visible after recovery." >&2
    exit 1
  fi
  echo "Process-interruption recovery passed: ${crash_recovery_mib} MiB PUT killed after staging began"
fi

if (( streaming_object_mib > 0 )); then
  streaming_bytes=$((streaming_object_mib * 1048576))
  if (( streaming_bytes > maximum_object_bytes )); then
    echo "The streaming object exceeds maximumObjectBytes." >&2
    exit 2
  fi
  streaming_input="$work_directory/streaming-input.bin"
  streaming_output="$work_directory/streaming-output.bin"
  rss_stop="$work_directory/stop-streaming-rss"
  rss_result="$work_directory/streaming-maximum-rss-kib.txt"
  dd if=/dev/zero of="$streaming_input" bs=1 count=0 seek="$streaming_bytes" 2>/dev/null
  if (( require_larger_than_physical_memory == 1 )); then
    physical_memory_bytes=$(sysctl -n hw.memsize)
    if (( streaming_bytes <= physical_memory_bytes )); then
      echo "The streaming object is not larger than physical memory." >&2
      exit 2
    fi
  fi
  (
    maximum_rss_kib=0
    while [[ ! -e "$rss_stop" ]] && kill -0 "$gateway_pid" 2>/dev/null; do
      current_rss_kib=$(ps -o rss= -p "$gateway_pid" | tr -d ' ')
      if [[ "$current_rss_kib" =~ ^[0-9]+$ ]] &&
         (( current_rss_kib > maximum_rss_kib )); then
        maximum_rss_kib=$current_rss_kib
      fi
      sleep 0.05
    done
    echo "$maximum_rss_kib" >"$rss_result"
  ) &
  rss_sampler_pid=$!
  aws "${aws_arguments[@]}" s3api put-object \
    --bucket test-bucket \
    --key compatibility/streaming-large.bin \
    --body "$streaming_input" \
    >/dev/null
  if (( streaming_discard_download == 1 )); then
    aws "${aws_arguments[@]}" s3api get-object \
      --bucket test-bucket \
      --key compatibility/streaming-large.bin \
      /dev/null \
      >/dev/null
  else
    aws "${aws_arguments[@]}" s3api get-object \
      --bucket test-bucket \
      --key compatibility/streaming-large.bin \
      "$streaming_output" \
      >/dev/null
    cmp "$streaming_input" "$streaming_output"
  fi
  touch "$rss_stop"
  wait "$rss_sampler_pid"
  maximum_rss_kib=$(sed -n '1p' "$rss_result")
  [[ "$maximum_rss_kib" =~ ^[1-9][0-9]*$ ]]
  if (( maximum_rss_kib * 1024 >= streaming_bytes )); then
    echo "Gateway peak RSS was not smaller than the streamed object." >&2
    exit 1
  fi
  if [[ -n ${STAGE1_STREAMING_RESULT_FILE:-} ]]; then
    cp "$rss_result" "$STAGE1_STREAMING_RESULT_FILE"
  fi
  if (( require_larger_than_physical_memory == 1 )); then
    echo "Large-object streaming passed: ${streaming_object_mib} MiB object exceeded ${physical_memory_bytes} bytes physical memory, ${maximum_rss_kib} KiB peak gateway RSS"
  else
    echo "Large-object streaming passed: ${streaming_object_mib} MiB object, ${maximum_rss_kib} KiB peak gateway RSS"
  fi
fi

presigned_url=$(aws "${aws_arguments[@]}" s3 presign \
  s3://test-bucket/compatibility/object.bin \
  --expires-in 60)
curl --silent --fail --cacert "$certificate" "$presigned_url" \
  --output "$work_directory/presigned.bin"
cmp "$input_file" "$work_directory/presigned.bin"

aws "${aws_arguments[@]}" s3api delete-object \
  --bucket test-bucket \
  --key compatibility/object.bin \
  >/dev/null
if aws "${aws_arguments[@]}" s3api head-object \
  --bucket test-bucket \
  --key compatibility/object.bin \
  >/dev/null 2>&1; then
  echo "Deleted object remained visible." >&2
  exit 1
fi

echo "AWS CLI Stage 1 compatibility passed: $(aws --version 2>&1)"
