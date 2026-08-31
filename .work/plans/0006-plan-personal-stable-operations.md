---
type: implementation-plan
id: "0006"
title: Personal Stable Image and Recovery Operations
status: in_progress
owner: Codex
research: docs/research/0006-research-personal-stable-operations.md
created: 2026-08-31
updated: 2026-09-01
---

# 0006 Plan: Personal Stable Image and Recovery Operations

> Lifecycle: ephemeral delivery state. Delete this plan after implementation and acceptance are
> complete, once durable decisions and residual work have been transferred to permanent operations
> documentation.

## Goal

Deliver a tracked Windows operations system that builds app and computer images from the latest
pushed `integration/rakazo-dev` commit, runs them as an independent stable personal deployment on
port 5400, creates state recovery points linked to exact image sets, replicates them encrypted to an
optional NAS destination, and restores them through guarded one-click launchers. Source development
on port 5300 and the official reference deployment remain unchanged.

## Agent Contract

Primary agent:

- Role: implement the ordered work items on `ops/versioned-rakazo-recovery` branched from the current
  `integration/rakazo-dev`.
- Must preserve: development scripts and data, release stack and data, existing recovery points,
  feature-branch workflow, and Ollama configuration.
- Must not change: Rakazo product behavior, web/mobile UI, upstream merge policy, existing backup
  contents, or any Docker project/volume outside explicit disposable tests and `rakazo-personal`.
- Ask before: creating live deployment state, installing restic, creating Windows shortcuts,
  accessing a real NAS share, running a destructive restore, importing historical state, or deleting
  any image/volume/recovery point.

Supporting agents:

- research: not delegated; current-machine evidence and private operational context must remain with
  the orchestrator.
- plan-review: orchestrator.
- test: delegate only disposable fixture tests if a subagent environment is available.
- review: independent code-review pass after implementation.
- UI-validation: not applicable to product UI; orchestrator validates launchers and health pages.

## Inputs

Research:

- `docs/research/0006-research-personal-stable-operations.md`

Relevant files:

- `.dockerignore`: add `.local` exclusion.
- `infra/compose/docker-compose.images.yml`: make host web/API ports configurable without changing
  defaults.
- `infra/updater/src/compose-images.test.ts`: preserve Compose-image contract where affected.
- `scripts/windows-dev/`: read-only patterns; behavior must remain unchanged.
- `scripts/windows-ops/`: new common recovery module and fixture tests.
- `scripts/windows-personal/`: new personal lifecycle commands and launcher installer.
- `scripts/windows-release/`: sanitized canonical forms of the existing release backup/restore tools.
- `docs/fork-development-handbook.md` and `docs/fork-development-guide/`: durable operator guidance.

Dependencies:

- Docker Desktop Linux engine and Compose.
- Git and PowerShell 7.
- Restic only for encrypted off-machine replication/retrieval.
- Ollama remains on the Windows host and is not included in image or state archives.

Assumptions:

- Personal stable runs on the same Windows workstation as Docker Desktop and Ollama.
- The NAS path and recovery password are supplied during live initialization, not committed.
- The integration branch is pushed before an image can be promoted to personal stable.

## Scope

Implement:

- Immutable local app and computer images from a clean detached integration worktree.
- Personal stable project `rakazo-personal`: web 5400, API 3300, independent named volumes and `.env`.
- Shared manifest/checksum/image-set/container-ownership module.
- Backup, sync, build-and-deploy, restore, rollback, start, stop, status, and shortcut installation.
- Official/custom image source support through the same configuration interface.
- Canonical, mount-scoped release backup and restore adapters in the fork.
- Disposable integration harness and complete operator documentation.

Do not implement:

- Historical-state import (plan 0007).
- Port-5300 state migration or development workflow changes.
- Automated restoration of development-workshop state; the existing development backup and
  verifier remain available, and personal-stable recovery is implemented independently.
- Registry publishing, NAS-hosted registry, scheduled tasks, automatic upstream merges, or image
  pruning.
- A custom graphical dashboard.

## Product Decisions

Resolved decisions:

| Decision | Choice | Rationale | Evidence |
|---|---|---|---|
| Daily environment | independent `rakazo-personal` on 5400 | separates stable use from workshop/reference | user clarification + research 0006 |
| Build ref | fetched `origin/integration/rakazo-dev` | every deployed image is recoverable from the fork | user workflow + disaster requirement |
| Image naming | `rakazo-personal/{app,computer}:sha-<full-commit>` | immutable provenance and simple rollback | existing SHA workflow pattern |
| Build context | temporary detached worktree | excludes untracked/private data and ignores current feature checkout | `.dockerignore` finding |
| Backup model | state every run, image archive only for a new image set | exact recovery without repeated multi-GB copies | existing release precedent |
| NAS role | optional encrypted replication, never runtime | NAS can sleep without affecting Rakazo | user infrastructure constraint |
| Encryption | restic repository | free, encrypted, authenticated, deduplicated, Windows-capable | official restic docs |
| Restore UX | one-click launcher plus selection, preview, safety backup, typed confirmation | simple entry without silent destruction | recovery risk |
| Official/custom support | same manifest and Compose variables | one deep interface with two real adapters | existing Compose seam |

Open product-level decisions:

| Decision | Options | Recommendation | Impact | Blocks implementation? |
|---|---|---|---|---|
| NAS destination | SMB/local path; rest-server; SFTP | configurable filesystem path first | only live replication setup varies | no |
| Recovery-password custody | password manager; separate physical copy | either, but not workstation-only | disaster readiness cannot be declared until confirmed | no for code; yes for live acceptance |

Planning disposition:

- Finalize with the two deployment-time inputs above; neither changes code architecture.

## Delegation Decision

Disposition:

- Orchestrator implements locally; delegate review/verification only if a suitable isolated agent is
  available.

Reason:

- Docker projects, private local deployment context, and destructive safety boundaries require one
  owner. Parallel code edits would increase cross-stack risk.

Ownership:

- All planned files: orchestrator.
- Final standards/spec review: independent reviewer when available.

Orchestrator local-fix rule:

- Patch only findings within this plan; stop for any requested product change, unplanned data
  migration, registry publication, or real destructive operation.

## Deterministic Work Items

| Step | Task | Files | Output | Depends On | Agent |
|---:|---|---|---|---|---|
| 1 | Create `ops/versioned-rakazo-recovery` from current integration and record baseline health/containers/volumes without mutation | Git metadata, research/plan status | isolated branch and evidence log | none | orchestrator |
| 2 | Define versioned manifest schemas and a common PowerShell module for command execution, hashing, atomic directory publication, image-set identity, secret-safe config parsing, health waits, and appdata-mount ownership | `scripts/windows-ops/Rakazo.Operations.psm1`, schema docs, fixture tests | one deep module used by release and personal adapters | 1 | orchestrator |
| 3 | Harden local build context | `.dockerignore`, build-context test | `.local`, `.env`, backups, logs, and ignored private data cannot enter images | 1 | orchestrator |
| 4 | Make image Compose host ports configurable while preserving 5173/3100 defaults | `infra/compose/docker-compose.images.yml`, existing Compose tests | `RAKAZO_WEB_PORT` and `RAKAZO_API_PORT` overrides | 2 | orchestrator |
| 5 | Implement prerequisite/config initialization for personal stable | `scripts/windows-personal/Test-RakazoPersonalPrerequisites.ps1`, `Initialize-RakazoPersonal.ps1`, templates | ignored deployment config with generated secrets, project `rakazo-personal`, ports 5400/3300, host Ollama URL | 2,4 | orchestrator |
| 6 | Implement custom image builder | `scripts/windows-personal/Build-RakazoPersonalImages.ps1` | fetch integration, resolve pushed full SHA, build in temporary detached worktree, tag app+computer, scan metadata/context, emit checksum-protected image manifest | 2,3 | orchestrator |
| 7 | Implement disposable image smoke-test harness | `scripts/windows-ops/tests/Invoke-PersonalImageSmokeTest.ps1`, fixture Compose/config | generated secrets and unique project/ports/volumes; web/API/supervisor/database health; guaranteed scoped cleanup | 4,6 | orchestrator |
| 8 | Implement personal start/stop/status | `scripts/windows-personal/Start-RakazoPersonal.ps1`, `Stop-RakazoPersonal.ps1`, `Get-RakazoPersonalStatus.ps1` | exact project control and secret-free commit/image/health output | 5,6 | orchestrator |
| 9 | Implement image-set-aware local backup | `scripts/windows-personal/Backup-RakazoPersonal.ps1` | quiesced state snapshot, database dump, appdata archive, `.env`, deployment config, code/image manifests, checksums; image tar only when set is new; atomic completion | 2,8 | orchestrator |
| 10 | Implement encrypted NAS replication and retrieval | `Sync-RakazoPersonalBackups.ps1`, `Get-RakazoPersonalRecoveryPoint.ps1` | restic tagging by recovery/image-set IDs, retryable pending state, `restic check` path, no secret logging | 9 | orchestrator |
| 11 | Implement guarded restore and rollback | `Restore-RakazoPersonal.ps1`, `Rollback-RakazoPersonal.ps1` | list/resolve local or retrieved points, verify, preview, safety backup, typed target confirmation, load images, replace only target state, health verification, retain failure evidence | 9,10 | orchestrator |
| 12 | Implement build-and-deploy orchestration | `Update-RakazoPersonal.ps1` | backup current state, build/reuse exact pushed images, disposable smoke test, switch immutable refs, deploy/migrate, verify, report rollback point; no automatic destructive rollback | 7,9,11 | orchestrator |
| 13 | Consolidate release scripts behind the common module | `scripts/windows-release/Backup-RakazoRelease.ps1`, `Restore-RakazoRelease.ps1`, `Test-RakazoReleaseRecoveryPoint.ps1` | parameterized deployment root/destination; exact project and release-appdata mount scoping; support existing manifests without modifying old recovery points | 2,9,11 | orchestrator |
| 14 | Generate click launchers | `scripts/windows-personal/Install-RakazoPersonalShortcuts.ps1`, generated untracked `.cmd`/`.lnk` files | Backup, Update, Restore, Sync, Start, Stop, Status launchers that retain readable results; installer requires approval | 8-12 | orchestrator |
| 15 | Document setup, ordinary use, image/state distinction, NAS sleep behavior, password custody, disaster bootstrap, and release/reference boundaries | handbook, HTML guide, script READMEs | junior-readable canonical instructions with no personal paths | 5-14 | orchestrator |
| 16 | Run targeted, disposable, broad, safety, and manual verification; perform independent review; update artifacts | tests/review evidence | no blocking findings and no mutation outside disposable/personal scope | all | orchestrator/reviewer |

## Implementation Notes

Required patterns:

- Every mutating Docker command receives explicit context, project, Compose files, and target IDs.
- Dynamic bot selection requires `rakazo.managed=true` and a home mount beneath the target appdata
  mount root. Names and workspace labels are insufficient.
- Publish directories by renaming `.incomplete` only after all checksums/manifests succeed.
- Accept dependencies through the common module's command-runner seam so fixture tests never need
  live Docker.
- Custom tags always contain the full commit; human-friendly aliases may be added only as secondary
  pointers and are never written to recovery manifests.

Data/contracts:

- `image-set.json`: schema version, exact references, IDs/digests, source commit, platform,
  Dockerfiles, creation time, archive path/hash.
- `recovery-point.json`: schema version, deployment kind, created time, Git commit, image-set ID,
  database/appdata/config filenames and hashes, ports/project, replication status.
- `personal-config.json`: ignored, non-secret paths and operational settings.
- `.env`: ignored secrets/provider settings; copied only into private recovery material.

Error handling:

- Fail closed on malformed manifest, checksum mismatch, missing image archive, wrong project, wrong
  mount ownership, unavailable Docker engine, unpushed integration ref, failed smoke test, failed
  pre-update backup, or failed post-deploy health.
- NAS unavailable after a valid local backup is a warning with pending status, not a false failure of
  local capture and not permission to claim disaster readiness.
- Restore cancellation changes nothing.

Logging/telemetry:

- Local timestamped logs only; redact secrets and never print `.env` values or restic password.
- No telemetry or hosted service.

Security/privacy:

- Never add `.env`, config, real paths, NAS names, logs, manifests from live data, image archives, or
  recovery points to Git.
- Restrict local password/config file ACLs to the current Windows user.
- A live restore or shortcut installation requires explicit user approval at execution time.

Documentation/comment conventions:

- Public commands include comment-based help, examples with placeholders, destructive behavior,
  exit semantics, and target project.
- Plain-English documentation leads; implementation terms follow.

## Test Strategy

Commands:

```powershell
# Parser and fixture tests
.\scripts\windows-ops\tests\Test-RakazoOperations.ps1

# Repository checks through the pinned toolchain
corepack pnpm lint
corepack pnpm check
corepack pnpm build

# Disposable Docker integration test; must use a generated project name
.\scripts\windows-ops\tests\Invoke-RakazoPersonalRecoveryIntegration.ps1
```

Unit tests:

- Identical image records produce identical set IDs; any ID/digest/reference change changes the ID.
- Path containment rejects repository root, deployment root misuse, traversal, and ambiguous mounts.
- Mixed release/development/personal bot fixtures select only the requested appdata root.
- Secret parser round-trips values without logging them.
- Manifest verifier rejects missing, extra-required, malformed, and tampered files.
- Recovery selector sorts deterministically and never silently substitutes another point.

Integration tests:

- Build from a detached commit while a fake `.local/secret-sentinel.txt` exists in the live checkout;
  prove it is absent from build context and image.
- Start disposable custom image stack, create fixture database/appdata state, back up, alter, restore,
  and verify exact fixture state.
- Remove disposable image tags, load image archive, and recover without registry pulls.
- Run with a missing NAS destination, confirm pending status, expose a local restic fixture, sync,
  retrieve, and verify.
- Place non-target managed bot fixtures beside the test stack and prove no command addresses them.

Regression tests:

- Record and compare 5200 and 5300 health before/after disposable tests.
- `git diff` proves no changes to development lifecycle scripts except intentional documentation
  references.

Manual checks:

- Generated launchers open, show the exact action/result, and retain failures.
- Personal status identifies commit and images without secrets.
- Update refuses an unpushed commit and succeeds with a pushed integration commit.
- Restore cancel path is non-mutating; confirmed restore requires the exact target phrase.

Verification freshness:

- Rebuild custom images after any Dockerfile/build-script change; do not rely on an old tag.

## UI Validation Hooks

No Rakazo UI implementation changes. Manual browser checks:

- 5400: sign-in page and authenticated personal workflow after initialization.
- 5300: existing development conversation remains available.
- 5200: reference responds when it was running before the test.

Pass conditions:

- no port/project/volume overlap;
- launcher output remains readable;
- exact deployed commit visible in status/health evidence;
- no product UI regression.

## Review Gates

Gate 1: Scope Review

- [x] Only planned files changed
- [x] Historical import and development state untouched
- [x] No registry/scheduler/pruning scope added

Gate 2: Code Review

- [x] Every Docker mutation has exact context/project/resource ownership
- [x] Error and interruption paths preserve completed backups and prior image references
- [x] No secrets/private paths/data added
- [x] Common module removes duplication without hiding target identity
- [x] Public scripts have help and safe defaults

Gate 3: Test Review

- [x] Parser, unit, fixture, image smoke, and disposable recovery tests pass
- [x] Tamper and wrong-stack tests fail closed
- [x] Fresh images were tested
- [x] 5200/5300 regression evidence is clean

Gate 4: Operations Review

- [ ] Backup, update, restore, sync, status, cancellation, and failure launchers exercised on the live
  personal deployment; this remains approval-gated.
- [x] Independent recovery password requirement is explicit
- [x] NAS-unavailable behavior is truthful

## Acceptance Criteria

- [x] Latest pushed integration commit builds into immutable local app and computer images.
- [x] Images contain no live-checkout `.local`, `.env`, backup, log, or private sentinel content.
- [ ] Personal stable runs independently on 5400/3300 as `rakazo-personal`.
- [x] Backup implementation always creates state and saves images only for a new set; live shortcut
  exercise remains approval-gated.
- [x] Update implementation performs prebackup, build/reuse, disposable smoke test, deployment, and health
  verification without touching development/reference.
- [x] Disposable restore recovers database, appdata, `.env`, deployment config, and images without a
  registry, after preview and typed confirmation.
- [x] Missing NAS produces a pending-replication result; per-point retry and retrieval are covered by
  offline fixtures. A live NAS sync remains approval-gated.
- [x] Official and custom image sets pass the same verifier/restore logic.
- [x] Canonical release scripts are stored in the fork and target only release-owned resources.
- [ ] All checks and review gates pass; live initialization remains unperformed until approved.

## Rollback Plan

- Revert tracked operations commits; source development and release files remain unchanged.
- Stop/remove only project `rakazo-personal` after explicit approval; preserve its volumes and local
  recovery points by default.
- Restore the pre-update personal recovery point and recorded image set through confirmed rollback.
- Remove generated shortcuts only through the installer with explicit approval.

## Loop Status

| Loop | Status | Agent | Action | Evidence | Next |
|---:|---|---|---|---|---|
| 1 | complete | orchestrator | implemented common contracts and safety fixtures | 9 offline checks passed; 25 PowerShell files parsed | targeted Docker checks |
| 2 | complete | orchestrator | implemented personal image/deploy/backup/recovery adapters | repeatable image IDs, image smoke, state recovery, and no-registry archive round-trip passed | final regression checks |
| 3 | complete | reviewers + orchestrator | closed standards/spec/safety findings | restore safety backups fail closed; historical checksum coverage is mandatory; active manifests are validated; replication is per point; retrieved points enter the Restore catalogue; reparse escapes are rejected | user reviews branch before live activation |

## Final Handoff

Changed files:

- Configurable image-Compose ports and updater contract tests.
- Shared Windows operations module, offline/disposable verification harnesses, personal lifecycle,
  encrypted replication/retrieval, guarded recovery, release adapters, and launcher installer.
- Junior-facing handbook and HTML guide plus permanent research and follow-up import plan.

Verification run:

- PowerShell parser: 25 files passed.
- Offline safety suite: 9 passed, including checksum tamper, ownership, atomic publication,
  interrupted per-point replication, retrieval/import, and junction rejection.
- Historical release verifier passed against an existing image-set backup.
- Fresh custom images built twice with unchanged image IDs; disposable image smoke, state
  backup/alter/restore, and no-registry archive round-trip passed.
- `pnpm lint`, `pnpm check`, and `pnpm build` passed. Lint reports two pre-existing informational
  notices in `packages/core/src/events.test.ts`.
- The full product test run completed with unrelated pre-existing Windows/path failures; the changed
  Compose contract suite passed 6/6.
- Ports 5200 and 5300 returned HTTP 200 after disposable tests; no personal/disposable containers
  remained.
- Two independent review passes found no blockers after fixes.

Known residual risk:

- Live NAS transport and password custody require deployment-owner input and an approved live drill.

Artifacts:

- Research status: complete
- Durable decisions transferred to product documentation or ADRs: complete in the operations
  handbook and script READMEs
- Residual work transferred to the repository's normal tracker: historical migration remains plan
  0007; live activation remains an explicit owner-approved operation
- Plan deleted after acceptance or explicitly retained: retain until implementation acceptance
- Stale sections removed or updated: yes

Ready for:

- final review and user acceptance; live personal/NAS initialization remains approval-gated
