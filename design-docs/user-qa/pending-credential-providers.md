# Credential Providers and Rotation

## Question

Which deployable credential providers and rotation model should supply inbound
SigV4 verification keys, upstream S3 signing credentials, and pagination-token
keys for the MVP?

## Status

Answered

## Answer

On 2026-07-23, the user accepted the recommended staged file-provider model.
Use separate owner-readable, versioned credential files for inbound SigV4
verification records, upstream S3 signing credentials, and pagination-token
keys. Require absolute regular-file paths, expected ownership, no symlinks, and
mode `0600` or stricter. Load bounded records at startup into provider-owned,
redacted memory. Inbound rotation uses multiple independently identifiable
access-key records; upstream signing uses one active credential with an optional
session token; pagination uses one active key identifier plus bounded previous
keys for token-lifetime overlap. Atomic file replacement followed by a controlled
restart activates changes. Live reload, Keychain, and external secret-manager
providers remain later implementations behind the same typed interfaces.

## Context

The three secret domains must remain separate. Inbound access-key records map to
principal identities but do not grant operations; upstream credentials sign only
new backend requests; pagination keys authenticate only opaque gateway tokens.
Provider references may appear in ordinary configuration, but secret values must
not appear in process arguments, logs, diagnostics, domain DTOs, or the main
configuration file. Provider failures and rotation overlap must be deterministic
without silently retaining disabled credentials.

## Options

- Permission-restricted, versioned credential files loaded at startup, with
  rotation activated by atomic file replacement and a controlled restart.
- macOS Keychain-backed providers referenced by stable item identifiers.
- An external secret-manager or command provider with bounded lookup, caching,
  timeout, and failure semantics.
- A staged combination: local files for the MVP and external providers behind the
  same typed interfaces later.

## Provisional Planning Assumption

Use separate owner-readable credential files for the three secret domains. Require
an absolute path, regular file, expected owner, no symlink, and mode `0600` or
stricter; load and validate bounded, versioned records at startup into
provider-owned redacted memory. Inbound rotation uses multiple independently
identifiable access-key records. Upstream signing uses one active credential with
an optional session token. Pagination uses one active key identifier plus bounded
previous keys for token-lifetime overlap. Changes take effect only after a
controlled restart; live reload and external secret managers are follow-up work.
