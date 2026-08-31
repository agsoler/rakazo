# Shared bot guidance and knowledge

## Decision

Rakazo will not gain a private `teamInstructions` field or another hidden workspace-wide system
prompt on this development branch.

Operational rules that define how a built-in tool should be used belong with that tool. The
`message_bot` intent meanings therefore remain in its tool metadata, as implemented by commit
`aed6a415` on `feat/group-aware-bot-collaboration`.

Broader team knowledge and user preferences belong in durable memory. A future user-facing feature
should expose that existing memory as an explicit, editable space handbook rather than silently
elevating it to system-prompt authority. General collaboration etiquette may also be offered as an
optional bot-operations skill, but a skill must not be required to understand a built-in tool.

## Why this was reconsidered

Upstream pull request [#418](https://github.com/elie222/rakazo/pull/418) implemented
`Organization.teamInstructions` and prepended it to every bot's instructions. It was closed without
merging. The maintainer rejected the product direction: shared knowledge should live in user/project
memory rather than in a workspace prompt hidden from normal conversation.

That decision rules out using `teamInstructions` as the contribution path. Maintaining the rejected
implementation only in our fork would also add a database migration, settings interface, prompt
composition logic, and recurring merge conflicts for a feature whose precedence and context-budget
rules remain unresolved.

## What Rakazo already provides

| Mechanism | Scope | Automatically available to the model? | Authority and purpose |
| --- | --- | --- | --- |
| Bot instructions | One bot | Yes, on every run | Instructions defining that bot's identity and behaviour |
| Built-in tool metadata | Runs exposing that tool | Yes, alongside the tool schema | The authoritative interface for choosing and calling that tool |
| Native durable memory | Bot scope plus user/space scope | Yes, on every run, subject to a 32 KiB combined cap | Background knowledge; explicitly labelled as possibly outdated data, not instructions |
| Optional semantic-memory provider | Isolated or shared, according to configuration | Relevant results are recalled through the provider | Searchable background knowledge; not a universal default |
| Team Computer `shared/` folder | Bots sharing that computer | No; a bot must deliberately list or read files | Shared working files and artifacts, not instinctive knowledge |
| Conversation or group history | One thread | Yes, subject to compaction | The record and context of that conversation only |

Native durable memory is Markdown-shaped content stored in PostgreSQL's `memory_documents` and
`memory_revisions` tables. It is not a file that bots automatically discover on the Team Computer.
Before each run, `loadAgentMemoryContext` reads both the current bot's memory and the current user's
shared memory, orders the documents by recency, caps the combined block, and supplies it to the model
inside `<durable_memory>`.

On current upstream, the user-level document is scoped to a Space. Every one of that user's bots in
the same Space receives it. The repository still calls the document's scope `user`, which means it
is shared between that user's bots rather than between every human member of an organization.

The Team Computer filesystem solves a different problem. Bots can deliberately collaborate through
`shared/`, but Rakazo does not scan that directory into every prompt. A handbook stored only there is
invisible until a bot decides to read it or is told where to find it.

## The actual gap

The default database memory already has a shared scope, but the product does not make it an obvious
team knowledge surface:

- Rakazo creates a shared user/space `MEMORY.md` document and loads it for every bot run.
- The API can list and update native memory documents.
- The current web memory settings manage the optional semantic-memory provider; they do not provide
  a normal editor for the shared native document.
- The built-in `remember` tool writes only to the calling bot's private native memory.
- Consequently, shared memory is technically present but difficult for an ordinary user or bot to
  curate deliberately.

This is a defensible future enhancement: expose a clearly named shared memory or space handbook in
the UI, backed by the existing `MemoryStore`, with revisions, export, and normal space isolation. It
should remain visible background knowledge rather than a hidden system instruction.

## Guidance versus enforcement

Memory can communicate preferences such as "use `fyi` for a message that requires no work," but it
cannot define or enforce the `message_bot` interface. It may be outdated, omitted by the context cap,
or ignored by the model. Tool metadata is therefore the correct home for the five intent meanings.
Server-side invariants remain necessary wherever a wrong choice could violate routing, security, or
data integrity.

The merged upstream work in [#385](https://github.com/elie222/rakazo/pull/385) follows this principle:
the model-supplied intent remains useful guidance, while durable reply relationships protect result
delivery when the model labels a reply incorrectly.

## Revisit only if

A future requirement genuinely needs owner-authored instructions rather than knowledge. Before
adding such a layer, the design must explicitly settle:

- where it appears in the prompt-precedence order;
- whether models and users can distinguish it from product policy;
- its space, user, and bot visibility;
- context budgeting and truncation behaviour;
- editing, auditing, export, and migration;
- how it differs from bot instructions, memory, and skills.

Until those questions have a product-level answer, no private global-prompt implementation will be
carried on the integration branch.
