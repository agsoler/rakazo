# Group-aware bot collaboration

## Decision

Group conversations expose two distinct routing surfaces to each running bot:

- The active members of the current group.
- The user's other active bots outside the current group.

These lists are model instructions assembled from trusted database state before each run. They are
not user-visible messages and they are not tools.

`handoff_to_bot` transfers the next stage to another active member of the current group. The request
and response remain in the shared group conversation.

`message_bot` delegates separate work to an active bot outside the current group. The recipient works
in its personal bot conversation and its result returns to the conversation where the delegation
originated.

## Server invariant

Tool guidance alone is insufficient because a model can supply any known bot ID. The server derives
the originating group from the trusted run thread and applies this rule before creating any message,
task, run, event, notification, or job:

- A personal conversation may use `message_bot` for any other active bot. Membership of unrelated
  groups does not affect that personal exchange.
- A group conversation may use `message_bot` for an active bot outside that group.
- A group conversation may not use `message_bot` for another active member of that same group. The
  error explains that a private side conversation would split the exchange and instructs the caller
  to use `handoff_to_bot` so both sides remain in the group.

The membership check shares the group row lock used by group membership edits. This makes the routing
decision and group membership update deterministic relative to one another.

## Examples

Assume Ellie and Churchill are members of a group and Marco is not:

| Originating conversation | Action | Result destination |
| --- | --- | --- |
| Ellie's personal conversation | Ellie uses `message_bot` for Churchill | Ellie's personal conversation |
| Shared group | Ellie uses `handoff_to_bot` for Churchill | Shared group |
| Shared group | Ellie uses `message_bot` for Marco | Shared group |
| Marco's personal conversation | Marco uses `message_bot` for Ellie | Marco's personal conversation |

In every `message_bot` case, the recipient performs the delegated run in its own personal bot
conversation. “Result destination” identifies where the automatic result is returned.
