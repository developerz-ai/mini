import { tool } from "@opencode-ai/plugin"
import os from "os"
import path from "path"

/**
 * Web search with no API key.
 *
 * The heavy lifting lives in a plain bash script at ~/.cache/mini/tools/websearch
 * so the same capability works from the shell, from a cron job, or from here.
 * This file only teaches the model that the capability exists.
 *
 * Named mini_search rather than websearch on purpose: these tools install
 * globally, and shadowing an opencode built-in would change behaviour in every
 * other project the user opens.
 */
const SCRIPT = path.join(
  process.env.MINI_HOME || path.join(os.homedir(), ".cache", "mini"),
  "tools",
  "websearch",
)

export default tool({
  description:
    "Search the web and get back titles, URLs and snippets. Use this whenever an error message is unfamiliar, a package or repository path may have changed, or you would otherwise guess at a version number. Follow up with mini_fetch to read a result.",
  args: {
    query: tool.schema
      .string()
      .describe("Search query. Quote exact error strings for best results."),
    count: tool.schema
      .number()
      .min(1)
      .max(25)
      .optional()
      .describe("How many results to return (default 5)"),
  },
  async execute(args) {
    const count = String(args.count ?? 5)
    try {
      const out = await Bun.$`${SCRIPT} -n ${count} ${args.query}`.text()
      return out.trim() || "no results"
    } catch (e: any) {
      return `search failed: ${e?.stderr?.toString?.().trim() || e?.message || String(e)}`
    }
  },
})
