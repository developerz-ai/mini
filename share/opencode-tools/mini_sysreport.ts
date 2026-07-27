import { tool } from "@opencode-ai/plugin"
import os from "os"
import path from "path"

/**
 * One read-only snapshot of the host: failed units, disk, inodes, memory, OOM
 * kills, top processes, listening sockets, recent errors, kernel warnings.
 *
 * Cheaper and more reliable than making a small model issue a dozen separate
 * bash calls and stitch the outputs together itself.
 */
const SCRIPT = path.join(
  process.env.MINI_HOME || path.join(os.homedir(), ".cache", "mini"),
  "tools",
  "sysreport",
)

export default tool({
  description:
    "Read-only snapshot of this machine's health: failed services, disk and inode usage, memory and OOM kills, top processes, listening ports, recent errors and kernel warnings. Run this FIRST when asked to debug or diagnose the machine. Changes nothing.",
  args: {
    full: tool.schema
      .boolean()
      .optional()
      .describe(
        "Also include network, DNS, firewall, mounts, recent package installs and journal size",
      ),
  },
  async execute(args) {
    try {
      const out = args.full
        ? await Bun.$`${SCRIPT} -f`.text()
        : await Bun.$`${SCRIPT}`.text()
      return out.trim() || "sysreport produced no output"
    } catch (e: any) {
      return `sysreport failed: ${e?.stderr?.toString?.().trim() || e?.message || String(e)}`
    }
  },
})
