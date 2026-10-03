import { access, realpath } from "node:fs/promises";
import path from "node:path";
import { loadConfig } from "./config";

export interface Diagnostic { component: string; ok: boolean; message: string }
export async function doctor(cwd = process.cwd()): Promise<Diagnostic[]> {
  const diagnostics: Diagnostic[] = [];
  const add = (component: string, ok: boolean, message: string): void => { diagnostics.push({ component, ok, message }); };
  add("node", Number(process.versions.node.split(".")[0]) >= 22, `Node ${process.versions.node}; minimum 22`);
  let config;
  try { config = await loadConfig(cwd); add("config", true, "Configuration loaded; secrets omitted"); }
  catch (error) { add("config", false, error instanceof Error ? error.message : "Invalid configuration"); return diagnostics; }
  try {
    const url = new URL(config.botChatBaseUrl);
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) throw new Error();
    add("backend.url", true, "HTTP backend URL valid");
    if (process.argv.includes("--network")) {
      try { const response = await fetch(`${config.botChatBaseUrl}/health`, { signal: AbortSignal.timeout(3000) }); add("backend.health", response.ok, `HTTP ${response.status}`); }
      catch { add("backend.health", false, "Backend health probe failed; check connectivity"); }
    }
  } catch { add("backend.url", false, "Backend must be an HTTP(S) URL without embedded credentials"); }
  if (config.openClawAgentHandler) {
    try { await access(path.resolve(cwd, config.openClawAgentHandler)); add("handler", true, "Handler exists"); }
    catch { add("handler", false, "Configured handler file is missing"); }
    if (config.openClawAgentHandler.endsWith("openai-compatible-handler.cjs")) {
      add("model.url", Boolean(process.env.OPENAI_COMPAT_BASE_URL), "Set OPENAI_COMPAT_BASE_URL");
      add("model.key", Boolean(process.env.OPENAI_COMPAT_API_KEY), "Set OPENAI_COMPAT_API_KEY; value omitted");
    }
  } else { add("handler", Boolean(config.openClawAgentUrl), "Set an agent handler or agent HTTP URL"); }
  for (const name of ["OPENAI_COMPAT_FS_ALLOWED_READ_ROOTS", "OPENAI_COMPAT_FS_ALLOWED_WRITE_ROOTS"]) {
    const roots = (process.env[name] ?? "").split(",").map(item => item.trim()).filter(Boolean);
    if (!roots.length) { add(name, false, "No authorized directories configured; filesystem access must be denied"); continue; }
    for (const root of roots) {
      try { await realpath(path.resolve(cwd, root)); add(name, true, "Authorized directory exists"); }
      catch { add(name, false, "An authorized directory does not exist"); }
    }
  }
  if (process.env.OPENAI_COMPAT_BASH_ENABLED === "true") add("shell", false, "Shell requires a configured isolated runner; host execution is forbidden");
  if (process.env.OPENAI_COMPAT_MCP_CONFIG) {
    try { await access(path.resolve(cwd, process.env.OPENAI_COMPAT_MCP_CONFIG)); add("mcp", true, "MCP configuration exists; tools require explicit policies"); }
    catch { add("mcp", false, "MCP configuration file is missing"); }
  }
  return diagnostics;
}
if (require.main === module) void doctor().then(items => { console.log(JSON.stringify(items, null, 2)); process.exitCode = items.some(item => !item.ok) ? 1 : 0; });
