package podcmd

import (
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// runServicesAdmin installs or removes a devzone service from inside the
// Kubernetes workspace pod using a temporary administrator token read on
// standard input; it replaces the removed services-admin.sh shell script.
func runServicesAdmin(ctx *cli.Context) int {
	args := ctx.Args
	action := ""
	service := ""
	if len(args) > 0 {
		action = args[0]
	}
	if len(args) > 1 {
		service = args[1]
	}
	options := []string{}
	if len(args) > 2 {
		options = append([]string{}, args[2:]...)
	}

	switch action {
	case "enable", "disable":
	case "seed":
	default:
		return refuseServicesAdmin(ctx, "usage: services-admin.sh enable|disable|seed gitlab|postgres|argocd [options]")
	}
	switch service {
	case "gitlab", "postgres", "argocd":
	default:
		return refuseServicesAdmin(ctx, "unknown service: "+orNone(service)+" (gitlab, postgres, argocd)")
	}
	if action == "seed" && service != "gitlab" {
		return refuseServicesAdmin(ctx, "seed: only gitlab")
	}
	if os.Getenv("DEVZONE_WORKSPACE") != "kubernetes" {
		return refuseServicesAdmin(ctx, "only in the Kubernetes workspace pod")
	}

	saDir := os.Getenv("DEVZONE_SA_DIR")
	if saDir == "" {
		saDir = "/var/run/secrets/kubernetes.io/serviceaccount"
	}
	apiServer := os.Getenv("DEVZONE_API_SERVER")
	if apiServer == "" {
		apiServer = "https://kubernetes.default.svc"
	}
	caPath := filepath.Join(saDir, "ca.crt")
	if _, err := os.Stat(caPath); err != nil {
		return refuseServicesAdmin(ctx, "cluster CA not found: "+caPath)
	}

	tokenBytes, err := io.ReadAll(ctx.Stdin)
	if err != nil {
		return refuseServicesAdmin(ctx, "cannot read the token on standard input")
	}
	token := strings.ReplaceAll(string(tokenBytes), "\r", "")
	token = strings.ReplaceAll(token, "\n", "")
	if strings.TrimSpace(token) == "" {
		return refuseServicesAdmin(ctx, "empty token on stdin")
	}

	tmpDir := os.Getenv("TMPDIR")
	if tmpDir == "" {
		tmpDir = "/tmp"
	}
	kubeconfigFile, err := os.CreateTemp(tmpDir, "devzone-services-admin.*")
	if err != nil {
		return refuseServicesAdmin(ctx, "cannot create the temporary kubeconfig")
	}
	kubeconfigPath := kubeconfigFile.Name()
	_ = kubeconfigFile.Close()
	if err := os.Chmod(kubeconfigPath, 0o600); err != nil {
		_ = os.Remove(kubeconfigPath)
		return refuseServicesAdmin(ctx, "cannot secure the temporary kubeconfig")
	}

	stPath := statePath()
	clusterBefore := readClusterLine(stPath)

	script, err := podScript()
	if err != nil {
		_ = os.Remove(kubeconfigPath)
		return refuseServicesAdmin(ctx, err.Error())
	}

	defer func() {
		_ = os.Remove(kubeconfigPath)
		_, _ = ctx.Runner.Run(context.Background(), script, []string{service, "relay-stop"}, exec.Opts{
			Env: []string{"DEVZONE_STATE=" + stPath},
		})
		if clusterBefore != "" {
			_, _ = ctx.Runner.Run(context.Background(), script, []string{"state", "write", "cluster", clusterBefore}, exec.Opts{
				Env: []string{"DEVZONE_STATE=" + stPath},
			})
		} else {
			_, _ = ctx.Runner.Run(context.Background(), script, []string{"state", "remove", "cluster"}, exec.Opts{
				Env: []string{"DEVZONE_STATE=" + stPath},
			})
		}
	}()

	caData, err := os.ReadFile(caPath)
	if err != nil {
		return refuseServicesAdmin(ctx, "cannot read the cluster CA")
	}
	encodedCA := base64.StdEncoding.EncodeToString(caData)

	content := "apiVersion: v1\n" +
		"kind: Config\n" +
		"clusters:\n" +
		"  - name: devzone-pod\n" +
		"    cluster:\n" +
		"      server: " + apiServer + "\n" +
		"      certificate-authority-data: " + encodedCA + "\n" +
		"users:\n" +
		"  - name: devzone-services-admin\n" +
		"    user:\n" +
		"      token: " + token + "\n" +
		"contexts:\n" +
		"  - name: devzone-admin\n" +
		"    context:\n" +
		"      cluster: devzone-pod\n" +
		"      user: devzone-services-admin\n" +
		"  - name: devzone\n" +
		"    context:\n" +
		"      cluster: devzone-pod\n" +
		"      user: devzone-services-admin\n" +
		"current-context: devzone-admin\n"
	if err := os.WriteFile(kubeconfigPath, []byte(content), 0o600); err != nil {
		return refuseServicesAdmin(ctx, "cannot write the temporary kubeconfig")
	}

	env := []string{
		"KUBECONFIG=" + kubeconfigPath,
		"DEVZONE_KUBE_CONFIG=" + kubeconfigPath,
		"DEVZONE_SERVICES_ADMIN=1",
		"DEVZONE_STATE=" + stPath,
	}

	if res, err := ctx.Runner.Run(context.Background(), script, []string{"state", "write", "cluster", "devzone-admin"}, exec.Opts{Env: env}); err != nil || res.Code != 0 {
		return refuseServicesAdmin(ctx, "cannot write the state: "+stPath)
	}

	fmt.Fprintf(ctx.Out, "devzone services: %s %s in the cluster of the pod (temporary administrator)\n", action, service)

	serviceArgs := []string{}
	if action == "seed" {
		serviceArgs = append(serviceArgs, "gitlab", "seed")
	} else {
		serviceArgs = append(serviceArgs, action, service)
	}
	serviceArgs = append(serviceArgs, options...)

	res, err := ctx.Runner.Run(context.Background(), script, serviceArgs, exec.Opts{Env: env})
	if len(res.Stdout) > 0 {
		_, _ = ctx.Out.Write(res.Stdout)
	}
	if len(res.Stderr) > 0 {
		_, _ = ctx.Err.Write(res.Stderr)
	}
	if err != nil {
		return 1
	}
	if res.Code != 0 {
		return res.Code
	}
	return 0
}

// refuseServicesAdmin prints a refusal message to standard error and returns
// the exit status used by the removed shell script for invalid input.
func refuseServicesAdmin(ctx *cli.Context, msg string) int {
	fmt.Fprintf(ctx.Err, "devzone services: %s\n", msg)
	return 2
}

// readClusterLine returns the last cluster= value of a state file, or an empty
// string when the key is absent, matching the shell helper.
func readClusterLine(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	last := ""
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "cluster=") {
			last = strings.TrimPrefix(line, "cluster=")
		}
	}
	return last
}

// orNone returns a readable placeholder for an empty service name.
func orNone(s string) string {
	if s == "" {
		return "(none)"
	}
	return s
}
