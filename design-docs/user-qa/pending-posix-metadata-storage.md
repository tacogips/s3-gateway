# POSIX Metadata Storage

## Question

Should `POSIXBackend` persist S3 metadata in extended attributes, sidecar files,
or a hybrid representation?

## Status

Answered

## Answer

On 2026-07-23, the user accepted versioned sidecar metadata and commit records.
Keep sidecar access behind an internal metadata-store abstraction. In the shared
local-directory mode, store gateway metadata in a reserved sidecar root outside
the exposed data namespace but on the same mounted local filesystem for writable
operation. Bind each record to observed file identity and generation attributes
so external replacement or modification invalidates stale metadata.

## Context

The representation must preserve bounded user metadata, content type, ETag,
checksums, and an opaque generation token. Data and metadata must publish
atomically, survive crashes, remain portable across supported filesystems, and
produce explicit failures when metadata is lost or externally changed.

## Options

- Versioned sidecar files for portability, with an atomic commit record joining
  object and metadata generations.
- Extended attributes for locality, with startup filesystem capability checks.
- A hybrid that uses xattrs when proven safe and sidecars otherwise.

## Provisional Planning Assumption

Use versioned sidecars and commit records because their behavior can be tested on
all supported filesystems. Keep metadata access behind an internal abstraction so
the decision can change without affecting `ObjectStoreBackend`.
