import type { BootstrapResponse } from "../types";

interface RequestOptions {
  body?: unknown;
  query?: Record<string, string | number | undefined>;
}

type JsonRecord = Record<string, unknown>;

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

function encodeConversationPath(conversationId: string): string {
  return conversationId
    .split("/")
    .map((segment) => encodeURIComponent(segment))
    .join("/");
}
