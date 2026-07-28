// Firstmate's home-persistent Pi footer indicator for queued/scheduled commands.
//
// Reads the private schedule file at data/scheduled-commands.json (see
// docs/configuration.md "Scheduled command footer" for the complete file-format
// contract) and mirrors its pending items in the footer via ctx.ui.setStatus() - the
// same supported extension footer/status hook Firstmate's fm-calm.ts and Herdr's
// managed quota-status.ts extension already use.
//
// This extension is read-only display: it never executes, dismisses, or reschedules a
// command, and a missing or malformed schedule file degrades to the idle footer text
// rather than throwing. The wake mechanism that actually resumes queued captain work
// (the watcher, the durable wake queue, a quota-reset scheduler) is authoritative and
// entirely independent of this file - this extension only reflects it.
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { formatScheduledCommandsStatus, loadScheduleDocument } from "./lib/fm-pending-command-schedule.ts";

const STATUS_KEY = "firstmate-pending-commands";
const DEFAULT_REFRESH_MS = 30_000;

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");

export default function (pi: ExtensionAPI) {
  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const dataDirectory = process.env.FM_DATA_OVERRIDE || resolve(fmHome, "data");
  const scheduleFilePath = resolve(dataDirectory, "scheduled-commands.json");
  const refreshMs = Number(process.env.FM_PENDING_FOOTER_REFRESH_MS) || DEFAULT_REFRESH_MS;

  let timer: ReturnType<typeof setInterval> | undefined;

  const refresh = (ctx: ExtensionContext): void => {
    if (ctx.mode !== "tui") return;
    const items = loadScheduleDocument(scheduleFilePath, (path) => readFileSync(path, "utf8"));
    ctx.ui.setStatus(STATUS_KEY, formatScheduledCommandsStatus(items));
  };

  pi.on("session_start", (_event, ctx) => {
    if (ctx.mode !== "tui") return;
    if (timer) clearInterval(timer);
    refresh(ctx);
    // Poll instead of watching the file: due/overdue transitions must show up even
    // when nothing else touches the file, and a plain fs.watch would miss that.
    timer = setInterval(() => refresh(ctx), refreshMs);
    timer.unref?.();
  });

  pi.on("agent_settled", (_event, ctx) => {
    refresh(ctx);
  });

  pi.on("session_shutdown", (_event, ctx) => {
    if (timer) clearInterval(timer);
    timer = undefined;
    ctx.ui.setStatus(STATUS_KEY, undefined);
  });
}
