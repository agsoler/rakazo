import { createHash } from "node:crypto";

export const COMPUTER_IMAGE = process.env.RAKAZO_COMPUTER_IMAGE ?? "rakazo/computer:local";
export const COMPUTER_UID = 1000;
export const COMPUTER_GID = 1000;
export const COMPUTER_USER = `${COMPUTER_UID}:${COMPUTER_GID}`;
export const TEAM_SCREEN_LIMIT = 8;
export const COMPUTER_CONTROL_PORT = 7070;
export const SCREEN_HOST = process.env.SANDBOX_SCREEN_HOST ?? "127.0.0.1";
export const DEPLOYMENT_LABEL = "rakazo.deployment";
export type ScreenNetworkMode = "published" | "internal" | "isolated";

export function resolveDeploymentId(value: string | undefined): string | undefined {
  const deploymentId = value?.trim();
  if (!deploymentId) return undefined;
  if (!/^[a-z0-9][a-z0-9_.-]{0,31}$/.test(deploymentId)) {
    throw new Error(
      "RAKAZO_DEPLOYMENT_ID must be 1-32 lowercase letters, numbers, dots, underscores, or hyphens and start with a letter or number",
    );
  }
  return deploymentId;
}

export function resolveComputerExtraNetwork(
  value: string | undefined,
  deploymentId: string | undefined,
): string | undefined {
  const network = value?.trim();
  if (!network) return undefined;
  const deployment = resolveDeploymentId(deploymentId);
  if (!deployment) {
    throw new Error("RAKAZO_COMPUTER_EXTRA_NETWORK requires RAKAZO_DEPLOYMENT_ID");
  }
  const expected = `${deployment}_data`;
  if (network !== expected) {
    throw new Error(`RAKAZO_COMPUTER_EXTRA_NETWORK must be ${expected}`);
  }
  return network;
}

export function containerMatchesDeployment(
  labels: Record<string, string> | undefined,
  deploymentId: string | undefined,
) {
  const actual = labels?.[DEPLOYMENT_LABEL]?.trim();
  return deploymentId ? actual === deploymentId : !actual;
}

export function containerUsesHome(
  mounts: Array<{ Destination?: string; Source?: string }> | undefined,
  expectedHome: string,
  platform: NodeJS.Platform = process.platform,
) {
  const normalize = (value: string) => {
    const normalized = value.replaceAll("\\", "/").replace(/\/+$/, "");
    return platform === "win32" ? normalized.toLowerCase() : normalized;
  };
  const expected = normalize(expectedHome);
  return Boolean(
    mounts?.some(
      (mount) => mount.Destination === "/home/rakazo" && normalize(mount.Source ?? "") === expected,
    ),
  );
}

interface ComputerContainerIdentity {
  image: string;
  labels: Record<string, string> | undefined;
  mounts?: Array<{ Destination?: string; Source?: string }>;
}

export function containerMatchesComputerIdentity(
  container: ComputerContainerIdentity,
  botId: string,
  workspaceId: string,
  deploymentId: string | undefined,
  computerImage = COMPUTER_IMAGE,
) {
  const labels = container.labels ?? {};
  const managed = labels["rakazo.managed"] === "true" || container.image === computerImage;
  return (
    managed &&
    labels["rakazo.botId"] === botId &&
    labels["rakazo.workspaceId"] === workspaceId &&
    containerMatchesDeployment(labels, deploymentId)
  );
}

export function legacyContainerCanBeAdopted(
  container: ComputerContainerIdentity,
  botId: string,
  workspaceId: string,
  deploymentId: string | undefined,
  expectedHome: string,
  computerImage = COMPUTER_IMAGE,
) {
  return Boolean(
    deploymentId &&
      containerMatchesComputerIdentity(container, botId, workspaceId, undefined, computerImage) &&
      containerUsesHome(container.mounts, expectedHome),
  );
}

export function resolveScreenNetworkMode(value: string | undefined): ScreenNetworkMode {
  if (!value || value === "published") return "published";
  if (value === "internal" || value === "isolated") return value;
  throw new Error(`Unsupported SANDBOX_SCREEN_NETWORK value: ${value}`);
}

export function hostComputerUser(uid = process.getuid?.(), gid = process.getgid?.()): string {
  if (uid === undefined || gid === undefined || uid === 0) return COMPUTER_USER;
  return `${uid}:${gid}`;
}

export function screenPorts(index: number) {
  if (index < 0 || index >= TEAM_SCREEN_LIMIT) {
    throw new Error(
      `screen index ${index} exceeds the Team Computer limit of ${TEAM_SCREEN_LIMIT}`,
    );
  }
  return {
    display: `:${index + 1}`,
    displayNumber: index + 1,
    viewPort: String(6080 + index * 2),
    controlPort: String(6081 + index * 2),
    viewVncPort: 5900 + index * 2,
    controlVncPort: 5901 + index * 2,
  };
}

export function computerPortBindings() {
  const ExposedPorts: Record<string, object> = {};
  const PortBindings: Record<string, Array<{ HostIp: string; HostPort: string }>> = {};
  for (let index = 0; index < TEAM_SCREEN_LIMIT; index += 1) {
    const ports = screenPorts(index);
    ExposedPorts[`${ports.viewPort}/tcp`] = {};
    ExposedPorts[`${ports.controlPort}/tcp`] = {};
    PortBindings[`${ports.viewPort}/tcp`] = [{ HostIp: "127.0.0.1", HostPort: "0" }];
    PortBindings[`${ports.controlPort}/tcp`] = [{ HostIp: "127.0.0.1", HostPort: "0" }];
  }
  // Control stays on the container network only (0.0.0.0 inside the container).
  // Do not publish 7070 to the host.
  return { ExposedPorts, PortBindings };
}

export interface ComputerCreateInput {
  name: string;
  image: string;
  botId: string;
  workspaceId: string;
  homePath: string;
  user?: string;
  controlToken?: string;
  networkMode?: string;
  deploymentId?: string;
}

interface PointerInput {
  kind: "pointer";
  x: number;
  y: number;
  button?: "left" | "right";
  type: "move" | "down" | "up" | "click";
}

export type SandboxInput =
  | { kind: "key"; key: string; modifiers?: string[] }
  | PointerInput
  | { kind: "clipboard"; text: string };

export function containerCreateOptions(input: ComputerCreateInput) {
  const ports = computerPortBindings();
  const deploymentId = resolveDeploymentId(input.deploymentId);
  return {
    Image: input.image,
    name: input.name,
    User: input.user ?? COMPUTER_USER,
    Tty: true,
    Env: [
      "DISPLAY=:1",
      "HOME=/home/rakazo",
      "PATH=/home/rakazo/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
      "NPM_CONFIG_PREFIX=/home/rakazo/.local",
      "PIP_USER=1",
      ...(input.controlToken ? [`RAKAZO_COMPUTER_CONTROL_TOKEN=${input.controlToken}`] : []),
    ],
    Labels: {
      "rakazo.managed": "true",
      "rakazo.botId": input.botId,
      "rakazo.workspaceId": input.workspaceId,
      ...(deploymentId ? { [DEPLOYMENT_LABEL]: deploymentId } : {}),
    },
    ExposedPorts: ports.ExposedPorts,
    HostConfig: {
      Binds: [`${input.homePath}:/home/rakazo`],
      PortBindings: ports.PortBindings,
      ShmSize: 256 * 1024 * 1024,
      CapDrop: ["ALL"],
      SecurityOpt: ["no-new-privileges:true"],
      PidsLimit: 2048,
      ReadonlyPaths: ["/usr/share/novnc"],
      AutoRemove: false,
      NetworkMode: input.networkMode ?? "bridge",
    },
    WorkingDir: "/home/rakazo",
  };
}

export function sanitizeIdentifier(botId: string) {
  const safe = botId.replace(/[^a-zA-Z0-9_.-]/g, "").slice(0, 40);
  return safe || "box";
}

export function containerNameFor(botId: string, deploymentId?: string) {
  const scope = resolveDeploymentId(deploymentId);
  return scope
    ? `${scope}-bot-${sanitizeIdentifier(botId)}`
    : `rakazo-bot-${sanitizeIdentifier(botId)}`;
}

export function computerNetworkNameFor(botId: string, deploymentId?: string) {
  // Keep distinct botIds on distinct networks even when sanitization collapses
  // characters (e.g. "a/b" and "ab"). Optional deployment scope also keeps
  // cloned workspaces isolated on one Docker daemon.
  const scope = resolveDeploymentId(deploymentId);
  const hash = createHash("sha256").update(botId).digest("hex").slice(0, 32);
  const prefix = scope ? `${scope}-computer` : "rakazo-computer";
  return `${prefix}-${sanitizeIdentifier(botId).slice(0, 32)}-${hash}`;
}

/** Current and prior network names used by this PR, for delete cleanup. */
export function computerNetworkNamesForCleanup(botId: string, deploymentId?: string) {
  const scope = resolveDeploymentId(deploymentId);
  if (scope) return [computerNetworkNameFor(botId, scope)];
  const safe = sanitizeIdentifier(botId);
  const digest = createHash("sha256").update(botId).digest("hex");
  return [
    computerNetworkNameFor(botId),
    `rakazo-computer-${safe}`,
    `rakazo-computer-${safe.slice(0, 32)}-${digest.slice(0, 8)}`,
  ];
}

/**
 * Legacy unsalted network names can collide across botIds. Only remove such a
 * network when no other bot's container is still attached.
 */
export function legacyNetworkOwnedSolelyBy(
  botId: string,
  attachedBotIds: Array<string | undefined>,
): boolean {
  return attachedBotIds.every((owner) => owner === botId);
}

export function screenUrlFor(hostPort: string, host = SCREEN_HOST) {
  return `http://${host}:${hostPort}/embed.html`;
}

/**
 * Decide which host:port clients (and readiness probes) should use.
 *
 * Per-bot NetworkMode isolation must not change this: a container always has a
 * docker-internal IP on its network, but browsers cannot load that 172.x
 * address. Compose modes that attach the supervisor/screen proxy to the bot
 * network may return the container IP; host-run supervisors use the published
 * loopback mapping.
 */
export function resolveScreenPublishTarget(input: {
  screenNetwork: ScreenNetworkMode;
  networkMode: string | null | undefined;
  networks: Record<string, { IPAddress?: string } | undefined> | null | undefined;
  hostPort: string | undefined;
  containerPort: string;
  screenHost?: string;
}): { host: string; port: string } | undefined {
  if (input.screenNetwork === "internal" || input.screenNetwork === "isolated") {
    const address = input.networkMode ? input.networks?.[input.networkMode]?.IPAddress : undefined;
    if (address) return { host: address, port: input.containerPort };
    return undefined;
  }
  if (input.hostPort) return { host: input.screenHost ?? SCREEN_HOST, port: input.hostPort };
  return undefined;
}

/**
 * A containerized supervisor probes published screens over the private computer network while the
 * host-facing URL continues to use the loopback-published port. A host-run supervisor can probe the
 * same target it publishes.
 */
export function resolveScreenReadinessTarget(
  input: Parameters<typeof resolveScreenPublishTarget>[0] & { supervisorContainerized: boolean },
): { host: string; port: string } | undefined {
  if (input.screenNetwork === "published" && input.supervisorContainerized) {
    const address = input.networkMode ? input.networks?.[input.networkMode]?.IPAddress : undefined;
    if (address) return { host: address, port: input.containerPort };
  }
  return resolveScreenPublishTarget(input);
}

/**
 * Resolve the in-container control service via its Docker network IP.
 * Control is never host-published; the supervisor reaches 7070 on the
 * container network while the process binds 0.0.0.0 inside the sandbox.
 */
export function resolveComputerControlEndpoint(input: {
  token: string | undefined;
  networkMode: string | null | undefined;
  networks: Record<string, { IPAddress?: string } | undefined> | null | undefined;
}): { url: string; token: string } | undefined {
  if (!input.token) return undefined;
  const address =
    (input.networkMode ? input.networks?.[input.networkMode]?.IPAddress : undefined) ||
    Object.values(input.networks ?? {}).find((network) => network?.IPAddress)?.IPAddress;
  if (!address) return undefined;
  return { url: `http://${address}:${COMPUTER_CONTROL_PORT}/v1/desktop`, token: input.token };
}

export function xdotoolCommand(input: SandboxInput): string[] {
  if (input.kind === "key") {
    const key = mapKey(input.key);
    const mods = (input.modifiers ?? []).map(mapKey);
    const combo = [...mods, key].join("+");
    return ["xdotool", "key", "--clearmodifiers", combo];
  }
  if (input.kind === "pointer") {
    const btn = input.button === "right" ? "3" : "1";
    if (input.type === "move")
      return ["xdotool", "mousemove", "--", String(input.x), String(input.y)];
    if (input.type === "down") {
      return ["xdotool", "mousemove", "--", String(input.x), String(input.y), "mousedown", btn];
    }
    if (input.type === "up") return ["xdotool", "mouseup", btn];
    return ["xdotool", "mousemove", "--", String(input.x), String(input.y), "click", btn];
  }
  return ["xdotool", "type", "--clearmodifiers", "--", input.text];
}

function mapKey(key: string) {
  const lower = key.toLowerCase();
  if (lower === "enter" || lower === "return") return "Return";
  if (lower === "esc" || lower === "escape") return "Escape";
  if (lower === "space") return "space";
  if (lower === "tab") return "Tab";
  if (lower === "backspace") return "BackSpace";
  if (lower === "ctrl" || lower === "control") return "ctrl";
  if (lower === "alt") return "alt";
  if (lower === "shift") return "shift";
  if (lower === "meta" || lower === "cmd" || lower === "super") return "super";
  return key;
}
