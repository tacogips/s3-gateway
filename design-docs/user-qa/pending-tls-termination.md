# TLS Termination

## Question

Must the first production release terminate TLS inside the gateway, or may it
require a trusted reverse proxy or load balancer?

## Status

Answered

## Answer

On 2026-07-23, the user selected native TLS for the first production release.
Stage 1 production configuration must terminate TLS in the gateway using
configured certificate and private-key provider references and must support a
controlled certificate rotation procedure. External TLS termination may remain
available behind an explicitly trusted proxy, but it is not a substitute for the
native-TLS Stage 1 release requirement.

## Context

SigV4 verification depends on the externally visible host, path, and scheme.
External termination therefore requires an explicit trusted-proxy allowlist and
strict handling of forwarded fields. Native TLS adds certificate configuration
and rotation responsibilities.

## Options

- External TLS termination for the MVP, with loopback or private binding and a
  trusted-proxy configuration.
- Native TLS in the MVP, with external termination remaining supported.

## Provisional Planning Assumption

Use native TLS for Stage 1 production deployments. Keep external termination as
an optional, explicitly trusted-proxy topology. TLS remains mandatory on
untrusted networks in either mode.
