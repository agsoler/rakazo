import {
  type Actor,
  GROUP_CONTEXT_MAX_LENGTH,
  GROUP_MEMBER_MAX,
  GROUP_NAME_MAX_LENGTH,
} from "@rakazo/contracts";
import { createGroupRepos, IsolationError, type PrismaClient } from "@rakazo/db";

export interface CreateAgentGroupInput {
  creator: {
    id: string;
    name: string;
    workspaceId: string;
    userId: string;
  };
  createKey: string;
  name: string;
  memberBotIds?: unknown;
  sharedContext?: string;
  creatorContext?: string;
}

export async function createAgentGroup(prisma: PrismaClient, input: CreateAgentGroupInput) {
  const actor: Actor = {
    workspaceId: input.creator.workspaceId,
    userId: input.creator.userId,
    email: "",
    isDeploymentOwner: false,
  };
  const groups = createGroupRepos(prisma);
  const existing = await groups.getGroupByCreateKey(actor, input.createKey);
  if (existing) {
    return {
      ok: true as const,
      duplicate: true as const,
      groupId: existing.id,
      name: existing.name,
      memberCount: existing.members.length,
      threadId: existing.threadId,
    };
  }
  const name = input.name.trim();
  if (!name) return { error: "Group name is required." };
  if (name.length > GROUP_NAME_MAX_LENGTH) {
    return { error: `Group name must be ${GROUP_NAME_MAX_LENGTH} characters or fewer.` };
  }
  const rawMemberBotIds = input.memberBotIds ?? [];
  if (!Array.isArray(rawMemberBotIds)) {
    return { error: "member_bot_ids must be a list of bot IDs." };
  }
  const memberBotIds = rawMemberBotIds.map((value) =>
    typeof value === "string" ? value.trim() : "",
  );
  if (memberBotIds.some((id) => !id)) {
    return { error: "Every member_bot_ids entry must be a bot ID." };
  }
  if (memberBotIds.length > GROUP_MEMBER_MAX - 1) {
    return { error: `Choose up to ${GROUP_MEMBER_MAX - 1} other bots.` };
  }
  if (new Set(memberBotIds).size !== memberBotIds.length) {
    return { error: "member_bot_ids must contain distinct bot IDs." };
  }
  if (memberBotIds.includes(input.creator.id)) {
    return {
      error: "Do not include the creating bot in member_bot_ids; it joins automatically.",
    };
  }

  const sharedContext = normalizeContext(input.sharedContext);
  const creatorContext = normalizeContext(input.creatorContext);
  if (sharedContext && sharedContext.length > GROUP_CONTEXT_MAX_LENGTH) {
    return { error: `shared_context must be ${GROUP_CONTEXT_MAX_LENGTH} characters or fewer.` };
  }
  if (creatorContext && creatorContext.length > GROUP_CONTEXT_MAX_LENGTH) {
    return { error: `creator_context must be ${GROUP_CONTEXT_MAX_LENGTH} characters or fewer.` };
  }

  const botIds = [input.creator.id, ...memberBotIds];
  let group: Awaited<ReturnType<typeof groups.createGroup>>;
  try {
    group = await groups.createGroup(actor, {
      name,
      botIds,
      creatorBotId: input.creator.id,
      creatorContext,
      createKey: input.createKey,
      initialContext: sharedContext
        ? {
            kind: "group_context",
            creatorBotId: input.creator.id,
            creatorBotName: input.creator.name,
            text: sharedContext,
          }
        : undefined,
    });
  } catch (error) {
    if (error instanceof IsolationError) {
      return {
        error: "Every group member must be one of the user's active bots in this workspace.",
      };
    }
    throw error;
  }
  return {
    ok: true as const,
    groupId: group.id,
    name: group.name,
    memberCount: group.members.length,
    threadId: group.threadId,
  };
}

function normalizeContext(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}
