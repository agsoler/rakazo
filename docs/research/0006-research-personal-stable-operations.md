---
type: research
id: "0006"
title: Personal Stable Image and Recovery Operations
status: complete
owner: Codex
created: 2026-08-31
updated: 2026-08-31
related_plan: .work/plans/0006-plan-personal-stable-operations.md
---

# 0006 Research: Personal Stable Image and Recovery Operations

## Objective

Define a reproducible, low-friction Windows workflow that builds a stable personal Rakazo image from
the pushed integration branch, deploys it independently from source development and the official
reference stack, backs up its state and exact images, and restores it without relying on an online
container registry.

## Scope

In scope:

- A personal image deployment built from an exact `origin/integration/rakazo-dev` commit.
- Local app and computer images with immutable commit-addressed tags.
- Independent Compose project, ports, secrets, database, and appdata.
- One-click Windows launchers for backup, build-and-deploy, restore, start, stop, sync, and status.
- State recovery points linked to content-addressed image sets.
- Encrypted off-machine replication to a configurable NAS destination that may be unavailable.
- Canonical, parameterized release backup/restore scripts stored in the fork.

Out of scope:

- Importing an existing release recovery point; that is initiative 0007.
- Migrating source-development state into the personal deployment.
- Running the personal deployment or model server on the NAS.
- Automatically merging upstream or feature branches.
- Publishing images to GHCR, Docker Hub, or Forgejo in the first implementation.
- Scheduling unattended backups in the first implementation.
- Changing Rakazo product behavior or user interfaces.
- Automatically pruning images, build cache, recovery points, or restic snapshots.

## Current State

Key files:

- `infra/compose/Dockerfile`: builds one application image used by API, worker, web, and supervisor.
- `infra/sandboxes/computer/Dockerfile`: builds the bot-computer image.
- `infra/compose/docker-compose.images.yml`: selects app and computer repositories/tags through
  environment variables and provides the pull-based deployment topology.
- `.github/workflows/publish-server-image.yml`: demonstrates commit-addressed image metadata and a
  clean CI checkout, but does not provide the requested local personal workflow.
- `.dockerignore`: excludes `.env` but currently does not exclude ignored `.local` development data.
- `scripts/windows-dev/`: tracked, isolated source-development lifecycle and development backup
  helpers.
- Local release `backup.ps1` and `restore.ps1`: useful image-set and state-recovery precedents, but
  currently live outside Git and select all `rakazo-bot-*` containers too broadly.

Existing behavior:

- Source development is a hybrid Windows/Docker environment and is intentionally simple.
- The official image deployment and source development are isolated by Compose project, ports, and
  storage.
- `docker-compose.images.yml` already supports official or custom app/computer image references.
- The release backup records exact image IDs, saves an image archive only for a new image set, and
  links every state recovery point to that set.
- The current machine can build and retain Docker images locally without a registry.

Known constraints:

- A Docker image contains software, not PostgreSQL records, appdata volumes, or `.env` secrets.
- An image stored only in Docker Desktop does not survive workstation disk loss or a Docker reset.
- Backups contain private conversations and encryption keys and must not be committed or copied
  unencrypted to general-purpose storage.
- The NAS may be asleep. Normal application use and local backup creation must not depend on it.
- The public repository cannot contain machine names, personal paths, NAS shares, credentials, or
  real recovery metadata.
- Dynamic bot containers do not consistently carry a Compose-project label. Environment ownership
  must be established from the exact appdata mount root, not only the container name or labels.

## Dependencies

Runtime:

- PowerShell 7.
- Git.
- Docker Desktop with the Linux engine and Compose v2.
- Ollama on the Windows workstation.
- Restic for encrypted, deduplicated off-machine replication.

Internal:

- `RAKAZO_IMAGE` and `RAKAZO_IMAGE_TAG`: application-image selection seam.
- `RAKAZO_COMPUTER_IMAGE` and `RAKAZO_COMPUTER_IMAGE_TAG`: bot-computer-image selection seam.
- `Test-RakazoDevPrerequisites.ps1`: Windows audit pattern.
- `Resolve-NodeToolchain.ps1`: repository-pinned Node/pnpm resolution where source checks require it.
- Existing release image-set manifest: content-addressed image backup precedent.

External:

- GitHub fork: source and pushed integration commit.
- Restic: free, open-source, encrypted and deduplicated repository format; Windows is supported.
- Configured NAS path: off-machine storage only, never a runtime requirement.

## Findings

1. A stable personal deployment must be a fourth operational identity, not a renamed development
   stack.
   Evidence: source development uses Windows processes, a bind-mounted `.local/data`, and project
   `rakazo-dev`; image deployment uses containerized app processes and named volumes.
   Impact: use Compose project `rakazo-personal`, web port 5400, API port 3300, and independent
   volumes/secrets.

2. The existing Compose image-selection variables already form the correct seam.
   Evidence: `infra/compose/docker-compose.images.yml` references app and computer repository/tag
   variables for all consumers.
   Impact: official and custom images are two adapters behind one deployment interface; no second
   product topology is needed.

3. Local builds must never use the live checkout as their Docker build context.
   Evidence: `.dockerignore` omits `.local`, while local development data is ignored by Git but still
   present on disk and `infra/compose/Dockerfile` copies the build context.
   Impact: add `.local` to `.dockerignore` and build from a temporary detached worktree at a pushed
   commit.

4. Image-centric recovery complements state recovery; it does not replace it.
   Evidence: Docker volumes and bind mounts are not included by `docker image save`.
   Impact: keep one image archive per changed image set and create a state snapshot every backup.

5. The NAS sleep schedule requires decoupled local capture and remote replication.
   Evidence: off-machine storage is not continuously reachable.
   Impact: backup creates and verifies a local recovery point first, then attempts encrypted restic
   replication. Unavailable NAS storage leaves a visible pending state and a separately clickable
   sync operation.

6. A destructive restore cannot safely be a silent single click.
   Evidence: restore replaces the database, appdata, and `.env` and may need the old image set.
   Impact: the restore launcher can be one click, but it must show the selected recovery point,
   verify integrity, create a safety backup when state exists, and require typed confirmation.

7. Existing release scripts must be parameterized and scoped before being tracked as canonical.
   Evidence: their current `name=rakazo-bot-` filters include release and development containers.
   Docker inspection shows the appdata mount source reliably distinguishes environments.
   Impact: common container selection must require the expected appdata mount root; thin personal
   and release adapters supply different project and storage identities.

8. Restic is suitable only for replication, not for defining the Rakazo recovery format.
   Evidence: restic encrypts, authenticates, verifies, and deduplicates arbitrary files, but Rakazo
   still needs manifests linking state, images, code, and deployment settings.
   Impact: create ordinary self-describing recovery-point directories locally, then store them in an
   encrypted restic repository. Recovery first materializes a directory and then invokes Rakazo's
   verifier/restore module.

## Existing Patterns To Reuse

- `scripts/windows-dev/Start-RakazoDev.ps1`: explicit Docker context, health waits, and source-process
  ownership checks.
- `scripts/windows-dev/Backup-RakazoDevState.ps1`: incomplete-directory publication and manifest
  metadata.
- `scripts/windows-dev/Test-RakazoDevRecoveryPoint.ps1`: fail-closed checksum verification.
- `infra/compose/docker-compose.images.yml`: one image-deployment topology.
- Release image-set identifier: hash exact references, image IDs, and digests so unchanged images are
  archived once.

## Decisions Needed

| Decision | Options | Recommendation | Blocking? |
|---|---|---|---|
| Personal web port | reuse 5200/5300; use 5400 | 5400, keeping reference and workshop independent | no |
| Build source | live checkout; local branch; pushed integration commit | detached worktree at fetched `origin/integration/rakazo-dev` | no |
| Custom images | app only; app and computer | build/tag both; Docker cache makes unchanged computer layers cheap and creates a complete local set | no |
| Image storage | Docker cache only; registry only; cache plus archive | cache plus content-addressed archive; optional registry later | no |
| NAS protection | plaintext folders; encrypted archive; restic repository | local recovery directories replicated into encrypted restic | no |
| NAS password custody | machine-only file; independent recovery secret | local restricted password file plus a separately stored recovery copy | yes at live initialization, not code implementation |
| Click interface | bespoke GUI; `.cmd` files; generated shortcuts | parameterized PowerShell commands plus generated Windows shortcuts and readable console results | no |
| Failed update rollback | silently restore; stop and guide | retain pre-update snapshot and previous image, stop, and require confirmed rollback | no |

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---:|---:|---|
| Private `.local` data enters image | medium without change | high | detached tracked worktree, `.dockerignore` defence, image-content scan |
| Script addresses wrong stack or bot | medium in current scripts | high | exact project plus appdata-mount ownership check and adversarial tests |
| NAS unavailable during backup | high by design | medium | local verified capture, pending replication status, retryable sync |
| Restic password lost with workstation | low | high | setup cannot declare disaster-ready until independent recovery secret confirmed |
| Database migration makes image-only rollback unsafe | medium | high | mandatory pre-update state snapshot; confirmed state+image rollback |
| Mutable tags hide code provenance | medium | high | full commit tags and recorded image IDs; no `latest` for custom deployment |
| One-click window closes before error is read | medium | low | launcher writes log/status and waits for acknowledgement on failure |
| Backup/image accumulation fills disk | medium | medium | report usage; no automatic deletion in first implementation |

## Test Surface

Unit:

- Manifest creation and schema validation.
- Image-set identity stability and change detection.
- Appdata-mount ownership filtering with mixed release/development fixtures.
- Configuration parsing without printing secret values.
- Recovery-point selection and confirmation parsing.
- Pending/synced replication state.

Integration:

- Build app and computer images from a detached fixture commit.
- Start a disposable image stack with generated secrets and isolated project/ports/volumes.
- Create state, back it up, alter state, restore, and prove the original state returns.
- Save images, remove only disposable tags, load archives, and restore the disposable stack.
- Simulate unavailable NAS storage, then sync when a local test repository becomes reachable.
- Verify mixed managed bot containers outside the target appdata mount are never stopped or changed.

UI:

- No Rakazo product UI changes.
- Windows shortcut/console flows require human-readable success, warning, preview, and failure output.

Regression:

- Port 5300 development startup, stop, hot reload, and data remain unchanged.
- Port 5200 reference deployment remains untouched.
- Existing Docker projects, volumes, bot containers, and local backups are never pruned.

## UI Validation Hooks

Not applicable to Rakazo web/mobile UI. Manual launcher checks cover:

- backup success and pending-NAS warning;
- update preview and success;
- restore preview, cancellation, confirmation, and checksum failure;
- status output identifying exact commit, image IDs, health, and replication state.

## Acceptance Criteria Inputs

The implementation plan must satisfy:

- A pushed integration commit produces immutable local app and computer images without exposing
  ignored data or secrets.
- Personal stable runs on port 5400 under project `rakazo-personal` with independent state.
- One click creates a verified state recovery point and archives images only when the image set is
  new.
- One click builds and smoke-tests the latest pushed integration commit, creates a pre-update
  backup, and deploys it to personal stable.
- One click opens a guided, fail-closed restore that can recover from local or NAS material.
- NAS unavailability never breaks personal runtime or local backup creation.
- Official and custom image references use the same manifest and restore logic.
- All reusable scripts and documentation are tracked; all config, secrets, logs, state, archives,
  and shortcuts remain untracked.

## Open Questions

| Question | Owner | Needed By | Status |
|---|---|---|---|
| What NAS share or backend path will hold the encrypted repository? | deployment owner | live initialization | open; runtime parameter, not an implementation blocker |
| Where will the independent restic recovery password be kept? | deployment owner | live initialization | open; setup must require acknowledgement |

## Loop Status

| Loop | Agent | Goal | Result | Next |
|---:|---|---|---|---|
| 1 | Codex | map source, image, deployment, and existing backup behavior | complete | choose bounded architecture |
| 2 | Codex | resolve local/NAS and click-operation contracts | complete | implement plan 0006 after approval |
