#!/usr/bin/env node

import { createRequire } from "node:module";

const PACKAGE_NAME = "@workclawdev/extension-bot-chat";
const CHANNEL_ID = "bot-chat";
const DEFAULT_BIND_URL = `openclaw://extensions/install?package=${encodeURIComponent(PACKAGE_NAME)}&channel=${encodeURIComponent(CHANNEL_ID)}`;

type QrCodeTerminal = {
  generate: (
    input: string,
    optionsOrCallback?: { small?: boolean } | ((output: string) => void),
    callback?: (output: string) => void,
  ) => void;
};

export function buildBindingUrl(env: NodeJS.ProcessEnv = process.env): string {
  const explicitUrl = normalizeUrl(env.OPENCLAW_BOTCHAT_BIND_URL);
  if (explicitUrl) {
    return explicitUrl;
  }

  const backendUrl = normalizeUrl(env.BOT_CHAT_BACKEND_URL);
  const botId = normalizeValue(env.BOT_CHAT_BOT_ID);
  if (backendUrl && botId) {
    const url = new URL("/openclaw/bind", backendUrl);
    url.searchParams.set("package", PACKAGE_NAME);
    url.searchParams.set("channel", CHANNEL_ID);
    url.searchParams.set("botId", botId);
    return url.toString();
  }

  return DEFAULT_BIND_URL;
}

export function printSetupQr(env: NodeJS.ProcessEnv = process.env): void {
  const bindUrl = buildBindingUrl(env);
  console.log("");
  console.log("OpenClaw BotChat extension");
  console.log("Scan this QR code from the iOS device to start binding:");
  console.log("");

  const qrcode = loadQrCodeTerminal();
  if (qrcode) {
    qrcode.generate(bindUrl, { small: true });
  } else {
    console.log(bindUrl);
    console.log("");
    console.log("Install dependency qrcode-terminal to render a terminal QR code.");
  }

  console.log("");
  console.log("Setup command:");
  console.log(`  npx ${PACKAGE_NAME}`);
  console.log("");
  console.log("Optional environment:");
  console.log("  OPENCLAW_BOTCHAT_BIND_URL=<full iOS binding URL>");
  console.log("  BOT_CHAT_BACKEND_URL=<backend URL> BOT_CHAT_BOT_ID=<bot UUID>");
  console.log("");
  console.log("Secrets such as BOT_CHAT_BOT_KEY are never encoded into the QR code.");
}

function loadQrCodeTerminal(): QrCodeTerminal | null {
  try {
    const require = createRequire(import.meta.url);
    return require("qrcode-terminal") as QrCodeTerminal;
  } catch {
    return null;
  }
}

function normalizeUrl(value: string | undefined): string | null {
  const normalized = normalizeValue(value);
  if (!normalized) {
    return null;
  }
  try {
    return new URL(normalized).toString();
  } catch {
    return null;
  }
}

function normalizeValue(value: string | undefined): string | null {
  const normalized = value?.trim();
  return normalized ? normalized : null;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  printSetupQr();
}
