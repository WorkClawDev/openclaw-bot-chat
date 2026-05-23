import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";

import type { Checkpoint } from "../types";

interface CheckpointState {
  checkpoints: Record<string, Checkpoint>;
}

export class CheckpointStore {
  private readonly checkpoints = new Map<string, Checkpoint>();

  constructor(private readonly filePath: string) {}

  async load(): Promise<void> {
    const state = await this.readState();
    this.checkpoints.clear();
    for (const [dialogId, checkpoint] of Object.entries(state.checkpoints)) {
      if (dialogId) {
        this.checkpoints.set(dialogId, checkpoint);
      }
    }
  }

  get(dialogId: string): Checkpoint | undefined {
    return this.checkpoints.get(dialogId);
  }

  values(): Checkpoint[] {
    return [...this.checkpoints.values()];
  }

  async merge(checkpoints: Checkpoint[]): Promise<void> {
    let dirty = false;

    for (const checkpoint of checkpoints) {
      if (!checkpoint.dialog_id) {
        continue;
      }
      const current = this.checkpoints.get(checkpoint.dialog_id);
      if (!current || compareCheckpoint(checkpoint, current) >= 0) {
        this.checkpoints.set(checkpoint.dialog_id, checkpoint);
        dirty = true;
      }
    }

    if (dirty) {
      await this.flush();
    }
  }

  async update(checkpoint: Checkpoint): Promise<void> {
    this.checkpoints.set(checkpoint.dialog_id, checkpoint);
    await this.flush();
  }

  async flush(): Promise<void> {
    const state: CheckpointState = {
      checkpoints: Object.fromEntries(this.checkpoints.entries()),
    };
    await writeJsonFile(this.filePath, state);
  }

  private async readState(): Promise<CheckpointState> {
    try {
      const raw = await readFile(this.filePath, "utf8");
      const parsed = JSON.parse(raw) as unknown;
      if (isRecord(parsed) && isRecord(parsed["checkpoints"])) {
        return {
          checkpoints: parsed["checkpoints"] as Record<string, Checkpoint>,
        };
      }
    } catch {
      return { checkpoints: {} };
    }

    return { checkpoints: {} };
  }
}

function compareCheckpoint(left: Checkpoint, right: Checkpoint): number {
  const leftSeq = left.last_seq ?? 0;
  const rightSeq = right.last_seq ?? 0;
  if (leftSeq !== rightSeq) {
    return leftSeq - rightSeq;
  }
  return (left.updated_at ?? 0) - (right.updated_at ?? 0);
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
