import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";

import type { Checkpoint } from "../types";

interface SessionState {
  sessions: Record<string, string>;
}

export class SessionManager {
  private readonly sessions = new Map<string, string>();

  constructor(private readonly filePath: string) {}

  async load(): Promise<void> {
    const state = await this.readState();
    this.sessions.clear();
    for (const [dialogId, sessionId] of Object.entries(state.sessions)) {
      if (dialogId && sessionId) {
        this.sessions.set(dialogId, sessionId);
      }
    }
  }

  get(dialogId: string): string | undefined {
    return this.sessions.get(dialogId);
  }

  async getOrCreate(dialogId: string, preferredSessionId?: string): Promise<string> {
    const existing = this.sessions.get(dialogId);
    if (existing) {
      return existing;
    }

    const sessionId = preferredSessionId ?? randomUUID();
    this.sessions.set(dialogId, sessionId);
    await this.flush();
    return sessionId;
  }

  async set(dialogId: string, sessionId: string): Promise<void> {
    this.sessions.set(dialogId, sessionId);
    await this.flush();
  }

  async restoreFromCheckpoints(checkpoints: Checkpoint[]): Promise<void> {
    let dirty = false;
    for (const checkpoint of checkpoints) {
      if (!checkpoint.dialog_id || !checkpoint.session_id) {
        continue;
      }
      if (this.sessions.get(checkpoint.dialog_id) === checkpoint.session_id) {
        continue;
      }
      this.sessions.set(checkpoint.dialog_id, checkpoint.session_id);
      dirty = true;
    }

    if (dirty) {
      await this.flush();
    }
  }

  entries(): Array<[string, string]> {
    return [...this.sessions.entries()];
  }

  async flush(): Promise<void> {
    const state: SessionState = {
      sessions: Object.fromEntries(this.sessions.entries()),
    };
    await writeJsonFile(this.filePath, state);
  }

  private async readState(): Promise<SessionState> {
    try {
      const raw = await readFile(this.filePath, "utf8");
      const parsed = JSON.parse(raw) as unknown;
      if (isRecord(parsed) && isRecord(parsed["sessions"])) {
        return {
          sessions: parsed["sessions"] as Record<string, string>,
        };
      }
    } catch {
      return { sessions: {} };
    }

    return { sessions: {} };
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

async function writeJsonFile(filePath: string, value: unknown): Promise<void> {
  await mkdir(path.dirname(filePath), { recursive: true });
  const tmpPath = `${filePath}.tmp`;
  await writeFile(tmpPath, JSON.stringify(value, null, 2), "utf8");
  await rename(tmpPath, filePath);
}
