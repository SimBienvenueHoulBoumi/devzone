package agent

import (
	"context"
	"os"
	"strings"
)

func kubectlOut(ctx context.Context, r Runner, args ...string) string {
	if r == nil {
		return ""
	}
	res, err := r.Run(ctx, "kubectl", args, Opts{})
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(res.Stdout))
}

// AgentPodImageWorkspace workspace image; default when kubectl silent.
func AgentPodImageWorkspace(ctx context.Context, r Runner) string {
	v := kubectlOut(ctx, r, "get", "pod", "devzone-workspace-0", "-o", `jsonpath={.spec.containers[?(@.name=="workspace")].image}`)
	if v == "" {
		return "ghcr.io/simbienvenuehoulboumi/devzone-workspace:latest"
	}
	return v
}

// AgentPodPathWorkspace PATH of the workspace container; default.
func AgentPodPathWorkspace(ctx context.Context, r Runner) string {
	v := kubectlOut(ctx, r, "get", "pod", "devzone-workspace-0", "-o", `jsonpath={.spec.containers[?(@.name=="workspace")].env[?(@.name=="PATH")].value}`)
	if v == "" {
		return "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
	}
	return v
}

// AgentPodPVCWorkspace workspace PVC claim; default.
func AgentPodPVCWorkspace(ctx context.Context, r Runner) string {
	v := kubectlOut(ctx, r, "get", "pod", "devzone-workspace-0", "-o", `jsonpath={.spec.volumes[?(@.name=="workspace")].persistentVolumeClaim.claimName}`)
	if v == "" {
		return "workspace-devzone-workspace-0"
	}
	return v
}

// AgentPodPVCEtat etat PVC claim; default.
func AgentPodPVCEtat(ctx context.Context, r Runner) string {
	v := kubectlOut(ctx, r, "get", "pod", "devzone-workspace-0", "-o", `jsonpath={.spec.volumes[?(@.name=="etat")].persistentVolumeClaim.claimName}`)
	if v == "" {
		return "etat-devzone-workspace-0"
	}
	return v
}

// BuildManifest builds the session pod manifest to a temp file; returns path.
// brief never written here; only the ConfigMap. Shell agent_pod_build_manifest.
func BuildManifest(ctx context.Context, r Runner, folder, podName string, st PodState) (string, error) {
	wsImage := AgentPodImageWorkspace(ctx, r)
	wsPath := AgentPodPathWorkspace(ctx, r)
	pvcWorkspace := AgentPodPVCWorkspace(ctx, r)
	pvcEtat := AgentPodPVCEtat(ctx, r)
	egressMode := AgentPodEgressMode(ctx, r)
	ticketBlock := ""
	if st.Ticket != "" {
		ticketBlock = `    devzone.io/agent-ticket: "` + st.Ticket + `"`
	}
	tmpDir := os.Getenv("TMPDIR")
	if tmpDir == "" {
		tmpDir = os.TempDir()
	}
	tmp, err := os.CreateTemp(tmpDir, "devzone-agent-pod-manifest.*.yaml")
	if err != nil {
		return "", err
	}
	manifestFile := tmp.Name()
	tmp.Close()
	var b strings.Builder
	w := func(s string) { b.WriteString(s); b.WriteByte('\n') }
	w("apiVersion: v1")
	w("kind: Pod")
	w("metadata:")
	w("  name: " + podName)
	w("  labels:")
	w("    devzone.io/agent-session: " + st.SessionLabel)
	if ticketBlock != "" {
		w(ticketBlock)
	}
	w("spec:")
	b.WriteString(EgressInitLines(egressMode, wsImage))
	w("  restartPolicy: Never")
	w("  activeDeadlineSeconds: " + AgentPodActiveDeadlineSeconds())
	w("  automountServiceAccountToken: false")
	w("  securityContext:")
	w("    runAsUser: 1000")
	w("    runAsGroup: 1000")
	w("    runAsNonRoot: true")
	w("    fsGroup: 1000")
	w("  affinity:")
	w("    podAffinity:")
	w("      requiredDuringSchedulingIgnoredDuringExecution:")
	w("      - labelSelector:")
	w("          matchExpressions:")
	w("          - key: statefulset.kubernetes.io/pod-name")
	w("            operator: In")
	w("            values:")
	w("            - devzone-workspace-0")
	w("        topologyKey: kubernetes.io/hostname")
	w("  containers:")
	w("  - name: agent")
	w("    image: " + wsImage)
	w("    env:")
	w("    - name: HOME")
	w(`      value: "/home/vscode"`)
	w("    - name: NPM_CONFIG_PREFIX")
	w(`      value: "/home/vscode/.local/npm"`)
	w("    - name: PATH")
	w(`      value: "` + wsPath + `"`)
	w("    - name: DEVZONE_WORKSPACE")
	w(`      value: "kubernetes"`)
	w("    - name: DEVZONE_ROOT")
	w(`      value: "/workspaces/projets"`)
	b.WriteString(EgressManifestLines(egressMode))
	w("    resources:")
	w("      limits:")
	w("        cpu: " + AgentPodCPULimit())
	w("        memory: " + AgentPodMemLimit())
	w("    volumeMounts:")
	w("    - name: workspace")
	w("      mountPath: " + st.WorktreeMountpath)
	w("      subPath: " + st.WorktreeSubpath)
	w("    - name: workspace")
	w("      mountPath: " + st.GitMountpath)
	w("      subPath: " + st.GitSubpath)
	w("    - name: workspace")
	w("      mountPath: /workspaces/projets/.devzone.modules")
	w("      subPath: .devzone.modules")
	w("      readOnly: true")
	w("    - name: etat")
	w("      mountPath: /home/vscode/.config/opencode")
	w("      subPath: .config/opencode")
	w("    - name: etat")
	w("      mountPath: /home/vscode/.local/share/opencode")
	w("      subPath: .local/share/opencode")
	w("    - name: etat")
	w("      mountPath: /home/vscode/.local/state/oc-lancer")
	w("      subPath: .local/state/oc-lancer")
	w("    - name: etat")
	w("      mountPath: /home/vscode/.local/npm")
	w("      subPath: .local/npm")
	w("      readOnly: true")
	w("    - name: consigne")
	w("      mountPath: /agent-consigne")
	w("      readOnly: true")
	w("    - name: session-workspace")
	w("      mountPath: /workspaces/projets/workspace")
	w(`    command: ["/bin/bash", "-lc"]`)
	w("    args:")
	w("    - 'devzone agent --local " + folder + ` /agent-consigne/consigne.md; code=\$?; cat \"\$DEVZONE_ROOT/workspace/.agents/` + st.SessionLabel + `.log\" 2>/dev/null; exit \$code'`)
	w("  volumes:")
	w("  - name: workspace")
	w("    persistentVolumeClaim:")
	w("      claimName: " + pvcWorkspace)
	w("  - name: etat")
	w("    persistentVolumeClaim:")
	w("      claimName: " + pvcEtat)
	w("  - name: consigne")
	w("    configMap:")
	w("      name: " + podName + "-consigne")
	w("  - name: session-workspace")
	w("    emptyDir:")
	w("      sizeLimit: 256Mi")
	if err := os.WriteFile(manifestFile, []byte(b.String()), 0o644); err != nil {
		return "", err
	}
	return manifestFile, nil
}
