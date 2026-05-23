"use strict";

const conversationHistory = new Map();
const sessionMemory = new Map();

function createSessionState(options) {
  const {
    historyTurns,
    memoryMaxNotes,
    previewText,
    readContentText,
    readString,
    truncateText,
  } = options;

  function clearSession(sessionId) {
    conversationHistory.delete(sessionId);
    sessionMemory.delete(sessionId);
  }

  function clearMemory(sessionId) {
    sessionMemory.delete(sessionId);
  }

  function appendConversationTurn(sessionId, role, content) {
    if (!sessionId || !content) {
      return;
    }

    const history = conversationHistory.get(sessionId) || [];
    history.push({ role, content });

    const maxMessages = Math.max(0, historyTurns * 2);
    const trimmed =
      maxMessages > 0 && history.length > maxMessages
        ? history.slice(history.length - maxMessages)
        : history;

    conversationHistory.set(sessionId, trimmed);
  }

  function appendMemoryNote(sessionId, note) {
    const notes = sessionMemory.get(sessionId) || [];
    notes.push(note);
    const trimmed = notes.length > memoryMaxNotes ? notes.slice(notes.length - memoryMaxNotes) : notes;
    sessionMemory.set(sessionId, trimmed);
  }

  function getMemoryNotes(sessionId) {
    return sessionMemory.get(sessionId) || [];
  }

  function buildHistoryWithSummary(sessionId) {
    const history = conversationHistory.get(sessionId) || [];
    const maxMessages = Math.max(0, historyTurns * 2);
    if (maxMessages <= 0 || history.length <= maxMessages) {
      return history;
    }

    const head = history.slice(0, history.length - maxMessages);
    const tail = history.slice(history.length - maxMessages);
    const summary = summarizeHistoryTurns(head);
    if (!summary) {
      return tail;
    }
    return [{ role: "system", content: `Earlier context summary: ${summary}` }, ...tail];
  }

  function summarizeHistoryTurns(turns) {
    if (!Array.isArray(turns) || turns.length === 0) {
      return "";
    }
    const compact = turns
      .slice(-12)
      .map((item) => {
        if (!item || typeof item !== "object") {
          return "";
        }
        const role = readString(item.role) || "unknown";
        const text = previewText(readContentText(item.content)) || "";
        return text ? `${role}: ${text}` : "";
      })
      .filter(Boolean)
      .join(" | ");
    return truncateText(compact, 1200);
  }

  return {
    clearSession,
    clearMemory,
    appendConversationTurn,
    appendMemoryNote,
    getMemoryNotes,
    buildHistoryWithSummary,
  };
}

module.exports = { createSessionState };
