package catalog

import (
	"os"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/relay"
)

// remove uninstalls one application: relay, failure marker, limited account and
// either the Argo CD Application or the manifest. The volume and data stay.
func (e *env) remove(app string) int {
	ns, err := e.appNamespace(app)
	if err != nil {
		return e.refuse("%s", err.Error())
	}
	relay.Stop(e.relayDir(app), app)
	_ = os.Remove(e.failureFile(app))
	if ctxName := e.cluster(); ctxName != "" {
		_ = e.kube.AccountRemove(e.ctx, ctxName, ns)
	}
	claim := ""
	if res, err := e.k(ns, "get", "statefulset", app,
		"-o", "jsonpath={.spec.volumeClaimTemplates[0].metadata.name}"); err == nil && res.Code == 0 {
		claim = strings.TrimSpace(string(res.Stdout))
	}
	if claim == "" {
		claim = "donnees"
	}
	pvc := claim + "-" + app + "-0"
	if res, err := e.exec(e.script, []string{"argocd", "catalog-application-exists", app}); err == nil && res.Code == 0 {
		_, _ = e.exec(e.script, []string{"argocd", "catalog-delete", app})
		_, _ = e.k(ns, "delete", "secret", app+"-admin")
		e.out("✔ %s removed: Application deleted; volume %s and databases kept: devzone %s volume", app, pvc, app)
		e.regenerate()
		return 0
	}
	_, _ = e.k(ns, "delete", "statefulset/"+app, "service/"+app, "secret/"+app+"-admin")
	e.out("✔ %s removed from the cluster; volume %s and databases kept: devzone %s volume", app, pvc, app)
	e.regenerate()
	return 0
}
