// Guard for opencode 1.x: blocks Docker commands in devzone (Kubernetes-first).
// Each shell tool call is checked by docker-guard.sh. Exit code 2: error shown
// to the agent with stderr message. Script absent or failing: nothing blocked.
// The installed copy (devzone enable ai) replaces the placeholder below with
// the script path; DEVZONE_DOCKER_GUARD overrides it. The script is resolved
// from the plugin location itself (.devcontainer/ai/plugins -> ../docker-guard.sh).
import { spawnSync } from "node:child_process"
import { existsSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

const INSTALLED = process.env.DEVZONE_DOCKER_GUARD || "__DEVZONE_DOCKER_GUARD__"

function guardScript() {
  if (INSTALLED && INSTALLED.indexOf("__DEVZONE_DOCKER_GUARD__") !== 0 && existsSync(INSTALLED)) {
    return INSTALLED
  }
  const script = join(dirname(fileURLToPath(import.meta.url)), "..", "docker-guard.sh")
  if (existsSync(script)) {
    return script
  }
  return null
}

export const DevzoneGarde = async (ctx) => {
  const cwd = ctx?.directory || ctx?.location?.directory || process.cwd()
  const script = guardScript()
  return {
    "tool.execute.before": async (input, output) => {
      if (!script || !existsSync(script)) return
      const r = spawnSync("bash", [script], {
        input: JSON.stringify({ tool: input.tool, args: output.args, cwd }),
        encoding: "utf8",
      })
      if (r.status === 2) throw new Error((r.stderr || "").trim())
    },
  }
}
