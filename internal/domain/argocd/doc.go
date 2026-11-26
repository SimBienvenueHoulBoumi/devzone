/*
Package argocd ports the argocd module of the devcontainer to Go. It keeps the
same behavior and outputs as the original shell scripts, exposes pod
subcommands for callers that remain in shell, and covers every removed bats
test with Go tests.
*/
package argocd
