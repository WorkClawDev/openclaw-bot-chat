import type { BootstrapResponse } from "../types";

interface RequestOptions {
  body?: unknown;
  query?: Record<string, string | number | undefined>;
}

type JsonRecord = Record<string, unknown>;

export interface BotChatRuntimeTask {
  id: string;
  title: string;
  status: string;
  assignee_bot_id?: string | null;
  progress?: number;
  latest_status_note?: string | null;
  [key: string]: unknown;
}

export type BotChatTaskCreatePayload = Record<string, unknown>;

export class BotChatHttpError extends Error {
  readonly status: number;
  readonly responseBody: unknown;

  constructor(message: string, status: number, responseBody: unknown) {
    super(message);
    this.name = "BotChatHttpError";
    this.status = status;
    this.responseBody = responseBody;
  }
}

export class BotChatHttpClient {
  constructor(
    private readonly baseUrl: string,
    private readonly accessKey: string,
    private readonly timeoutMs: number,
  ) {}

  async bootstrap(): Promise<BootstrapResponse> {
    return this.request<BootstrapResponse>("GET", "/api/v1/bot-runtime/bootstrap");
  }

  async tasks(options: { queue?: boolean } = {}): Promise<BotChatRuntimeTask[]> {
    const useQueue = options.queue ?? true;
    if (useQueue) {
      try {
        return normalizeTasks(
          await this.request<unknown>("GET", "/api/v1/bot-runtime/tasks/queue"),
        );
      } catch (error) {
        if (!isMissingCompatEndpoint(error)) {
          throw error;
        }
      }
    }

    return normalizeTasks(
      await this.request<unknown>("GET", "/api/v1/bot-runtime/tasks"),
    );
  }

  async createTask(payload: BotChatTaskCreatePayload): Promise<BotChatRuntimeTask> {
    return normalizeTask(
      await this.request<unknown>("POST", "/api/v1/bot-runtime/tasks", {
        body: payload,
      }),
    );
  }

  async claimTask(
    taskId: string,
    body: Record<string, unknown> = {},
  ): Promise<BotChatRuntimeTask> {
    return this.postTaskAction(taskId, "claim", body);
  }

  async progressTask(
    taskId: string,
    body: { progress?: number; latest_status_note?: string },
  ): Promise<BotChatRuntimeTask> {
    return this.postTaskAction(taskId, "progress", body);
  }

  async resultTask(
    taskId: string,
    body: { result?: unknown; latest_status_note?: string },
  ): Promise<BotChatRuntimeTask> {
    try {
      return await this.postTaskAction(taskId, "result", body);
    } catch (error) {
      if (!isMissingCompatEndpoint(error)) {
        throw error;
      }
      return this.postTaskAction(taskId, "complete", body);
    }
  }

  async failTask(
    taskId: string,
    body: { latest_status_note?: string; error?: unknown },
  ): Promise<BotChatRuntimeTask> {
    return this.postTaskAction(taskId, "fail", body);
  }

  async getConversationMessages(
    conversationId: string,
    options: {
      afterSeq?: number;
      limit?: number;
    } = {},
  ): Promise<unknown[]> {
    const payload = await this.request<unknown>(
      "GET",
      `/api/v1/bot-runtime/messages/${encodeConversationPath(conversationId)}`,
      {
        query: {
          after_seq: options.afterSeq,
          limit: options.limit,
        },
      },
    );

    if (Array.isArray(payload)) {
      return payload;
    }
    if (isRecord(payload)) {
      const messages = payload["messages"];
      if (Array.isArray(messages)) {
        return messages;
      }
      const items = payload["items"];
      if (Array.isArray(items)) {
        return items;
      }
    }

    return [];
  }

  private async postTaskAction(
    taskId: string,
    action: "claim" | "progress" | "result" | "complete" | "fail",
    body: Record<string, unknown>,
  ): Promise<BotChatRuntimeTask> {
    return normalizeTask(
      await this.request<unknown>(
        "POST",
        `/api/v1/bot-runtime/tasks/${encodeURIComponent(taskId)}/${action}`,
        {
          body,
        },
      ),
    );
  }

  private async request<T>(
    method: string,
    endpoint: string,
    options: RequestOptions = {},
  ): Promise<T> {
    const url = new URL(endpoint, `${this.baseUrl}/`);
    for (const [key, value] of Object.entries(options.query ?? {})) {
      if (value !== undefined) {
        url.searchParams.set(key, String(value));
      }
    }

    const init: RequestInit = {
      method,
      headers: this.buildHeaders(options.body !== undefined),
      signal: AbortSignal.timeout(this.timeoutMs),
    };
    if (options.body !== undefined) {
      init.body = JSON.stringify(options.body);
    }

    const response = await fetch(url, init);

    const rawText = await response.text();
    const parsed = rawText ? parseJson(rawText) : undefined;

    if (!response.ok) {
      throw new BotChatHttpError(
        `${method} ${url.pathname} failed with ${response.status}`,
        response.status,
        parsed ?? rawText,
      );
    }

    return unwrapPayload<T>(parsed);
  }

  private buildHeaders(withJsonBody: boolean): HeadersInit {
    const headers: Record<string, string> = {
      Accept: "application/json",
      "X-Bot-Key": this.accessKey,
    };

    if (withJsonBody) {
      headers["Content-Type"] = "application/json";
    }

    return headers;
  }
}

function unwrapPayload<T>(value: unknown): T {
  if (isRecord(value) && "data" in value) {
    return value["data"] as T;
  }
  return value as T;
}

function parseJson(value: string): unknown {
  try {
    return JSON.parse(value);
  } catch {
    return value;
  }
}

function isRecord(value: unknown): value is JsonRecord {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function normalizeTasks(value: unknown): BotChatRuntimeTask[] {
  if (Array.isArray(value)) {
    return value.map(normalizeTask);
  }
  if (isRecord(value)) {
    const tasks = value["tasks"] ?? value["items"];
    if (Array.isArray(tasks)) {
      return tasks.map(normalizeTask);
    }
  }
  return [];
}

function normalizeTask(value: unknown): BotChatRuntimeTask {
  if (!isRecord(value)) {
    throw new Error("BotChat task response is not an object");
  }
  const id = readString(value["id"]);
  const title = readString(value["title"]);
  const status = readString(value["status"]);
  if (!id || !title || !status) {
    throw new Error("BotChat task response is missing id, title, or status");
  }
  const progress = readNumber(value["progress"]);
  return {
    ...value,
    id,
    title,
    status,
    assignee_bot_id: readString(value["assignee_bot_id"]) ?? null,
    latest_status_note: readString(value["latest_status_note"]) ?? null,
    ...(progress !== undefined ? { progress } : {}),
  };
}

function readString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function readNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function isMissingCompatEndpoint(error: unknown): boolean {
  return error instanceof BotChatHttpError && (error.status === 404 || error.status === 405);
}

function encodeConversationPath(conversationId: string): string {
  return conversationId
    .split("/")
    .map((segment) => encodeURIComponent(segment))
    .join("/");
}
