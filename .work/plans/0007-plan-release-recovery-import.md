---
type: implementation-plan
id: "0007"
title: Existing Release Recovery Import
status: in_progress
owner: Codex
research: docs/research/0007-research-release-recovery-import.md
created: 2026-08-31
updated: 2026-09-01
---

# 0007 Plan: Existing Release Recovery Import

> Lifecycle: ephemeral delivery state. Delete this plan after the one-time import is accepted and
> durable evidence is recorded in private operator logs. Never commit live migration paths, values,
> manifests, or output.

## Goal

After initiative 0006 is verified, import one explicitly selected, complete existing release
recovery point into personal stable through a disposable baseline restore and custom-image upgrade
rehearsal. Preserve the source byte-for-byte, do not inspect port-5300 state, and finish with an
ordinary personal recovery point that needs no legacy migration code for future recovery.

## Agent Contract

Primary agent:

- Role: implement and rehearse the importer; perform the live import only after separate user
  approval naming the source and target.
- Must preserve: source recovery tree, release deployment, source development, personal image sets,
  and any existing personal state.
- Must not change: ordinary 0006 backup/update/restore contracts or any live environment during
  fixture/rehearsal tests.
- Ask before: reading real secret-bearing recovery files beyond metadata verification, loading real
  archived images, creating rehearsal containers from real data, replacing personal state, or
  applying the live migration.

Supporting agents:

- research: complete in research 0007.
- review: independent safety/spec review before live rehearsal.
- test: synthetic fixtures may be delegated; real rehearsal remains with orchestrator.

## Inputs

Research:

- `docs/research/0007-research-release-recovery-import.md`

Relevant files:

- `scripts/windows-release/Test-RakazoReleaseRecoveryPoint.ps1`: old-format verifier from 0006.
- `scripts/windows-personal/Restore-RakazoPersonal.ps1`: target adapter from 0006.
- `scripts/windows-migration/Import-RakazoReleaseRecoveryPoint.ps1`: new one-off importer.
- `scripts/windows-ops/tests/`: synthetic old-format fixtures and migration integration harness.

Dependencies:

- Initiative 0006 fully accepted, including disposable recovery test.
- Explicit source path supplied at runtime.
- Explicit target custom image-set ID/commit supplied at runtime.

Assumptions:

- The source follows the inspected release recovery-point/image-set schema.
- The desired source is a stored recovery point, not live release data.

## Scope

Implement:

- Candidate listing and old-format verification.
- Config ownership/merge contract.
- Synthetic tests, disposable real baseline rehearsal, disposable custom upgrade rehearsal.
- Confirmed empty-target or backed-up replacement import.
- Post-import personal backup and private migration report.

Do not implement:

- Automatic newest-source selection, live-release extraction, port-5300 migration, source cleanup,
  or a permanent legacy branch in ordinary personal restore.

## Product Decisions

Resolved decisions:

| Decision | Choice | Rationale | Evidence |
|---|---|---|---|
| Migration source | stored existing release recovery point | user correction | user request |
| Relationship to normal operations | separate one-time command/plan | keeps steady state simple and testable | research 0007 |
| Validation order | old baseline, custom upgrade rehearsal, live import | isolates format/schema/encryption failures | recovery safety |
| Source treatment | read-only and retained | source is irreplaceable historical evidence | user goal |
| Target default | empty-only | prevents accidental replacement | destructive risk |

Open product-level decisions:

| Decision | Options | Recommendation | Impact | Blocks implementation? |
|---|---|---|---|---|
| Exact source point | any verified candidate | user selects after candidate report | determines imported state age | no for code; yes for live run |
| Existing target replacement | refuse; backed-up override | refuse unless explicitly approved with verified pre-import backup | protects any new personal use | no |

Runtime decisions resolved for this migration:

- Source: the explicitly selected and verified historical recovery point supplied by the operator.
- Target: the initialized `rakazo-personal` deployment, protected by verified empty-state recovery
  points.
- Cutover: restore and validate API/web on 5400 without starting its worker while the source 5200
  worker is still live; this prevents duplicate task and routine execution before decommissioning is
  separately approved.

Planning disposition:

- Finalize; runtime source selection is intentionally deferred to the live migration gate.

## Delegation Decision

Disposition:

- Orchestrator implements and owns real rehearsal; delegate synthetic review/verification only.

Reason:

- Real recovery material is private and the migration has destructive potential.

Ownership:

- Migration scripts and real rehearsal: orchestrator.
- Independent source-diff and wrong-stack review: reviewer.

Orchestrator local-fix rule:

- Fix only migration-plan defects; any new data source, config class, or target environment requires
  plan revision.

## Deterministic Work Items

| Step | Task | Files | Output | Depends On | Agent |
|---:|---|---|---|---|---|
| 1 | Confirm 0006 is accepted and merged into `integration/rakazo-dev`, then create `ops/import-release-recovery` from that exact integration commit | Git status/evidence | isolated migration branch on the accepted reusable foundation | 0006 | orchestrator |
| 2 | Define old-to-personal config ownership map with fake fixtures | migration module/tests | source-owned secret/provider keys, target-owned project/ports/images/paths, unknown-key report | 0006 | orchestrator |
| 3 | Implement candidate listing and fail-closed source verification without printing values | `Import-RakazoReleaseRecoveryPoint.ps1`, common adapters | explicit source summary and source-tree hash inventory | 2 | orchestrator |
| 4 | Implement offline migration policy tests and reuse the established disposable recovery harness | migration tests/existing operations tests | config ownership, tamper identity, wrong-target, archive, and restore primitives pass with fake data | 3 | orchestrator |
| 5 | Run code/safety review before any real recovery material is used | review evidence | no wrong-stack, secret-log, traversal, or source-write finding | 4 | orchestrator |
| 6 | With approval, verify the selected real source and image set read-only; record private hashes and candidate summary | private ignored log | named validated source; no mutation | 5 + user approval | orchestrator |
| 7 | With approval, create a uniquely named disposable rehearsal stack, load saved official images, restore baseline, and verify health/authentication/data/files | disposable project and private checklist | proven old baseline | 6 + user approval | orchestrator |
| 8 | Upgrade the rehearsal stack to the selected custom personal image, apply migrations, and verify the same representative data plus one disposable model run | disposable project/private checklist | proven upgrade path | 7 | orchestrator |
| 9 | Re-hash source tree and prove byte identity; clean only the uniquely named disposable rehearsal project after approval | private evidence | preserved source and scoped cleanup | 8 | orchestrator |
| 10 | Require an empty personal target or create/verify a normal pre-import personal recovery point; preview exact migration and request typed confirmation | personal backup/preview | safe target gate | 8 | orchestrator |
| 11 | Import database/appdata and merged configuration into `rakazo-personal`, preserve custom immutable images and target ports, start, migrate, and verify health | personal deployment | migrated stable state | 10 + user confirmation | orchestrator |
| 12 | Perform manual authenticated acceptance, create a normal personal recovery point, replicate or mark pending, and prove it restores in disposable 0006 harness | private checklist + normal personal manifests | migration exits legacy format | 11 | orchestrator |
| 13 | Record durable generic lessons without private details; remove migration plan after acceptance while retaining importer only if documented as legacy utility | docs/artifacts | clean handoff | 12 | orchestrator |

## Implementation Notes

Required patterns:

- Open source files read-only; never use source directories as extraction or working locations.
- All working/output directories are newly created under ignored staging roots.
- Unique rehearsal project and volume names include a generated identifier and are validated before
  cleanup.
- Unknown `.env` keys are reported by key name only and require classification before live import.

Data/contracts:

- Secret/provider values preserved from source: database password, auth/encryption/screen/supervisor
  secrets, supported provider/model keys and settings.
- Target values preserved from personal configuration: project, ports, host URLs, image references,
  operational paths, replication configuration.
- No source image tag overrides the selected custom personal image during final import.

Error handling:

- Any checksum, manifest, image, baseline, migration, health, source-identity, or target-backup failure
  stops before the next mutation gate.
- A failed live import retains the pre-import personal recovery point and stops for a separately
  confirmed rollback.

Logging/telemetry:

- Private ignored migration log with hashes, counts, health, image IDs, and timestamps; never secret
  values or message/file contents.

Security/privacy:

- No real path, hostname, manifest, `.env`, bot ID, account data, counts tied to a user, or migration
  output enters Git.

Documentation/comment conventions:

- The importer explicitly states that it is a legacy one-time utility, names its source and target
  formats, and documents every destructive gate.

## Test Strategy

Commands:

```powershell
.\scripts\windows-ops\tests\Test-RakazoOperations.ps1
.\scripts\windows-ops\tests\Test-RakazoMigration.ps1
corepack pnpm lint
corepack pnpm check
corepack pnpm build
```

Unit tests:

- Fake config allowlist merge and unknown-key handling.
- Explicit source selection and no-fallback behavior.
- Read-only path and pre/post hash inventory.
- Empty-target and replace-with-backup gates.

Disposable verification:

- Existing synthetic personal backup/restore and image-archive tests remain passing.
- A real source baseline and custom-image upgrade run in a generated project before confirmation.
- Tampered source identity and wrong-target settings fail closed in offline tests.
- The generated project is removed while release, development, and personal endpoint health remains
  unchanged.

Regression tests:

- Normal 0006 code path has no dependency on legacy importer.
- 5200/5300 health and resources unchanged.

Manual checks:

- Real baseline sign-in and representative content only after approval.
- Real upgraded rehearsal sign-in and representative content.
- Final personal sign-in, bots/groups/history/files/models, and one disposable run.
- Separately document maintenance-bot tools/database access result if applicable.

## UI Validation Hooks

No UI implementation. Manual route checks use the disposable rehearsal URL and personal port 5400.

Pass conditions:

- baseline and upgraded rehearsal show the same selected representative state;
- final personal state is usable;
- no source or non-target environment changes.

## Review Gates

Gate 1: Scope Review

- [x] Only selected stored recovery point is a source
- [x] Development and live release data are not migration inputs
- [x] Normal 0006 restore remains legacy-free

Gate 2: Code Review

- [x] Source is provably read-only
- [x] Config merge is allowlisted and secret-safe
- [x] Every Docker mutation is rehearsal or personal scoped
- [x] Failure paths retain recovery evidence

Gate 3: Test Review

- [x] Offline migration policy tests pass
- [x] Tamper/wrong-target tests fail closed
- [x] Real baseline and custom-image upgrade rehearsal completes before live confirmation
- [x] Source hashes match before/after

Gate 4: Live Acceptance

- [x] Exact source and custom image identified privately
- [x] Target empty state has a verified pre-import recovery point
- [ ] User typed confirmation immediately before import
- [ ] Post-import normal backup and disposable restore pass

## Acceptance Criteria

- [ ] One explicitly selected existing release recovery point is imported; no automatic substitution.
- [ ] Source recovery tree remains byte-identical.
- [ ] Old baseline and custom upgrade are rehearsed before target mutation.
- [ ] Personal target is protected by empty-target or verified-backup gate.
- [ ] Required secrets/providers survive while personal project/ports/images remain authoritative.
- [ ] Final state passes authenticated checks and one disposable model run.
- [ ] A normal personal recovery point is created, replicated or marked pending, and restored through
  0006 tooling.
- [ ] No port-5300, live-release, or non-target Docker resource changes occur.

## Rollback Plan

- Before live import: cancel and clean only the generated rehearsal project after approval.
- After live import failure: use the verified pre-import personal recovery point through confirmed
  0006 rollback.
- Never use or modify the historical source as rollback working space.

## Loop Status

| Loop | Status | Agent | Action | Evidence | Next |
|---:|---|---|---|---|---|
| 1 | complete | orchestrator | importer, offline policy tests, and safety review | passing tests | real rehearsal |
| 2 | complete | orchestrator | real baseline/upgrade rehearsal | private ignored evidence | live import confirmation |
| 3 | pending | orchestrator | live import and ordinary personal recovery drill | private checklist | acceptance |

## Final Handoff

Changed files:

- `scripts/windows-migration/RakazoMigration.Common.ps1`
- `scripts/windows-migration/Import-RakazoReleaseRecoveryPoint.ps1`
- `scripts/windows-ops/tests/Test-RakazoMigration.ps1`
- `scripts/windows-ops/README.md`

Verification run:

- PowerShell parser: pass for all migration files.
- `Test-RakazoMigration.ps1`: pass.
- `Test-RakazoOperations.ps1`: pass.
- Real isolated release-baseline/custom-image upgrade rehearsal: pass; private evidence retained.

Known residual risk:

- Historical maintenance-container customizations may require separately approved re-establishment.

Artifacts:

- Research status: complete
- Durable decisions transferred to product documentation or ADRs: pending acceptance
- Residual work transferred to repository tracker: not applicable yet
- Plan deleted after acceptance or explicitly retained: retain until migration acceptance
- Stale sections removed or updated: yes

Ready for:

- implementation only after initiative 0006 is accepted
