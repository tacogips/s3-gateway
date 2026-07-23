# S3 Gateway MVP

**Status**: In Progress
**Design Reference**: `design-docs/specs/s3-gateway-design.md#staged-rollout`
**Architecture Reference**: `design-docs/specs/architecture.md`
**Issue Reference**: None

## Purpose

Implement the accepted bounded S3-compatible gateway design while preserving the
existing `AppCore`, `AppCLI`, and `AppCoreTests` SwiftPM targets. The gateway will
authenticate and authorize inbound S3 requests, translate them into explicit
`Sendable` domain operations, and stream object bodies to one startup-selected
`POSIXBackend` or `S3Backend` without whole-object buffering.

Stage 1 is the MVP. Native TLS is required for its production release. Multipart
routes remain staged work and must not be represented as Stage 1 compatibility
until their capability, recovery, and interoperability suites pass.

## Design Decisions and Preconditions

- `design-docs/specs/s3-gateway-design.md` is the source of truth for names,
  boundaries, security invariants, and rollout stages.
- The existing SwiftPM target layout remains unchanged. Directories listed below
  are source organization inside current targets, not new targets.
- Public protocols and DTOs are `Sendable`; closed sets use stable raw-value
  enums; generic dictionaries do not cross architectural boundaries.
- HTTP/SigV4/routing types do not cross `ObjectStoreBackend`.
- Inbound verification credentials, upstream signing credentials, and
  pagination-token keys remain separate and never enter logs or domain DTOs.
- The five implementation-gating decisions under `design-docs/user-qa/` were
  answered on 2026-07-23: SwiftNIO with native TLS, permission-restricted file
  credentials, versioned sidecars, and local-only shared-directory
  reconciliation.

## Deliverables

- [x] Typed configuration and startup validation for one selected backend.
- [x] `Sendable` domain DTOs, stable enums, `ObjectBodyStream`, backend errors,
  `ObjectStoreBackend`, and immutable capability reporting.
- [x] Bounded HTTP transport adapter, S3 addressing and routing, SigV4
  verification, default-deny authorization, pagination-token protection, and
  controlled S3 response/error encoding.
- [x] Stage 1 object operations through both `POSIXBackend` and `S3Backend` with
  streaming, cancellation, backpressure, conditions, one range, metadata, ETags,
  checksums, and pagination.
- [x] CLI composition, lifecycle management, sanitized telemetry, readiness, and
  graceful shutdown.
- [x] Adversarial unit, contract, integration, interoperability, filesystem,
  credential-confinement, and bounded-memory verification.
- [x] Stage 2 multipart implementation kept capability-gated until its contract
  and recovery criteria pass.

## Dependency Summary

- TASK-001 is the decision gate for dependency, credential, TLS, and POSIX
  representation choices.
- TASK-002 and TASK-003 establish configuration and domain contracts.
- TASK-004 through TASK-009 build disjoint protocol, security, error, transport,
  and application layers on those contracts.
- TASK-010 and TASK-011 implement the two backends in parallel after the domain
  contract is stable.
- TASK-012 composes the layers; TASK-013 proves Stage 1 end to end; TASK-014
  performs security and resilience gates; TASK-015 adds staged multipart support;
  TASK-016 closes documentation and release-readiness evidence.

## Tasks

### TASK-001: Resolve implementation-gating user decisions

**Dependencies**: None

**Parallelizable**: No

**Likely Files/Targets**:

- `design-docs/user-qa/pending-http-server-library.md`
- `design-docs/user-qa/pending-tls-termination.md`
- `design-docs/user-qa/pending-credential-providers.md`
- `design-docs/user-qa/pending-posix-metadata-storage.md`
- `design-docs/user-qa/pending-posix-out-of-band-mutation.md`
- `design-docs/specs/s3-gateway-design.md`

**Work**:

- Record explicit user decisions using the repository's answered-question
  convention shown in `design-docs/user-qa/qa-example.md`: set `## Status` to
  answered and add an `## Answer` section recording the decision and its date.
- Reconcile any selected option with the accepted design without weakening its
  security or streaming invariants.
- If no decision is available, retain the question as pending and mark dependent
  implementation completion blocked rather than silently finalizing the
  provisional assumption.

**Completion Criteria**:

- [x] Every implementation-gating choice has a recorded decision or an explicit
  blocker with owner and impact.
- [x] Design links and terminology remain consistent.
- [x] No production source is changed by this task.

**Verification**:

- `rg -n "^## (Question|Status|Context|Options|Provisional Planning Assumption|Answer)$" design-docs/user-qa/*.md`
- `git diff --check`

### TASK-002: Establish package dependencies and typed configuration

**Dependencies**: TASK-001, which selected SwiftNIO with native TLS and separate
permission-restricted credential files.

**Parallelizable**: Yes; after TASK-001, write scope is limited to `Package.swift`,
`Configuration/`, and corresponding tests and does not overlap TASK-003

**Likely Files/Targets**:

- `Package.swift`
- `Sources/AppCore/Configuration/`
- `Tests/AppCoreTests/Configuration/`

**Work**:

- Add only the selected transport/crypto dependencies, pinned according to
  project policy, without introducing new SwiftPM targets.
- Define immutable `GatewayConfiguration`, backend-specific configuration,
  addressing, limits, authorization grants, provider references, TLS, retry, and
  telemetry settings with documented CLI/environment/file precedence.
- Validate mutually exclusive backend configuration, loopback-only plaintext
  development mode, native-TLS certificate/key references, trusted proxies,
  absolute POSIX roots, POSIX layout policy and filesystem type, same-filesystem
  sidecar placement, bounded limits, and secret-reference fields before listener
  binding.

**Completion Criteria**:

- [x] Valid POSIX and upstream S3 configurations decode into typed `Sendable`
  values.
- [x] Invalid or ambiguous settings fail with field-scoped, redacted diagnostics.
- [x] Configuration precedence and startup validation are deterministic.

**Verification**:

- `swift test --filter ConfigurationTests`
- `swift build`

### TASK-003: Define domain contracts, streaming, and capabilities

**Dependencies**: None

**Parallelizable**: Yes; write scope is limited to `Domain/`, `Backends/Contracts/`,
and corresponding contract tests and does not overlap TASK-002

**Likely Files/Targets**:

- `Sources/AppCore/Domain/`
- `Sources/AppCore/Backends/Contracts/`
- `Tests/AppCoreTests/Domain/`
- `Tests/AppCoreTests/Backends/BackendContractTests.swift`

**Work**:

- Add the stable enums and explicit value types named in the design, including
  `BackendKind`, `AddressingStyle`, `GatewayOperation`, `BackendCapability`,
  `ChecksumAlgorithm`, `GatewayErrorCode`, bucket/key, range, conditions,
  metadata, request context, and operation-specific request/result DTOs.
- Define the single-consumer `ObjectBodyStream` ownership and backpressure
  contract without exposing transport buffer types or whole objects as `Data`.
- Define `ObjectStoreBackend`, `BackendCapabilities`, and `BackendError` with one
  typed async method per `GatewayOperation` and immutable startup capabilities.
- Create reusable backend contract fixtures before either backend implementation.

**Completion Criteria**:

- [x] Public contracts compile under Swift 6 strict concurrency and are
  `Sendable` by construction.
- [x] Stable enum raw values and DTO validation have regression tests.
- [x] Streaming tests prove bounded buffering, single consumption, cancellation,
  and error propagation.
- [x] Backend contracts contain no HTTP, SigV4, or library-specific buffer types.

**Verification**:

- `swift test --filter DomainTests`
- `swift test --filter ObjectBodyStreamTests`
- `swift test --filter BackendContractTests`

### TASK-004: Implement controlled error mapping and S3 response encoding

**Dependencies**: TASK-003

**Parallelizable**: Yes; write scope is limited to `S3Protocol/Responses/`,
`Errors/`, and matching tests

**Likely Files/Targets**:

- `Sources/AppCore/Errors/`
- `Sources/AppCore/S3Protocol/Responses/`
- `Tests/AppCoreTests/Errors/`
- `Tests/AppCoreTests/S3Protocol/S3ResponseEncoderTests.swift`

**Work**:

- Define transport, `BackendError`, and `GatewayError` boundaries and the
  allowlisted mapping to S3 status, code, bounded message, request ID, headers,
  and XML.
- Encode success and failure responses without relaying raw upstream XML, local
  paths, endpoints, stack traces, or credential material.
- Add bounded XML and header encoding plus retry-hint rules.

**Completion Criteria**:

- [x] Every Stage 1 domain/backend failure maps deterministically to a tested S3
  response.
- [x] Error output passes secret/path redaction and XML/header-injection tests.
- [x] Unsupported routes and capabilities produce the design-specified errors.

**Verification**:

- `swift test --filter GatewayErrorMappingTests`
- `swift test --filter S3ResponseEncoderTests`

### TASK-005: Build the bounded HTTP transport adapter

**Dependencies**: TASK-001, TASK-002, TASK-003

**Parallelizable**: Yes; write scope is limited to `Transport/` and transport tests

**Likely Files/Targets**:

- `Sources/AppCore/Transport/`
- `Tests/AppCoreTests/Transport/`

**Work**:

- Adapt SwiftNIO behind `HTTPTransport` while preserving raw
  method, target, query, headers, and host for SigV4.
- Enforce connection, header, XML, deadline, chunk, object-size, concurrency, and
  in-flight-byte limits.
- Bridge request and response bodies to `ObjectBodyStream` with demand-driven
  backpressure and prompt bidirectional cancellation.
- Implement native TLS with SwiftNIO SSL, certificate/private-key references,
  controlled rotation, and trusted-proxy handling without leaking transport types
  into domain or backend contracts.

**Completion Criteria**:

- [x] Raw signed request components survive transport adaptation byte-for-byte.
- [x] Slow-producer, slow-consumer, disconnect, timeout, malformed framing, and
  over-limit tests fail safely with bounded memory.
- [x] Transport cancellation stops downstream work.
- [x] Production mode cannot bind without a valid native-TLS configuration;
  handshake, protocol-version, certificate, key, and rotation tests pass.

**Verification**:

- `swift test --filter HTTPTransportTests`
- `swift test --filter TransportBackpressureTests`

### TASK-006: Implement addressing, operation routing, and request validation

**Dependencies**: TASK-003

**Parallelizable**: Yes; write scope is limited to `S3Protocol/Addressing/`,
`S3Protocol/Routing/`, and their tests

**Likely Files/Targets**:

- `Sources/AppCore/S3Protocol/Addressing/`
- `Sources/AppCore/S3Protocol/Routing/`
- `Tests/AppCoreTests/S3Protocol/AddressingTests.swift`
- `Tests/AppCoreTests/S3Protocol/OperationRouterTests.swift`

**Work**:

- Resolve configured path-style and trusted-suffix virtual-host-style requests
  without rewriting the raw signed target.
- Decode logical keys exactly once and keep duplicate slashes, dot segments, and
  encoded separators as key data.
- Route only the Stage 1 method/subresource/query matrix, parse bounded metadata,
  ranges, conditions, checksums, and list parameters into explicit DTOs, and
  reject ambiguous or duplicate security-sensitive fields.

**Completion Criteria**:

- [x] Addressing and routing fixtures cover valid, ambiguous, malformed, and
  unsupported requests.
- [x] Path normalization cannot alter the signed representation or logical key.
- [x] Unsupported operations are rejected before unbounded body consumption.

**Verification**:

- `swift test --filter AddressingTests`
- `swift test --filter OperationRouterTests`

### TASK-007: Implement credential confinement and SigV4 verification

**Dependencies**: TASK-001, TASK-002, TASK-003, TASK-005

**Parallelizable**: Yes; write scope is limited to `Security/Credentials/`,
`Security/SigV4/`, and matching tests

**Likely Files/Targets**:

- `Sources/AppCore/Security/Credentials/`
- `Sources/AppCore/Security/SigV4/`
- `Tests/AppCoreTests/Security/CredentialProviderTests.swift`
- `Tests/AppCoreTests/Security/SigV4VerifierTests.swift`

**Work**:

- Implement the decided bounded credential provider with separate namespaces for
  inbound, upstream, and pagination use.
- Verify header and presigned SigV4 algorithm, scope, canonical request, signed
  headers, timestamps, expiry, payload policy, and signatures using constant-time
  comparison.
- Keep secret material provider-owned and return only principal identity and
  verification outcome to later layers.
- Verify streamed write payload hashes before publication; define and test the
  staging/finalization handoff used by each backend.

**Completion Criteria**:

- [x] Published vectors and adversarial canonicalization cases pass.
- [x] Unknown, duplicate, disabled, expired, or malformed credentials fail
  without provider-state disclosure.
- [x] Secret-scanning assertions find no credential, Authorization, security
  token, or presigned-query data in DTOs, logs, errors, or traces.
- [x] Failed payload verification cannot publish a reachable object.

**Verification**:

- `swift test --filter CredentialProviderTests`
- `swift test --filter SigV4VerifierTests`
- `swift test --filter CredentialConfinementTests`

### TASK-008: Implement default-deny authorization and protected pagination

**Dependencies**: TASK-002, TASK-003

**Parallelizable**: Yes; write scope is limited to `Security/Authorization/`,
`Security/Pagination/`, and matching tests, disjoint from TASK-007

**Likely Files/Targets**:

- `Sources/AppCore/Security/Authorization/`
- `Sources/AppCore/Security/Pagination/`
- `Tests/AppCoreTests/Security/AuthorizationPolicyTests.swift`
- `Tests/AppCoreTests/Security/PaginationTokenTests.swift`

**Work**:

- Evaluate immutable operation, exact-bucket, and logical key-prefix grants with
  missing/empty policy denying all storage access.
- Enforce the design's `ListObjectsV2` scope rules without silently broadening or
  filtering unauthorized requests.
- Encode bounded, opaque, authenticated, versioned pagination state bound to
  principal, backend, operation, bucket, grant prefix, requested prefix,
  delimiter, ordering, issue/expiry time, and key identifier.
- Re-authenticate and re-authorize continuation requests before token acceptance.

**Completion Criteria**:

- [x] Denials reveal no target existence and cause no backend call.
- [x] Prefix boundary, Unicode, whole-bucket, revocation, rotation, expiry,
  tampering, restart, and context-mismatch tests pass.
- [x] Out-of-scope backend list results fail closed and do not advance a token.

**Verification**:

- `swift test --filter AuthorizationPolicyTests`
- `swift test --filter PaginationTokenTests`

### TASK-009: Implement GatewayService orchestration and capability admission

**Dependencies**: TASK-003, TASK-004, TASK-006, TASK-008

**Parallelizable**: No

**Likely Files/Targets**:

- `Sources/AppCore/Gateway/`
- `Tests/AppCoreTests/Gateway/`

**Work**:

- Compose authenticated, authorized, typed operations into `GatewayService`
  calls without coupling the service to transport types.
- Compute immutable `EffectiveGatewayCapabilities` at startup, fail missing
  baseline capabilities before listener binding, and reject unsupported optional
  semantics before unbounded body consumption.
- Enforce deadlines, cancellation, object and metadata limits, range/condition
  semantics, and streamed checksum finalization around backend calls.
- Produce a bounded diagnostic capability report without exposing secrets,
  internal paths, or upstream endpoint details.

**Completion Criteria**:

- [x] Every Stage 1 operation follows authenticate, route, authorize, admit,
  invoke, and encode ordering.
- [x] Mandatory capability mismatch fails startup; optional mismatch returns the
  designed request error.
- [x] Cancellation and condition failures cannot leave published partial writes.

**Verification**:

- `swift test --filter GatewayServiceTests`
- `swift test --filter CapabilityAdmissionTests`

### TASK-010: Implement POSIXBackend confinement and atomic persistence

**Dependencies**: TASK-001, TASK-002, TASK-003

**Parallelizable**: Yes; write scope is limited to `Backends/POSIX/` and POSIX
tests, disjoint from TASK-011

**Likely Files/Targets**:

- `Sources/AppCore/Backends/POSIX/`
- `Tests/AppCoreTests/Backends/POSIX/`

**Work**:

- Implement both POSIX policies beneath approved, opened roots: collision-free
  reversible key encoding for `managedPrivateLayout`, and exact safe native-path
  mapping for `sharedLocalDirectory`.
- Use directory-relative descriptor operations, no-follow semantics, and
  containment checks that resist symlink swaps, hard links, special files, and
  traversal through logical key data.
- Stream writes to unreachable temporary generations, compute ETags/checksums,
  atomically join decided metadata representation with data, rename, and fsync
  according to durability mode.
- Add per-key coordination, stable ordered pagination, atomic condition checks,
  startup recovery, bounded cleanup, quotas, and permission handling.
- For `sharedLocalDirectory`, positively reject unsupported non-local mounts,
  reconcile external create/replace/modify/rename/delete on access and listing,
  invalidate stale sidecars, detect mid-operation changes, and report reduced
  consistency and conditional capabilities.

**Completion Criteria**:

- [ ] The shared backend contract suite passes for Stage 1 capabilities.
- [ ] Objects larger than available memory stream without whole-object buffering.
  Current retained evidence transfers 512 MiB with 18,800 KiB peak gateway RSS;
  macOS rejected lowering `RLIMIT_AS`, so the stricter larger-than-available-memory
  formulation is not yet directly exercised.
- [x] Traversal, symlink race, hard-link, Unicode collision, special-file,
  permission, disk-full, crash-point, recovery, and external-mutation tests pass.
- [x] Readers never observe partial data or metadata generations.
- [x] Pre-existing regular files are visible in shared mode, safe external
  mutations are reconciled, stale metadata is never attached to replacement
  bytes, and unsupported filesystems or key/path forms fail explicitly.

**Verification**:

- `swift test --filter POSIXBackendTests`
- `swift test --filter POSIXSecurityTests`
- `swift test --filter POSIXRecoveryTests`

### TASK-011: Implement S3Backend re-signing and streamed forwarding

**Dependencies**: TASK-001, TASK-002, TASK-003, TASK-007

**Parallelizable**: Yes; write scope is limited to `Backends/S3/` and upstream S3
tests, disjoint from TASK-010

**Likely Files/Targets**:

- `Sources/AppCore/Backends/S3/`
- `Tests/AppCoreTests/Backends/S3/`

**Work**:

- Map domain operations to new bounded upstream requests using configured
  endpoint, region, addressing, bucket mapping, TLS, and dedicated upstream
  credentials; strip all inbound authentication material.
- Stream bodies through bounded buffers with cancellation and backpressure.
- Preserve or verify upstream metadata, ETags, checksums, conditions, ranges, and
  continuation state without relaying arbitrary headers, XML, or tokens.
- Enforce TLS validation, redirect policy, connection/in-flight limits, typed
  error parsing, deadline-budgeted retry classification, and replay safety.
- Ensure the streamed-write strategy honors inbound payload validation before
  publication without whole-object buffering.

**Completion Criteria**:

- [ ] The shared backend contract suite passes against a controlled S3-compatible
  service.
- [x] Tests prove inbound credentials cannot select or reach upstream signing,
  endpoint, region, bucket mapping, or TLS fields.
- [x] TLS, redirect, throttle, retry, truncation, cancellation, slow-peer,
  malformed XML, and upstream error-mapping tests pass.
- [x] Unsafe writes are never retried and failed validation publishes no object.

**Verification**:

- `swift test --filter S3BackendTests`
- `swift test --filter S3BackendSigningTests`
- `swift test --filter S3BackendBackpressureTests`

### TASK-012: Compose CLI startup, lifecycle, telemetry, and health

**Dependencies**: TASK-002, TASK-004, TASK-005, TASK-007, TASK-008, TASK-009,
TASK-010, TASK-011

**Parallelizable**: No

**Likely Files/Targets**:

- `Sources/AppCLI/main.swift`
- `Sources/AppCore/Telemetry/`
- `Sources/AppCore/Server/`
- `Tests/AppCoreTests/Server/`
- `Tests/AppCoreTests/Telemetry/`
- `design-docs/specs/command.md`

**Work**:

- Load configuration, instantiate exactly one backend, obtain immutable
  capabilities, run credential/root/upstream readiness probes, and bind only
  after mandatory validation succeeds.
- Add request IDs, allowlisted structured telemetry, bounded-cardinality metrics,
  liveness/readiness, signal handling, graceful drain, deadline enforcement, and
  cleanup.
- Ensure telemetry excludes raw buckets, keys, principals, endpoints, paths,
  headers, queries, bodies, credential identifiers, and secrets.
- Document the public CLI surface (gateway entry point, flags, configuration
  precedence, exit codes) in `design-docs/specs/command.md`.

**Completion Criteria**:

- [x] Valid POSIX and S3 configurations start the selected backend only.
- [x] Invalid configuration or mandatory capability failure occurs before bind.
- [x] Graceful shutdown cancels or drains work within its configured deadline.
- [x] Telemetry redaction and bounded-cardinality tests pass.
- [x] `design-docs/specs/command.md` matches the implemented CLI surface.

**Verification**:

- `swift test --filter ServerLifecycleTests`
- `swift test --filter TelemetryTests`
- `swift run swift-s3-gateway --help`

### TASK-013: Prove Stage 1 compatibility end to end

**Dependencies**: TASK-012

**Parallelizable**: No

**Likely Files/Targets**:

- `Tests/AppCoreTests/Integration/`
- `Tests/AppCoreTests/Compatibility/`
- `Tests/AppCoreTests/Fixtures/`
- `design-docs/specs/s3-gateway-design.md`

**Work**:

- Run the same black-box suite against POSIX and controlled upstream S3
  configurations for path and virtual-host addressing, header and presigned
  SigV4, CRUD, head, list pagination, one range, conditions, metadata, ETags,
  checksums, and unsupported routes.
- Exercise representative S3 clients and record any bounded, intentional
  compatibility divergence in the design before accepting it.
- Benchmark the POSIX backend against recorded current versions of VersityGW,
  S3Proxy, and SeaweedFS using the scope in
  `design-docs/references/posix-s3-gateway-oss-comparison.md`.
- Prove memory bounds with objects larger than available process memory and slow
  peers; prove cancellation and checksum mismatch leave no partial publication.

**Completion Criteria**:

- [ ] Both backends pass the mandatory Stage 1 compatibility matrix.
- [x] Unsupported features fail with controlled S3 errors rather than silent
  downgrade.
- [x] Load evidence demonstrates configured memory, connection, and in-flight
  byte bounds.
- [x] Any discovered client divergence is documented and tested.
- [ ] Reproducible benchmark commands, versions, storage models, and results are
  recorded without combining unlike consistency guarantees.

**Verification**:

- `swift test --filter S3CompatibilityTests`
- `swift test --filter GatewayIntegrationTests`
- `swift test --filter StreamingLoadTests`

### TASK-014: Complete adversarial security and resilience gates

**Dependencies**: TASK-013

**Parallelizable**: No

**Likely Files/Targets**:

- `Tests/AppCoreTests/Security/`
- `Tests/AppCoreTests/FaultInjection/`
- `Tests/AppCoreTests/Backends/POSIX/`
- `Tests/AppCoreTests/Backends/S3/`

**Work**:

- Combine adversarial SigV4, credential confinement, authorization, pagination,
  framing, streaming, filesystem, upstream TLS/retry, and secret-redaction cases
  into a release gate.
- Add deterministic fault injection at body, commit, fsync, metadata, cancellation,
  upstream response, retry, and shutdown boundaries.
- Verify readiness and recovery behavior after interrupted or ambiguous state.

**Completion Criteria**:

- [ ] No high or mid security, data-integrity, credential, traversal, or
  unbounded-memory finding remains open.
- [ ] Every injected failure has a typed, bounded outcome and leaves either a
  committed object or recoverable/quarantined state, never silent corruption.
- [x] Logs, metrics, traces, errors, and test artifacts contain no secret values.

**Verification**:

- `swift test --filter SecurityRegressionTests`
- `swift test --filter FaultInjectionTests`
- `swift test --filter SecretRedactionTests`

### TASK-015: Implement capability-gated Stage 2 multipart operations

**Dependencies**: TASK-014

**Parallelizable**: No; POSIX and S3 multipart state must first share finalized
domain and gateway contracts, after which backend-specific subtasks may be split
only by disjoint backend directories

**Design Sections**:

- `design-docs/specs/s3-gateway-design.md#multipart-uploads`
- `design-docs/specs/s3-gateway-design.md#stage-2-multipart-and-native-tls`

**Likely Files/Targets**:

- `Sources/AppCore/Domain/Multipart/`
- `Sources/AppCore/Gateway/Multipart/`
- `Sources/AppCore/S3Protocol/Routing/`
- `Sources/AppCore/S3Protocol/Responses/`
- `Sources/AppCore/Backends/POSIX/Multipart/`
- `Sources/AppCore/Backends/S3/Multipart/`
- `Tests/AppCoreTests/Multipart/`
- `Tests/AppCoreTests/S3Protocol/MultipartRoutingTests.swift`
- `Tests/AppCoreTests/S3Protocol/MultipartResponseEncoderTests.swift`
- `Tests/AppCoreTests/Integration/MultipartGatewayIntegrationTests.swift`

**Work**:

- Implement create, upload-part, complete, and abort using opaque gateway upload
  IDs bound to principal, backend, bucket, key, initiation time, and configuration
  generation.
- Extend inbound routing for the multipart method and subresource matrix,
  including `uploads`, `uploadId`, and `partNumber`; reject duplicate, ambiguous,
  malformed, unauthorized, or capability-disabled requests before consuming an
  unbounded body.
- Parse `CompleteMultipartUpload` XML with the configured XML-byte and part-count
  bounds, validate its ordered part manifest into explicit DTOs, and encode
  controlled create, upload-part, complete, and abort responses without relaying
  backend-specific XML, headers, or upload tokens.
- Enforce part ordering, uniqueness, sizes, quotas, checksums, expiry, abort
  idempotence, cancellation, and no publication before validated completion.
- Add POSIX isolated part state, atomic assembly, recovery, and garbage collection;
  map S3 state to upstream upload IDs without exposing unsigned upstream tokens.
- Keep routes disabled until both backends pass the same contract and recovery
  suites and report `multipartUpload` capability.
- Run black-box multipart HTTP flows through path-style and virtual-host-style
  addressing against both backends, including SigV4, authorization, capability
  denial, malformed completion manifests, cancellation, and controlled errors.

**Completion Criteria**:

- [ ] Multipart routes remain `NotImplemented` when the stage or capability is
  disabled.
- [ ] Enabled multipart routes admit only the designed method/subresource matrix,
  parse completion manifests within configured bounds, and emit controlled S3
  responses.
- [ ] Both backends pass shared ordering, limit, abort, expiration, duplicate
  completion, cancellation, crash recovery, and no-partial-publication tests.
- [ ] Multipart assembly never requires whole-object buffering.
- [ ] Black-box create, upload-part, complete, and abort flows pass against both
  backends without exposing internal or upstream upload identifiers.

**Verification**:

- `swift test --filter MultipartContractTests`
- `swift test --filter MultipartRecoveryTests`
- `swift test --filter MultipartCompatibilityTests`
- `swift test --filter MultipartRoutingTests`
- `swift test --filter MultipartResponseEncoderTests`
- `swift test --filter MultipartGatewayIntegrationTests`

### TASK-016: Close implementation documentation and release evidence

**Dependencies**: TASK-014 for Stage 1 closure; TASK-015 only if Stage 2 is being
declared complete

**Parallelizable**: No

**Likely Files/Targets**:

- `design-docs/specs/s3-gateway-design.md`
- `design-docs/specs/architecture.md`
- `design-docs/specs/command.md`
- `design-docs/user-qa/`
- `impl-plans/active/s3-gateway-mvp.md`
- `impl-plans/completed/s3-gateway-mvp.md`

**Work**:

- Reconcile implemented behavior, intentional compatibility limits, capability
  matrix, configuration, and decided questions with the design.
- Record final verification evidence and unresolved follow-up scope without
  claiming full S3 compatibility.
- Check every task and progress-log entry; move the plan to `completed/` only when
  all Stage 1 completion criteria are satisfied. Keep Stage 2 follow-up explicitly
  open if multipart was not selected for the same release.

**Completion Criteria**:

- [ ] Design, architecture, code names, tests, and capability claims agree.
- [ ] No unresolved implementation blocker is hidden in a pending question or
  unchecked task.
- [x] Stage 1 verification commands pass and their results are recorded.
- [x] Plan status and location accurately reflect completed versus remaining work.

**Verification**:

- `task lint`
- `task test`
- `swift build`
- `git diff --check`
- `git status --short`

## Parallel Execution Map

Parallel execution is allowed only after dependencies are satisfied and only for
the disjoint write scopes named in each task:

- TASK-003 may start immediately. After TASK-001 is resolved, TASK-002 may run
  alongside any unfinished TASK-003 work because they own
  `Configuration/`/`Package.swift` and domain/backend-contract paths respectively.
- TASK-004, TASK-005, TASK-006, TASK-007, and TASK-008 may run concurrently after
  their prerequisites because they own separate response/error, transport,
  routing, SigV4/credential, and authorization/pagination paths.
- TASK-010 and TASK-011 may run concurrently because they own separate backend
  directories and tests.
- Integration, cross-cutting security, composition, documentation, and plan
  closure tasks are not parallelizable.
- If an implementation discovers a necessary shared-contract edit, pause the
  parallel tasks, land the contract change first, rerun affected contract tests,
  and then resume; do not make competing edits to shared files.

## Global Verification

Run the narrow task-level tests while implementing, then run the full gate at each
stage boundary:

```bash
swift build
swift test
task lint
task test
swift run swift-s3-gateway --help
git diff --check
git status --short
```

For Stage 1 release readiness, retain test evidence for both backend selections,
representative S3 clients, bounded-memory streaming, cancellation, crash recovery,
credential confinement, authorization, pagination tampering, filesystem escape,
upstream TLS/retry behavior, and secret redaction.

## Overall Completion Criteria

- [ ] Stage 1 operations work through both backends and match the accepted
  compatibility matrix.
- [x] The existing `AppCore`, `AppCLI`, and `AppCoreTests` targets are preserved.
- [x] All public protocols and DTOs satisfy Swift 6 concurrency requirements.
- [x] No request path buffers a whole object; backpressure and cancellation are
  verified under load.
- [x] Authentication, default-deny authorization, credential separation,
  pagination protection, POSIX containment, atomic publication, TLS, retry, and
  redaction invariants have adversarial coverage.
- [x] Backend capability reporting controls startup and route admission without
  silent semantic downgrade.
- [x] Pending user decisions are resolved or explicitly block the affected
  completion claim.
- [x] Documentation and plan status match the implemented rollout stage.
- [x] `swift build`, `swift test`, `task lint`, `task test`, `git diff --check`, and
  scope review pass before handoff.

## Risks

- SigV4 canonicalization and presigned behavior are compatibility-sensitive;
  published vectors alone are insufficient without adversarial raw-target tests.
- Several AWS SDKs default to `aws-chunked` streaming upload signatures that
  Stage 1 does not accept; interoperability tests must pin and document working
  client configurations or default-configured clients will fail uploads.
- `Package.swift` declares macOS 14 only, and POSIX durability differs across
  platforms (`F_FULLFSYNC` on macOS versus `fsync`/`fdatasync` elsewhere);
  untested platform assumptions can silently weaken the durability mode.
- Credential providers can accidentally collapse trust domains; type and provider
  boundaries plus negative tests must enforce separation.
- POSIX containment is race-sensitive; string path checks or resolve-then-open
  flows are unacceptable.
- Shared-directory outside writers can invalidate sidecars and bypass gateway
  condition coordination; identity/generation validation, bounded retries, and
  reduced capability reporting must prevent false atomicity claims.
- Upstream retries can duplicate writes or force buffering unless replay safety is
  explicit.
- Pagination tokens can leak or broaden authorization scope unless every page is
  re-authenticated, re-authorized, and context-bound.
- Transport adapters can hide buffering or normalize signed targets; integration
  tests must measure both.
- Scope may drift toward full S3 compatibility; stage and capability gates must
  remain explicit.

## Progress Log

- 2026-07-21: Plan created from the accepted S3 gateway design. No production
  Swift code was changed. Step 3 reported no high or mid findings.
- 2026-07-21: Self-review reconciled TASK-002's parallelizable field with the
  disjoint-scope parallel execution map; no design revision was required.
- 2026-07-21: Step 5 review feedback added anchored design traceability and
  expanded TASK-015 with inbound multipart routing, bounded completion-manifest
  parsing, response encoding, capability admission, and black-box HTTP tests for
  both backends.
- 2026-07-21: Documentation review pass. Aligned TASK-001 with the
  answered-question convention (`## Answer`, per `design-docs/user-qa/qa-example.md`),
  removed planning-workflow metadata, let TASK-002 proceed on recorded
  provisional assumptions while decisions stay blocked, added CLI-surface
  documentation duties to TASK-012 and TASK-016, and added client
  `aws-chunked` default and platform-durability risks. Matching design updates:
  supported-platforms section with `F_FULLFSYNC` note, Stage 1 payload-signature
  client-compatibility note, `Content-MD5`/`BadDigest` handling, health-endpoint
  configuration, and status promoted to accepted-for-planning.
- 2026-07-23: Completed TASK-001 documentation. Recorded user selections of
  SwiftNIO, Stage 1 native TLS, permission-restricted file credential providers,
  versioned sidecars, and local-filesystem-only shared-directory reconciliation.
  Updated POSIX capability and containment requirements and added VersityGW,
  S3Proxy, and SeaweedFS comparison and benchmark scope. No production Swift code
  changed.
- 2026-07-23: Implemented the Stage 1 Swift surface across TASK-002 through
  TASK-012: typed JSON configuration, separate descriptor-safe credential files,
  domain/backend contracts, bounded SwiftNIO HTTP/1.1 and native TLS, header and
  presigned SigV4, default-deny authorization, encrypted scoped pagination,
  capability admission, POSIX managed/shared layouts, upstream S3 re-signing and
  replay-safe staged retries, CLI lifecycle, request deadlines, health routes,
  and sanitized startup failures. POSIX staging now remains outside the exposed
  directory and uses same-filesystem descriptor-relative atomic publication;
  shared mode reconciles external regular-file changes and rejects symlinks,
  hard links, special files, nested mounts, and unsafe key forms.
- 2026-07-23: Added runnable POSIX configuration and benchmark harnesses based on
  the recorded VersityGW, S3Proxy, and SeaweedFS storage models. Direct Xcode and
  `nix develop` verification passed with 52 tests, SwiftLint with zero findings,
  Nix flake evaluation/build, CLI help, shell syntax, `git diff --check`, and
  scoped Gitleaks scans. The initial bare-shell and Nix-shell Swift checks exposed
  an inherited macOS 11.3 SDK; the Darwin shell now selects the installed Xcode
  SDK. The initial whole-worktree Gitleaks scan included `.build` dependencies;
  scoped source/document/test scans pass after removing credential-like examples.
- 2026-07-23: Release evidence remains intentionally open for TASK-013 and
  TASK-014: representative external S3 clients, controlled real upstream S3,
  multi-process fault injection, larger-than-memory load, and comparative OSS
  benchmark results require provisioned services and the `aws`/`hyperfine` tools,
  which are not present in this workspace. Stage 2 multipart remains disabled and
  returns a controlled unsupported-operation response as designed.
- 2026-07-23: Completed the remaining TASK-012 operational surface and extended
  TASK-011 TLS evidence. Added backend-aware startup and HTTP readiness probes,
  opt-in allowlisted JSON request telemetry, upstream private-CA configuration
  with full hostname verification, and a positive native-TLS upstream transport
  integration test plus wrong-host rejection. Updated the CLI/design/README and
  OSS benchmark harness documentation; the harness now records tool and operating
  system versions. `task lint`, `task test`, and `task build` pass in the Nix
  development shell with 59 tests and zero lint findings. External benchmark and
  client evidence remains open because `aws` and `hyperfine` are unavailable.
- 2026-07-23: Resolved the preceding tool/client blocker with reproducible Nix
  invocations using AWS CLI 2.35.11 and Hyperfine 1.20.0. The native-TLS
  black-box gate passed signed PUT, HEAD, complete and ranged GET,
  `ListObjectsV2` with `encoding-type=url`, presigned GET, DELETE, and absence
  checks against `sharedLocalDirectory`. The documented AWS CLI checksum settings
  select Stage 1's supported single-chunk payload mode; the default
  streaming/trailer mode remains explicitly outside Stage 1.
- 2026-07-23: Hardened TASK-005, TASK-008, TASK-010, TASK-011, TASK-013, and
  TASK-014 coverage. Added demand-driven inbound, outbound, POSIX, and upstream
  streaming; transport drain and request-deadline cancellation; bounded POSIX
  list selection with byte-ordered Unicode/delimiter pagination; descriptor-safe
  readiness; strict backend result validation; malicious list and metadata
  injection failures; malformed upstream LIST rejection; controlled native-TLS
  S3 integration; and cancellation cleanup for both backends. The upstream
  connection and response now consume one absolute deadline rather than separate
  timeout budgets.
- 2026-07-23: Extended the benchmark harness with configurable run, warmup, and
  concurrency counts plus optional target RSS sampling. A local smoke run passed
  sequential and two-client concurrent 64 MiB PUT/GET, HEAD, LIST, and RSS
  capture (23,408 KiB peak); it is not treated as a publishable comparison.
  `task lint`, `task test`, and `task build` pass in `nix develop` with 74 tests
  and zero lint findings. `nix flake check --no-build`, shell syntax,
  `git diff --check`, file-size policy, and scoped Gitleaks scans also pass.
  Publishable VersityGW, S3Proxy, and SeaweedFS comparisons, larger-than-memory
  load evidence, multi-process crash/fault injection, and Stage 2 multipart
  remain open; Docker has no running daemon and the Podman machine is not
  running in this workspace.
- 2026-07-23: Closed additional TASK-010 and TASK-014 implementation gaps.
  POSIX PUT now writes an identity-bound versioned commit record before
  publication; startup deterministically completes published/staged generations,
  rolls back a vanished stage, preserves exact user metadata, and fails closed
  instead of overwriting an externally replaced destination. Ambiguous publish
  errors resolve the record idempotently, including the rename-succeeded/fsync-
  failed window. Metadata reads reject symlinks with `O_NOFOLLOW`, regular-file,
  link-count, size, and device checks. LIST traversal now uses descriptor-relative
  `readdir`, `fstatat`, and `openat`, rejects cross-device and unsafe entries
  before descent, and validates directory identity before and after recursion.
- 2026-07-23: Hardened TASK-011 and TASK-013 upstream behavior. S3 retries now
  share the absolute request deadline through backoff, and duplicate or missing
  critical upstream metadata headers fail as consistency errors. Added a signed
  application-level virtual-host request covering addressing, SigV4,
  authorization, and backend routing. The combined AWS CLI gate killed a signed
  1 GiB PUT after staging began, restarted the process, proved no partial
  publication, then completed a byte-verified 512 MiB TLS PUT/GET with 18,800 KiB
  peak gateway RSS. The stricter literal larger-than-available-memory exercise
  remains open because macOS rejected lowering `RLIMIT_AS`.
- 2026-07-23: Final local source gates after these changes pass: `task lint`,
  `task test`, and `task build` in `nix develop` with 83 tests and zero lint
  findings. Focused recovery, deadline, virtual-host, controlled upstream TLS,
  AWS CLI, process-interruption, and bounded-RSS gates pass. Comparative
  VersityGW, S3Proxy, and SeaweedFS result sets remain external release evidence,
  not an unimplemented gateway code path.
- 2026-07-23: Closed the remaining local Stage 1 hardening gaps across TASK-002
  through TASK-014. Added POSIX permission, capacity, atomic-replacement and
  generation-consistency faults; adversarial SigV4 and credential-field bounds;
  pagination restart/rotation/expiry/retirement coverage; authorization
  non-disclosure; exact raw-target and malformed-framing transport tests;
  bounded upstream XML, redirect, throttling, deadline and staging failures;
  exhaustive backend-error mapping and escaped S3 error encoding; typed upstream
  S3 example configuration; authorization boundary/Unicode/whole-bucket/restart
  revocation checks; TLS 1.2 minimum, invalid key material, and controlled-restart
  certificate rotation; and rejection of cross-operation query fields and
  multipart subresources without silent downgrade. Strict SwiftLint reports zero
  findings, all 104 tests pass, and `task build` succeeds in `nix develop`.
- 2026-07-23: Repeated the native-TLS AWS CLI 2.35.11 black-box gate after the
  routing changes. A signed 1 GiB PUT killed after staging began recovered
  without partial publication; a byte-verified 512 MiB PUT/GET used 18,608 KiB
  peak gateway RSS. `nix flake check --no-build`, shell syntax, `git diff
  --check`, the under-1000-line Swift policy, and scoped Gitleaks scans of all
  repository-owned artifacts pass. A whole-worktree Gitleaks attempt also
  traversed `.build` and reported third-party SwiftPM cryptographic test vectors;
  those generated dependencies are outside the scoped source gate. Remaining
  release evidence is explicit: the literal larger-than-available-memory
  formulation, a single identical black-box matrix against both backend
  selections, and publishable VersityGW/S3Proxy/SeaweedFS comparison runs.

For every implementation update, append a dated entry containing completed task
IDs, files or targets changed, verification commands and outcomes, decisions or
intentional divergences, newly discovered risks, and blockers. Do not mark a task
complete without its completion criteria and verification evidence. Do not delete
failed attempts from the log; summarize the resolution so later reviewers can
audit the path to completion.
