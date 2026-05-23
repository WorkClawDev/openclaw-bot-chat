"use strict";

function createModelClient(options) {
  const {
    tryParseJson,
    isRecord,
    sleep,
    readFloat,
    readInt,
    readContentText,
    sanitizeAssistantText,
    summarizeValue,
    debugLog,
  } = options;

  function buildHeaders(apiKey) {
    const headers = {
      Accept: "application/json",
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    };

    const extraHeaders = process.env.OPENAI_COMPAT_EXTRA_HEADERS;
    if (!extraHeaders) {
      return headers;
    }

    const parsed = tryParseJson(extraHeaders);
    if (!isRecord(parsed)) {
      throw new Error("OPENAI_COMPAT_EXTRA_HEADERS must be a JSON object");
    }

    for (const [key, value] of Object.entries(parsed)) {
      headers[key] = String(value);
    }
    return headers;
  }

  function buildPayload(model, messages, mcpRuntime) {
    const payload = {
      model,
      messages,
      stream: false,
    };

    if (mcpRuntime && mcpRuntime.tools.length > 0) {
      payload.tools = mcpRuntime.tools;
      payload.tool_choice = "auto";
    }

    const temperature = readFloat("OPENAI_COMPAT_TEMPERATURE");
    if (temperature !== undefined) {
      payload.temperature = temperature;
    }

    const maxTokens = readInt("OPENAI_COMPAT_MAX_TOKENS");
    if (maxTokens !== undefined) {
      payload.max_tokens = maxTokens;
    }

    return payload;
  }

  async function requestModelWithRetry(params) {
    const {
      endpoint,
      apiKey,
      payload,
      timeoutMs,
      maxRetries,
      retryBackoffMs,
      logBase,
    } = params;

    for (let attempt = 0; attempt <= maxRetries; attempt += 1) {
      let response;
      let rawText = "";
      try {
        response = await fetch(endpoint, {
          method: "POST",
          headers: buildHeaders(apiKey),
          body: JSON.stringify(payload),
          signal: AbortSignal.timeout(timeoutMs),
        });
        rawText = await response.text();
      } catch (error) {
        if (attempt >= maxRetries) {
          throw error;
        }
        debugLog("handler.model_request.retry.transport", {
          ...logBase,
          attempt,
          retry_in_ms: retryBackoffMs * (attempt + 1),
          error: String(error && error.message ? error.message : error),
        });
        await sleep(retryBackoffMs * (attempt + 1));
        continue;
      }

      const parsed = tryParseJson(rawText);
      if ((response.status === 429 || response.status >= 500) && attempt < maxRetries) {
        debugLog("handler.model_request.retry.http", {
          ...logBase,
          attempt,
          status: response.status,
          retry_in_ms: retryBackoffMs * (attempt + 1),
          response_body: summarizeValue(parsed !== undefined ? parsed : rawText),
        });
        await sleep(retryBackoffMs * (attempt + 1));
        continue;
      }
      return { response, parsed, rawText };
    }

    throw new Error("Model request retry loop exhausted unexpectedly");
  }

  function extractAssistantMessage(payload) {
    if (!isRecord(payload)) {
      return null;
    }

    if (Array.isArray(payload.choices) && payload.choices.length > 0) {
      const firstChoice = payload.choices[0];
      if (isRecord(firstChoice) && isRecord(firstChoice.message)) {
        const message = firstChoice.message;
        return {
          raw: {
            role: "assistant",
            ...(message.content !== undefined ? { content: message.content } : {}),
            ...(Array.isArray(message.tool_calls) ? { tool_calls: message.tool_calls } : {}),
          },
          content: message.content,
          tool_calls: Array.isArray(message.tool_calls) ? message.tool_calls : [],
        };
      }
    }

    return null;
  }

  function extractAssistantText(message) {
    return sanitizeAssistantText(readContentText(message && message.content)).trim();
  }

  return {
    buildPayload,
    requestModelWithRetry,
    extractAssistantMessage,
    extractAssistantText,
  };
}

module.exports = { createModelClient };
