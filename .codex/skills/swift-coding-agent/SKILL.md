---
name: swift-coding-agent
description: Use when implementing, refactoring, reviewing, or maintaining Swift code in this SwiftPM project. Enforces SwiftLint execution when available, splits Swift files over 1000 lines by responsibility, and guides maintainable Swift design using local package conventions, tests, and Swift idioms.
---

# Swift Coding Agent

## Core Workflow

1. Inspect the project before editing:
   - Read `Package.swift`, nearby source, tests, `.swiftlint.yml` if present,
     `Taskfile.yml`, and CI workflows if present.
   - Match local naming, access control, dependency injection, error handling,
     concurrency style, and formatting.
   - Use `rg --files -g '*.swift'` and `wc -l` to identify Swift files over
     1000 lines.

2. Plan changes around existing boundaries:
   - Prefer current SwiftPM targets over new modules.
   - Keep behavior changes narrow unless broader redesign is requested.
   - Preserve public API compatibility unless a breaking change is requested.

3. Implement with maintainability as a hard requirement:
   - Apply DRY, single responsibility, cohesive types, and testable boundaries.
   - Use value types and `let` by default.
   - Model closed string domains with enums when doing so prevents invalid
     states at behavioral boundaries.
   - Avoid force unwraps, implicitly unwrapped optionals, global mutable state,
     hidden singletons, and broad catch-all error swallowing.
   - Prefer dependency injection for clocks, file systems, network clients,
     persistence, and external processes when tests need determinism.

4. Verify:
   - Run SwiftLint after Swift edits when available.
   - Run the narrowest relevant test/build command, then broaden if shared
     behavior changed.
   - Fix lint, compile, and test failures caused by the work before handing off.

## SwiftLint

Always try to run SwiftLint for Swift code changes:

```bash
swiftlint
```

When using the Nix shell on macOS with Xcode's Swift toolchain, prefer:

```bash
nix develop -c bash -lc 'export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; export SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk; export TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault; export PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH; swiftlint'
```

If SwiftLint is unavailable, report that clearly and still run available Swift
formatting, build, and tests.

## Splitting 1000+ Line Files

Treat any non-generated Swift file over 1000 lines as a refactoring target.
Split by meaningful responsibility:

- One primary type per file when practical.
- Related small types grouped by responsibility.
- Substantial protocol conformances in named extension files.
- Separate UI composition, state, domain logic, persistence, networking,
  parsing, and test fixtures when they have distinct reasons to change.

Preserve access control where possible. Prefer keeping encapsulation strong over
widening access after a move.

## Validation Commands

Choose commands from project evidence:

```bash
swift test
swift build
task test
task build
```

In final responses, report exact lint/build/test commands run and any commands
that could not run.
