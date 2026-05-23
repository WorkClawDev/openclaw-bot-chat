exports.respond = async function respond(request) {
  const metadata =
    request && request.metadata && typeof request.metadata === "object"
      ? request.metadata
      : {};
  if (shouldSkipReply(metadata)) {
    return {
      content: "",
      metadata: {
        content_type: "text",
        skip_reply: true,
      },
    };
  }

  const text = typeof request?.content === "string" ? request.content.trim() : "";
  const content = text ? `echo: ${text}` : "echo: (empty)";

  return {
    content,
    metadata: {
      content_type: "text",
    },
  };
};

function shouldSkipReply(metadata) {
  const channelContext = metadata && typeof metadata.channel_context === "object"
    ? metadata.channel_context
    : undefined;
  if (!channelContext) {
    return false;
  }

  const channelType =
    typeof channelContext.type === "string" ? channelContext.type : undefined;
  if (channelType !== "group" && channelType !== "channel") {
    return false;
  }

  if (metadata.mentioned_current_bot === false) {
    return true;
  }

  const botId =
    typeof channelContext.botId === "string" ? channelContext.botId : undefined;
  const messageMeta = metadata && typeof metadata.message_meta === "object"
    ? metadata.message_meta
    : undefined;
  const mentionedBotIds = Array.isArray(messageMeta?.mentioned_bot_ids)
    ? messageMeta.mentioned_bot_ids.filter((item) => typeof item === "string")
    : [];

  return Boolean(botId) && mentionedBotIds.length > 0 && !mentionedBotIds.includes(botId);
}
