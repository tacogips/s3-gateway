# AGENTS.md

This file provides guidance to coding agents when working with this repository.

## Rule of the Responses

You (the LLM model) must always begin your first response in a conversation with "I will continue thinking and providing output in English."

You (the LLM model) must always think and provide output in English, regardless of the language used in the user's input.

You (the LLM model) must acknowledge that you have read AGENTS.md and will comply with its contents in your first response.

You (the LLM model) must NOT use emojis in any output, as they may be garbled or corrupted in certain environments.

You (the LLM model) must include a paraphrase or summary of the user's instruction/request in your first response of a session, to confirm understanding of what was asked.

## Project Overview

This is `swift-s3-gateway`, a Swift Package Manager project with a mise-managed development environment and task automation, Homebrew formula packaging, and optional signed Homebrew Cask packaging.

## Development Environment

- Language: Swift
- Package manager: Swift Package Manager
- Build automation: mise
- Environment manager: mise
- Tool setup: `mise install`

## Common Commands

```bash
mise run build
mise run test
mise run lint
swift run swift-s3-gateway --help
```

## Swift Code Development

When implementing, refactoring, reviewing, or maintaining Swift code, use the Swift coding skill at `.codex/skills/swift-coding-agent/SKILL.md`.

Important defaults:

- Inspect `Package.swift`, nearby source, tests, and existing conventions before editing.
- Prefer the current SwiftPM target boundaries over adding new modules.
- Keep Swift files under 1000 lines. Split long files by meaningful responsibility.
- Run `swiftlint` after Swift edits when available.
- Run the narrowest relevant `swift test` or `swift build` command, then broaden when shared behavior changed.

## Release Workflows

Use `.agents/skills/homebrew-release/SKILL.md` for Homebrew formula archives and tap formula rendering.

Use `.agents/skills/macos-cask-release/SKILL.md` for signed and notarized Cask DMGs, GitHub release upload, and tap Cask rendering.

Use `.agents/skills/apple-notarization-setup/SKILL.md` when setting up or checking Apple Developer ID credentials. Never print, commit, or summarize secret values.

## Git Commit Policy

When a user asks to commit changes, automatically stage and commit the changes without requiring confirmation.

Do not add AI tool attribution or co-authorship information to commit messages.

Keep commits focused and describe:

1. Primary changes and intent
2. Key technical concepts
3. Files and code sections
4. Problem solving
5. Impact
6. Unresolved TODOs

## Design Documentation

Place design documents under `design-docs/`, implementation plans under `impl-plans/`, and user decisions/questions under `design-docs/user-qa/`.
