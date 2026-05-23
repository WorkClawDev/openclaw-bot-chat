export interface AllowList {
  items: string[];
  matchMode: "id" | "name" | "any";
}

export interface ActionPermissions {
  sendMessage: boolean;
  sendImage: boolean;
  typing: boolean;
  reactions: boolean;
  threads: boolean;
}

export type ChannelPolicy = "open" | "allowlist";
export type GroupPolicy = ChannelPolicy | "disabled";

export type PermissionCode =
  | "PERMISSION_ACTION_DISABLED"
  | "PERMISSION_BOT_DISABLED"
  | "PERMISSION_CHANNEL_NOT_ALLOWED"
  | "PERMISSION_GROUP_DISABLED"
  | "PERMISSION_GROUP_NOT_ALLOWED"
  | "PERMISSION_USER_NOT_ALLOWED";

export interface PermissionCheck {
  allowed: boolean;
  code?: PermissionCode;
  reason?: string;
  required?: string[];
}

export interface PermissionContext {
  userId: string;
  channelId: string;
  botId: string;
  userName?: string;
  channelName?: string;
  channelType?: "dm" | "group" | "channel";
}

export interface PermissionScopedBotConfig {
  id?: string;
  enabled: boolean;
  channels?: AllowList | string[];
  users?: AllowList | string[];
  groupPolicy?: GroupPolicy;
  actions?: Partial<ActionPermissions> | ActionPermissions;
}

export const DEFAULT_ACTION_PERMISSIONS: ActionPermissions = {
  sendMessage: true,
  sendImage: true,
  typing: true,
  reactions: false,
  threads: false,
};

interface AllowListTarget {
  kind: "id" | "name";
  value: string;
}

export function resolveActionPermissions(
  value?: Partial<ActionPermissions> | ActionPermissions,
): ActionPermissions {
  return {
    ...DEFAULT_ACTION_PERMISSIONS,
    ...(value ?? {}),
  };
}

export function normalizeAllowList(
  value: AllowList | string[] | undefined,
): AllowList | undefined {
  if (Array.isArray(value)) {
    const items = normalizeItems(value);
    return items.length > 0 ? { items, matchMode: "any" } : undefined;
  }
  if (!isRecord(value) || !Array.isArray(value["items"])) {
    return undefined;
  }

  const items = normalizeItems(value["items"]);
  if (items.length === 0) {
    return undefined;
  }

  const matchMode = readMatchMode(value["matchMode"]);
  return {
    items,
    matchMode: matchMode ?? "any",
  };
}

export function isInAllowList(
  target: string,
  allowList: AllowList | undefined,
): boolean {
  if (!allowList) {
    return false;
  }

  const trimmedTarget = target.trim();
  if (!trimmedTarget) {
    return false;
  }

  switch (allowList.matchMode) {
    case "id":
      return allowList.items.includes(trimmedTarget);
    case "name":
      return allowList.items.some(
        (item) => item.toLocaleLowerCase() === trimmedTarget.toLocaleLowerCase(),
      );
    case "any":
      return (
        allowList.items.includes(trimmedTarget) ||
        allowList.items.some(
          (item) => item.toLocaleLowerCase() === trimmedTarget.toLocaleLowerCase(),
        )
      );
  }
}

export function checkPermission(
  action: keyof ActionPermissions,
  context: PermissionContext,
  config: PermissionScopedBotConfig,
): PermissionCheck {
  if (!config.enabled) {
    return deny(
      "PERMISSION_BOT_DISABLED",
      "bot is disabled",
      ["bot.enabled"],
    );
  }

  const actions = resolveActionPermissions(config.actions);
  if (!actions[action]) {
    return deny(
      "PERMISSION_ACTION_DISABLED",
      `action "${action}" is disabled`,
      [`actions.${action}`],
    );
  }

  const userAllowList = normalizeAllowList(config.users);
  if (
    userAllowList &&
    !matchesAllowList(userAllowList, [
      { kind: "id", value: context.userId },
      ...(context.userName
        ? [{ kind: "name", value: context.userName } satisfies AllowListTarget]
        : []),
    ])
  ) {
    return deny(
      "PERMISSION_USER_NOT_ALLOWED",
      "user is not in the allowlist",
      ["users"],
    );
  }

  const isScopedChannel =
    context.channelType === "group" || context.channelType === "channel";
  const channelAllowList = normalizeAllowList(config.channels);
  const groupPolicy = config.groupPolicy ?? "open";

  if (isScopedChannel && groupPolicy === "disabled") {
    return deny(
      "PERMISSION_GROUP_DISABLED",
      "group and channel conversations are disabled",
      ["groupPolicy"],
    );
  }

  if (channelAllowList) {
    const allowed = matchesAllowList(channelAllowList, [
      { kind: "id", value: context.channelId },
      ...(context.channelName
        ? [{ kind: "name", value: context.channelName } satisfies AllowListTarget]
        : []),
    ]);
    if (!allowed) {
      return deny(
        "PERMISSION_CHANNEL_NOT_ALLOWED",
        "channel is not in the allowlist",
        ["channels"],
      );
    }
  } else if (isScopedChannel && groupPolicy === "allowlist") {
    return deny(
      "PERMISSION_GROUP_NOT_ALLOWED",
      "group and channel conversations require an allowlist entry",
      ["channels"],
    );
  }

  return { allowed: true };
}

function matchesAllowList(
  allowList: AllowList,
  targets: AllowListTarget[],
): boolean {
  for (const target of targets) {
    if (!target.value.trim()) {
      continue;
    }
    if (allowList.matchMode === "id" && target.kind !== "id") {
      continue;
    }
    if (allowList.matchMode === "name" && target.kind !== "name") {
      continue;
    }
    if (isInAllowList(target.value, allowList)) {
      return true;
    }
  }
  return false;
}

function normalizeItems(values: unknown[]): string[] {
  const items = new Set<string>();
  for (const value of values) {
    if (typeof value === "string" && value.trim()) {
      items.add(value.trim());
    }
  }
  return [...items];
}

function readMatchMode(value: unknown): AllowList["matchMode"] | undefined {
  switch (value) {
    case "id":
    case "name":
    case "any":
      return value;
    default:
      return undefined;
  }
}

function deny(
  code: PermissionCode,
  reason: string,
  required: string[],
): PermissionCheck {
  return {
    allowed: false,
    code,
    reason,
    required,
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}
