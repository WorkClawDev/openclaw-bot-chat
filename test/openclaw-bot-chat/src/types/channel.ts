import type { Checkpoint } from "./index";

interface DialogInfo {
  dialog_id: string;
  topic?: string;
  title?: string;
  last_seq?: number;
  last_message_id?: string;
  updated_at?: number;
}

export interface ChannelContext {
  id: string;
  type: "dm" | "group" | "channel";
  botId: string;
  userId?: string;
  guildId?: string;
  groupId?: string;
}

interface ChannelScopedState {
  dialogs: Map<string, DialogInfo>;
  sessions: Map<string, string>;
  checkpoints: Map<string, Checkpoint>;
}

export class ChannelState {
  private readonly states = new Map<string, ChannelScopedState>();

  getScopeKey(context: ChannelContext): string {
    return buildChannelScopeKey(context);
  }

  getState(context: ChannelContext): ChannelScopedState {
    const scopeKey = this.getScopeKey(context);
    let state = this.states.get(scopeKey);
    if (!state) {
      state = {
        dialogs: new Map<string, DialogInfo>(),
        sessions: new Map<string, string>(),
        checkpoints: new Map<string, Checkpoint>(),
      };
      this.states.set(scopeKey, state);
    }
    return state;
  }

  trackDialog(context: ChannelContext, dialog: DialogInfo): void {
    this.getState(context).dialogs.set(dialog.dialog_id, dialog);
  }

  getDialog(
    context: ChannelContext,
    dialogId: string,
  ): DialogInfo | undefined {
    return this.getState(context).dialogs.get(dialogId);
  }

  setSession(
    context: ChannelContext,
    dialogId: string,
    sessionId: string,
  ): void {
    this.getState(context).sessions.set(dialogId, sessionId);
  }

  getSession(
    context: ChannelContext,
    dialogId: string,
  ): string | undefined {
    return this.getState(context).sessions.get(dialogId);
  }

  setCheckpoint(context: ChannelContext, checkpoint: Checkpoint): void {
    this.getState(context).checkpoints.set(checkpoint.dialog_id, checkpoint);
  }

  getCheckpoint(
    context: ChannelContext,
    dialogId: string,
  ): Checkpoint | undefined {
    return this.getState(context).checkpoints.get(dialogId);
  }
}

export function buildChannelScopeKey(context: ChannelContext): string {
  switch (context.type) {
    case "dm":
      return `bot:${context.botId}:dm:${context.userId ?? context.id}`;
    case "group":
      return `bot:${context.botId}:group:${context.groupId ?? context.id}`;
    case "channel":
      return `bot:${context.botId}:channel:${context.guildId ?? "global"}:${context.id}`;
  }
}
