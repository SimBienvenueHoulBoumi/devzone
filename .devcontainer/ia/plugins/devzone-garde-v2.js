// Guard for opencode 2.x: blocks Docker commands in devzone (Kubernetes-first).
// Each shell tool call is checked by docker-garde.sh. Exit code 2: error shown
// to the agent with stderr message. Script absent or failing: nothing blocked.
// The installed copy (devzone enable ia) replaces the placeholder below with
// the script path; DEVZONE_DOCKER_GARDE overrides it. The script is resolved
// from the plugin location itself (.devcontainer/ia/plugins -> ../docker-garde.sh).
// opencode 1.x also loads default exports with an id; without ctx.tool.hook the
// 1.x guard in devzone-garde.js remains active.
import { spawnSync } from "node:child_process"
import { existsSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

const INSTALLED = process.env.DEVZONE_DOCKER_GARDE || "__DEVZONE_DOCKER_GARDE__"

function guardScript() {
  if (INSTALLED && INSTALLED.indexOf("__DEVZONE_DOCKER_GARDE__") !== 0 && existsSync(INSTALLED)) {
    return INSTALLED
  }
  const script = join(dirname(fileURLToPath(import.meta.url)), "..", "docker-garde.sh")
  if (existsSync(script)) {
    return script
  }
  return null
}

function garde(script, tool, args, cwd) {
  if (!script || !existsSync(script)) return
  const r = spawnSync("bash", [script], {
    input: JSON.stringify({ tool, args, cwd }),
    encoding: "utf8",
  })
  if (r.status === 2) throw new Error((r.stderr || "").trim())
}

export default {
  id: "devzone-garde",
  setup: (ctx) => {
    if (typeof ctx?.tool?.hook !== "function") return
    const dir = ctx.location?.directory || process.cwd()
    const script = guardScript()
    return ctx.tool.hook("execute.before", (call) => garde(script, call.tool, call.input, dir))
  },
  server: async () => ({}),
}
