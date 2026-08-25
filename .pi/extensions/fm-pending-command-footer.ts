// Firstmate's home-persistent Pi footer indicator for queued/scheduled commands.
//
// Reads the private schedule file at state/scheduled-commands.json (see
// docs/configuration.md "Scheduled command footer" for the complete file-format
// contract) and renders its pending items as a distinct footer line beneath Pi's
// existing pwd/stats/model line and any other extension's own ctx.ui.setStatus() row
// (Herdr's managed quota-status.ts included), via ctx.ui.setFooter() rather than
// ctx.ui.setStatus() - Pi's built-in footer joins every setStatus() text onto one
// shared row, and the captain wants scheduled-command status on its own line instead
// of concatenated onto quota/usage's row. Owning the footer this way means this
// extension must also reproduce the pwd/stats/model line and the (now quota-only)
// extension-status row itself; that reproduction lives in the pure, testable
// ./lib/fm-footer-stats.ts module, kept in sync by hand against Pi's own
// modes/interactive/components/footer.js. docs/configuration.md documents the two
// display details that module intentionally approximates.
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
import {
  buildExtensionStatusLine,
  buildPwdLine,
  buildStatsLine,
  clampToWidth,
  collectUsageTotals,
  type FooterStatsInput,
} from "./lib/fm-footer-stats.ts";

const DEFAULT_REFRESH_MS = 30_000;

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");

export default function (pi: ExtensionAPI) {
  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const stateDirectory = process.env.FM_STATE_OVERRIDE || resolve(fmHome, "state");
  const scheduleFilePath = resolve(stateDirectory, "scheduled-commands.json");
  const refreshMs = Number(process.env.FM_PENDING_FOOTER_REFRESH_MS) || DEFAULT_REFRESH_MS;

  let timer: ReturnType<typeof setInterval> | undefined;
  let requestRender: (() => void) | undefined;
  let pendingLineText = "";

  const computePendingLineText = (): string => {
    const items = loadScheduleDocument(scheduleFilePath, (path) => readFileSync(path, "utf8"));
    return formatScheduledCommandsStatus(items);
  };

  const refresh = (ctx: ExtensionContext): void => {
    if (ctx.mode !== "tui") return;
    pendingLineText = computePendingLineText();
    requestRender?.();
  };

  pi.on("session_start", (_event, ctx) => {
    if (ctx.mode !== "tui") return;
    pendingLineText = computePendingLineText();

    ctx.ui.setFooter((tui, theme, footerData) => {
      requestRender = () => tui.requestRender();
      const unsubscribeBranch = footerData.onBranchChange(() => tui.requestRender());
      return {
        dispose: () => {
          unsubscribeBranch();
        },
        invalidate() {},
        render(width: number): string[] {
          const usage = collectUsageTotals(ctx.sessionManager.getEntries());
          const statsInput: FooterStatsInput = {
            cwd: ctx.sessionManager.getCwd(),
            home: process.env.HOME || process.env.USERPROFILE,
            gitBranch: footerData.getGitBranch(),
            sessionName: ctx.sessionManager.getSessionName(),
            usage,
            contextUsage: ctx.getContextUsage(),
            model: ctx.model,
            thinkingLevel: ctx.thinkingLevel,
            usingSubscription: ctx.model
              ? ctx.model.provider === "kimi-coding" || ctx.modelRegistry.isUsingOAuth(ctx.model)
              : false,
            availableProviderCount: footerData.getAvailableProviderCount(),
          };

          const lines = [buildPwdLine(statsInput, width, theme), buildStatsLine(statsInput, width, theme)];
          const extensionStatusLine = buildExtensionStatusLine(footerData.getExtensionStatuses(), width);
          if (extensionStatusLine !== undefined) lines.push(extensionStatusLine);
          lines.push(clampToWidth(pendingLineText, width));
          return lines;
        },
      };
    });

    if (timer) clearInterval(timer);
    timer = setInterval(() => refresh(ctx), refreshMs);
    timer.unref?.();
  });

  pi.on("agent_settled", (_event, ctx) => {
    refresh(ctx);
  });

  pi.on("session_shutdown", (_event, ctx) => {
    if (timer) clearInterval(timer);
    timer = undefined;
    requestRender = undefined;
    if (ctx.mode === "tui") ctx.ui.setFooter(undefined);
  });
}
