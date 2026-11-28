//go:build !windows

package podcmd

import "syscall"

// setCoreLimit disables core dumps at startup so a crash cannot leave a huge
// file in a worktree; a failure is ignored because init must never stop the pod.
func setCoreLimit() {
	var limit syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_CORE, &limit); err != nil {
		return
	}
	limit.Cur = 0
	_ = syscall.Setrlimit(syscall.RLIMIT_CORE, &limit)
}
