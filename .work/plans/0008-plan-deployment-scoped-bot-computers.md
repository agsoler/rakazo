---
type: implementation-plan
id: "0008"
title: Deployment-Scoped Bot Computers
status: complete
owner: Codex
research: docs/research/0008-research-deployment-scoped-bot-computers.md
created: 2026-09-01
updated: 2026-09-01
---

# 0008 Plan: Deployment-Scoped Bot Computers

> Lifecycle: ephemeral delivery state. Delete this plan after implementation and acceptance are
> complete, once durable decisions and residual work have been transferred to permanent documents.

## Goal

Add optional deployment identity to Docker bot computers so release, development, and personal
stable can contain cloned bot/workspace IDs without sharing containers or networks; then build and
deploy an empty personal-stable stack from the protected integration commit.

## Agent Contract

Primary agent:

- Role: implement, verify, integrate, and deploy the empty personal stack.
- Must preserve: official 5200 containers/data, development data, legacy behavior when configuration
  is absent, and all unrelated worktree changes.
- Must not change: product UI, bot behavior above the sandbox seam, release state, or upstream PRs.
- Ask before: restoring release data into personal stable or decommissioning any deployment.

Supporting agents:

- None. The user did not request delegation; the orchestrator owns the tightly coupled lifecycle
  change. A separate local review pass is required after implementation.

## Inputs

Research:

- `docs/research/0008-research-deployment-scoped-bot-computers.md`

Relevant files:

- `infra/sandboxes/supervisor/src/computer-spec.ts`: pure identity/name helpers.
- `infra/sandboxes/supervisor/src/index.ts`: Docker discovery and lifecycle.
- `infra/sandboxes/supervisor/src/computer-spec.test.ts`: deterministic unit coverage.
- `infra/compose/docker-compose.yml`: optional source configuration pass-through.
- `infra/compose/docker-compose.images.yml`: optional image configuration pass-through.
- `scripts/windows-dev/docker-compose.dev.yml`: existing-env development default.
- `scripts/windows-dev/Initialize-RakazoDev.ps1`: new development configurations.
- `scripts/windows-personal/Initialize-RakazoPersonal.ps1`: personal identity.
- `scripts/windows-ops/Rakazo.Operations.psm1`: recovery ownership enforcement.
- `scripts/windows-ops/tests/Test-RakazoOperations.ps1`: operational regression coverage.

Dependencies:

- Docker Engine, Docker Compose, dockerode, Vitest, and PowerShell 7.

Assumptions:

- `rakazo-dev` and `rakazo-personal` are distinct deployment IDs.
- The official reference remains unscoped until it is later decommissioned and rebuilt.

## Scope

Implement:

- Optional `RAKAZO_DEPLOYMENT_ID` validation and propagation.
- `rakazo.deployment` label and scoped container/network naming.
- Exact deployment matching for every supervisor operation.
- Exact-home legacy adoption and recreation.
- Scoped network cleanup and operations ownership checks.
- Local documentation and automated tests.
- Merge to integration, immutable rebuild, empty 5400 deployment, and initial personal backup.

Do not implement:

- Compose-label impersonation or Docker Desktop stack grouping.
- Release-to-personal data restore.
- Release decommissioning.
- Upstream contribution.

## Product Decisions

Resolved decisions:

| Decision | Choice | Rationale | Evidence |
|---|---|---|---|
| Compatibility | Configuration is optional; absent keeps legacy names | Official 5200 cannot change before migration | User decision and research 0008 |
| Scope identity | `RAKAZO_DEPLOYMENT_ID` / `rakazo.deployment` | Identifies one deployment rather than a broad environment class | Research 0008 |
| Adoption | Exact home bind only, then recreate | Labels are immutable and another deployment may share IDs | Research 0008 |
| Publication | Fork integration only | User explicitly declined upstream contribution | User decision |
| Migration | Separate explicit gate | Restore replaces personal state | User decision |

Open product-level decisions: none.

Planning disposition:

- Proceed with implementation.

## Delegation Decision

Disposition:

- Orchestrator implements locally.

Reason:

- Identity, lookup, migration compatibility, network cleanup, operations ownership, and live
  deployment are tightly coupled; splitting them would increase integration risk.

Ownership:

- All listed files: orchestrator.

Orchestrator local-fix rule:

- Patch only blocking findings within the listed lifecycle/configuration/test surface.

## Deterministic Work Items

| Step | Task | Files | Output | Depends On | Agent |
|---:|---|---|---|---|---|
| 1 | Add validated optional deployment identity and pure matching/naming helpers | `computer-spec.ts` | Legacy-compatible helpers | none | implement |
| 2 | Apply identity to create, lookup, authorization, adoption, network creation, and cleanup | `index.ts` | Cross-deployment isolation | 1 | implement |
| 3 | Configure development and personal supervisors | Compose files and initializers | `rakazo-dev` / `rakazo-personal` identities | 1 | implement |
| 4 | Strengthen operational ownership checks | operations module/tests | Label + mount-root enforcement | 1 | implement |
| 5 | Add deterministic unit and configuration tests | supervisor/operations tests | Regression coverage | 1-4 | test |
| 6 | Run targeted checks, lint, typecheck, build, and relevant broad tests | repository | Classified verification evidence | 5 | test |
| 7 | Review scope, security, DRY, compatibility, and secrets | all changed files | No blocking findings | 6 | review |
| 8 | Commit/push local branch and fast-forward integration | Git branches | Pushed protected integration commit | 7 | implement |
| 9 | Validate release recovery point, rebuild immutable personal images, and deploy empty 5400 | Windows personal scripts | Healthy isolated personal stack | 8 | implement |
| 10 | Verify three-environment isolation and create initial personal recovery point | Docker/health/backup scripts | Verified empty baseline; migration not started | 9 | test |

## Implementation Notes

Required patterns:

- Keep one deployment parser and one deployment-label matcher in `computer-spec.ts`.
- Pass the deployment ID into existing creation and network helpers; do not duplicate naming logic.
- Match unscoped supervisors only to unlabelled containers.
- When scoped lookup finds no scoped container, consider an unlabelled candidate only if its exact
  `/home/rakazo` source equals the requested host home; force recreation before use.
- Never add reserved `com.docker.compose.*` labels to dynamic bot containers.

Data/contracts:

- Environment variable: `RAKAZO_DEPLOYMENT_ID`, optional, lowercase Docker-safe identifier.
- Container label: `rakazo.deployment`, present only when configured.

Error handling:

- Invalid non-empty IDs fail supervisor startup with a clear error.
- Another deployment's container is treated as not found.

Security/privacy:

- No secret values, private paths, recovery content, or real hostnames in tracked files.
- Container authorization requires bot, workspace, and deployment identity.

Documentation/comment conventions:

- Document optional configuration and legacy behavior in templates and local operational guides.

## Test Strategy

Commands:

```powershell
corepack pnpm --filter @rakazo/sandbox-supervisor test
corepack pnpm --filter @rakazo/sandbox-supervisor check
& .\scripts\windows-ops\tests\Test-RakazoOperations.ps1
corepack pnpm lint
corepack pnpm check
corepack pnpm build
```

Unit tests:

- Unset identity preserves exact existing names/labels/networks.
- Scoped identities produce distinct names, labels, and networks for the same bot ID.
- Scoped and unscoped matchers reject each other.
- Exact-home matching permits only same-deployment legacy adoption.
- Scoped cleanup never lists unscoped network names.

Integration tests:

- Rendered Compose configuration contains the expected development and personal identity.
- Operations ownership rejects a mismatched `rakazo.deployment` label.
- Personal build script's disposable deployment passes health checks.

Regression tests:

- Existing unconfigured release behavior remains unchanged.
- Existing Windows supervisor baseline failures are classified, not attributed to this patch.

Manual checks:

- Docker container and network names visibly contain the configured deployment after first use.
- Ports 5200, 5300, and 5400 answer independently after deployment.
- No 5200 container, volume, or file is changed by personal operations.

Verification freshness:

- Build after the final code change before live image generation.

## Review Gates

Gate 1: Scope Review

- [x] Only planned files changed
- [x] Non-goals untouched
- [x] Dependencies confirmed

Gate 2: Code Review

- [x] Existing patterns followed
- [x] Error paths handled
- [x] No secrets/private data added
- [x] Legacy behavior is explicit and tested
- [x] No reserved Compose labels forged

Gate 3: Test Review

- [x] Required targeted commands pass or baseline failures are unchanged and classified
- [x] New behavior covered
- [x] Build is fresh before image creation

Gate 4: Deployment Review

- [x] Release recovery point validates
- [x] Disposable personal stack passes
- [x] 5200 and 5300 remain healthy
- [x] Empty 5400 backup completes
- [x] Release-state migration has not started

## Acceptance Criteria

- [x] Same bot/workspace IDs cannot cross legacy, development, and personal deployments.
- [x] Unset identity preserves legacy resource names.
- [x] Development and personal identities are configured without editing private existing files.
- [x] Protected integration commit is pushed.
- [x] Empty personal stable is healthy on the suggested port 5400.
- [x] Initial personal recovery point exists and 5200 remains untouched.
- [x] Review has no blocking findings.

## Rollback Plan

- Stop only `rakazo-personal` using the tracked personal script.
- Revert the local feature commit from integration if tests expose a code regression.
- Leave 5200 and its recovery point unchanged.
- Existing unscoped containers retain their data in deployment-owned home mounts.

## Loop Status

| Loop | Status | Agent | Action | Evidence | Next |
|---:|---|---|---|---|---|
| 1 | complete | Codex | implement scoped lifecycle and tests | targeted identity tests and 9 operations tests pass | live verification |
| 2 | complete | Codex | review and deploy empty personal stable | image smoke test, three HTTP 200 responses, verified recovery point | separate migration decision |

## Final Handoff

Changed files:

- Supervisor identity, lookup, naming, network, and legacy-adoption logic with unit tests.
- Compose propagation and Windows development/personal initialization, update, restore, backup, and
  ownership checks.
- Operator READMEs, handbook, and interactive guide.
- Windows supervisor compatibility patch refreshed after the new constant changed its context.

Verification run:

- Baseline operations tests: 9 passed.
- Targeted deployment tests: 4 passed.
- Lint, repository type-check, and repository build: passed with repository-pinned pnpm 9.15.0.
- Supervisor suite on Windows: 67 passed, 3 unrelated baseline platform-sensitive failures, 3
  skipped. Failures remain in existing shell/process/symlink tests.
- Repository unit suite: 2,008 passed; 28 unrelated Windows/environment-sensitive failures.
- Disposable personal image smoke test: passed.
- Release recovery point `20260901-010315`: verified without restoration.
- Ports 5200, 5300, and 5400: HTTP 200 concurrently.
- Empty personal recovery point: verified and linked to image set
  `sha256-a4049e237c4edb1363c82483104eddfe789e9f68432533d5e5c8d5599ec7122f`.

Known residual risk:

- Release-state migration remains intentionally deferred.

Artifacts:

- Research status: complete
- Durable decisions transferred to product documentation or ADRs: yes, in research 0008 and the
  operator documentation
- Residual work transferred to the repository's normal tracker: not applicable
- Plan deleted after acceptance or explicitly retained: retained as implementation evidence until
  the user accepts the deployment
- Stale sections removed or updated: yes

Ready for:

- a separately approved migration of the 5200 recovery point into personal stable
