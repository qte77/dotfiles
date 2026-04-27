# Contributing

Development workflows, coding standards, and collaboration guidelines.

## Quick Start

1. Fork and clone the repository
2. Create a feature branch from `main`
3. Make your changes
4. Run validation (lint, type check, tests as applicable)
5. Submit a pull request

## Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/) format:

```text
type[(scope)][!]: description
```

**Types**: `feat` | `fix` | `docs` | `refactor` | `test` | `ci` | `build` | `perf` | `style` | `revert` | `chore`

**Breaking changes**: append `!` after type, e.g. `feat!:` or `feat(scope)!:`

## Code Standards

- Follow existing codebase patterns and conventions
- Write concise, focused code — no unnecessary features
- Use absolute imports where applicable
- Add inline `# Reason:` comments for complex logic explaining the *why*

## Testing

- Write tests for new features and bug fixes
- Mock external dependencies in unit tests
- Test real integrations during development, then mock for CI
- Tests must pass before merging

## Pre-Commit Checklist

1. Code formatted and linted
2. Type checks pass (if applicable)
3. Tests pass
4. `CHANGELOG.md` updated under `## [Unreleased]` (for non-trivial changes)
5. Documentation updated as needed

## Pull Requests

- Use the [PR template](.github/PULL_REQUEST_TEMPLATE.md)
- Keep PRs focused — one concern per PR
- Provide a clear summary of changes and testing performed

## Documentation

- Update `CHANGELOG.md` for user-facing changes
- Update `README.md` for setup or usage changes
- Update `CONTRIBUTING.md` for workflow or standards changes

## CHANGELOG Guidelines

**Requires entry**: new features, breaking changes, bug fixes, dependency updates, config changes

**No entry needed**: typo fixes, formatting, internal refactoring, test-only changes

**Format**: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) with sections:
`Added` · `Changed` · `Deprecated` · `Removed` · `Fixed` · `Security`
