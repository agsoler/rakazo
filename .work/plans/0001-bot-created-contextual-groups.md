# Bot-created contextual groups implementation plan

## Contract and persistence

- Add `group_context` and `child_group` message blocks plus group-detail context fields.
- Add nullable `creatorBotId`, `creatorContext`, and workspace-scoped `createKey` columns and migration.
- Extend group creation to atomically persist members, thread, optional shared message, and creator-only context, returning an existing group for the same creation key.

## Agent execution

- Add `create_group` with strict name, member, and context limits.
- Implement an adapter service that includes the creator, validates peers through the group repository, and performs no wakeup.
- Dispatch through the external-effect pipeline, publish a parent `child_group` block and `group.created` event, and expose creator-only prompt context only to the creator.

## Product surfaces

- Render shared context and clickable group creation cards on web/Electron and mobile.
- Refresh group navigation after agent creation.
- Show read-only shared and creator-only starting context in authenticated group settings.
- Document the generic collaboration capability without domain-specific product terminology.

## Acceptance

- Automated tests prove ownership, member limits, context combinations, retry idempotency, zero automatic runs, and creator-only non-disclosure.
- Lint, typecheck, production build, unit, integration, and web E2E suites pass.
- Manual source testing succeeds against Ollama on port 5300 while the release remains available on port 5200.
