---
type: research
id: "0007"
title: Existing Release Recovery Import
status: complete
owner: Codex
created: 2026-08-31
updated: 2026-08-31
related_plan: .work/plans/0007-plan-release-recovery-import.md
---

# 0007 Research: Existing Release Recovery Import

## Objective

Define a separate, one-time, rehearsed migration that imports a selected existing image-release
recovery point into the new personal stable deployment after initiative 0006 is verified.

## Scope

In scope:

- Read-only discovery and verification of an operator-selected existing recovery-point directory.
- Existing release format: custom PostgreSQL dump, appdata archive, `.env`, Compose file, manifest,
  checksums, and linked image set.
- Disposable baseline restoration using the saved official images.
- Disposable upgrade rehearsal to the selected custom personal image.
- Confirmed import into an empty or separately backed-up personal deployment.
- Post-import health, authentication, data, bot-file, and model checks.

Out of scope:

- Reading or migrating port-5300 development state.
- Reading the live official database instead of the selected recovery point.
- Modifying, renaming, deleting, or rewriting the source recovery point or image set.
- Making legacy-format conversion part of ordinary future backups/restores.
- Deleting the official reference deployment after migration.

## Current State

Key inputs:

- Existing release recovery points contain `rakazo.pgdump`, `rakazo-appdata.tar.gz`, `.env`,
  `docker-compose.images.yml`, `manifest.json`, `SHA256SUMS.txt`, and image references.
- Existing image sets contain the exact official images, manifest, references, checksums, and one
  archive reused by multiple state recovery points.
- Existing restore logic proves the dump/appdata format is recoverable but is too broadly scoped for
  mixed local environments.
- Plan 0006 will provide safe manifests, exact resource ownership, custom images, personal Compose,
  backup, restore, and disposable test infrastructure.

Known constraints:

- The source `.env` contains the encryption key required by the old database and may contain
  provider credentials. Values must never be logged or committed.
- Old URLs, ports, image references, and project identity cannot be copied unchanged into personal
  stable.
- A database migration may be one-way. The old baseline must be proven before applying newer code.
- The imported state may contain local maintenance customizations that are not part of generic
  Rakazo state; these require explicit post-import verification rather than assumptions.

## Dependencies

Runtime:

- Completed and verified initiative 0006.
- Docker Desktop Linux engine.
- Saved release image archive or registry availability for the baseline rehearsal.
- Custom personal image set selected for the target.

Internal:

- 0006 common manifest/checksum/ownership module.
- 0006 disposable Compose harness.
- 0006 personal backup and restore adapters.
- Existing release verifier/adapter consolidated by 0006.

External:

- Operator-selected existing recovery point, provided as a runtime path.

## Findings

1. Import must be a separate initiative, not a branch in normal restore code.
   Evidence: the old release and new personal formats have different deployment identities and
   configuration needs, while future personal recovery points are homogeneous.
   Impact: implement one importer that consumes the old adapter and emits normal personal state;
   ordinary backup/restore remains format-simple.

2. The newest directory is not automatically the correct source.
   Evidence: completeness and checksum validity matter more than filename ordering, and an operator
   may intentionally choose an earlier point.
   Impact: list valid candidates and require an explicit selected path; never silently fall back.

3. Rehearsal must restore the old code before upgrading it.
   Evidence: the saved image set and `.env` describe the schema/encryption behavior that created the
   backup.
   Impact: disposable baseline restore and health checks precede custom-image migration tests.

4. Configuration migration is a merge, not a file copy.
   Evidence: old secrets/encryption/provider values must survive, while project, host URLs, ports,
   image references, and operational paths must come from the personal deployment.
   Impact: define an explicit allowlist of secret/provider keys copied from source and an explicit
   personal-owned key set; unknown keys are reported by name only for review.

5. Source preservation is part of acceptance.
   Evidence: this is the only historical input requested for migration.
   Impact: open source files read-only, record pre/post hashes, and leave the entire source tree
   byte-identical.

## Existing Patterns To Reuse

- Release `Test-Sha256Sums`: checksum format compatibility.
- Release image-set manifest: old image association.
- Personal disposable smoke harness: isolated project/ports/volumes and scoped cleanup.
- Personal pre-restore safety backup and typed confirmation.

## Decisions Needed

| Decision | Options | Recommendation | Blocking? |
|---|---|---|---|
| Source choice | newest automatically; explicit verified point | explicit point selected from verified candidates | yes at migration run, not implementation |
| Migration path | direct old-to-new; baseline then upgrade rehearsal | baseline restore, verify, upgrade rehearsal, then live import | no |
| Target state | overwrite silently; empty-only; backed-up replace | empty target by default; replacement requires successful target backup plus separate flag | no |
| Config handling | copy old `.env`; regenerate; allowlisted merge | preserve required secrets/providers and replace deployment-owned settings | no |
| Source cleanup | move/delete after import; preserve | preserve indefinitely until independent recovery drill accepted | no |

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---:|---:|---|
| Wrong recovery point selected | low | high | explicit path, summary, typed confirmation |
| Backup is corrupt | low | high | checksum and manifest verification before any target mutation |
| New migrations reject old database | medium | high | disposable baseline and upgrade rehearsal |
| Encryption/provider credentials lost | low | high | allowlisted config merge and authenticated manual checks |
| Existing personal state overwritten | low | high | empty-only default and mandatory pre-import backup for override |
| Source recovery data modified | low | high | read-only handling plus pre/post hash comparison |
| Maintenance bot loses local tools/network | medium | medium | explicit post-import checklist; no broad automatic bot modification |

## Test Surface

Unit:

- Old checksum and manifest parser fixtures.
- Configuration-key ownership/merge rules with fake values.
- Source-path read-only enforcement.
- Empty-target and replace-target gates.

Integration:

- Synthetic old-format point restored into disposable old-image stack.
- Disposable upgrade to custom image with schema migration and state preservation.
- Failed/tampered input leaves target and source unchanged.
- Import into disposable personal target followed by normal 0006 backup and restore.

UI:

- No product UI changes.
- Manual authenticated checks use existing Rakazo web UI.

Regression:

- Source development and official reference remain unchanged.
- Normal personal backup/update/recovery contains no legacy-format branch.

## UI Validation Hooks

Manual post-import checks:

- sign in with the restored account;
- inspect representative bots, groups, messages, settings, and bot files;
- run one disposable model interaction;
- verify configured provider/model availability;
- verify any explicitly documented maintenance-bot customization separately.

## Acceptance Criteria Inputs

The implementation plan must satisfy:

- Source recovery data remains byte-identical.
- Old baseline and custom-image upgrade both pass in a disposable environment before live import.
- The target is empty or has a verified pre-import personal backup.
- Secrets are merged without display; personal ports/project/image refs override historical values.
- Imported state immediately produces an ordinary personal recovery point and can be restored through
  initiative 0006 without legacy knowledge.

## Open Questions

| Question | Owner | Needed By | Status |
|---|---|---|---|
| Which verified historical recovery point should be imported? | deployment owner | migration execution | open; explicit runtime selection |
| Which maintenance-bot customizations, if any, must be re-established? | deployment owner | post-import verification | open; not a generic import blocker |

## Loop Status

| Loop | Agent | Goal | Result | Next |
|---:|---|---|---|---|
| 1 | Codex | inspect historical format and separate migration from steady state | complete | implement only after 0006 acceptance |
