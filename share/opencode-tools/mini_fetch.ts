import { tool } from "@opencode-ai/plugin"
import os from "os"
import path from "path"

/**
 * Fetch a URL as readable text.
 *
 * Sends the headers a normal desktop browser sends, so documentation sites that
 * reject bare curl still render. Wraps ~/.cache/mini/tools/webfetch.
 */
const SCRIPT = path.join(
  process.env.MINI_HOME || path.join(os.homedir(), ".cache", "mini"),
  "tools",
  "webfetch",
)

export default tool({
  description:
    "Fetch a web page and return it as plain text, with scripts, styles and navigation stripped. Use it to read documentation, changelogs, or a URL returned by mini_search.",
  args: {
    url: tool.schema.string().describe("Full URL to fetch"),
    max_chars: tool.schema
      .number()
      .min(1000)
      .max(200000)
      .optional()
      .describe("Truncate the output (default 20000)"),
  },
  async execute(args) {
    const max = String(args.max_chars ?? 20000)
    try {
      const out = await Bun.$`${SCRIPT} -c ${max} ${args.url}`.text()
      return out.trim() || "empty page"
    } catch (e: any) {
      return `fetch failed: ${e?.stderr?.toString?.().trim() || e?.message || String(e)}`
    }
  },
})
