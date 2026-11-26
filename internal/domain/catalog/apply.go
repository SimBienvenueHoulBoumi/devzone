package catalog

import (
	"os"
	"strings"
)

// apply closes the gap between the wanted and the real state of every catalog
// application: remove what is off, restart the relay or install what is on.
// The first failure is marked and does not stop the other applications.
func (e *env) apply() int {
	names, err := e.apps()
	if err != nil {
		e.warn("%v", err)
		return 1
	}
	code := 0
	for _, app := range names {
		wanted := e.wanted(app)
		present := e.present(app)
		switch {
		case !wanted && present:
			clone, buf := e.captured()
			if result := clone.remove(app); result != 0 {
				code = 1
				e.appFailure(app, buf.String())
			} else {
				e.printCaptured(buf.String())
			}
		case wanted && present:
			if !e.appReady(app) {
				code = 1
				e.warn("devzone : catalog : %s installed but not ready: devzone apply", app)
				_ = os.WriteFile(e.failureFile(app), []byte("not ready\n"), 0o644)
			} else {
				_ = os.Remove(e.failureFile(app))
			}
			e.restartRelay(app)
		case wanted:
			clone, buf := e.captured()
			if result := clone.install(app); result != 0 {
				code = 1
				e.appFailure(app, buf.String())
			} else {
				e.printCaptured(buf.String())
			}
		}
	}
	return code
}

// restartRelay starts the permanent relay of an installed application when it
// stopped; a failed start marks the application but keeps the other ones.
func (e *env) restartRelay(app string) {
	ctxName := e.cluster()
	if ctxName == "" {
		return
	}
	ns, err := e.appNamespace(app)
	if err != nil {
		return
	}
	clone, buf := e.captured()
	if err := clone.startRelay(app, ctxName, ns); err != nil {
		e.appFailure(app, err.Error())
		return
	}
	if text := strings.TrimSpace(buf.String()); text != "" {
		e.printCaptured(buf.String())
	}
}

// printCaptured writes the output of a successful nested command once.
func (e *env) printCaptured(text string) {
	if text == "" {
		return
	}
	e.out("%s", text)
}
