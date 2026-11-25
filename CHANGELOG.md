# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-25

### Added
- Quota-aware routing with tiers, daily limits, peak-hour handling and escalation on quota errors.
- Parallel `split`, `dual`, `tri` and `route` modes with per-backend lanes.
- Backend kinds: OpenAI-compatible runner, `agy` CLI, Anthropic-compatible and OpenAI-compatible APIs.
- Run report with attempts, escalations, token usage and estimated cost.
- `scripts/setup.sh` prerequisite check and offline end-to-end test; `AI_SETUP.md` prompt and checklist.
- Architecture diagram, terminal screenshots and rendered sample report.
- CONTRIBUTING, SECURITY, issue templates and `.editorconfig`.

### Changed
- `PEAK_TZ` now defaults to `UTC` (set it to your provider's time zone).
