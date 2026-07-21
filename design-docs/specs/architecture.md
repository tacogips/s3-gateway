# Architecture

## Status

Draft

## Overview

`swift-s3-gateway` is a Swift Package Manager project with a
library target, an executable target, tests, and release automation for Homebrew.

## Targets

- `AppCore`: domain and command logic
- `AppCLI`: command line entry point
- `AppCoreTests`: package tests

## Release Surfaces

- Homebrew formula archives under `dist/homebrew/`
- Signed and notarized Cask DMGs under `dist/homebrew-cask/`
