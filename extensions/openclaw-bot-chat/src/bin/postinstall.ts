#!/usr/bin/env node

import { printSetupQr } from "./setup.js";

if (process.env.OPENCLAW_BOTCHAT_SKIP_POSTINSTALL_QR === "1") {
  process.exit(0);
}

if (process.env.CI === "true") {
  process.exit(0);
}

printSetupQr();
