# S3 Gateway Stage 2 Multipart

**Status**: Planned
**Design Reference**: `design-docs/specs/s3-gateway-design.md#stage-2-multipart`
**Predecessor**: `impl-plans/completed/s3-gateway-mvp.md`

## Purpose

Enable multipart create, upload-part, complete, and abort only after both
backends pass the same capability, recovery, bounded-memory, and interoperability
suites. Until every completion criterion in this plan passes, the routes remain
disabled and the gateway does not advertise `multipartUpload`.

## Dependencies

- The Stage 1 MVP plan is complete.
- POSIX and S3 multipart state share finalized domain and gateway contracts
  before backend-specific implementation work diverges.

## Deliverables

- Opaque gateway upload IDs bound to principal, backend, bucket, key, initiation
  time, and configuration generation.
- Bounded multipart routing and `CompleteMultipartUpload` XML parsing.
- Controlled S3 responses that do not expose backend tokens or XML.
- POSIX isolated part state, atomic assembly, recovery, expiration, and garbage
  collection.
- S3 upstream multipart translation with private upstream upload IDs.
- Shared backend contracts and black-box compatibility suites.

## Work

1. Add explicit multipart DTOs and capability-gated route admission for
   `uploads`, `uploadId`, and `partNumber`. Reject duplicate, ambiguous,
   malformed, unauthorized, expired, or disabled requests before consuming an
   unbounded body.
2. Parse `CompleteMultipartUpload` within configured XML-byte and part-count
   limits. Validate ordering, uniqueness, part sizes, quotas, checksums, and
   expiry into typed DTOs.
3. Encode controlled create, upload-part, complete, and abort responses without
   relaying backend-specific XML, headers, or upload identifiers.
4. Implement POSIX part staging, atomic assembly, abort idempotence, recovery,
   expiration, and garbage collection with no partial publication.
5. Map S3 multipart state to upstream upload IDs without exposing unsigned
   upstream tokens. Bound retries and preserve replayable part bodies.
6. Run path-style and virtual-host-style black-box flows against both backends,
   including SigV4, authorization, capability denial, malformed completion,
   cancellation, crash recovery, and controlled errors.

## Completion Criteria

- [ ] Enabled routes admit only the designed method/subresource matrix, parse
  completion manifests within configured bounds, and emit controlled responses.
- [ ] Both backends pass shared ordering, limit, abort, expiration, duplicate
  completion, cancellation, crash recovery, and no-partial-publication tests.
- [ ] Multipart assembly never requires whole-object buffering.
- [ ] Upload IDs are scoped, authenticated, opaque, expiring, and never reveal
  internal paths or upstream identifiers.
- [ ] Black-box create, upload-part, complete, and abort flows pass through both
  addressing styles and both backends.
- [ ] Only after all preceding criteria pass do both backends advertise
  `multipartUpload` and the routes become enabled.

## Verification

```bash
swift test --filter MultipartContractTests
swift test --filter MultipartRecoveryTests
swift test --filter MultipartCompatibilityTests
swift test --filter MultipartRoutingTests
swift test --filter MultipartResponseEncoderTests
swift test --filter MultipartGatewayIntegrationTests
mise run lint
mise run test
```
