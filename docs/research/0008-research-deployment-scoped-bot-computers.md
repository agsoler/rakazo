---
type: research
id: "0008"
title: Deployment-Scoped Bot Computers
status: complete
owner: Codex
created: 2026-09-01
updated: 2026-09-01
related_plan: .work/plans/0008-plan-deployment-scoped-bot-computers.md
---

# 0008 Research: Deployment-Scoped Bot Computers

## Objective

Define a backwards-compatible local deployment identity so an official reference installation,
source development, and personal stable can run on one Docker daemon without sharing bot containers
or per-bot networks.

## Scope

In scope:

- Docker supervisor container discovery, creation, resume, deletion, and network cleanup.
- Development and personal-stable configuration.
- Backup and restore ownership checks.
- Local-only fork integration and an empty personal-stable deployment.

Out of scope:

- An upstream pull request.
- Docker Compose ownership or visual grouping of dynamic bot containers.
- Restoring release state into personal stable.
- Decommissioning the official reference deployment.

## Current State

Key files:

- `infra/sandboxes/supervisor/src/computer-spec.ts`: bot container labels and names, plus per-bot
  network names.
- `infra/sandboxes/supervisor/src/index.ts`: global Docker lookup, identity checks, lifecycle, and
  network cleanup.
- `infra/compose/docker-compose.yml`: source supervisor configuration.
- `infra/compose/docker-compose.images.yml`: image-based supervisor configuration.
- `scripts/windows-personal/Initialize-RakazoPersonal.ps1`: ignored personal environment creation.
- `scripts/windows-ops/Rakazo.Operations.psm1`: backup and restore ownership checks.

Existing behavior:

- Bot containers are labelled with `rakazo.managed`, `rakazo.botId`, and `rakazo.workspaceId`.
- Lookup searches the entire Docker daemon using only bot and workspace IDs.
- Container and isolated-network names derive only from the bot ID.
- Dynamic bot containers are created through Docker Engine, not Compose.

Known constraints:

- A release-state restore copies bot and workspace IDs into personal stable.
- Container labels are immutable; adopting an old unscoped container requires recreation.
- The official reference image cannot be changed before migration and must retain legacy behavior.
- Tracked content must contain no private paths, secrets, or real recovery data.

## Dependencies

Runtime:

- Docker Engine through `dockerode`.
- Docker Compose for the supervisor, database, and application stack only.

Internal:

- `containerCreateOptions`: one creation seam for every Docker bot computer.
- `findBotContainer` and `isRakazoContainer`: identity and authorization seam.
- `computerNetworkNameFor` and `computerNetworkNamesForCleanup`: network lifecycle seam.
- `Test-RakazoBotOwnership`: operational backup and restore ownership seam.

External:

- Docker reserves the `com.docker.*` label namespace; dynamic containers should retain Rakazo-owned
  labels instead of masquerading as Compose services.

## Findings

1. Matching only bot and workspace IDs is unsafe after a state clone.
   Evidence: `findBotContainer` filters only `rakazo.botId` and `rakazo.workspaceId`.
   Impact: two deployments with cloned IDs can operate the same container.

2. Names and networks also collide after a state clone.
   Evidence: `containerNameFor` and `computerNetworkNameFor` accept only `botId`.
   Impact: a second deployment cannot safely create an independent computer and may share an
   isolation network.

3. The exact home bind mount can identify a legacy container during migration.
   Evidence: every bot computer mounts one deployment-owned home at `/home/rakazo`; existing
   operations code already verifies that mount against the expected app-data root.
   Impact: a scoped deployment can safely replace its own old container while refusing a legacy
   container from another deployment.

4. Unset configuration must mean the legacy scope, not “match every scope.”
   Evidence: the official 5200 supervisor will remain unconfigured while personal stable becomes
   scoped.
   Impact: an unscoped supervisor must accept only containers without a deployment label.

5. The personal image already built from integration lacks this protection.
   Evidence: it predates this initiative.
   Impact: rebuild from the new pushed integration commit before deploying port 5400.

## Existing Patterns To Reuse

- `sanitizeIdentifier`: safe Docker name fragments.
- Content-derived network suffixes: collision resistance for sanitized bot IDs.
- Optional configuration defaults: preserve existing behavior when a value is absent.
- Exact app-data-root checks in `Test-RakazoBotOwnership`.
- Immutable personal images tagged by full integration commit.

## Decisions Needed

| Decision | Options | Recommendation | Blocking? |
|---|---|---|---|
| Configuration name | `RAKAZO_ENVIRONMENT` or `RAKAZO_DEPLOYMENT_ID` | Use `RAKAZO_DEPLOYMENT_ID`; it identifies one deployment and allows more than one development environment | no |
| Missing value | Match all containers or only legacy containers | Match only containers with no deployment label | no |
| Legacy adoption | Ignore, reuse, or recreate | Recreate only when the exact home bind belongs to the requesting deployment | no |
| Compose grouping | Forge Compose labels or retain Rakazo ownership | Retain Rakazo-owned labels; do not forge reserved labels | no |
| Contribution target | Upstream PR or fork-only | Fork-only, per user decision | no |

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---:|---:|---|
| Cross-deployment container access | high after cloned restore | high | Require exact deployment-label match |
| Cross-deployment network deletion | high after cloned restore | high | Scope current and cleanup network names |
| Existing dev computer becomes orphaned | medium | medium | Adopt only by exact home mount, then recreate with scoped identity |
| Official reference behavior changes | low | high | Unset variable preserves names and accepts only unlabelled legacy resources |
| Backup script stops wrong computer | low | high | Require matching deployment label when present and retain exact mount-root verification |

## Test Surface

Unit:

- Deployment ID parsing and validation.
- Legacy and scoped container names, labels, and networks.
- Deployment-label matching.
- Exact home-mount matching.
- Scoped cleanup variants.

Integration:

- Compose renders `rakazo-dev` and `rakazo-personal` identities.
- Operations ownership accepts matching/legacy homes and rejects another deployment.
- Disposable personal build passes health checks before activation.

UI:

- None. Docker Desktop naming is an operational consequence, not a Rakazo UI change.

Regression:

- With no deployment ID, existing names and network names remain byte-for-byte unchanged.

## Acceptance Criteria Inputs

The implementation plan must satisfy:

- Identical bot and workspace IDs cannot cross scoped and legacy deployments.
- Container and network names are deployment-scoped only when configured.
- Existing unscoped installations retain their names and can operate their own legacy containers.
- Personal and development helpers supply explicit distinct deployment IDs.
- Relevant tests pass; known Windows-only baseline failures remain classified and unchanged.
- Port 5400 is deployed only from the new immutable integration commit.

## Open Questions

| Question | Owner | Needed By | Status |
|---|---|---|---|
| Restore release state into personal stable | User | post-deployment migration | deferred by agreement |

## Loop Status

| Loop | Agent | Goal | Result | Next |
|---:|---|---|---|---|
| 1 | Codex | map identity and lifecycle seams | cross-deployment collision confirmed; deterministic design selected | implement and verify |
