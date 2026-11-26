// Package agent is the Go port of devzone agent (#878): it drives opencode on
// a brief with free-model rotation, exclusions, rights protection, a shared
// rank, the Kubernetes workspace and an ephemeral session pod, with identical
// behavior, outputs, journals, state files and exit codes as the removed
// shell scripts. opencode, git, gh, kubectl, curl, getent and ps go through
// injectable interfaces; tests use fakes only.
package agent
