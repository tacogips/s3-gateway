# Command

## Status

Implemented for Stage 1

## Current CLI

```text
swift-s3-gateway --help
swift-s3-gateway --version
swift-s3-gateway serve --config <configuration.json>
swift-s3-gateway serve <configuration.json>
```

`serve` loads one JSON configuration, validates credentials and the selected
backend, constructs the server, and only then binds the listener. SIGINT and
SIGTERM initiate graceful transport shutdown. Configuration layering through
environment variables or individual CLI overrides is intentionally unsupported;
the named JSON document is the single non-secret configuration source.

The process exits nonzero for an invalid command, unreadable or invalid
configuration, insecure credential files, TLS setup failure, backend startup
failure, or listener failure. Diagnostics identify the failing category without
printing credential values.

When configured, readiness probes the selected backend before listener binding
and on every readiness request. POSIX probes validate the opened local root,
sidecar, and mapped bucket directories. S3 probes send a newly signed `HEAD`
request for a configured upstream bucket. `backend.s3.trustedCAPath` may name an
absolute private-CA PEM bundle; upstream hostname verification is never disabled.
Opt-in telemetry is emitted as redacted, bounded-cardinality JSON lines on
standard error.
