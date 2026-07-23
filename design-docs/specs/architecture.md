# Architecture

## Status

Stage 1 implemented; release evidence in progress

## Overview

`swift-s3-gateway` is a Swift Package Manager project that will expose a bounded
S3-compatible HTTP service and route object operations to a configured storage
backend. The detailed protocol, security, backend, and rollout design is defined
in [S3 Gateway Design](s3-gateway-design.md).

The gateway is not intended to reproduce the entire S3 API in its first release.
The supported operation and semantic matrix is versioned and advertised by the
service, while unsupported operations fail explicitly with S3-compatible errors.

## Architectural Boundaries

The server is divided into these logical layers:

1. The inbound transport preserves the raw request target and provides bounded,
   backpressured request and response streams.
2. S3 addressing, SigV4 authentication, default-deny authorization, operation
   routing, and request validation interpret the inbound protocol without
   depending on storage implementation.
3. The application service invokes the `ObjectStoreBackend` contract using
   explicit `Sendable` request and result DTOs.
4. Exactly one configured backend, `POSIXBackend` or `S3Backend`, performs storage
   operations and reports its capabilities.
5. The response layer maps domain results and errors to controlled S3 HTTP
   responses and attaches a gateway request ID.

Inbound credentials and authorization headers never cross the backend boundary.
An authenticated principal reaches a backend operation only when a configured
policy allows its operation, bucket, and key prefix. `S3Backend` signs a new
upstream request with separately configured credentials. Object bodies remain
streaming across all boundaries; whole-object buffering is not permitted.

## SwiftPM Targets

The MVP preserves the existing target layout:

- `AppCore`: configuration models, S3 protocol semantics, authentication,
  application services, backend contracts and implementations, and reusable
  server composition.
- `AppCLI`: command-line parsing, configuration loading, dependency wiring,
  startup, signal handling, and process exit behavior.
- `AppCoreTests`: unit, contract, integration, security, and fault-injection tests.

These are responsibility boundaries within the existing targets, not a proposal
for new SwiftPM modules. A later split requires measured build or ownership
pressure and a separate design decision.

## Release Surfaces

- Homebrew formula archives under `dist/homebrew/`
- Signed and notarized Cask DMGs under `dist/homebrew-cask/`

Release mechanics are outside the S3 gateway MVP design and are unchanged.
