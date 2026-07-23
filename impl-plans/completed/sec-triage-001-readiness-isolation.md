# SEC-TRIAGE-001 Readiness Isolation

**Status**: Completed
**Workflow Mode**: Issue resolution
**Issue Reference**: `SEC-TRIAGE-001` (medium)
**Design Reference**: `design-docs/specs/s3-gateway-design.md#health-probe-isolation-and-request-lifetime`
**Review Decision**: Accepted for implementation planning after independent review

## Purpose

Resolve the availability finding in which disconnected, unauthenticated
readiness probes can retain upstream work and shared authenticated-request
capacity. Implement the accepted request-lifetime, deadline-propagation, and
health-admission design while preserving the existing fixed health responses and
all unrelated worktree changes.

## Source of Truth and Scope

The accepted design section is authoritative for admission classification,
ownership, cleanup, deadlines, data flow, and test behavior. This plan is limited
to:

- one shared health-route classifier and trusted admission result;
- one request-scoped absolute deadline created by the inbound transport;
- transport ownership and cancellation of each accepted application task;
- a dedicated, fail-fast readiness gate with fixed capacity one;
- readiness-deadline propagation through the service and backend boundaries;
- prompt cancellation of upstream S3 readiness work; and
- focused deterministic tests and post-fix security verification.

This work adds no configuration setting, does not change the SwiftPM target
layout, and does not change the fixed readiness/liveness status, body, headers,
or `GET`/`HEAD` behavior. It must not modify dependency checkouts, `.build`
artifacts, unrelated POSIX work, release scripts, benchmarks, or multipart work.
There are no Codex-agent reference inputs and no new user decision is required.

## Deliverables

- A single immutable health classifier shared by server composition, transport,
  and application boundaries.
- A transport request envelope carrying the classifier-derived admission class
  and request-scoped absolute deadline.
- Transport lifecycle ownership that cancels application work and releases only
  permits actually acquired.
- A separate readiness gate that cannot consume authenticated-request capacity.
- Deadline-aware readiness contracts and prompt upstream cancellation.
- Deterministic disconnect, timeout, classification, saturation, deadline, and
  fixed-response regression tests.
- A dated progress log and complete verification evidence.

## Task Breakdown

### TASK-SEC-001: Establish shared classification and request-envelope contracts

**Dependencies**: None

**Parallelizable**: Yes, with TASK-SEC-002. Write scopes are disjoint.

**Likely Files/Targets**:

- `Sources/AppCore/Configuration/GatewayConfiguration.swift`
- `Sources/AppCore/Gateway/HealthRouteClassifier.swift` (new, if a dedicated
  file best matches local organization)
- `Sources/AppCore/Transport/HTTPTransportModels.swift`
- `Tests/AppCoreTests/Configuration/ConfigurationTests.swift`
- focused classifier tests under `Tests/AppCoreTests/Gateway/` or
  `Tests/AppCoreTests/Transport/`

**Work**:

- Define an immutable, `Sendable` classification contract with `liveness`,
  `readiness`, and `none`.
- Define the classifier API consumed by the later transport and application
  tasks; TASK-SEC-003 owns the transport initializer, while TASK-SEC-004 owns the
  application initializer and the single server-composition write.
- Classify only exact configured raw paths with an empty raw query and `GET` or
  `HEAD`. Disabled health configuration, alternate methods, nonempty queries,
  and near matches must classify as `none`.
- Extend the transport request envelope with the classifier-derived admission
  class and absolute request deadline. Prevent callers from independently
  asserting a trusted health class; tests and non-network callers must use the
  same classification path.
- Preserve all existing health configuration defaults and validation. Do not add
  readiness-capacity or timeout configuration.

**Deliverables**:

- Shared classifier contract.
- Request-envelope contract for admission class and deadline.
- Exact-match and disabled-route regression tests.

**Completion Criteria**:

- The transport and application cannot drift onto separate path predicates.
- Only an exact configured health route can carry a health admission class.
- Near matches and malformed health candidates remain on the normal
  authenticated path.
- Existing configuration files decode unchanged.

**Verification**:

- `swift test --filter ConfigurationTests`
- `swift test --filter HealthRouteClassifierTests`
- `rg -n "HealthRouteClassifier|healthAdmission|deadline" Sources/AppCore/Configuration Sources/AppCore/Gateway Sources/AppCore/Transport`

### TASK-SEC-002: Propagate and enforce readiness deadlines through backends

**Dependencies**: None

**Parallelizable**: Yes, with TASK-SEC-001. This task owns service, backend
contract, backend implementation, upstream client, and matching test files.

**Likely Files/Targets**:

- `Sources/AppCore/Backends/Contracts/ObjectStoreBackend.swift`
- `Sources/AppCore/Gateway/GatewayService.swift`
- `Sources/AppCore/Backends/POSIX/POSIXBackend.swift`
- `Sources/AppCore/Backends/S3/S3Backend.swift`
- `Sources/AppCore/Backends/S3/NIOUpstreamHTTPClient.swift`
- `Tests/AppCoreTests/Gateway/GatewayServiceTests.swift`
- `Tests/AppCoreTests/Backends/BackendContractTests.swift`
- `Tests/AppCoreTests/Backends/POSIXBackendTests.swift`
- `Tests/AppCoreTests/Backends/S3BackendTests.swift`

**Work**:

- Change the readiness contract to accept an absolute deadline and update every
  production and test backend conformance. HTTP readiness callers pass the
  transport-created request deadline; the existing non-request startup caller is
  assigned explicitly to TASK-SEC-004.
- Make `GatewayService` reject expired work and enforce the deadline around the
  backend readiness call.
- Make POSIX and test backends reject an already-expired deadline.
- Pass the deadline into the signed S3 readiness `HEAD` request. Ensure retry
  attempts, retry backoff, connection setup, and response waiting all use the
  remaining deadline and never fall back to a longer configured upstream
  timeout.
- Audit the upstream cancellation handler so task cancellation promptly closes
  the active channel/exchange and interrupts response waits, request-body work,
  and retry sleeps.
- Use explicit test synchronization for blocking upstream work; do not base
  cancellation assertions solely on elapsed sleeps.

**Deliverables**:

- Deadline-aware readiness protocol, service, and backend implementations.
- S3 deadline and cancellation regression tests.
- Updated test doubles and backend contract fixtures.

**Completion Criteria**:

- An expired readiness deadline reaches no backend or upstream attempt.
- Every S3 readiness attempt and backoff is bounded by the inbound deadline.
- Cancelling readiness closes active upstream work promptly and does not leave a
  retry sleep running.
- All backend conformances compile under Swift 6 strict concurrency.

**Verification**:

- `swift test --filter GatewayServiceTests`
- `swift test --filter BackendContractTests`
- `swift test --filter POSIXBackendTests`
- `swift test --filter S3BackendTests`
- `rg -n "readinessCheck|deadline|withTaskCancellationHandler|executeWithRetry" Sources/AppCore/Gateway Sources/AppCore/Backends`

### TASK-SEC-003: Implement transport admission and application-task lifecycle

**Dependencies**: TASK-SEC-001

**Parallelizable**: No. It owns the transport lifecycle and transport tests.

**Likely Files/Targets**:

- `Sources/AppCore/Transport/NIOHTTPTransport.swift`
- `Tests/AppCoreTests/Transport/HTTPTransportTests.swift`

**Work**:

- Update the transport initializer to accept the shared classifier contract from
  TASK-SEC-001.
- Create the absolute deadline when the transport accepts the request head and
  carry it with the single classifier result.
- Acquire the shared request limiter only for admission class `none`. Exact
  health traffic must bypass that limiter; every near match must acquire it.
- Store exactly one cancellable application task handle for each accepted
  request for the lifetime of that channel request.
- Cancel the application task on channel inactivity, request timeout, handler
  removal, transport shutdown, and response-write failure.
- Centralize idempotent cleanup so each acquired shared permit is released
  exactly once, including cancellation before application entry, application
  failure, write failure, and normal completion. Health requests must never
  release a shared permit they did not acquire.
- Keep channel and task state transitions on an explicit synchronization
  boundary suitable for SwiftNIO event-loop callbacks and Swift task
  cancellation.

**Deliverables**:

- Health-aware transport admission.
- Stored application-task cancellation ownership.
- Idempotent shared-limiter cleanup.
- Deterministic transport lifecycle tests.

**Completion Criteria**:

- Channel inactivity and timeout cancel the associated application task.
- Shared authenticated-request capacity is released promptly after every
  terminal path.
- Health traffic cannot decrement, consume, or over-release the shared limiter.
- Near-match health paths still exercise the limiter and normal authentication
  path.

**Verification**:

- `swift test --filter HTTPTransportTests`
- `rg -n "applicationTask|channelInactive|handlerRemoved|timeout|requestLimiter|healthAdmission" Sources/AppCore/Transport/NIOHTTPTransport.swift Tests/AppCoreTests/Transport/HTTPTransportTests.swift`

### TASK-SEC-004: Wire server composition, application invariant, and readiness gate

**Dependencies**: TASK-SEC-001, TASK-SEC-002

**Parallelizable**: Yes, with TASK-SEC-003 after its dependencies are complete.
Its write scope is limited to server composition, application health handling,
and their matching tests.

**Likely Files/Targets**:

- `Sources/AppCore/Server/GatewayServer.swift`
- `Sources/AppCore/Gateway/S3GatewayApplication.swift`
- `Tests/AppCoreTests/Server/GatewayServerTests.swift`
- `Tests/AppCoreTests/Gateway/GatewayIntegrationTests.swift`

**Work**:

- Update the application initializer to accept the shared classifier contract
  from TASK-SEC-001.
- Build one classifier from the validated `HealthEndpointConfiguration` in
  `GatewayServer.make` and inject that same immutable value into the transport
  and application.
- Update the existing server-startup `backend.readinessCheck()` caller for the
  deadline-taking protocol. Derive a separate bounded startup deadline from the
  validated `limits.requestTimeoutSeconds`; document that it represents startup
  lifetime rather than an inbound request, and do not use an unbounded or
  `distantFuture` fallback.
- Recompute health classification with the shared classifier before health,
  authentication, or backend work and compare it with the carried admission
  class.
- Return a bounded, detail-free `500` on mismatch without invoking health,
  authentication, or backend behavior.
- Add a dedicated, fail-fast readiness gate with fixed capacity one. Acquire it
  immediately before `GatewayService.readinessCheck` and release it exactly once
  through task-lifetime cleanup on success, failure, expiry, or cancellation.
- Map gate saturation, expiry, cancellation, and backend failure to the existing
  fixed readiness `503` representation. Preserve successful liveness/readiness
  responses and `HEAD` body suppression.
- Add direct application tests for invariant failure, gate saturation, permit
  release, deadline propagation, and fixed response bytes/headers.
- Add focused server tests proving one classifier is wired to both boundaries
  and startup readiness receives a bounded deadline.

**Deliverables**:

- Single-classifier server composition and a bounded startup-readiness call.
- Application-side admission invariant.
- Dedicated readiness gate and cleanup.
- Server wiring, fixed-response, and application-boundary regression tests.

**Completion Criteria**:

- At most one backend readiness probe is in flight.
- A rejected or failed readiness probe has the same externally visible fixed
  response as before.
- Cancellation releases the readiness permit before a subsequent probe is
  admitted.
- A carried-class mismatch cannot fall through to authenticated work.
- The startup readiness call compiles against the new protocol and remains
  bounded without being represented as an inbound request deadline.

**Verification**:

- `swift test --filter GatewayServerTests`
- `swift test --filter GatewayIntegrationTests`
- `swift build`
- `rg -n "HealthRouteClassifier|readinessGate|readinessCheck|healthAdmission|not-ready|requestTimeoutSeconds" Sources/AppCore/Server/GatewayServer.swift Sources/AppCore/Gateway/S3GatewayApplication.swift Tests/AppCoreTests/Server/GatewayServerTests.swift Tests/AppCoreTests/Gateway/GatewayIntegrationTests.swift`

### TASK-SEC-005: Prove cross-boundary behavior and close security verification

**Dependencies**: TASK-SEC-002, TASK-SEC-003, TASK-SEC-004

**Parallelizable**: No. This task validates the integrated result and records
final evidence.

**Likely Files/Targets**:

- `Tests/AppCoreTests/Transport/HTTPTransportTests.swift`
- `Tests/AppCoreTests/Gateway/GatewayIntegrationTests.swift`
- `Tests/AppCoreTests/Backends/S3BackendTests.swift`
- `impl-plans/active/sec-triage-001-readiness-isolation.md`

**Work**:

- Add or finalize a blocking-readiness disconnect test that observes application
  and upstream cancellation, then proves readiness admission and shared capacity
  are released.
- Add or finalize a saturation test with readiness in flight and an
  authenticated object request. Readiness traffic alone must not cause a
  limiter-generated `503`.
- Exercise timeout, channel close, response-write failure, exact health
  classification, near matches, and fixed `GET`/`HEAD` responses with explicit
  synchronization signals.
- Run focused tests, the complete Swift suite, SwiftLint when available, source
  inspection, diff validation, and gitleaks.
- Return control to the security-check loop and require secrets, gitleaks,
  static, dependency, and supply-chain/config methods to rerun. The dependency
  method must discover tracked `Package.swift` and `Package.resolved` and run
  with `networkAudits=true`; capped or incomplete results do not close the
  coverage gap.
- Record every command, result, changed file, and residual blocker in the
  progress log.

**Deliverables**:

- Cross-boundary disconnect and saturation evidence.
- Clean lint, test, source, diff, and security checks.
- Complete progress log and residual-risk statement.

**Completion Criteria**:

- Both acceptance tests pass deterministically without timing-only sleeps.
- Relevant focused tests and the full Swift suite pass.
- SwiftLint passes when available, or unavailability is explicitly recorded.
- No source secret, static, dependency, or supply-chain/config finding remains
  unreviewed.
- Network-enabled dependency audit coverage is valid and uncapped, or the issue
  remains open with the exact blocker recorded.
- No unrelated dirty worktree file is staged, reverted, or modified.

**Verification**:

- `swift test --filter HTTPTransportTests`
- `swift test --filter GatewayIntegrationTests`
- `swift test --filter S3BackendTests`
- `swift test`
- `swift build`
- `command -v swiftlint >/dev/null && swiftlint`
- `rg -n 'readinessCheck|deadline|cancel|requestLimiter|healthAdmission' Sources/AppCore/Gateway Sources/AppCore/Transport Sources/AppCore/Backends/S3`
- `git diff --check`
- `gitleaks detect --source . --no-git --redact`
- `git ls-files --error-unmatch Package.swift Package.resolved`
- Security-check loop dependency method with
  `manifests=["Package.swift","Package.resolved"]` and `networkAudits=true`

## Dependency Order

1. TASK-SEC-001 and TASK-SEC-002 may run concurrently because their write scopes
   are disjoint.
2. TASK-SEC-003 begins after the classifier and request-envelope contract from
   TASK-SEC-001 is stable.
3. TASK-SEC-004 begins after TASK-SEC-001 and the readiness contract from
   TASK-SEC-002 are stable. It exclusively owns `GatewayServer.swift` and may run
   alongside TASK-SEC-003 because their write scopes are disjoint.
4. TASK-SEC-005 begins only after all implementation tasks are integrated.

## Risks and Mitigations

- **Classifier drift or forged admission**: construct and inject one immutable
  classifier, carry its result from transport, and fail closed on mismatch.
- **Permit leak or double release during races**: assign ownership explicitly
  and test cancellation before entry, during work, during write, and after
  completion.
- **Cancellation without upstream interruption**: retain the active upstream
  channel/exchange under the cancellation handler and assert closure with test
  synchronization.
- **Deadline mismatch between wall and monotonic clocks**: create one absolute
  inbound deadline, use remaining time at each boundary, and reject nonpositive
  intervals before starting work.
- **Flaky disconnect tests**: coordinate blocking, cancellation, and permit
  release with continuations, actors, or test probes rather than sleep-only
  timing.
- **Protocol-signature ripple**: update every backend conformance and test double
  in TASK-SEC-002; update the existing `GatewayServer.make` startup caller in
  TASK-SEC-004 with a bounded, configuration-derived startup deadline; run
  contract, server, and build verification before integration.
- **Incomplete security coverage**: do not treat capped scans or
  `networkAudits=false` as closure; rerun the security-check loop with tracked
  manifests discovered.
- **Dirty-worktree interference**: inspect scoped diffs throughout and preserve
  every unrelated modified or untracked file.

## Progress Log Expectations

Append dated entries below as work proceeds. Each entry must include:

- task ID and status (`started`, `blocked`, or `completed`);
- exact source and test paths changed;
- exact verification commands and pass/fail/ unavailable results;
- relevant lifecycle, limiter, deadline, or response evidence;
- blockers, deviations from this plan, and residual risks; and
- confirmation that no staging, commit, push, or unrelated worktree mutation
  occurred.

Do not mark a task complete from compilation alone. TASK-SEC-005 closes only
after focused behavioral tests and the required post-fix security-check loop
complete.

## Progress Log

- 2026-07-23: Plan created from the independently accepted design. No
  implementation work started; no source files staged, committed, or pushed.
- 2026-07-23: Revised after Step 5 review. Assigned all `GatewayServer.swift`
  writes to TASK-SEC-004, defined bounded startup-readiness deadline behavior,
  preserved disjoint TASK-SEC-001/TASK-SEC-002 write scopes, and added focused
  server/build verification. No implementation work started and no source files
  staged, committed, or pushed.
- 2026-07-23: Completed TASK-SEC-001 through TASK-SEC-004. Added the shared
  classifier and trusted request envelope, absolute readiness deadlines,
  cancellation-aware upstream exchanges, transport-owned application tasks,
  idempotent shared-limiter cleanup, a capacity-one readiness gate, bounded
  startup readiness, and fail-closed classifier invariant checks. Added focused
  classifier, gateway, transport lifecycle, server, POSIX, and S3 backend
  regressions. The transport lifecycle coverage was split into
  `HTTPTransportTests+Lifecycle.swift` to keep every Swift file below 1,000
  lines. No source file was staged, committed, or pushed during implementation.
- 2026-07-23: Completed TASK-SEC-005. `swift test --filter
  HTTPTransportTests`, `GatewayIntegrationTests`, `GatewayServerTests`,
  `POSIXBackendTests`, and `S3BackendTests` passed. A full parallel run exposed
  and then deterministically fixed a pre-existing disconnect-test race; the
  repeated full suite passed with 120 tests before release-gate suite naming and
  121 tests afterward. `swift build`, strict SwiftLint, `git diff --check`, the
  under-1,000-line policy, and the post-fix AWS CLI native-TLS matrix passed.
  Scoped Gitleaks scans of repository-owned source, tests, scripts,
  documentation, plans, manifests, and benchmark harnesses found no leaks.
- 2026-07-23: The packaged scan wrapper was run with network audits enabled. Its
  text/static pass found no secret assignment and only the required S3 XML
  namespace plus loopback-only HTTP test URLs; its recursive Gitleaks invocation
  ignored the configured `.build` exclusion and reported only generated
  dependency test vectors. The gap was closed with clean scoped Gitleaks runs,
  `swift package show-dependencies --format json`, and an OSV query for all
  seven resolved Swift packages, which returned no known vulnerabilities.
  `.github/workflows` inspection found no unpinned action. No high or medium
  source, dependency, or supply-chain finding remains open.
