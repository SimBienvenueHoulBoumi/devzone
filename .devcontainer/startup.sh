#!/usr/bin/env bash
# At each startup, in order: git identity (deduced from the gh account),
# Kubernetes clusters, gitlab.localhost name and 8929/2224
# relay of the gitlab module if enabled, relays of the postgres and argocd
# modules if enabled, port relays to the workstation, grouped credentials
# (.password), then the summary of what remains to be done (devzone).
# Sequential: the summary sees the identity just set; the failure of one step
# does not prevent the following ones.
# Never a question (gh, kubectl and its authentication plugins): output hidden
# behind make, a wait would block (see post-create.sh)
exec </dev/null
ICI="$(dirname "$0")"
# Former French names renamed first (#733): the packages check below reads the
# English names
bash "$ICI/rename-legacy-files.sh" || echo "startup : legacy names not renamed (devzone repair)"
bash "$ICI/git-identity.sh" || echo "startup : git identity not handled (devzone start)"
bash "$ICI/kube-config.sh" || echo "startup : clusters not handled (devzone start)"
# Token of the limited Kubernetes account (#430): 24 h, renewed at each
# startup; account set up on the way if missing. Without a chosen services
# cluster, nothing to do
devzone account token || echo "startup : kubernetes account token not renewed (devzone repair)"
# gitlab module enabled: /etc/hosts is a Docker mount regenerated at each
# startup, gitlab.localhost must be set again (ssh, glab and getent go through
# the system resolver); hote-poser never fails (warning only)
if bash "$ICI/devzone" is-enabled gitlab; then
    bash "$ICI/gitlab/gitlab.sh" hote-poser || echo "startup : gitlab.localhost name not set (devzone repair)"
    # TCP relay 8929/2224: curl and git over HTTP go through the local loop for
    # *.localhost, the relay must be restarted after each startup
    bash "$ICI/gitlab/gitlab.sh" relay-start || echo "startup : gitlab relay not started (devzone repair)"
fi
# postgres module enabled: the relay (port-forward to 127.0.0.1:5432) does not
# survive the container stop, restarted here after the clusters
if bash "$ICI/devzone" is-enabled postgres; then
    devzone postgres relay-start || echo "startup : postgres relay not started (devzone repair)"
fi
# argocd module enabled: relay (port-forward to 127.0.0.1:8443), restarted
# after the clusters like the one of postgres
if bash "$ICI/devzone" is-enabled argocd; then
    "$ICI/devzone" argocd relay-start || echo "startup : argocd relay not started (devzone repair)"
fi
# mysql module enabled: the relay 127.0.0.1:3306, restarted like the one of
# postgres after each startup
if bash "$ICI/devzone" is-enabled mysql; then
    devzone mysql relay-start || echo "startup : mysql relay not started (devzone repair)"
fi
# Port relays to the workstation (#290): the container IP changes at each
# startup, each relay of the state is recreated; a failure prevents nothing
bash "$ICI/ports.sh" restart || echo "startup : port relays not restarted (devzone repair)"
# Automatic port watcher to the workstation (#394, guard #293): a single
# instance in the background, real context set for this call only.
# Kubernetes workspace (#517): no watcher, ports go through devzone workspace ports
if [ "${DEVZONE_WORKSPACE:-}" != kubernetes ]; then
    DEVZONE_PORTS_AUTO_REAL=yes bash "$ICI/ports-auto.sh" demarrer >/dev/null 2>&1 || echo "startup : auto ports watcher not started (devzone repair)"
fi
# Application catalog: one <app>=off line per absent application, written
# once, never an existing line modified (#414)
bash "$ICI/catalog.sh" sync || echo "startup : catalog not synchronized (devzone repair)"
# Catalog watcher: applies again on the fly as soon as .devzone.modules changes
DEVZONE_CATALOG_REAL=yes bash "$ICI/catalog/catalog-watcher.sh" demarrer >/dev/null 2>&1 || echo "startup : catalog watcher not started (devzone repair)"

# Grouped view of the credentials (#332), regenerated at each startup; a failure
# prevents nothing and the content is never displayed
bash "$ICI/password.sh" regenerer || echo "startup : grouped credentials not updated (devzone repair)"
echo
bash "$ICI/devzone"
