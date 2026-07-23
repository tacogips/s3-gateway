# Stage 1 Benchmark Results: 2026-07-23

These retained warm-cache results compare client-visible AWS CLI operations on
one Apple M4 host with APFS storage. Each result used a 4 KiB small object, a
64 MiB large object, one Hyperfine warmup, five measured runs, and concurrency
two for the concurrent cases. TLS was disabled to isolate local storage and
request-processing overhead. Exact versions and source revisions are in each
target's `run-metadata.json`.

All timings are arithmetic means in seconds. RSS is the maximum resident set
size sampled for the target process during the benchmark.

| Target | GET 64 MiB | PUT 64 MiB | PUT 4 KiB | HEAD | LIST | GET x2 | PUT x2 | Peak RSS KiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| swift-s3-gateway 0.1.0 shared directory | 0.2880 | 0.4432 | 0.3190 | 0.2637 | 0.2677 | 0.3242 | 0.5841 | 15,536 |
| VersityGW 1.7.0 POSIX | 0.4010 | 0.4791 | 0.2801 | 0.2671 | 0.2674 | 0.3561 | 0.5852 | 33,056 |
| S3Proxy 3.3.0 filesystem-nio2 | 0.2944 | 0.4925 | 0.2695 | 0.3335 | 0.2704 | 0.3226 | 0.5050 | 760,160 |
| SeaweedFS 4.40 mini filer | 0.2949 | 0.5984 | 0.3005 | 0.2936 | 0.2921 | 0.3318 | 0.7143 | 1,176,416 |

The storage models are intentionally labeled rather than presented as strictly
equivalent. swift-s3-gateway and VersityGW expose direct local-directory models.
S3Proxy owns a filesystem-nio2 namespace, while SeaweedFS mini mode includes its
filer and supporting services in one process. The S3Proxy RSS includes a JVM and
the SeaweedFS RSS includes the all-in-one service, so those memory figures are
useful operational observations rather than component-normalized comparisons.

The raw Hyperfine samples remain in each `warm-operations.json`. The benchmark
does not claim cold-cache behavior, multi-host scaling, or WAN/TLS performance.

`literal-memory-streaming-gate.txt` separately records the release gate in which
a 33,792 MiB object exceeded the host's 32 GiB physical memory while the gateway
peaked at 16,048 KiB RSS. It is correctness and bounded-memory evidence, not a
throughput comparison.
