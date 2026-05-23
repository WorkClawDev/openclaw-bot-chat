declare module "openclaw/plugin-sdk/channel-entry-contract" {
  export function defineBundledChannelEntry<T>(entry: T): T & {
    kind: "bundled-channel-entry";
  };

  export function defineBundledChannelSetupEntry<T>(entry: T): T & {
    kind: "bundled-channel-setup-entry";
  };
}

declare module "openclaw/plugin-sdk/native-command-registry" {
  export function listNativeCommandSpecsForConfig(
    cfg: Record<string, unknown>,
    params?: { provider?: string },
  ): Array<Record<string, unknown>>;
}

declare module "openclaw/plugin-sdk/command-auth-native" {
  export function listNativeCommandSpecsForConfig(
    cfg: Record<string, unknown>,
    params?: { provider?: string; skillCommands?: Array<Record<string, unknown>> },
  ): Array<Record<string, unknown>>;
}

declare module "openclaw/plugin-sdk/skill-commands-runtime" {
  export function listSkillCommandsForAgents(params: {
    cfg: Record<string, unknown>;
  }): Array<Record<string, unknown>>;
}

declare module "openclaw/plugin-sdk/plugin-runtime" {
  export function getPluginCommandSpecs(
    provider?: string,
    options?: { config?: Record<string, unknown> },
  ): Array<Record<string, unknown>>;
}
