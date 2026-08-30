# Bot-created contextual groups

## Question

How should a full Rakazo bot create a durable group, optionally provide shared and creator-only starting context, and avoid starting work until the user explicitly messages the group?

## Current architecture

- Human group creation is defined by the shared contracts and implemented by the database group repository.
- A group owns one thread and contains one to six active bots.
- Agent-owned durable actions are declared in `builtin-tools.ts` and dispatched through the executor's persisted external-effect pipeline.
- `spawn_bot` provides the closest retry-safe precedent: the operation creates durable state, publishes a result block in the parent thread, and does not require a parallel implementation in the API router.
- Group model context is assembled centrally by `loadGroupContext`; web/Electron and mobile render the same shared message-block contract.

## Decisions

1. Add one provider-neutral `create_group` tool for full bots and exclude it from temporary subagents.
2. Include the creator automatically and accept zero to five other active bot IDs.
3. Store shared context as the first group-thread message so it is visible, exportable as ordinary shared history, and naturally participates in compaction.
4. Store creator-only context on the group, never in its thread, events, list projections, previews, search, notifications, or exports.
5. Inject creator-only context only when the running member is the recorded creator.
6. Return both context values only from the authenticated group-detail endpoint so the human owner can inspect them.
7. Create no task or run during group creation; the user's first group message starts the work.
8. Add a workspace-scoped creation key so an interrupted tool call cannot create a duplicate group.

## Security and privacy boundary

Creator-only context is isolation between bot model contexts, not encryption from the deployment owner or database administrator. Context is treated as untrusted background and cannot override system policy or later user instructions.

## Verification strategy

Use deterministic unit and integration tests for validation, retry safety, prompt isolation, absence from shared projections, and zero automatic runs. Exercise navigation and presentation on web/Electron and mobile. Use live Ollama only for final manual verification, not automated tests.
