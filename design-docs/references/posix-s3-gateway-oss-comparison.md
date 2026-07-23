# POSIX S3 Gateway OSS Comparison

## Status

Reviewed 2026-07-23. These projects are behavioral and performance benchmark
targets, not normative dependencies. Re-check the linked upstream documentation
when updating the compatibility matrix or publishing benchmark results.

## VersityGW

Sources:

- [VersityGW repository and POSIX overview](https://github.com/versity/versitygw)
- [VersityGW POSIX metadata documentation](https://github.com/versity/versitygw/wiki/POSIX-metadata)

Relevant behavior:

- Its stated use cases include turning a local filesystem into an S3 server and
  common access to files through POSIX and S3.
- Its POSIX backend exposes a configured directory and supports xattr, sidecar,
  and metadata-free strategies.
- Its sidecar documentation explicitly warns that outside file modification can
  leave ETag and other metadata stale or associate old metadata with replacement
  bytes. Metadata-free mode is described as useful for pre-existing read-only
  datasets.

Design consequence for this project: benchmark direct-path interoperability and
read/list throughput against VersityGW, but do not copy its stale-metadata
behavior. Bind sidecars to observed file generations, invalidate them after
outside mutation, and report weaker consistency capabilities in shared mode.

## S3Proxy

Source:

- [S3Proxy repository documentation](https://github.com/gaul/s3proxy/blob/master/README.md)

Relevant behavior:

- It documents local-filesystem use through a configured base directory.
- Its recommended on-disk provider is `filesystem-nio2`.
- It distinguishes backend capability from S3 emulation and documents operations
  whose conditions are emulated rather than natively atomic.

Design consequence for this project: include S3Proxy's filesystem backend in
basic CRUD/list and small-object performance comparisons. Keep capability
reporting explicit and never represent a userspace condition check as atomic
against an independent local writer.

## SeaweedFS

Sources:

- [SeaweedFS repository](https://github.com/seaweedfs/seaweedfs)
- [SeaweedFS S3 command](https://github.com/seaweedfs/seaweedfs/blob/master/weed/command/s3.go)

Relevant behavior:

- Its S3 endpoint is backed by SeaweedFS filers and shares the filer's logical
  namespace with other SeaweedFS protocols.
- It is not a direct adapter over an arbitrary pre-existing native directory, so
  its storage-layout semantics are not the model for `sharedLocalDirectory`.
- It remains useful as an S3 interoperability and throughput comparison target,
  including native TLS and streaming behavior.

## Benchmark Scope

At minimum, compare `swift-s3-gateway` with current releases of VersityGW,
S3Proxy, and SeaweedFS using recorded versions, identical hardware and local
filesystem, identical object sets, warm and cold runs, and published command
lines. Measure:

- sequential and concurrent PUT/GET throughput for small and large objects;
- HEAD and LIST latency over increasing file counts;
- process memory and bounded in-flight bytes;
- behavior after external create, replace, rename, and delete operations;
- metadata/ETag correctness after external mutation;
- TLS overhead and representative AWS CLI/SDK compatibility.

Do not combine direct-local-directory results with filer-backed or managed-layout
results without labeling the storage model and consistency guarantees.
