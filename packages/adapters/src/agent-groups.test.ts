import { beforeEach, describe, expect, it, vi } from "vitest";

const createGroup = vi.hoisted(() => vi.fn());
const getGroupByCreateKey = vi.hoisted(() => vi.fn());

vi.mock("@rakazo/db", () => ({
  IsolationError: class IsolationError extends Error {},
  createGroupRepos: () => ({ createGroup, getGroupByCreateKey }),
}));

import { IsolationError } from "@rakazo/db";
import { createAgentGroup } from "./agent-groups.js";

const creator = {
  id: "creator-1",
  name: "Coordinator",
  workspaceId: "workspace-1",
  userId: "user-1",
};

function fakePrisma() {
  return {} as never;
}

describe("createAgentGroup", () => {
  beforeEach(() => {
    getGroupByCreateKey.mockReset().mockResolvedValue(null);
    createGroup.mockReset().mockResolvedValue({
      id: "group-1",
      name: "Project team",
      members: [{}, {}, {}],
      threadId: "thread-1",
    });
  });

  it("automatically includes the creator and stores both contexts", async () => {
    const prisma = fakePrisma();
    await expect(
      createAgentGroup(prisma, {
        creator,
        createKey: "effect-1",
        name: " Project team ",
        memberBotIds: ["bot-2", "bot-3"],
        sharedContext: " Shared requirements ",
        creatorContext: " Private coordination notes ",
      }),
    ).resolves.toEqual({
      ok: true,
      groupId: "group-1",
      name: "Project team",
      memberCount: 3,
      threadId: "thread-1",
    });

    expect(createGroup).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({
        botIds: ["creator-1", "bot-2", "bot-3"],
        creatorBotId: "creator-1",
        creatorContext: "Private coordination notes",
        createKey: "effect-1",
        initialContext: {
          kind: "group_context",
          creatorBotId: "creator-1",
          creatorBotName: "Coordinator",
          text: "Shared requirements",
        },
      }),
    );
  });

  it.each([undefined, []])(
    "creates a focused group with only the creator from %j",
    async (memberBotIds) => {
      createGroup.mockResolvedValueOnce({
        id: "group-1",
        name: "Private campaign",
        members: [{}],
        threadId: "thread-1",
      });

      await expect(
        createAgentGroup(fakePrisma(), {
          creator,
          createKey: "effect-solo",
          name: "Private campaign",
          memberBotIds,
          sharedContext: "Keep this story separate from the main conversation.",
        }),
      ).resolves.toMatchObject({ ok: true, memberCount: 1 });

      expect(createGroup).toHaveBeenCalledWith(
        expect.anything(),
        expect.objectContaining({ botIds: ["creator-1"] }),
      );
    },
  );

  it("stores shared context without creator-only context", async () => {
    await createAgentGroup(fakePrisma(), {
      creator,
      createKey: "effect-shared",
      name: "Research",
      memberBotIds: ["bot-2"],
      sharedContext: "Shared requirements",
    });
    expect(createGroup).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({
        creatorContext: undefined,
        initialContext: expect.objectContaining({ text: "Shared requirements" }),
      }),
    );
  });

  it("stores creator-only context without shared context", async () => {
    await createAgentGroup(fakePrisma(), {
      creator,
      createKey: "effect-private",
      name: "Research",
      memberBotIds: ["bot-2"],
      creatorContext: "Private coordination notes",
    });
    expect(createGroup).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({
        creatorContext: "Private coordination notes",
        initialContext: undefined,
      }),
    );
  });

  it("treats blank contexts as absent and creates no starting message", async () => {
    await createAgentGroup(fakePrisma(), {
      creator,
      createKey: "effect-2",
      name: "Research",
      memberBotIds: ["bot-2"],
      sharedContext: "  ",
      creatorContext: "\n",
    });
    expect(createGroup).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({ creatorContext: undefined, initialContext: undefined }),
    );
  });

  it.each([
    [["creator-1"], "Do not include the creating bot"],
    [["bot-2", "bot-2"], "distinct"],
    [["a", "b", "c", "d", "e", "f"], "up to 5"],
  ])("rejects invalid member IDs %#", async (memberBotIds, message) => {
    const result = await createAgentGroup(fakePrisma(), {
      creator,
      createKey: "effect-invalid",
      name: "Team",
      memberBotIds,
    });
    expect(result).toEqual({ error: expect.stringContaining(message) });
    expect(createGroup).not.toHaveBeenCalled();
  });

  it("rejects archived, foreign, or missing bots", async () => {
    createGroup.mockRejectedValueOnce(new IsolationError());
    const result = await createAgentGroup(fakePrisma(), {
      creator,
      createKey: "effect-3",
      name: "Team",
      memberBotIds: ["bot-2", "bot-3"],
    });
    expect(result).toEqual({
      error: "Every group member must be one of the user's active bots in this workspace.",
    });
    expect(createGroup).toHaveBeenCalledOnce();
  });

  it("returns the original group before revalidating members on a retry", async () => {
    getGroupByCreateKey.mockResolvedValue({
      id: "group-1",
      name: "Project team",
      threadId: "thread-1",
      members: [{}, {}, {}],
    });
    await expect(
      createAgentGroup(fakePrisma(), {
        creator,
        createKey: "effect-1",
        name: "Project team",
        memberBotIds: ["bot-2", "bot-3"],
      }),
    ).resolves.toMatchObject({ ok: true, duplicate: true, groupId: "group-1" });
    expect(createGroup).not.toHaveBeenCalled();
  });
});
