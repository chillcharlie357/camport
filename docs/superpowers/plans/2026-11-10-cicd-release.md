# CI/CD Release Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this bounded plan. Subagents are currently unavailable due to usage limits; complete and review locally.

**Goal:** Automatically verify PRs and publish versioned Android/macOS/Windows artifacts after a PR merges to main, with iOS compilation checked.

**Architecture:** Shared Flutter setup and reusable build workflow. CI performs checks; main-push release workflow confirms the associated merged PR, allocates deterministic version metadata, calls checks/builds, then publishes complete assets.

**Tech Stack:** GitHub Actions, gh CLI, Python standard library, Flutter 3.47.5, Java 17.

## Tasks

- [x] Add `tool/release.py` and `tool/tests/test_release.py`; verify missing implementation first, then check event fixtures, version bounds, draft retries, tag ownership and complete asset publication. Twelve tests pass locally, including annotated tag resolution.
- [x] Add `.github/actions/setup-flutter/action.yml` and reusable `.github/workflows/build.yml`; implement signed Android release, macOS archive plus iOS no-sign compile, and Windows complete bundle archive. Native build results are tracked separately below.
- [x] Add `.github/workflows/ci.yml` and `release.yml`; verify read-only PR execution, merged-main commit gating, scoped signing secrets and publish-only write permissions. Actionlint passes locally.
- [x] Configure stable Android signing with ignored private backup and repository secrets. Check workflow syntax, release logic, formatting, analysis and 41 Flutter tests locally.
- [x] Commit changes and update existing PR #1. Remote results are recorded in the PR's Actions checks. The first post-merge Release has not run; do not merge the app PR just to test publication.
- [ ] Confirm the final commit's native build results in GitHub Actions; no native build success is implied by local static checks.
