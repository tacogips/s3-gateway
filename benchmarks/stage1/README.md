# Stage 1 S3 Benchmark Harness

This harness records comparable client-visible timings without treating unlike
storage models as equivalent. Run it separately against:

- `swift-s3-gateway` `sharedLocalDirectory` on a local filesystem;
- VersityGW's direct POSIX backend on the same filesystem and object tree;
- S3Proxy `filesystem-nio2` on the same filesystem and an isolated tree;
- SeaweedFS S3 backed by a filer, labeled as filer-backed rather than direct
  POSIX storage.

Before every published run, copy `run-metadata.example.json` to the result
directory and record exact versions, commit IDs or image digests, hardware,
filesystem, TLS mode, storage model, object sizes, and concurrency. Do not place
credentials in metadata or command output.

The target bucket must already exist. Credentials are inherited by the AWS CLI:

```bash
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
S3_ENDPOINT=https://127.0.0.1:8443 S3_BUCKET=benchmark \
TARGET_LABEL=swift-s3-gateway-shared \
scripts/benchmark-s3-stage1.sh benchmarks/results/swift-shared
```

The script requires `aws` and `hyperfine`. It creates deterministic 4 KiB and
64 MiB files, verifies PUT/GET once, then records warm sequential GET, PUT, HEAD,
and LIST timings plus concurrent large-object GET and PUT timings as Hyperfine
JSON. `BENCHMARK_RUNS`, `BENCHMARK_WARMUP`, and `BENCHMARK_CONCURRENCY` control
the run count, warmup count, and parallel client count. Use an isolated bucket
because benchmark objects are overwritten repeatedly. Run cold-cache tests
separately with an OS-appropriate, documented cache procedure; never mix them
into warm results.

Set `TARGET_PID` to the benchmarked gateway process ID to sample its resident
memory during the run. The peak is written in KiB to `maximum-rss-kib.txt`.
Omit it for remote targets or when the server process is not directly observable.

For an end-to-end bounded-memory gate against this gateway, the AWS CLI fixture
can transfer an object larger than the gateway's measured process footprint:

```bash
MAXIMUM_OBJECT_BYTES=629145600 \
REQUEST_TIMEOUT_SECONDS=120 \
STAGE1_STREAMING_OBJECT_MIB=512 \
nix shell nixpkgs#awscli2 nixpkgs#jq --command \
  scripts/test-aws-cli-stage1.sh
```

The gate samples only the gateway PID during the upload and download, verifies
the downloaded bytes, and fails unless the peak gateway RSS is smaller than the
object. `STAGE1_STREAMING_RESULT_FILE` optionally retains the peak RSS value.

For the literal object-larger-than-host-memory gate, use a size greater than
`sysctl -n hw.memsize`, enable
`STAGE1_REQUIRE_OBJECT_LARGER_THAN_PHYSICAL_MEMORY=1`, and set
`STAGE1_STREAMING_DISCARD_DOWNLOAD=1`. The input is sparse, the signed PUT still
reads and validates every byte, and the GET must transfer the complete response
to `/dev/null`; this avoids retaining an unnecessary third full-size copy. The
explicit memory assertion fails before the transfer if the selected object is
not larger than physical memory.

Set `STAGE1_CRASH_RECOVERY_MIB` with a matching `MAXIMUM_OBJECT_BYTES` to run the
process-interruption gate. It starts a signed PUT of a sparse input, waits until
the gateway has written staged bytes, sends SIGKILL, restarts the gateway with
the same storage roots, and verifies that neither the abandoned staging file nor
the incomplete object remains visible.

For a private test CA, set `AWS_CA_BUNDLE` to its PEM file. The script writes
`environment.txt` with the client and benchmark-tool versions plus the supplied
target label; retain it beside the manually completed JSON metadata. Do not set
`AWS_CA_BUNDLE` to an insecure or hostname-bypassing client mode for published
TLS comparisons.

AWS CLI 2.35 enables optional streaming/trailer request checksums by default.
Stage 1 deliberately does not claim that payload mode. Set
`AWS_REQUEST_CHECKSUM_CALCULATION=when_required` and
`AWS_RESPONSE_CHECKSUM_VALIDATION=when_required` when benchmarking this gateway
so the client uses the supported single-chunk SigV4 payload contract. Record
those settings with every result.

Behavior after external create, replace, rename, and delete is a correctness
matrix, not a throughput number. For direct-directory targets, perform those
operations through the native filesystem and record visibility, ETag changes,
and stale-metadata behavior. SeaweedFS is excluded from that direct-directory
matrix because its filer namespace has a different storage contract.
