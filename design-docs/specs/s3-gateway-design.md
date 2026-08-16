# S3 Gateway Design

## Status

Accepted for implementation planning. The implementation-gating user decisions
were answered on 2026-07-23 and are recorded in `design-docs/user-qa/`.

## Purpose

Turn `s3-gateway` into a server-side Swift service that accepts a defined
subset of the S3 HTTP API and stores objects through one backend selected at
startup: a local POSIX filesystem (`POSIXBackend`) or an upstream S3-compatible
service (`S3Backend`). This document defines protocol behavior and architectural
contracts; it does not claim full S3 compatibility.

## Goals

- Keep inbound S3 HTTP, addressing, SigV4 authentication, routing, and response
  mapping independent from storage implementation.
- Define an `ObjectStoreBackend` contract that is safe under Swift 6 concurrency
  and supports streaming bodies with bounded memory and backpressure.
- Provide equivalent gateway behavior where backend capabilities permit, and
  reject unsupported behavior before consuming an unbounded body.
- Support both path-style and virtual-host-style addressing under explicit host
  configuration.
- Design for object CRUD, `HeadObject`, `ListObjectsV2`, single-range reads,
  conditional requests, pagination, user metadata, checksums, and multipart
  upload, with a realistic staged rollout.
- Protect credentials, filesystem roots, upstream connections, and service
  capacity through explicit security invariants and validation.
- Make compatibility and operational limits observable and testable.

## Non-Goals

- Full parity with every AWS S3 API, XML shape, ACL, policy, versioning,
  replication, notification, object-lock, website, or lifecycle feature.
- Dynamic backend selection per request or mixing POSIX and upstream objects in
  one gateway instance.
- A transparent HTTP proxy. `S3Backend` translates domain operations and creates
  newly signed upstream requests.
- Managing public certificate issuance or cloud load balancers.
- Promising full S3 consistency or the complete S3 key space while independent
  local processes concurrently mutate a shared POSIX directory.
- Changing the current `AppCore`, `AppCLI`, and `AppCoreTests` SwiftPM target
  layout. Adding dependencies to the existing targets is permitted.

## Supported Platforms

The MVP builds and is verified on macOS 14 or newer, matching `Package.swift`
and the Homebrew release surfaces. POSIX durability semantics are platform
specific: on macOS the strict durability mode must use `F_FULLFSYNC`, because
`fsync` alone does not guarantee persistence there. Contracts must avoid
macOS-only APIs so that Linux support remains possible, but Linux builds,
filesystem semantics, and CI verification are a separate follow-up decision and
are not a Stage 1 claim.

## Compatibility and Rollout Contract

Compatibility is an explicit operation-and-semantics matrix, not a general
promise of S3 equivalence. At startup, configuration and backend capabilities
produce an immutable `EffectiveGatewayCapabilities` value. The same value drives
route admission, a diagnostic capability report, and compatibility tests.

Each compatibility stage declares a mandatory baseline capability set and the
optional request semantics it may admit. Startup fails before binding a listener
when the selected backend lacks a mandatory capability for the configured stage.
An operation outside that stage returns an S3 `NotImplemented` response. A request
within the stage that selects an optional semantic not present in
`EffectiveGatewayCapabilities` returns `InvalidRequest` before consuming an
unbounded body, with a sanitized explanation and a capability-mismatch metric.
The gateway must not silently downgrade checksum, conditional, durability, or
range semantics.

## Architecture

### Logical Components

- `HTTPTransport`: owns listeners, connection limits, timeouts, cancellation, and
  backpressured byte streams. It preserves raw method, path, query, headers, and
  host information needed for SigV4.
- `S3AddressingResolver`: resolves configured path-style or virtual-host-style
  addressing into bucket, key, and operation candidates without rewriting the raw
  signed request target.
- `SigV4Verifier`: parses credential scope, canonicalizes the preserved request,
  validates signature and timestamp, and returns an authenticated principal.
- `AuthorizationPolicy`: applies a default-deny operation, bucket, and key-prefix
  policy to the authenticated principal before any backend call.
- `S3OperationRouter`: converts authenticated HTTP requests into explicit domain
  DTOs and rejects unsupported or malformed requests.
- `GatewayService`: enforces limits, conditionals, capability requirements, and
  cancellation before invoking `ObjectStoreBackend`.
- `ObjectStoreBackend`: storage-independent asynchronous contract.
- `POSIXBackend`: confines object data and metadata to a configured filesystem
  root and implements atomic local persistence.
- `S3Backend`: maps domain calls to an upstream S3-compatible endpoint and signs
  each request with upstream credentials.
- `S3ResponseEncoder`: serializes results and `GatewayError` values into bounded
  S3-compatible headers, XML bodies, and status codes.
- `Telemetry`: propagates request identifiers and records sanitized metrics,
  traces, and logs across layers.

These are type and responsibility names within `AppCore`, not separate SwiftPM
targets. `AppCLI` only loads configuration and composes the process.

### Dependency Rule

Protocol and application layers may depend on backend DTOs and the
`ObjectStoreBackend` protocol. Backends may depend on domain DTOs but must not
depend on inbound HTTP request types, SigV4 credentials, or response encoders.
Transport-specific buffers are adapted at the boundary to an `ObjectBodyStream`
abstraction so that the domain contract does not lock the project to an HTTP
library.

### Request Data Flow

1. `HTTPTransport` assigns a request ID, applies header and connection limits,
   and preserves the raw request target.
2. `S3AddressingResolver` resolves bucket and key using the configured addressing
   modes and trusted host suffixes.
3. `SigV4Verifier` authenticates against the raw signed representation and a
   credential provider. Authentication completes before a storage mutation.
4. `S3OperationRouter` identifies and validates the requested operation, bucket,
   key, subresources, headers, and bounded XML shape.
5. `AuthorizationPolicy` allows the operation only when the authenticated
   principal has a matching operation, bucket, and key-prefix grant. Denial is
   terminal and does not reveal whether the target exists.
6. `S3OperationRouter` validates the configured compatibility stage and builds a
   typed request DTO.
7. `GatewayService` checks body limits and required backend capabilities and
   invokes `ObjectStoreBackend` with cancellation and deadline context.
8. The backend consumes or produces bounded chunks. Backpressure propagates to
   the client; cancellation stops filesystem or upstream work promptly.
9. `S3ResponseEncoder` maps the result or typed error to an S3 response. Telemetry
   records only sanitized identifiers and dimensions.

### Health-Probe Isolation and Request Lifetime

Configured liveness and readiness routes are unauthenticated control-plane
traffic, not object operations. Server composition creates one immutable
health-route classifier from the validated `HealthEndpointConfiguration` and
shares that value with the transport and `S3GatewayApplication`; neither boundary
implements an independent path predicate. The classifier returns `liveness`,
`readiness`, or `none` and selects health traffic only for an exact configured raw
path, an empty raw query, and method `GET` or `HEAD`. Missing health
configuration, differing methods, nonempty queries, and every near match classify
as `none` and continue through the shared limiter and normal authentication.

The transport is authoritative for admission selection: one classifier invocation
both selects the shared-limiter path and records its result as the health admission
class carried by `HTTPTransportRequest`. The request also carries the absolute
deadline created when the transport accepts the request head. Before any health,
authentication, or storage work, `S3GatewayApplication` recomputes the class with
the shared classifier. A mismatch is an internal invariant failure and returns a
bounded, detail-free `500` response; it never falls through to authenticated work
after the transport has bypassed the shared limiter. Tests and non-network callers
construct requests through the same classifier rather than setting a trusted
health class independently.

Validated health traffic does not acquire the shared authenticated-request
limiter. `S3GatewayApplication` owns a dedicated, fail-fast readiness gate with
capacity one; the transport does not own or release this permit. The application
acquires the permit immediately before `GatewayService.readinessCheck` and uses
task-lifetime cleanup equivalent to `defer` to release it exactly once on success,
failure, deadline expiry, or cancellation. This keeps at most one backend
readiness probe in flight and reserves all authenticated-request capacity for
object operations. A readiness request rejected by that gate returns the same
fixed `503 {"status":"not-ready"}` representation as any other readiness failure.
Liveness performs no backend work and retains its fixed response.

The request deadline starts when the transport accepts the request head. The same
absolute deadline governs the transport timeout and is passed from
`S3GatewayApplication` through `GatewayService` to
`ObjectStoreBackend.readinessCheck`. `S3Backend` attaches it to the signed
upstream `HEAD` request, applies it to every retry and backoff, and does not start
an attempt after expiry. POSIX and test backends may complete synchronously, but
must reject an already-expired readiness deadline.

The transport owns exactly one application task for each accepted request and
stores its cancellation handle for the lifetime of the channel request.
Channel inactivity, transport timeout, handler removal, transport shutdown, and
response-write failure cancel that task. Transport mise run cleanup releases only a
shared-limiter permit it acquired; cancellation then unwinds the application
task, whose readiness-gate cleanup releases the separate permit. Both owners use
idempotent task-lifetime cleanup so cancellation before application entry or
while awaiting upstream work cannot leak or double-release capacity.
Cancellation must propagate through `GatewayService` and the S3 upstream client
so that the connection or exchange is closed promptly; a disconnected client
must not leave retry sleeps or signed upstream requests running.

Admission and cancellation are validated at their owning boundaries:

- A blocking readiness probe followed by client disconnect must observe
  cancellation and release the readiness permit before another probe is admitted.
- Readiness saturation must leave an authenticated object request eligible for
  the shared limiter; readiness traffic alone cannot cause that request to
  receive a limiter-generated `503`.
- Classifier tests must cover disabled health routes, exact liveness and readiness
  matches, `GET` and `HEAD`, nonempty queries, alternate methods, and path near
  matches. A near match must acquire the shared limiter and follow
  authentication; a carried-class mismatch must return the controlled invariant
  failure without invoking health, authentication, or backend work; only an exact
  health classification may bypass the shared limiter.
- Timeout and disconnect tests must wait on explicit synchronization signals,
  not timing-only sleeps, and must assert permit release as well as task
  cancellation.
- Health overload, expiry, and backend failure preserve the existing fixed
  readiness body, headers, and `GET`/`HEAD` behavior without exposing upstream
  details.

This change is internal and adds no configuration surface. The dedicated
readiness capacity remains fixed at one for Stage 1. Rollout requires the focused
transport, integration, and S3 backend tests to pass before the complete security
scan is rerun, including network-enabled dependency auditing.

## Domain Model

All public protocols and DTOs are `Sendable`. Mutable shared state is isolated in
actors or other synchronization primitives with documented ownership. Closed sets
are `String`-backed enums with stable raw values so logs, configuration, stored
metadata, and fixtures do not depend on Swift case spelling. Public contracts use
explicit types rather than `[String: Any]` or stringly typed dictionaries.

### Stable Types

- `BackendKind`: `posix`, `s3`.
- `AddressingStyle`: `path`, `virtualHost`.
- `GatewayOperation`: `getObject`, `headObject`, `putObject`, `deleteObject`,
  `listObjectsV2`, `createMultipartUpload`, `uploadPart`,
  `completeMultipartUpload`, `abortMultipartUpload`.
- `BackendCapability`: `rangeRead`, `conditionalRead`, `conditionalWrite`,
  `listPagination`, `userMetadata`, `multipartUpload`, `strongReadAfterWrite`,
  `checksumSHA256`, `checksumCRC32C`.
- `ChecksumAlgorithm`: `sha256`, `crc32c` for the initial contract. Algorithms
  can be added without changing existing raw values.
- `GatewayErrorCode`: stable domain cases mapped to S3 error codes.

### Value Objects and DTOs

- `BucketName` and `ObjectKey` retain the exact logical S3 identifiers after one
  well-defined percent-decoding pass. They validate syntax without filesystem
  normalization.
- `ObjectVersionToken` represents an opaque backend revision used for atomic
  conditional operations; it is not exposed as an S3 VersionId.
- `EntityTag` is an opaque quoted S3 entity tag. Clients must not assume it is an
  MD5 digest, especially for upstream or multipart objects.
- `ObjectMetadata` contains content type, content length, last-modified instant,
  entity tag, explicit user-metadata entries, and typed checksum entries. Header
  names are normalized at the protocol boundary and values are bounded.
- `ByteRange`, `ReadConditions`, and `WriteConditions` model range and HTTP
  precondition semantics explicitly.
- `RequestContext` carries request ID, authenticated principal ID, deadline, and
  cancellation; it never carries secret key material or the inbound Authorization
  header.
- `PrincipalAuthorization` contains immutable, bounded grants expressed as typed
  operation sets, exact bucket names, and optional logical key prefixes. An empty
  or missing grant set denies all storage operations. For `ListObjectsV2`, a grant
  without a key prefix authorizes the whole bucket; otherwise the request prefix
  must equal or descend from one granted prefix.
- Operation-specific request and result DTOs include `GetObjectRequest`,
  `GetObjectResult`, `PutObjectRequest`, `PutObjectResult`, `HeadObjectRequest`,
  `DeleteObjectRequest`, `ListObjectsV2Request`, and `ListObjectsV2Result`. Stage
  2 adds multipart equivalents. No generic operation dictionary crosses a
  boundary.

`ObjectBodyStream` is a single-consumer, asynchronous, throwing byte sequence whose
elements have a configured maximum chunk size. It is `Sendable` through a safe
ownership wrapper. Producers must wait for consumer demand and observe cancellation.
Known content length is carried separately when available. Neither gateway nor
backend APIs expose a whole object as `Data`.

### Backend Contract

`ObjectStoreBackend: Sendable` exposes immutable identity and capability reporting
plus asynchronous methods corresponding exactly to `GatewayOperation` cases:

- `capabilities()` returns `BackendCapabilities`, including the capability set,
  maximum supported part count, checksum algorithms, and consistency guarantees.
- `getObject`, `headObject`, `putObject`, `deleteObject`, and `listObjectsV2` cover
  the MVP object surface.
- `createMultipartUpload`, `uploadPart`, `completeMultipartUpload`, and
  `abortMultipartUpload` remain reserved stable operation identifiers. Stage 2
  adds their DTOs and backend methods before making them routable.

Every method accepts a `RequestContext` and one explicit request DTO. Streaming
results include metadata before their body stream. Failures use `BackendError`,
which preserves retryability and semantic cause but contains no HTTP status or S3
XML. The application layer is the sole owner of S3 error mapping.

Backend capability reporting is descriptive, not aspirational. It is immutable
after startup; a capability change requires reconfiguration and restart. Stage
baseline validation occurs during startup and is fatal when any mandatory
capability is absent. Request-time capability rejection is reserved for optional
semantics that the stage permits but does not require from every backend.

## Configuration

Configuration is loaded once into an immutable, typed `GatewayConfiguration`.
Stage 1 uses one explicitly named JSON file and has no environment or per-field
CLI overrides. Secrets are referenced through three separate restricted files,
not embedded in the gateway configuration.

### Common Configuration

- Listener address and port, request deadline, maximum concurrent requests,
  header bytes, XML bytes, object bytes, chunk bytes, and in-flight buffer bytes.
- Addressing styles and accepted SigV4 regions.
- Optional liveness and readiness paths. These are the only unauthenticated
  routes, serve health state only, and expose no storage data, configuration
  values, or capability details.
- Virtual-host suffixes. Stage 1 rejects nonempty trusted-proxy configuration and
  ignores forwarded host and scheme fields.
- Inbound credential-provider reference, accepted SigV4 regions and services,
  maximum clock skew, and presigned URL lifetime. The provider maps an access-key
  identifier to verification material, principal identity, and no implicit grant.
- Default-deny principal authorization grants. Each grant names allowed
  `GatewayOperation` values, exact buckets, and optional logical key prefixes;
  wildcards require explicit syntax and validation.
- Pagination-token signing-key provider, active key identifier, accepted previous
  key identifiers, and maximum token lifetime. Token keys are distinct from S3
  credentials and follow the same redaction rules.
- Native TLS listener certificate and private-key paths. Production Stage 1
  requires native TLS; controlled restart activates certificate rotation.
- Backend kind and exactly one matching backend configuration.

### POSIX Configuration

- Absolute storage root, configured bucket allowlist or bucket-to-directory map,
  `managedPrivateLayout` or `sharedLocalDirectory` policy, file and directory
  creation modes, temporary-file retention, durability mode, and sidecar root.
- The root must exist, be owned or explicitly approved for the service identity,
  not be a symlink, and pass read/write/rename/fsync capability probes.
- `sharedLocalDirectory` must positively identify an approved local filesystem
  and reject network, userspace, or clustered mounts. Its writable sidecar root
  must be outside the exposed namespace on the same mounted filesystem.

### Upstream S3 Configuration

- HTTPS endpoint, region, addressing style, bucket mapping, a distinct upstream
  signing credential-provider reference, trust roots, optional mTLS identity
  reference, connect/request timeouts, retry budget, maximum connections, and
  in-flight byte limits.
- Plain HTTP is rejected unless an explicit development-only option is enabled
  and the endpoint resolves to a loopback address.

Secret values remain owned by typed providers; domain configuration and request
DTOs retain only provider references. Inbound verification, upstream signing, and
pagination-token keys use separate provider instances and key namespaces.
Environment variables may identify a provider but are not the preferred place for
long-lived keys. Provider lookup, caching, rotation, and failure behavior must be
explicit, and configuration errors identify the field rather than its secret
value. Stage 1 uses separate permission-restricted, versioned credential files,
loaded at startup and activated after atomic replacement by controlled restart,
as recorded in `design-docs/user-qa/pending-credential-providers.md`.

## Inbound S3 Semantics

### Addressing and Routing

Path-style requests use `/{bucket}/{key...}`. Virtual-host-style requests derive
the bucket only from a configured host suffix and take the key from `/{key...}`.
Untrusted or ambiguous hosts fail before authentication. Bucket names follow the
supported S3 DNS rules. Object keys are decoded exactly once; duplicate slashes,
dot segments, and encoded separators remain logical key data and are never
normalized as filesystem paths.

Routing is based on method plus recognized subresources and query fields. Unknown
subresources, duplicate security-sensitive query fields, conflicting framing
headers, multiple ranges, and unsupported operations fail deterministically.
`ListObjectsV2` authorization never silently broadens or filters a request. A
request with no prefix, or with a prefix broader than every matching grant, is
denied unless a matching grant authorizes the whole bucket. An allowed request
uses an effective list scope containing the principal, operation, exact bucket,
matched grant prefix, and requested prefix. Every returned object key and
`CommonPrefixes` entry must remain within that scope; a backend result outside it
fails closed as an internal consistency error rather than being returned or used
to advance pagination.

Pagination tokens are opaque, authenticated, versioned values bound to backend,
effective list scope, delimiter, and ordering state; clients cannot inject
filesystem paths or upstream continuation tokens through them. Each token carries
issued and expiry instants plus a non-secret key identifier and is protected by an
approved MAC or authenticated-encryption construction. Every continuation request
is authenticated and authorized again before token state is accepted. The token's
principal, operation, bucket, grant prefix, requested prefix, and delimiter must
match that request and the current immutable authorization configuration; a
different or revoked scope is denied. Verification accepts only configured active
or rotation-overlap keys, applies a bounded lifetime, and performs no backend call
on malformed, expired, unauthenticated, or context-mismatched input. A restart
preserves token validity only while its referenced key and authorization scope
remain configured.

### SigV4

The verifier supports header-based SigV4 and presigned query authentication for
the MVP operations. It validates algorithm, access-key lookup, credential scope,
signed-header set, timestamp skew, expiry, canonical URI, canonical query,
canonical headers, and payload hash using constant-time signature comparison.
The raw request target is retained because general URL normalization would change
the signed representation.

The initial stage accepts fixed payload hashes and `UNSIGNED-PAYLOAD` only where
explicitly configured for TLS-protected reads. AWS streaming chunk signatures are
a later stage. Several AWS SDKs default to `aws-chunked` streaming signatures
for uploads, so Stage 1 interoperability requires client configurations that
send a single signed payload hash; this limitation and the client
configurations proven to work are recorded with the compatibility test
evidence. Presigned uploads that rely on `UNSIGNED-PAYLOAD` fall outside the
default Stage 1 payload policy. A write body is not committed until its declared payload checksum
or signature policy has been validated. Temporary bytes may be streamed to a
backend staging area before final validation but must remain unreachable and be
deleted on failure or cancellation.

Inbound credential lookup returns an identity and scoped verification key
material but grants no operation by itself. Unknown, disabled, malformed, or
duplicate access-key records fail authentication without disclosing provider
state. Secrets are short-lived in memory where practical, never placed in DTOs,
errors, metrics, traces, or logs, and never forwarded to `S3Backend`.

### Ranges, Conditions, Metadata, ETags, and Checksums

- The MVP supports one satisfiable byte range. Multiple ranges return
  `NotImplemented`; unsatisfiable ranges return `InvalidRange`.
- `If-Match`, `If-None-Match`, `If-Modified-Since`, and
  `If-Unmodified-Since` follow HTTP precedence rules. Mutation conditions must be
  enforced atomically by a backend or rejected when the capability is absent.
- User metadata is accepted from bounded `x-amz-meta-*` headers, normalized for
  comparison, stored with original values, and emitted without allowing control
  characters or response-header injection.
- ETags are opaque. `POSIXBackend` computes the documented single-part ETag while
  streaming; `S3Backend` preserves the upstream ETag. Multipart ETags follow the
  backend's S3-compatible result and are never presented as a general checksum.
- Supported checksum headers are verified while streaming and returned only when
  the backend can preserve their semantics. A mismatch aborts publication.
- A `Content-MD5` header, when present, is validated while streaming; a
  malformed value fails before body consumption and a digest mismatch aborts
  publication. `Content-MD5` is not exposed as a typed checksum value.

## POSIXBackend

### Namespace and Containment

Each configured bucket maps to an approved directory under one opened storage
root. `managedPrivateLayout` uses a private versioned layout and reversibly
encodes every logical key segment, including empty, `.`, `..`, percent,
slash-like, and platform-reserved forms. Its mapping is collision-free and
listable without interpreting a key as a native path.

`sharedLocalDirectory` maps safely representable S3 key components directly to
native relative paths, treats regular files as objects, and treats directories as
prefixes so a pre-existing directory tree is visible through S3. It rejects keys
that the host filesystem cannot represent exactly and safely; it never silently
normalizes two logical keys to one path. This mode therefore exposes a documented
subset of the S3 key space.

All traversal uses directory-relative file-descriptor operations and rejects
symlinks at every component. The backend verifies device/inode ancestry or an
equivalent root-containment invariant before mutation. String-prefix path checks
and resolve-then-open sequences are insufficient. Buckets cannot point outside the
root, and special files, hard links outside policy, sockets, and devices are never
served as objects.

### Atomic Writes and Crash Recovery

Writes stream to a uniquely named temporary file in the destination filesystem
while incrementally calculating ETag and checksums. On success the backend flushes
data according to durability mode, persists metadata, atomically renames the
complete generation into place, and fsyncs affected directories. The final key is
never visible with partial content. Conditional replacement compares an opaque
version token within the same commit critical section.

A small versioned commit record associates data and metadata generations. Startup
recovery removes expired uncommitted temporary files, completes or rolls back
recognizable interrupted commits, and quarantines ambiguous state. Cleanup is
bounded and observable. Requests encountering ambiguous state return a typed
internal consistency error instead of guessing.

Versioned sidecar files and commit records store S3 metadata. The sidecar store is
outside the exposed data namespace and, for writable operation, on the same
mounted filesystem. Records bind to file identity and observed generation
attributes so replacement or outside modification invalidates stale metadata.
Metadata access remains behind an internal abstraction.

### Consistency, Permissions, and External Mutation

In `managedPrivateLayout`, a successful put or delete is immediately reflected by
get, head, and list operations. Per-key coordination prevents readers from
observing uncommitted replacement state. Listing uses a stable ordering and
opaque cursor; it may be page-consistent rather than snapshot-consistent, which
is documented in the capability report.

The service uses least-privilege file and directory modes, honors explicit startup
ownership checks, creates no world-writable paths, and treats permission changes
as typed access failures. It does not follow changes made through writable links.

`sharedLocalDirectory` does not require exclusive ownership. It reconciles
authoritative directory state on access and listing using descriptor-relative,
bounded identity and generation checks. External create, replace, modify, rename,
and delete operations become visible without an always-on full-tree watcher.
Missing or stale sidecars produce safe default metadata and recomputation of
derived values when needed; stale metadata is never attached to replacement
bytes. A file that changes during an operation causes a bounded retry or typed
conflict/consistency failure.

Because an outside process bypasses gateway coordination, shared mode does not
advertise strong read-after-write, snapshot-consistent listing, or atomic S3
preconditions against external mutations. Gateway-originated publication remains
staged and atomically renamed. Symlinks, special files, escaping hard links, and
filesystem-boundary crossings remain excluded. The comparative rationale and
benchmark targets are recorded in
`design-docs/references/posix-s3-gateway-oss-comparison.md`.

## S3Backend

`S3Backend` maps each domain request to a new upstream S3 request. It removes all
inbound authentication material and signs the upstream method, raw path, query,
headers, and payload policy with a dedicated upstream credential provider, region,
service, and endpoint configuration. Client access keys can never select or
override upstream credentials, endpoint, region, bucket mapping, or TLS policy.

Request and response bodies stream through bounded buffers. If either side slows,
backpressure reaches the other side; the gateway does not accumulate the remainder
of an object. Client cancellation cancels the upstream exchange. Connection pools
and concurrent in-flight bytes are capped. Readiness uses the request-scoped
absolute deadline described above; it cannot fall back to the configured upstream
timeout or outlive the inbound request that initiated it.

TLS certificate and hostname validation are mandatory outside explicit loopback
development mode. Redirects are disabled unless the destination is pre-approved,
because redirects can cross trust or signing boundaries. Response headers and XML
are bounded before parsing.

Retries use typed failure classification, exponential backoff with jitter, a
deadline, and a retry-attempt budget. Reads and other idempotent operations may be
retried before response bytes are exposed. Writes are retried only when replay is
provably safe and the body source is replayable or the upstream protocol provides
an idempotent multipart unit. No retry may cause whole-object buffering. Upstream
request IDs are recorded, but authorization headers, security tokens, presigned
queries, raw credentials, and object bodies are never logged.

Upstream errors are parsed into bounded `BackendError` values. The gateway maps
them according to its public contract rather than relaying arbitrary upstream XML
or headers. Upstream continuation tokens remain inside authenticated gateway
pagination tokens.

## Multipart Uploads

Multipart upload is designed in the contract but enabled after the initial MVP.
Create returns an opaque gateway upload ID bound to principal, backend, bucket,
key, initiation time, and configuration generation. Part numbers and sizes are
validated before streaming. Completion validates the ordered, unique part list and
ETags; abort is idempotent.

`POSIXBackend` stores parts in an isolated upload namespace, commits the assembled
object atomically without loading all parts into memory, and garbage-collects
expired uploads. `S3Backend` maps gateway upload state to upstream upload IDs but
never exposes an unsigned upstream token. Crash recovery distinguishes active,
completing, committed, and aborted states. Quotas cap uploads per principal, parts,
bytes, and retention time.

## Error Model

Errors flow through three typed layers:

1. Transport and parsing errors describe bounded HTTP failures.
2. `BackendError` describes semantic storage failures such as not found, already
   exists, condition failed, invalid range, permission denied, unavailable,
   throttled, corrupt state, or unsupported capability.
3. `GatewayError` adds public operation context and maps to a controlled S3 status,
   code, message, resource, request ID, and XML body.

Representative mappings include missing key to `NoSuchKey`, failed precondition to
`PreconditionFailed`, unsatisfiable range to `InvalidRange`, checksum or
`Content-MD5` mismatch to `BadDigest`, invalid signature to
`SignatureDoesNotMatch`, unknown credential to `InvalidAccessKeyId`, expired
request to `RequestExpired`, authorization denial to `AccessDenied`, invalid or
expired pagination token to `InvalidArgument`, unavailable backend to
`ServiceUnavailable`, and an unsupported route to `NotImplemented`. Internal
paths, upstream endpoints, raw backend messages, stack traces, and credentials
never appear in client responses. Retry hints are emitted only when the failure
is safe to retry.

## Security Invariants

- No storage operation occurs without successful authentication except an
  explicitly configured health endpoint containing no storage data.
- Authentication alone grants no storage access. Authorization is default-deny,
  covers operation, bucket, and logical key prefix, runs before every backend
  call, and does not disclose target existence on denial.
- List authorization rejects absent or broader prefixes unless the principal has
  whole-bucket scope, confines object and common-prefix results to the effective
  authorized scope, and is repeated for every continuation page.
- The signature is verified over the preserved request representation before
  trusting signed identity or mutable headers.
- Inbound and upstream credentials are separate, redacted, and never logged.
- Object keys cannot escape a POSIX root, select an upstream endpoint, or alter an
  upstream bucket mapping.
- Request headers, queries, metadata, XML, object sizes, concurrency, buffer bytes,
  multipart state, and deadlines all have enforced limits.
- Conflicting content-length and transfer-encoding, malformed chunking, duplicate
  signed fields, invalid Unicode, and control characters fail closed.
- Checksums and signatures are compared without timing-sensitive early exits.
- Temporary and multipart data is unreachable as a committed object and is
  removed or quarantined after failure.
- TLS is required on untrusted networks, and trusted-proxy configuration is an
  explicit allowlist.
- Error and telemetry fields use allowlisted structured values; object bodies,
  authorization headers, security tokens, and presigned queries are excluded.

## Observability

Stage 1 returns a random gateway request ID in S3 responses and offers opt-in,
fixed liveness and readiness documents with no storage or configuration data.
Startup diagnostics are allowlisted and redact file paths and credential data.
Opt-in structured request telemetry writes allowlisted JSON lines to standard
error containing only request ID, coarse method class, backend kind, status, and
duration. Buckets, keys, principals, endpoints, paths, headers, queries, bodies,
and credential identifiers are excluded. Higher-cardinality traces and
aggregated metrics remain release follow-up work.

## Testing Strategy

- Domain tests verify stable enum raw values, DTO validation, condition precedence,
  range rules, error mapping, pagination-token authentication, and configuration
  single-source loading without network or filesystem dependencies.
- Authorization tests cover missing policies, empty grants, operation mismatch,
  exact bucket matching, prefix boundary and Unicode cases, list-prefix scope,
  denial non-disclosure, and configuration reload requiring restart.
- Pagination tests cover key rotation overlap, expiry, tampering, context binding,
  restart behavior, invalid key identifiers, and bounded decoding before any
  backend call.
- SigV4 tests use published canonical-request vectors plus adversarial path,
  percent-encoding, duplicate-query, header-whitespace, clock-skew, presigned URL,
  payload-hash, and constant-time comparison cases.
- A backend contract suite runs unchanged against `POSIXBackend`, `S3Backend`
  backed by a controlled compatible service, and fault-injecting test doubles.
- Streaming tests use slow producers/consumers, bounded-buffer assertions,
  cancellation, truncation, checksum mismatch, and objects larger than available
  memory to prove that whole-object buffering does not occur.
- POSIX security tests cover dot segments, encoded separators, Unicode collisions,
  symlink swaps, hard links, special files, permission changes, disk-full errors,
  atomic replacement, process interruption, recovery, and external mutation.
- S3 backend tests cover new request signing, credential separation, endpoint and
  region mismatch, TLS failure, redirect rejection, retry classification,
  throttling, truncated XML, upstream error mapping, backpressure, readiness
  deadline propagation, and cancellation of a blocking readiness exchange.
- HTTP compatibility tests exercise path and virtual-host addressing, CRUD, head,
  list pagination, metadata, ETags, checksums, single ranges, conditions, and
  unsupported-operation responses using representative S3 clients. Transport and
  integration tests additionally prove that readiness saturation cannot consume
  authenticated-request capacity and that disconnect releases readiness admission
  promptly.
- Multipart tests cover part ordering, limits, duplicate completion, abort,
  expiration, crash recovery, and no partial publication before the staged route
  is enabled.

## Staged Rollout

### Stage 0: Foundation

Typed configuration, domain DTOs, `ObjectStoreBackend`, capability validation,
stream abstraction, error mapping, telemetry schema, and deterministic test
fixtures. No public listener is enabled.

### Stage 1: MVP

Header and presigned SigV4; configured path-style and virtual-host-style
addressing; statically configured buckets; `GetObject`, `HeadObject`, `PutObject`,
`DeleteObject`, and `ListObjectsV2`; one range; standard read/write conditions;
bounded user metadata; single-part ETag and supported checksum behavior; both
`POSIXBackend` and `S3Backend`; `managedPrivateLayout` and local-filesystem-only
`sharedLocalDirectory`; graceful shutdown; and native TLS through SwiftNIO SSL.
Unsupported routes return controlled errors.

Rollout begins on loopback with contract tests, then a TLS-protected staging
environment with shadowed compatibility tests, and finally a limited production
allowlist. Promotion requires no secret-bearing telemetry, bounded memory under
load, verified cancellation, and clean crash-recovery exercises.

### Stage 2: Multipart

Enable multipart create/upload/complete/abort after both backends pass the same
contract and recovery suites. Expand checksum support without changing existing
enum raw values.

### Stage 3: Broader Compatibility

Evaluate AWS streaming chunk signatures, multiple ranges, copy operations, bucket
management, versioning, and other S3 APIs through separate design decisions.
Compatibility expands only with explicit capability, security, and test coverage.

## Decisions

- Preserve the existing SwiftPM target layout for the MVP.
- Use one startup-selected backend per process.
- Keep HTTP/SigV4/routing types out of `ObjectStoreBackend`.
- Use explicit `Sendable` DTOs and stable typed enums for public and persisted
  contracts.
- Require backpressured streams and prohibit whole-object buffering.
- Treat ETags as opaque and checksums as separately typed values.
- Put multipart upload after the initial object-operation MVP while defining its
  contract now.
- Use SwiftNIO and SwiftNIO SSL for Stage 1 HTTP and native TLS transport.
- Use separate permission-restricted, versioned files for the three credential
  domains, with controlled-restart rotation.
- Use versioned sidecar metadata and commit records.
- Support both a collision-free private managed POSIX layout and a
  local-filesystem-only shared-directory layout with on-access reconciliation and
  reduced consistency capabilities.
- Re-sign all upstream S3 requests with separate credentials.

## Answered User Decisions

- HTTP server and byte-buffer implementation:
  `design-docs/user-qa/pending-http-server-library.md`.
- Native TLS versus external-only termination for the first release:
  `design-docs/user-qa/pending-tls-termination.md`.
- Deployable credential providers and rotation behavior:
  `design-docs/user-qa/pending-credential-providers.md`.
- POSIX user metadata representation:
  `design-docs/user-qa/pending-posix-metadata-storage.md`.
- Long-term policy for out-of-band POSIX mutation:
  `design-docs/user-qa/pending-posix-out-of-band-mutation.md`.

These decisions remain isolated behind transport, credential-provider,
metadata-store, and reconciliation boundaries. They were answered on 2026-07-23;
the linked records contain the accepted details.
