import type { AgentRuntimeEvent } from "@rakazo/adapter-kit";
import { describe, expect, it } from "vitest";
import { ScriptedAgentRuntime } from "./scripted-runtime.js";

describe("ScriptedAgentRuntime executionIds", () => {
  it("gives repeated tools distinct executionIds within a run", async () => {
    const runtime = new ScriptedAgentRuntime();
    const events: AgentRuntimeEvent[] = [];
    for await (const event of runtime.run({
      botId: "bot-1",
      threadId: "thread-1",
      runId: "run-1",
      prompt: "ping",
      instructions: "",
      history: [],
      tools: [],
      model: { provider: "scripted", id: "scripted" },
      script: [
        {
          toolCalls: [
            { name: "message_agent", args: { phone: "+15551111111", message: "one" } },
            { name: "message_agent", args: { phone: "+15551111111", message: "two" } },
          ],
          complete: true,
        },
      ],
    })) {
      events.push(event);
    }

    const toolIds = events
      .filter(
        (event): event is Extract<AgentRuntimeEvent, { type: "tool" }> => event.type === "tool",
      )
      .map((event) => event.executionId);
    expect(toolIds).toEqual(["run-1:message_agent:0", "run-1:message_agent:1"]);
  });

  it("creates a focused group without requiring other bot ids", async () => {
    const runtime = new ScriptedAgentRuntime();
    const events: AgentRuntimeEvent[] = [];
    for await (const event of runtime.run({
      botId: "bot-1",
      threadId: "thread-1",
      runId: "run-1",
      prompt:
        "create a group named Focus room; shared context [Keep this topic separate.] creator context [Private notes.]",
      instructions: "",
      history: [],
      tools: [],
      model: { provider: "scripted", id: "scripted" },
    })) {
      events.push(event);
    }

    expect(events.find((event) => event.type === "tool")).toMatchObject({
      type: "tool",
      name: "create_group",
      args: {
        name: "Focus room",
        member_bot_ids: [],
        shared_context: "Keep this topic separate.",
        creator_context: "Private notes.",
      },
    });
  });
});
