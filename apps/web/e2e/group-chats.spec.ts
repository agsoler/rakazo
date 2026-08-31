import { expect, test } from "@playwright/test";
import {
  activeBotId,
  captureScreenshot,
  completeOnboarding,
  openNewBot,
  rpc,
  signup,
} from "./helpers";

async function createBot(page: import("@playwright/test").Page, name: string) {
  const botList = page.locator("aside").first();
  await openNewBot(page);
  await expect(page.getByText("New bot", { exact: true })).toBeVisible();
  await page.locator("label:has-text('Name') input").fill(name);
  await page.getByRole("button", { name: "Create", exact: true }).click();
  await expect(botList.getByRole("button", { name: new RegExp(`^${name}`) })).toBeVisible();
  await expect(page.getByRole("textbox", { name: `Message ${name}` })).toBeVisible();
  await page.waitForURL(/\/app\/[^/]+$/);
  return activeBotId(page);
}

test("two-bot member picker does not flicker its scrollbar", async ({ page }) => {
  const stamp = Date.now();
  await signup(page, `group-scroll-${stamp}@rakazo.test`, "password12", "Group Scroll E2E");
  await completeOnboarding(page);
  await page.goto("/app");
  await page.waitForURL(/\/app\/[^/]+$/);

  const firstBotId = await activeBotId(page);
  const secondBotId = await createBot(page, "Second member");
  const group = await rpc<{ id: string }>(page, "groups/create", {
    name: "Stable member picker",
    botIds: [firstBotId, secondBotId],
  });

  await page.goto(`/app/g/${group.id}`);
  await page.getByTestId("bot-settings-trigger").click();
  const settings = page.getByTestId("side-panel");
  const memberPicker = settings.locator("div.mt-2.max-h-\\[240px\\].overflow-y-auto");
  await expect(memberPicker).toBeVisible();

  const states = await memberPicker.evaluate(async (element) => {
    const observed: Array<{ clientWidth: number; overflow: boolean }> = [];
    let previous = "";
    for (let sample = 0; sample < 150; sample++) {
      const state = {
        clientWidth: element.clientWidth,
        overflow: element.scrollHeight > element.clientHeight,
      };
      const key = JSON.stringify(state);
      if (key !== previous) observed.push(state);
      previous = key;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    return observed;
  });

  expect(states).toHaveLength(1);
  expect(states[0]).toMatchObject({ overflow: false });
});

test("bot-created contextual group card opens the group and owner-visible settings", async ({
  page,
}) => {
  const stamp = Date.now();
  await signup(page, `bot-group-${stamp}@rakazo.test`, "password12", "Bot Group E2E");
  await completeOnboarding(page);
  const chiefId = activeBotId(page);
  const researcherId = await createBot(page, "Context Researcher");
  await page
    .locator("aside")
    .first()
    .getByRole("button", { name: /^Chief/ })
    .click();
  await page.waitForURL(new RegExp(`/app/${chiefId}$`));

  const composer = page.getByRole("textbox", { name: "Message Chief" });
  await composer.fill(
    `create a group named Launch team with bot ids ${researcherId}; shared context [Prepare a concise launch brief.] creator context [Coordinate the final review privately.]`,
  );
  await composer.press("Enter");
  const groupCard = page.getByRole("button", { name: /Launch team.*group.*2 members/i });
  await expect(groupCard).toBeVisible({ timeout: 60_000 });
  await groupCard.click();
  await page.waitForURL(/\/app\/g\/[^/]+$/);
  await expect(page.getByText("Shared starting context", { exact: false }).first()).toBeVisible();
  await expect(
    page.getByTestId("transcript").getByText("Prepare a concise launch brief.", { exact: true }),
  ).toBeVisible();

  await page.getByTestId("bot-settings-trigger").click();
  const settings = page.getByTestId("side-panel");
  await expect(settings.getByText("Created by", { exact: true })).toBeVisible();
  await expect(settings.getByTestId("group-creator-name")).toHaveText("Chief");
  await expect(settings.getByText("Shared starting context", { exact: true })).toBeVisible();
  await expect(
    settings.getByText("Prepare a concise launch brief.", { exact: true }),
  ).toBeVisible();
  await expect(settings.getByText("Creator-only starting context", { exact: true })).toBeVisible();
  await expect(
    settings.getByText("Coordinate the final review privately.", { exact: true }),
  ).toBeVisible();

  let groupListRefreshes = 0;
  let groupDetailRefetches = 0;
  await page.route("**/rpc/groups/list", async (route) => {
    groupListRefreshes += 1;
    await route.continue();
  });
  await page.route("**/rpc/groups/get", async (route) => {
    groupDetailRefetches += 1;
    await new Promise((resolve) => setTimeout(resolve, 300));
    await route.continue();
  });

  const settingsScroll = settings.locator(".rk-scroll");
  await settingsScroll.evaluate((element) => {
    element.setAttribute("data-context-unmounted", "false");
    const observer = new MutationObserver(() => {
      if (!element.textContent?.includes("Created by")) {
        element.setAttribute("data-context-unmounted", "true");
      }
    });
    observer.observe(element, { childList: true, subtree: true });
  });

  await rpc(page, "bots/create", {
    name: "Refresh trigger",
    title: "",
    description: "",
    instructions: "",
    notifyOnFinish: false,
  });
  await expect.poll(() => groupListRefreshes).toBeGreaterThan(0);
  await page.waitForTimeout(500);

  await expect(settingsScroll).toHaveAttribute("data-context-unmounted", "false");
  expect(groupDetailRefetches).toBeGreaterThan(0);

  const closeSettings = settings.getByRole("button", { name: "Close group settings" });
  await expect(closeSettings).toHaveCSS("cursor", "pointer");
  await closeSettings.hover();
  await expect(closeSettings).toHaveCSS("color", "rgb(236, 236, 238)");
  await expect(closeSettings).toHaveCSS("background-color", "rgb(26, 26, 29)");
  await closeSettings.click();
  await expect(settings).toHaveAttribute("data-panel", "closed");

  const launchTeam = page
    .locator("aside")
    .first()
    .getByRole("button", { name: /^Launch team/ });
  await launchTeam.click({ button: "right" });
  await page.getByRole("menuitem", { name: "Clear conversation", exact: true }).click();
  const clearDialog = page.getByRole("alertdialog", {
    name: "Clear Launch team’s conversation?",
  });
  await expect(clearDialog).toBeVisible();
  await clearDialog.getByRole("button", { name: "Clear", exact: true }).click();
  await expect(clearDialog).toHaveCount(0);
  await expect(
    page.getByTestId("transcript").getByText("Prepare a concise launch brief.", { exact: true }),
  ).toBeVisible();

  await page.getByTestId("bot-settings-trigger").click();
  await expect(
    page.getByTestId("side-panel").getByText("Prepare a concise launch brief.", { exact: true }),
  ).toBeVisible();
  await expect(
    page
      .getByTestId("side-panel")
      .getByText("Coordinate the final review privately.", { exact: true }),
  ).toBeVisible();
});

test("create group from + and see two bots in one transcript", async ({ page }, testInfo) => {
  const stamp = Date.now();
  await signup(page, `group-${stamp}@rakazo.test`, "password12", "Group E2E");
  await completeOnboarding(page);
  await page.goto("/app");
  await page.waitForURL(/\/app\/[^/]+$/);

  const researcherId = await createBot(page, "Researcher");
  const writerId = await createBot(page, "Research Writer");

  await page.getByTitle("Create").click();
  await page.getByRole("button", { name: "New group" }).click();
  await page.locator("label:has-text('Name') input").fill("Draft team");
  const panel = page.getByTestId("side-panel");
  await panel.getByRole("button", { name: "Researcher" }).click();
  await panel.getByRole("button", { name: "Research Writer" }).click();
  await captureScreenshot(page, testInfo, "group-creation");
  await page.route("**/rpc/groups/create", async (route) => route.abort("failed"));
  await page.getByRole("button", { name: "Create group", exact: true }).click();
  await expect(panel.getByRole("alert")).toHaveText("Failed to fetch");
  await expect(page.getByRole("button", { name: "Create group", exact: true })).toBeEnabled();
  await page.unroute("**/rpc/groups/create");
  await page.getByRole("button", { name: "Create group", exact: true }).click();
  await page.waitForURL(/\/app\/g\/[^/]+$/);
  const groupUrl = page.url();
  const draftGroupId = new URL(groupUrl).pathname.split("/").at(-1)!;
  const reviewGroup = await rpc<{ id: string }>(page, "groups/create", {
    name: "Review team",
    botIds: [researcherId, writerId],
  });
  await rpc(page, "voice/connect", {
    provider: "scripted",
    apiKey: "fake-group-voice-key",
  });
  await page.reload();
  await expect(page).toHaveURL(groupUrl);
  await expect(page.getByRole("textbox", { name: "Message Draft team" })).toBeVisible();

  const groups = await rpc<
    Array<{
      id: string;
      members: Array<{ botId: string; name: string; color: string; status?: string }>;
    }>
  >(page, "groups/list", {});
  const groupSnapshot = await rpc<{
    members?: Array<{ botId: string; name: string; color: string; status?: string }>;
  }>(page, "threads/get", { groupId: draftGroupId });
  await page.route("**/rpc/groups/list", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        json: groups.map((group) => ({
          ...group,
          members: group.members.map((member, index) => ({
            ...member,
            status: index === 0 ? "running" : "idle",
          })),
        })),
      }),
    });
  });
  await page.route("**/rpc/threads/get", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        json: {
          ...groupSnapshot,
          members: groupSnapshot.members?.map((member, index) => ({
            ...member,
            status: index === 0 ? "running" : "idle",
          })),
        },
      }),
    });
  });
  await page.reload();
  // Anchor ^ so Now/Recent activity rows ("Bot · Draft team, …") do not match.
  const groupAvatar = page
    .locator("aside")
    .first()
    .getByRole("button", { name: /^Draft team/ })
    .locator(".rakazo-group-avatar");
  await expect(groupAvatar).toBeVisible();
  await expect(groupAvatar.locator(".rakazo-bot-avatar")).toHaveCount(2);
  const workingAvatar = groupAvatar.locator('[data-working="true"]');
  await expect(workingAvatar).toHaveCount(1);
  await expect(workingAvatar.locator(".rakazo-bot-avatar-ring")).toHaveCSS(
    "animation-name",
    "rakazo-avatar-spin",
  );
  await captureScreenshot(page, testInfo, "group-avatar-active");
  await page.unroute("**/rpc/groups/list");
  await page.unroute("**/rpc/threads/get");
  await page.reload();

  await page.getByTestId("bot-settings-trigger").click();
  const desktopSettings = page.getByTestId("side-panel");
  const groupName = desktopSettings.locator("label:has-text('Name') input");
  await groupName.fill("Unsaved Draft team name");
  const sidebar = page.locator("aside").first();
  await sidebar.getByRole("button", { name: /^Review team/ }).click();
  await expect(groupName).toHaveValue("Review team");
  await sidebar.getByRole("button", { name: /^Draft team/ }).click();
  await expect(groupName).toHaveValue("Draft team");
  await page.route("**/rpc/groups/update", async (route) => route.abort("failed"));
  await desktopSettings.getByRole("button", { name: "Save", exact: true }).click();
  await expect(desktopSettings.getByRole("alert")).toHaveText("Failed to fetch");
  await expect(desktopSettings.getByRole("button", { name: "Save", exact: true })).toBeEnabled();
  await page.unroute("**/rpc/groups/update");
  await desktopSettings.getByRole("button", { name: "Save", exact: true }).click();

  await page
    .getByRole("textbox", { name: "Message Draft team" })
    .fill("@Researcher unfinished draft");
  await sidebar.getByRole("button", { name: /^Review team/ }).click();
  await expect(page.getByRole("textbox", { name: "Message Review team" })).toHaveValue("");
  await sidebar.getByRole("button", { name: /^Draft team/ }).click();
  await expect(page.getByRole("textbox", { name: "Message Draft team" })).toHaveValue("");

  const composer = page.getByRole("textbox", { name: "Message Draft team" });
  await composer.fill("@Res");
  await captureScreenshot(page, testInfo, "group-mention-picker");
  await page.getByRole("button", { name: "@Research Writer", exact: true }).click();
  await expect(
    page.getByTestId("mention-chip").filter({ hasText: "Research Writer" }),
  ).toBeVisible();
  await composer.fill("turn the sources into a draft. @Res");
  await page.getByRole("button", { name: "@Researcher", exact: true }).click();
  await expect(page.getByTestId("mention-chip").filter({ hasText: "Researcher" })).toBeVisible();
  await composer.fill(`${await composer.inputValue()}gather sources.`);
  await composer.press("Enter");

  await expect(page.getByTestId("transcript")).toContainText(/handled|on it|gather/i, {
    timeout: 60_000,
  });
  const transcript = page.getByTestId("transcript");
  await expect(transcript.getByText("Researcher", { exact: true }).first()).toBeVisible();
  await expect(transcript.getByText("Research Writer", { exact: true }).first()).toBeVisible();
  const researcherReply = transcript.getByText("Researcher", { exact: true }).first().locator("..");
  const [speechRequest] = await Promise.all([
    page.waitForRequest(
      (request) => request.url().includes("/api/voice/speak") && request.method() === "POST",
    ),
    researcherReply.getByRole("button", { name: "Speak this reply" }).click(),
  ]);
  expect(speechRequest.postDataJSON()).toMatchObject({ botId: researcherId });
  await captureScreenshot(page, testInfo, "group-transcript");

  await composer.fill("@Res");
  await page.getByRole("button", { name: "@Research Writer", exact: true }).click();
  await expect(
    page.getByTestId("mention-chip").filter({ hasText: "Research Writer" }),
  ).toBeVisible();
  await composer.fill("ask me which city to use");
  await composer.press("Enter");
  // threads/get / member status can observe waiting_input before realtime paints the ask card.
  await expect(page.getByRole("button", { name: /Research Writer waiting_input/ })).toBeVisible({
    timeout: 60_000,
  });
  const cityAsk = page.locator("p").filter({ hasText: /^Which city should I use\?$/ });
  if ((await cityAsk.count()) === 0) {
    await page.reload({ waitUntil: "domcontentloaded" });
    await expect(page.getByRole("textbox", { name: "Message Draft team" })).toBeVisible({
      timeout: 15_000,
    });
  }
  await expect(cityAsk).toBeVisible({ timeout: 15_000 });
  await page.getByRole("button", { name: "Edit first" }).click();
  await page.getByRole("textbox", { name: "Answer" }).fill("Paris");
  await page.getByRole("button", { name: "Send answer" }).click();
  await expect(page.getByText("Answered: Paris", { exact: true })).toBeVisible({ timeout: 30_000 });

  const firstMessage = transcript.locator("[data-message-id]").first();
  await firstMessage.hover();
  const replyButton = firstMessage.getByRole("button", { name: "Reply" });
  await expect(replyButton).toBeVisible();
  await replyButton.click();
  await expect(page.getByTestId("reply-chip")).toContainText(/Replying to/);
  await page.getByRole("button", { name: "Cancel reply" }).click();

  let releaseReviewSnapshot!: () => void;
  let sawReviewSnapshot!: () => void;
  const reviewSnapshotReleased = new Promise<void>((resolve) => {
    releaseReviewSnapshot = resolve;
  });
  const reviewSnapshotIntercepted = new Promise<void>((resolve) => {
    sawReviewSnapshot = resolve;
  });
  await page.route("**/rpc/threads/get", async (route) => {
    if (route.request().postData()?.includes(reviewGroup.id) !== true) {
      await route.continue();
      return;
    }
    sawReviewSnapshot();
    await reviewSnapshotReleased;
    await route.continue();
  });
  await sidebar.getByRole("button", { name: /^Review team/ }).click();
  await reviewSnapshotIntercepted;
  await expect(page).toHaveURL(new RegExp(`/app/g/${reviewGroup.id}$`));
  await expect(page.getByTestId("transcript")).not.toContainText("Answered: Paris");
  releaseReviewSnapshot();
  await expect(page.getByRole("textbox", { name: "Message Review team" })).toBeVisible();
  await page.unroute("**/rpc/threads/get");
  await sidebar.getByRole("button", { name: /^Draft team/ }).click();
  await expect(page.getByText("Answered: Paris", { exact: true })).toBeVisible();

  await composer.fill(
    "@Researcher write path notes/group-preview.md and attach it to the thread says # Group artifact",
  );
  await composer.press("Enter");
  const groupMarkdown = page.getByRole("button", { name: "Preview group-preview.md" });
  await expect(groupMarkdown).toBeVisible({ timeout: 30_000 });
  await groupMarkdown.click();
  const markdownDialog = page.getByRole("dialog", { name: "group-preview.md" });
  await expect(markdownDialog.getByRole("heading", { name: "Group artifact" })).toBeVisible();
  await markdownDialog.getByRole("button", { name: "Close preview" }).click();

  await page.setViewportSize({ width: 390, height: 844 });
  await expect(page.getByRole("button", { name: "Open navigation" })).toBeVisible();
  expect((await transcript.boundingBox())?.width).toBeGreaterThan(350);
  await page.getByRole("button", { name: "Open navigation" }).click();
  await expect(page.getByRole("button", { name: "Close navigation" })).toBeVisible();
  await page.getByRole("button", { name: "Close navigation" }).click();
  await page.getByTestId("bot-settings-trigger").click();
  const settings = page.getByTestId("side-panel");
  await expect(settings).toHaveAttribute("data-panel", "group-settings");
  expect((await settings.boundingBox())?.width).toBeLessThanOrEqual(390);
  await captureScreenshot(page, testInfo, "group-settings-mobile");

  await rpc(page, "groups/remove", { groupId: reviewGroup.id });
  await page.goto(`/app/g/${reviewGroup.id}`);
  await page.waitForURL(/\/app\/(?!g\/)[^/]+$/);
  await expect(page.getByRole("textbox", { name: /Message/ })).toBeVisible();
});
