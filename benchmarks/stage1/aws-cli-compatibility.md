# AWS CLI Stage 1 Compatibility

## Verified environment

- Date: 2026-07-23
- Client: AWS CLI 2.35.11, Python 3.14.6, Darwin arm64
- Gateway transport: SwiftNIO HTTP/1.1 with native TLS
- Trust: generated private CA with hostname verification for `localhost`
- Backend: POSIX `sharedLocalDirectory` on the local test filesystem
- Addressing: path style

## Reproduction

```bash
nix develop -c swift build
nix shell nixpkgs#awscli2 nixpkgs#jq --command \
  scripts/test-aws-cli-stage1.sh
```

The gate passed:

- signed `PutObject` with content type and user metadata;
- `HeadObject`;
- complete and ranged `GetObject`;
- `ListObjectsV2` with the client's standard `encoding-type=url`;
- presigned `GetObject`;
- `DeleteObject` and post-delete absence.

The same fixture also passed a one-run benchmark harness smoke check with two
parallel clients. It exercised sequential and concurrent 64 MiB PUT/GET, HEAD,
LIST, and target-process RSS sampling; the observed peak was 23,408 KiB. This is
test-harness evidence only, not a statistically meaningful or comparative
performance result.

## Bounded-memory and interruption gates

The final Stage 1 binary passed the combined stress invocation:

```bash
MAXIMUM_OBJECT_BYTES=2147483648 \
REQUEST_TIMEOUT_SECONDS=120 \
STAGE1_CRASH_RECOVERY_MIB=1024 \
STAGE1_STREAMING_OBJECT_MIB=512 \
nix shell nixpkgs#awscli2 nixpkgs#jq --command \
  scripts/test-aws-cli-stage1.sh
```

- A signed 1 GiB PUT was killed with SIGKILL after staged bytes appeared.
  Restart removed the abandoned stage and the incomplete key remained absent.
- A complete 512 MiB PUT/GET round trip matched byte-for-byte.
- Peak RSS sampled from the gateway PID during that transfer was 18,800 KiB,
  well below the object size.

The script uses:

```text
AWS_REQUEST_CHECKSUM_CALCULATION=when_required
AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
```

AWS CLI 2.35.11's default request-checksum behavior selects a streaming/trailer
payload mode for `PutObject`. The gateway intentionally rejects that mode because
SigV4 streaming-chunk uploads are outside Stage 1. Running the gate with
`AWS_CLI_DEFAULT_CHECKSUMS=1` therefore fails PUT authentication as expected.
This is a recorded compatibility boundary, not a claim of default-mode support.
