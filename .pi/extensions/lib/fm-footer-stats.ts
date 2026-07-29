// Pure, hand-rolled reimplementation of the pwd/token/cost/context and extension-status
// lines that Pi's built-in interactive footer renders, so Firstmate's pending-command
// footer extension can own the whole footer (via ctx.ui.setFooter()) and append a
// distinct scheduled-command line beneath them, instead of having Pi's own footer
// concatenate every ctx.ui.setStatus() text - including quota/usage - onto a single
// shared row. docs/configuration.md "Scheduled command footer" is the single owner of
// this compatibility boundary and the two display details it intentionally leaves
// approximate. This module only uses type-only imports from
// @earendil-works/pi-coding-agent and @earendil-works/pi-ai (erased at runtime by
// Node's native TypeScript support, so no install or version pin is required to test
// it), matching the rest of this extension's design.
import { isAbsolute, relative, resolve as resolvePath, sep } from "node:path";
import type { Model } from "@earendil-works/pi-ai";
import type { ContextUsage, SessionEntry } from "@earendil-works/pi-coding-agent";

/** Structural subset of Pi's real Theme, matching the object ctx.ui.setFooter()'s
 * factory already receives - no import needed. */
export interface FooterTheme {
  fg(color: string, text: string): string;
}

export interface FooterUsageTotals {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  cost: number;
  cacheHitRate: number | undefined;
}

export interface FooterStatsInput {
  cwd: string;
  home: string | undefined;
  gitBranch: string | null;
  sessionName: string | undefined;
  usage: FooterUsageTotals;
  contextUsage: ContextUsage | undefined;
  model: Model<any> | undefined;
  thinkingLevel: string | undefined;
  usingSubscription: boolean;
  availableProviderCount: number;
}

export function formatTokens(count: number): string {
  if (count < 1000) return String(count);
  if (count < 10000) return `${(count / 1000).toFixed(1)}k`;
  if (count < 1000000) return `${Math.round(count / 1000)}k`;
  if (count < 10000000) return `${(count / 1000000).toFixed(1)}M`;
  return `${Math.round(count / 1000000)}M`;
}

export function formatCwdForFooter(cwd: string, home: string | undefined): string {
  if (!home) return cwd;
  const resolvedCwd = resolvePath(cwd);
  const resolvedHome = resolvePath(home);
  const relativeToHome = relative(resolvedHome, resolvedCwd);
  const isInsideHome =
    relativeToHome === "" ||
    (relativeToHome !== ".." && !relativeToHome.startsWith(`..${sep}`) && !isAbsolute(relativeToHome));
  if (!isInsideHome) return cwd;
  return relativeToHome === "" ? "~" : `~${sep}${relativeToHome}`;
}

/**
 * Best-effort code-unit width clamp - not a full Unicode East-Asian-width table like Pi's
 * own truncateToWidth/visibleWidth, since importing those would pull a runtime dependency
 * on @earendil-works/pi-tui into this otherwise dependency-free extension. Every string
 * this module clamps (pwd, stats, sanitized status text) is already overwhelmingly ASCII,
 * so this is an acceptable approximation, not a silent correctness gap in the common case.
 */
export function clampToWidth(text: string, width: number, ellipsis = "..."): string {
  if (width <= 0) return "";
  if (text.length <= width) return text;
  if (width <= ellipsis.length) return text.slice(0, width);
  return `${text.slice(0, width - ellipsis.length)}${ellipsis}`;
}

export function buildPwdLine(
  input: Pick<FooterStatsInput, "cwd" | "home" | "gitBranch" | "sessionName">,
  width: number,
  theme: FooterTheme,
): string {
  let pwd = formatCwdForFooter(input.cwd, input.home);
  if (input.gitBranch) pwd = `${pwd} (${input.gitBranch})`;
  if (input.sessionName) pwd = `${pwd} • ${input.sessionName}`;
  return clampToWidth(theme.fg("dim", pwd), width);
}

/**
 * Kept in sync by hand against Pi's own modes/interactive/components/footer.js
 * FooterComponent.render(). Two display details are unavailable through the documented
 * extension API and are intentionally approximated rather than reimplemented:
 * - the auto-compaction "(auto)" suffix always assumes auto-compaction is enabled
 *   (ExtensionContext exposes no way to read the current session's autoCompactionEnabled
 *   flag, which defaults to true and is rarely toggled off);
 * - the "xp" experimental-features badge is never shown (ExtensionContext exposes no way
 *   to read whether experimental features are globally enabled).
 */
export function buildStatsLine(input: FooterStatsInput, width: number, theme: FooterTheme): string {
  const usage = input.usage;
  const statsParts: string[] = [];
  if (usage.input) statsParts.push(`↑${formatTokens(usage.input)}`);
  if (usage.output) statsParts.push(`↓${formatTokens(usage.output)}`);
  if (usage.cacheRead) statsParts.push(`R${formatTokens(usage.cacheRead)}`);
  if (usage.cacheWrite) statsParts.push(`W${formatTokens(usage.cacheWrite)}`);
  if ((usage.cacheRead > 0 || usage.cacheWrite > 0) && usage.cacheHitRate !== undefined) {
    statsParts.push(`CH${usage.cacheHitRate.toFixed(1)}%`);
  }
  if (usage.cost || input.usingSubscription) {
    statsParts.push(`$${usage.cost.toFixed(3)}${input.usingSubscription ? " (sub)" : ""}`);
  }

  const contextWindow = input.contextUsage?.contextWindow ?? input.model?.contextWindow ?? 0;
  const contextPercentValue = input.contextUsage?.percent ?? 0;
  const contextPercentKnown = input.contextUsage?.percent !== undefined && input.contextUsage?.percent !== null;
  const contextPercentDisplay = contextPercentKnown
    ? `${contextPercentValue.toFixed(1)}%/${formatTokens(contextWindow)} (auto)`
    : `?/${formatTokens(contextWindow)} (auto)`;
  const contextPercentStr =
    contextPercentValue > 90
      ? theme.fg("error", contextPercentDisplay)
      : contextPercentValue > 70
        ? theme.fg("warning", contextPercentDisplay)
        : contextPercentDisplay;
  statsParts.push(contextPercentStr);

  let statsLeft = statsParts.join(" ");
  let statsLeftWidth = statsLeft.length;
  if (statsLeftWidth > width) {
    statsLeft = clampToWidth(statsLeft, width, "");
    statsLeftWidth = statsLeft.length;
  }

  const modelName = input.model?.id || "no-model";
  const minPadding = 2;
  let rightSideWithoutProvider = modelName;
  if (input.model?.reasoning) {
    const level = input.thinkingLevel || "off";
    rightSideWithoutProvider = level === "off" ? `${modelName} • thinking off` : `${modelName} • ${level}`;
  }
  let rightSide = rightSideWithoutProvider;
  if (input.availableProviderCount > 1 && input.model) {
    rightSide = `(${input.model.provider}) ${rightSideWithoutProvider}`;
    if (statsLeftWidth + minPadding + rightSide.length > width) rightSide = rightSideWithoutProvider;
  }
  const rightSideWidth = rightSide.length;
  const totalNeeded = statsLeftWidth + minPadding + rightSideWidth;

  let statsLine: string;
  if (totalNeeded <= width) {
    statsLine = statsLeft + " ".repeat(Math.max(0, width - statsLeftWidth - rightSideWidth)) + rightSide;
  } else {
    const availableForRight = width - statsLeftWidth - minPadding;
    if (availableForRight > 0) {
      const truncatedRight = clampToWidth(rightSide, availableForRight, "");
      statsLine = statsLeft + " ".repeat(Math.max(0, width - statsLeftWidth - truncatedRight.length)) + truncatedRight;
    } else {
      statsLine = statsLeft;
    }
  }

  const dimStatsLeft = theme.fg("dim", statsLeft);
  const remainder = statsLine.slice(statsLeft.length);
  const dimRemainder = theme.fg("dim", remainder);
  return dimStatsLeft + dimRemainder;
}

/** Cumulative token/cost usage across every session entry, mirroring the loop Pi's own
 * FooterComponent runs over session.sessionManager.getEntries(). */
export function collectUsageTotals(entries: readonly SessionEntry[]): FooterUsageTotals {
  let input = 0;
  let output = 0;
  let cacheRead = 0;
  let cacheWrite = 0;
  let cost = 0;
  let cacheHitRate: number | undefined;

  for (const entry of entries) {
    if (entry.type === "message" && entry.message.role === "assistant") {
      const usage = entry.message.usage;
      input += usage.input;
      output += usage.output;
      cacheRead += usage.cacheRead;
      cacheWrite += usage.cacheWrite;
      cost += usage.cost.total;
      const latestPromptTokens = usage.input + usage.cacheRead + usage.cacheWrite;
      cacheHitRate = latestPromptTokens > 0 ? (usage.cacheRead / latestPromptTokens) * 100 : undefined;
    } else if (entry.type === "message" && entry.message.role === "toolResult" && entry.message.usage) {
      const usage = entry.message.usage;
      input += usage.input;
      output += usage.output;
      cacheRead += usage.cacheRead;
      cacheWrite += usage.cacheWrite;
      cost += usage.cost.total;
    } else if ((entry.type === "branch_summary" || entry.type === "compaction") && entry.usage) {
      const usage = entry.usage;
      input += usage.input;
      output += usage.output;
      cacheRead += usage.cacheRead;
      cacheWrite += usage.cacheWrite;
      cost += usage.cost.total;
    }
  }

  return { input, output, cacheRead, cacheWrite, cost, cacheHitRate };
}

function sanitizeStatusText(text: string): string {
  return text.replace(/[\r\n\t]/g, " ").replace(/ +/g, " ").trim();
}

/** Renders the same "extension statuses joined on one row" text Pi's built-in footer
 * shows - unchanged behavior, just computed here instead of inside Pi's own component,
 * so quota/usage (or any other extension's own ctx.ui.setStatus()) keeps its existing
 * row while this extension's own scheduled-command text moves to a distinct line. */
export function buildExtensionStatusLine(statuses: ReadonlyMap<string, string>, width: number): string | undefined {
  if (statuses.size === 0) return undefined;
  const sorted = Array.from(statuses.entries())
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([, text]) => sanitizeStatusText(text));
  return clampToWidth(sorted.join(" "), width);
}
