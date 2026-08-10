# swift-s3-gateway

A bounded, SigV4-authenticated S3 gateway written in Swift. It can expose an
approved local directory tree as S3 objects or forward requests to another S3
service with a separate upstream credential.

## Run the gateway

The production listener requires native TLS. Plain HTTP is accepted only when
`developmentPlaintext` is true and the listener is bound to loopback.

```bash
swift run swift-s3-gateway serve --config config-examples/gateway-posix-shared.json
```

The example uses absolute deployment paths that must be adjusted before use.
Create the sidecar directory with mode `0700` and on the same local filesystem as
the exposed root.
Use `config-examples/gateway-s3.json` as the corresponding typed starting point
for a separately credentialed upstream S3 deployment; its staging directory must
also be local, private, and adjusted before use.
Create three separate JSON files with mode `0600`: one for inbound client keys,
one for an upstream signing key, and one for pagination-token keys. Their schemas
are:

```text
{"version":1,"records":[{"accessKeyID":"CLIENTKEY","secretAccessKey":<at-least-16-byte-secret>,"principalID":"local-client","enabled":true}]}
{"version":1,"active":{"accessKeyID":"UPSTREAMKEY","secretAccessKey":<at-least-16-byte-secret>,"sessionToken":null}}
{"version":1,"activeKeyID":"page-1","keys":[{"keyID":"page-1","secretBase64":<exactly-32-random-bytes-as-base64>,"enabled":true}]}
```

The upstream file remains required by the current provider set even when the
selected backend is POSIX; its key is never used for POSIX requests. Authorization
is default-deny and is configured independently from inbound authentication.

Stage 1 supports signed PUT, GET, HEAD, DELETE, and ListObjectsV2, one byte range,
conditional requests, user metadata, SHA-256/CRC32C where supported, Content-MD5,
and opaque pagination. Multipart and SigV4 streaming-chunk uploads remain outside
the Stage 1 compatibility claim.

AWS CLI v2 can exercise the Stage 1 surface by disabling its optional
streaming/trailer checksum mode:

```bash
AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
aws --endpoint-url https://gateway.example.test s3api put-object \
  --bucket local-files --key example.bin --body example.bin
```

The reproducible local compatibility gate generates isolated credentials and a
private test CA, starts the native-TLS gateway, and runs CRUD, range, LIST, and
presigned-URL checks:

```bash
mise run test:aws-cli
```

For an upstream S3 backend, HTTPS certificate verification is always enabled.
Set `backend.s3.trustedCAPath` to an absolute PEM bundle path when the upstream
uses a private CA; omitting it uses the platform trust roots. Hostname
verification remains enabled in both cases.

Configured health routes are exact-match, unauthenticated control-plane routes
that return only fixed state. Readiness uses separate capacity from authenticated
object requests, has a single in-flight probe limit, and inherits the inbound
request deadline and cancellation.
Liveness reports that the process is running. Readiness verifies access to the
configured POSIX roots or performs a signed `HEAD` probe against a mapped
upstream bucket. Optional telemetry emits one JSON line per request to standard
error with only request ID, coarse method, backend kind, status, and duration.
It never includes bucket names, object keys, principals, endpoints, headers,
queries, bodies, or credential identifiers.

## Development

```bash
mise install
mise run build
mise run test
swift run swift-s3-gateway --help
```

The package uses Swift Package Manager with:

- Library target: `AppCore`
- Executable target: `AppCLI`
- Installed executable: `swift-s3-gateway`

Swift target names and type names must be valid Swift identifiers. If the project
name contains hyphens, keep `PROJECT_NAME` and `EXECUTABLE_NAME` hyphenated as
needed, but use identifier-safe values such as `AppCore`, `AppCLI`, and
`AppCommand` for Swift module/type variables.

## Homebrew Formula

Build local formula archives:

```bash
mise run build:homebrew -- darwin-arm64 darwin-x64
```

Render a formula after both platform archives exist:

```bash
mise run homebrew:formula -- 0.1.0
```

Render directly into the default sibling tap checkout:

```bash
mise run homebrew:tap-formula -- 0.1.0
```

Install from the tap after the formula is published:

```bash
brew tap user/tap
brew install swift-s3-gateway
```

## Homebrew Cask

The Cask workflow builds signed, notarized, and stapled macOS DMG artifacts.
Apple signing credentials must stay local and must not be committed.

Check the build plan:

```bash
mise run build:homebrew-cask -- --dry-run darwin-arm64 darwin-x64
```

Build with local signing credentials:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  mise run build:homebrew-cask -- darwin-arm64 darwin-x64
```

Render a Cask:

```bash
mise run homebrew:cask -- 0.1.0
```

For a tagged release, build, upload, and render the tap Cask:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  mise run release:homebrew-cask-local -- v0.1.0
```

See `packaging/homebrew/README.md` and `.agents/skills/` for release workflows.
