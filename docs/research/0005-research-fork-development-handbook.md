---
type: research
id: "0005"
title: Fork Development Handbook and Recovery Guide
status: complete
owner: Codex
created: 2026-08-31
updated: 2026-08-31
---

# 0005 Research: Fork Development Handbook and Recovery Guide

## Objective

Document the complete Windows development environment, make its reusable helpers recoverable from
the GitHub fork, and teach a new developer how to build, run, update, back up, and reconstruct the
port-5300 environment without endangering the release deployment on port 5200.

## Scope

In scope:

- Git remotes and branch responsibilities.
- Windows, Docker Desktop, Ollama, Node, pnpm, and PowerShell dependencies.
- Development service topology and ports.
- Tracked startup helpers and secret-free environment initialization.
- Build, test, troubleshooting, backup, and disaster-recovery guidance.
- A self-contained Markdown handbook and offline HTML SPA.

Out of scope:

- Changing Rakazo product behaviour.
- Moving, updating, or stopping the release deployment.
- Committing `.env`, database contents, bot files, logs, or backups.
- Automating destructive restore operations.

## Current State

Key files:

- `package.json`: Node range, pinned pnpm version, and build/test commands.
- `infra/compose/docker-compose.yml`: PostgreSQL and sandbox-supervisor development services.
- `.local/*.ps1`: working Windows helpers that are currently excluded from Git.
- `.local/docker-compose.dev.yml`: Windows bind-mount override for development bot data.
- `.local/windows-supervisor.patch`: Windows client-path translation needed by the containerized
  supervisor on the current branch.
- The release installation's `BACKUP-RESTORE.md`: separate published-image release backup strategy.

Existing behaviour:

- Source web/API/worker processes run on Windows; PostgreSQL and the supervisor run in Docker.
- Development uses web 5300, API 3200, PostgreSQL 5433, supervisor 7091, Ollama 11434, and Compose
  project `rakazo-dev`.
- Release uses web 5200 and Compose project `rakazo`; both environments are currently healthy and
  isolated.
- Development PostgreSQL persists in Docker volume `rakazo-dev_pgdata`.
- Development bot files persist under ignored `.local/data`.
- The integration branch and all feature branches are pushed to the public fork.

Known constraints:

- `.env` contains encryption and authentication secrets and must never enter Git.
- `.local/` is excluded through `.git/info/exclude`, so its current scripts do not survive a clone.
- A GitHub fork recovers code and branch history, not databases, Docker volumes, bot files, model
  downloads, local configuration, or secrets.
- Documentation committed to this public repository must not contain personal filesystem paths or
  real credentials.

## Dependencies

Runtime:

- Windows with PowerShell 7.
- Git.
- Node matching the effective lockfile requirement: 22.22.2+, 24.15.0+, or 26+ (excluding odd
  major versions 23 and 25).
- Corepack with repository-pinned `pnpm@9.15.0`.
- Docker Desktop using Linux containers and Docker Compose.
- Ollama with at least one configured model.

Internal:

- `turbo dev`: starts web, API, and worker source processes.
- Prisma: generates the client and migrates PostgreSQL.
- Docker sandbox images: provide persistent bot computers.

External:

- GitHub hosts the fork and upstream repository.
- Ollama exposes an OpenAI-compatible endpoint at `http://127.0.0.1:11434/v1`.

## Findings

1. The software and the user data have different recovery mechanisms.
   Evidence: Git tracks source; PostgreSQL uses `rakazo-dev_pgdata`; bot files use `.local/data`.
   Impact: the guide must state plainly that a fork-only recovery creates an empty Rakazo instance.

2. Release and development are isolated by names, ports, and storage.
   Evidence: Compose projects `rakazo` and `rakazo-dev`, distinct PostgreSQL volumes, and ports 5200
   versus 5300.
   Impact: tracked helpers must always pass `-p rakazo-dev` and never issue broad Docker cleanup.

3. The functional Windows helpers are not recoverable from GitHub.
   Evidence: `git check-ignore -v .local/Start-RakazoDev.ps1` resolves to `.git/info/exclude`.
   Impact: sanitized helpers and the supervisor patch must move to a tracked directory.

4. The development environment is a hybrid rather than an all-container deployment.
   Evidence: source processes listen on 5300 and 3200; Docker runs PostgreSQL, supervisor, and bot
   computers.
   Impact: documentation must distinguish `pnpm build`, `turbo dev`, and the published-image release.

5. Existing release backups are comprehensive but local to the release installation.
   Evidence: the release backup captures database, appdata, configuration, image manifests, and
   checksums under its local `backups` directory.
   Impact: a real disk-loss plan requires copying recovery points to another physical device or
   encrypted remote storage.

6. A Windows machine can silently mix Node and pnpm installations.
   Evidence: the active Node was compatible, while a system Corepack and nested global pnpm resolved
   older or newer incompatible tools during a clean startup.
   Impact: tracked helpers resolve Corepack beside the active Node and create repository-local pnpm
   9.15.0 shims under ignored `.local/run` for every nested process.

## Existing Patterns To Reuse

- `.local/Start-RakazoDev.ps1`: health checks, dependency preparation, migrations, image build, and
  background process management.
- `.local/Stop-RakazoDev.ps1`: PID ownership validation and project-scoped Docker stopping.
- `.local/Build-WindowsSupervisor.ps1`: detached worktree prevents the compatibility patch from
  contaminating feature diffs.
- The release installation's `BACKUP-RESTORE.md`: plain-English explanation and layered recovery
  vocabulary.

## Decisions Needed

| Decision | Options | Recommendation | Blocking? |
|---|---|---|---|
| Where should reusable Windows helpers live? | ignored `.local`; tracked `scripts/windows-dev` | Track code under `scripts/windows-dev`; retain `.local` only for mutable state | no |
| Should secrets be recoverable from Git? | commit them; generate them; restore secure backup | Generate for a fresh empty install or restore from a separate encrypted backup; never commit | no |
| Should this add automated destructive restore? | yes; documentation only | Documentation only; restore automation needs a separate, testable safety initiative | no |
| How should the HTML guide run? | framework build; hosted route; offline static SPA | Offline dependency-free SPA that works by opening `index.html` | no |

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---:|---:|---|
| A command addresses the release stack | low | high | Hard-code Compose project `rakazo-dev`; document stop-and-check rules |
| Secrets enter Git | low | high | Use generated placeholders; inspect staged diff and tracked files |
| Guide becomes stale | medium | medium | Point to `package.json` and `.env.example` as sources of truth; include verification commands |
| Fork-only recovery is mistaken for data recovery | medium | high | Use a prominent recovery matrix and explicit “empty instance” warning |
| Offline guide fails under `file://` | low | medium | No modules, fetches, remote fonts, or external assets; browser validation on file URL |

## Test Surface

Unit:

- PowerShell parser validation for every tracked helper.
- JavaScript syntax validation for the SPA.

Integration:

- Stop and start the isolated development environment through tracked helpers.
- Verify HTTP 200 from web 5300 and API 3200.
- Confirm release web 5200 remains healthy.

UI:

- Open the SPA from a local file.
- Navigate every section, copy a command, toggle the release overlay, and persist checklist state.

Regression:

- The release Compose project and volumes remain untouched.
- Existing feature branches and integration history remain unchanged except for this initiative.

## UI Validation Hooks

Screens/routes:

- `docs/fork-development-guide/index.html`: overview, setup, workflow, build, recovery, glossary.

Selectors/test ids needed:

- `[data-route]`: navigation.
- `[data-copy]`: command copy controls.
- `#show-release`: architecture overlay.
- `[data-check]`: persistent checklist items.

Viewports:

- desktop: 1440x1000
- mobile: 390x844

Visual states:

- initial overview;
- selected navigation section;
- release overlay on/off;
- recovery scenario comparison;
- keyboard focus;
- mobile navigation.

## Acceptance Criteria Inputs

The implementation must satisfy:

- A new developer can reconstruct an empty port-5300 environment from the fork.
- The guide clearly separates software recovery from state recovery.
- Required local helper code is tracked, portable, and secret-free.
- Development operations cannot target the release Compose project by default.
- The Markdown and SPA explain the same architecture and recovery model.
- The SPA works offline and is usable at desktop and mobile widths.

## Open Questions

| Question | Owner | Needed By | Status |
|---|---|---|---|
| Should development backup/restore automation be added? | Future initiative | After the documented manual process is reviewed | deferred |

## Loop Status

| Loop | Agent | Goal | Result | Next |
|---:|---|---|---|---|
| 1 | Codex | Map current setup and recovery boundaries | Complete | Implement handbook, helpers, and SPA |
| 2 | Codex | Implement and verify the recovery-ready developer experience | Complete | Commit and maintain with the fork |
