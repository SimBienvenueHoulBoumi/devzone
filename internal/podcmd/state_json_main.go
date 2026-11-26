package podcmd

import (
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
)

// runStateJSON prints the schema 3 status object with the exact key order of
// state-json.sh; each failure becomes a null value and an error entry.
func runStateJSON(ctx *cli.Context, st *state.State) int {
	d := jsonDeps{ctx: ctx, st: st, root: devzoneRoot(), code: codeRoot()}
	errs := jsonObject{}
	alerts := []any{}

	version, err := folderVersion(d.root)
	if err != nil {
		errs.set("devzone", "folder_version unavailable")
	}
	platform := platformJSON(d, &errs)
	alerts = appendClusterDiskAlert(d, alerts)
	services, servicesRemote := servicesClusterJSON(d)
	work, workInternal, hostCtx := workClusterJSON(d)
	tools, errs := toolsJSON(d, errs)
	modules, errs := modulesJSON(d, errs)
	ports, errs := portsJSON(d, errs)
	applications, errs := applicationsJSON(d, errs)
	alerts = appendOtherAlerts(d, alerts, services, servicesRemote, work, workInternal, hostCtx)

	out := jsonObject{
		{key: "schema", value: 3},
		{key: "devzone", value: devzoneJSON(d, version)},
		{key: "git_identity", value: gitIdentityJSON(d)},
		{key: "platform", value: platform},
		{key: "argocd_repo", value: argocdRepo(d.root)},
		{key: "tools", value: tools},
		{key: "modules", value: modules},
		{key: "clusters", value: clustersJSON(services, servicesRemote, work, workInternal, hostCtx)},
		{key: "ports", value: ports},
		{key: "applications", value: applications},
		{key: "credentials", value: credentialsJSON(d.root)},
		{key: "alerts", value: alerts},
		{key: "errors", value: errs},
	}
	if err := writeJSON(ctx.Out, out); err != nil {
		return 1
	}
	return 0
}

// appendAlert adds one alert with a null command when none is provided.
func appendAlert(alerts []any, code, message, command string) []any {
	return append(alerts, jsonObject{
		{key: "code", value: code},
		{key: "message", value: message},
		{key: "command", value: strOrNil(command)},
	})
}
