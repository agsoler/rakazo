# Single-bot focused groups

## Question

Should a Rakazo group be allowed to contain one bot, and what behavior changes are required?

## Rationale

Rakazo gives each bot one main conversation and does not otherwise provide named conversation
threads. A one-bot group provides a focused, durable conversation with its own transcript and
optional starting context. This lets a user or bot isolate a topic without polluting the bot's main
chat. Multi-bot groups continue to provide collaboration; a singleton group is a focused room.

The original two-bot minimum came from the initial product scope for group collaboration. There is no
database or execution requirement for two active bots.

## Decisions

1. Groups contain one to six active bots.
2. `create_group` includes its creator and accepts zero to five other active bot IDs.
3. A singleton group does not expose `handoff_to_bot`, `message_bot`, or scheduling tools because no
   peer bot exists and group conversations do not own private schedules.
4. A singleton group receives focused-conversation instructions instead of collaboration and handoff
   instructions.
5. The transcript and starting context are isolated. The bot's identity, durable memory, scratchpad,
   and computer remain shared across its conversations.
6. Existing lifecycle rules remain general: a group is usable while it has at least one active bot,
   and permanent deletion dissolves it only when no active bot remains.
7. Archiving is not redesigned. Archiving the sole member temporarily hides the group through the
   existing active-member filter; restoring that bot makes it available again.

## Compatibility

No database migration is required. The member minimum is enforced by shared validation and active
member checks, all of which use `GROUP_MEMBER_MIN`. Existing groups and multi-bot behavior remain
unchanged.
