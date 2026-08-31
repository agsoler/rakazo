import { beforeEach, describe, expect, it, vi } from "vitest";
import type { PrismaClient } from "./client.js";
import { createGroupRepos } from "./groups.js";
import { IsolationError } from "./scope.js";

describe("listGroups", () => {
  const actor = {
    workspaceId: "workspace-1",
    userId: "user-1",
    email: "user@example.com",
    isDeploymentOwner: true,
  };

  function groupWithRuns(input: {
    botRuns?: Array<{ status: string; threadId: string }>;
    groupRuns?: Array<{ botId: string; status: string }>;
  }) {
    return {
      id: "group-1",
      workspaceId: actor.workspaceId,
      userId: actor.userId,
      name: "Research",
      pinned: false,
      sectionId: null,
      archivedAt: null,
      createdAt: new Date("2026-08-31T10:00:00.000Z"),
      updatedAt: new Date("2026-08-31T10:00:00.000Z"),
      thread: {
        id: "group-thread",
        unread: false,
        messages: [],
        runs: input.groupRuns ?? [],
      },
      members: [
        {
          bot: {
            id: "bot-1",
            name: "Researcher",
            color: "#8B5CF6",
            runs: input.botRuns ?? [],
          },
        },
        {
          bot: {
            id: "bot-2",
            name: "Writer",
            color: "#06B6D4",
            runs: [],
          },
        },
      ],
    };
  }

  it("keeps a group idle when its member is running in a personal thread", async () => {
    const findMany = vi
      .fn()
      .mockResolvedValue([
        groupWithRuns({ botRuns: [{ status: "running", threadId: "personal-thread" }] }),
      ]);
    const prisma = { chatGroup: { findMany } } as unknown as PrismaClient;

    const groups = await createGroupRepos(prisma).listGroups(actor);

    expect(groups[0]?.members[0]?.status).toBe("idle");
  });

  it("reports activity that belongs to the group thread", async () => {
    const findMany = vi
      .fn()
      .mockResolvedValue([
        groupWithRuns({ groupRuns: [{ botId: "bot-1", status: "waiting_input" }] }),
      ]);
    const prisma = { chatGroup: { findMany } } as unknown as PrismaClient;

    const groups = await createGroupRepos(prisma).listGroups(actor);

    expect(groups[0]?.members[0]?.status).toBe("waiting_input");
  });
});

describe("archiveGroup", () => {
  const actor = {
    workspaceId: "workspace-1",
    userId: "user-1",
    email: "user@example.com",
    isDeploymentOwner: true,
  };
  let queryRaw: ReturnType<typeof vi.fn>;
  let findFirst: ReturnType<typeof vi.fn>;
  let findManyRuns: ReturnType<typeof vi.fn>;
  let findManyComputers: ReturnType<typeof vi.fn>;
  let runUpdateMany: ReturnType<typeof vi.fn>;
  let attemptUpdateMany: ReturnType<typeof vi.fn>;
  let taskUpdateMany: ReturnType<typeof vi.fn>;
  let leaseDeleteMany: ReturnType<typeof vi.fn>;
  let computerUpdateMany: ReturnType<typeof vi.fn>;
  let eventDeleteMany: ReturnType<typeof vi.fn>;
  let groupUpdate: ReturnType<typeof vi.fn>;
  let prisma: PrismaClient;

  beforeEach(() => {
    queryRaw = vi.fn().mockResolvedValue([{ id: "group-1" }]);
    findFirst = vi.fn().mockResolvedValue({ thread: { id: "thread-1" } });
    findManyRuns = vi.fn().mockResolvedValue([{ id: "run-1", taskId: "task-1" }]);
    findManyComputers = vi.fn().mockResolvedValue([
      {
        homeKey: "home-1",
        kind: "fake",
        providerRef: "computer-1",
        executionBotId: "bot-1",
      },
    ]);
    runUpdateMany = vi.fn();
    attemptUpdateMany = vi.fn();
    taskUpdateMany = vi.fn();
    leaseDeleteMany = vi.fn();
    computerUpdateMany = vi.fn();
    eventDeleteMany = vi.fn();
    groupUpdate = vi.fn();
    const tx = {
      $queryRaw: queryRaw,
      chatGroup: { findFirst, update: groupUpdate },
      run: { findMany: findManyRuns, updateMany: runUpdateMany },
      attempt: { updateMany: attemptUpdateMany },
      task: { updateMany: taskUpdateMany },
      computerExecutionLease: { deleteMany: leaseDeleteMany },
      computer: { findMany: findManyComputers, updateMany: computerUpdateMany },
      event: { deleteMany: eventDeleteMany },
    };
    prisma = {
      $transaction: vi.fn(async (callback: (client: typeof tx) => unknown) => callback(tx)),
    } as unknown as PrismaClient;
  });

  it("locks the group, archives it, and cancels only that thread's runs", async () => {
    const repos = createGroupRepos(prisma);

    await expect(repos.archiveGroup(actor, "group-1")).resolves.toEqual({
      cancelledRunIds: ["run-1"],
      computers: [
        {
          homeKey: "home-1",
          kind: "fake",
          providerRef: "computer-1",
          executionBotId: "bot-1",
        },
      ],
    });

    expect(queryRaw).toHaveBeenCalled();
    expect(findManyRuns).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({ threadId: "thread-1" }),
      }),
    );
    expect(findFirst).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({
          id: "group-1",
          archivedAt: null,
        }),
      }),
    );
    expect(leaseDeleteMany).toHaveBeenCalledWith({ where: { runId: { in: ["run-1"] } } });
    expect(computerUpdateMany).toHaveBeenCalledWith({
      where: { executionRunId: { in: ["run-1"] } },
      data: {
        executionRunId: null,
        executionBotId: null,
        executionLeaseExpiresAt: null,
      },
    });
    expect(groupUpdate).toHaveBeenCalledWith({
      where: { id: "group-1" },
      data: expect.objectContaining({ pinned: false, archivedAt: expect.any(Date) }),
    });
  });

  it("rejects when the group is already archived or missing", async () => {
    findFirst.mockResolvedValue(null);
    const repos = createGroupRepos(prisma);
    await expect(repos.archiveGroup(actor, "group-1")).rejects.toBeInstanceOf(IsolationError);
    expect(groupUpdate).not.toHaveBeenCalled();
  });
});

describe("bot-created group persistence", () => {
  const actor = {
    workspaceId: "workspace-1",
    userId: "user-1",
    email: "user@example.com",
    isDeploymentOwner: true,
  };

  function groupRecord() {
    return {
      id: "group-1",
      workspaceId: actor.workspaceId,
      userId: actor.userId,
      name: "Project team",
      pinned: false,
      sectionId: null,
      archivedAt: null,
      creatorBotId: "bot-1",
      creatorContext: "Private notes",
      createKey: "effect-1",
      createdAt: new Date("2026-08-30T00:00:00Z"),
      updatedAt: new Date("2026-08-30T00:00:00Z"),
      thread: {
        id: "thread-1",
        unread: false,
        messages: [
          {
            blocks: [
              {
                kind: "group_context",
                creatorBotId: "bot-1",
                creatorBotName: "Coordinator",
                text: "Shared requirements",
              },
            ],
          },
        ],
      },
      members: ["bot-1", "bot-2"].map((id) => ({
        bot: { id, name: id, color: "#111111", runs: [] },
      })),
    };
  }

  it("creates the group, members, thread, and shared message in one transaction", async () => {
    const record = groupRecord();
    const tx = {
      bot: {
        findMany: vi.fn(async () =>
          record.members.map((member) => ({
            id: member.bot.id,
            name: member.bot.name,
            color: member.bot.color,
          })),
        ),
      },
      chatGroup: {
        findFirst: vi.fn(async () => null),
        create: vi.fn(async () => ({ id: record.id })),
        findFirstOrThrow: vi.fn(async () => record),
      },
      chatGroupMember: { createMany: vi.fn(async () => ({ count: 2 })) },
      thread: {
        create: vi.fn(async () => ({ id: "thread-1" })),
        update: vi.fn(async () => ({ nextMessageSeq: 1 })),
      },
      message: { create: vi.fn(async () => ({ id: "message-1" })) },
    };
    const prisma = {
      $transaction: vi.fn(async (callback: (client: typeof tx) => unknown) => callback(tx)),
    } as unknown as PrismaClient;

    const created = await createGroupRepos(prisma).createGroup(actor, {
      name: "Project team",
      botIds: ["bot-1", "bot-2"],
      creatorBotId: "bot-1",
      creatorContext: "Private notes",
      createKey: "effect-1",
      initialContext: record.thread.messages[0]!.blocks[0] as never,
    });

    expect(created.id).toBe("group-1");
    expect(prisma.$transaction).toHaveBeenCalledTimes(1);
    expect(tx.chatGroup.create).toHaveBeenCalledWith({
      data: expect.objectContaining({
        creatorBotId: "bot-1",
        creatorContext: "Private notes",
        createKey: "effect-1",
      }),
    });
    expect(tx.message.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          threadId: "thread-1",
          role: "user",
          blocks: record.thread.messages[0]!.blocks,
        }),
      }),
    );
    expect(tx).not.toHaveProperty("task");
    expect(tx).not.toHaveProperty("run");
  });

  it("returns the original group for the same create key", async () => {
    const record = groupRecord();
    const tx = {
      chatGroup: {
        findFirst: vi.fn(async () => record),
        create: vi.fn(),
      },
      bot: { findMany: vi.fn() },
    };
    const prisma = {
      $transaction: vi.fn(async (callback: (client: typeof tx) => unknown) => callback(tx)),
    } as unknown as PrismaClient;

    await expect(
      createGroupRepos(prisma).createGroup(actor, {
        name: "Project team",
        botIds: ["bot-1", "bot-2"],
        creatorBotId: "bot-1",
        createKey: "effect-1",
      }),
    ).resolves.toMatchObject({ id: "group-1" });
    expect(tx.chatGroup.create).not.toHaveBeenCalled();
    expect(tx.bot.findMany).not.toHaveBeenCalled();
  });
});
