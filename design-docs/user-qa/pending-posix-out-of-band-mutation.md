# POSIX Out-of-Band Mutation

## Question

Should `POSIXBackend` reconcile filesystem changes made outside the gateway, or
require exclusive ownership of its storage root?

## Status

Answered

## Answer

On 2026-07-23, the user selected reconciliation for a local-filesystem directory
tree and explicitly rejected a strict exclusive-ownership requirement. The
gateway must support exposing the contents below a configured directory through
S3 while local processes may also create, replace, modify, rename, or remove
ordinary files.

Implement this as an explicit `sharedLocalDirectory` policy, distinct from the
private managed-layout policy:

- Map configured buckets to approved local directories. Map safe S3 key path
  components directly to native relative paths so existing files are visible;
  reject keys that are not safely and reversibly representable on the host
  filesystem rather than silently normalizing them.
- Treat regular files as objects and directories as prefixes. Never expose or
  follow symlinks, devices, sockets, FIFOs, filesystem boundaries, or hard links
  that violate the configured containment policy.
- Reconcile on access and listing from authoritative filesystem state. Detect
  changes with descriptor-relative lookup and bounded identity/generation checks;
  do not require an always-on full-tree watcher or scan before serving traffic.
- Store sidecar metadata outside the exposed namespace. Bind it to file identity
  and observed generation attributes. When it is absent or stale, synthesize
  safe defaults and recompute derived values when required; never attach stale
  metadata to replacement bytes.
- Gateway-originated writes remain staged and atomically renamed. If a file
  changes during a read, metadata calculation, conditional mutation, or listing,
  retry within a bound or return a typed conflict/consistency error.
- Report weaker capabilities in this mode: concurrent external writers prevent
  a truthful guarantee of strong read-after-write, snapshot-consistent listing,
  or atomic S3 preconditions against non-gateway mutations. Configuration must
  not advertise those capabilities.
- Limit this mode to storage positively identified as a supported local
  filesystem. Reject network, userspace, and clustered mounts unless a future
  filesystem-specific contract and test suite approves them.

This policy is informed by VersityGW's direct POSIX mapping and its documented
warning that metadata maintained only through the gateway becomes stale after
outside modification. See
`design-docs/references/posix-s3-gateway-oss-comparison.md`.

## Context

External changes can separate object bytes from S3 metadata, bypass conditional
writes, introduce symlinks or special files, and invalidate list pagination. Safe
reconciliation would require a defined import policy, conflict handling, and an
index or scan strategy.

## Options

- Permanently require an exclusively owned private layout and fail closed on
  detected mutation.
- Add a later read-only import or explicit reconciliation command.
- Continuously reconcile a documented subset of native filesystem changes.

## Provisional Planning Assumption

Support `sharedLocalDirectory` in Stage 1 for approved local filesystems, using
on-access reconciliation and reduced capability reporting. Retain a private
managed-layout policy when the broader collision-free S3 key space and stronger
gateway-controlled consistency are required.
