# HTTP Server Library

## Question

Which Swift HTTP server and byte-buffer library should provide the MVP transport?

## Status

Answered

## Answer

On 2026-07-23, the user selected SwiftNIO for the HTTP server and byte-buffer
implementation. Use SwiftNIO HTTP/1.1 handlers behind `HTTPTransport`, with an
adapter-owned `ObjectBodyStream` boundary so NIO request and `ByteBuffer` types do
not cross into `ObjectStoreBackend`. Use SwiftNIO SSL for the selected native TLS
mode.

## Context

The transport must preserve raw request targets for SigV4, support cancellation
and bounded backpressure, enforce connection and header limits, and avoid exposing
library-specific request or buffer types through `ObjectStoreBackend`.

## Options

- SwiftNIO with explicit HTTP/1.1 handlers and a small `ObjectBodyStream` adapter.
- A higher-level server framework whose raw-target and streaming behavior can be
  proven through integration tests.

## Provisional Planning Assumption

Use SwiftNIO behind `HTTPTransport` and an adapter-owned buffer boundary. Do not
create a new SwiftPM target solely for the adapter in the MVP.
