// Package subreaper runs one command as the child of a process that adopts the
// orphans of its whole subtree and reaps them.
//
// Why: an orphan is re-parented to the nearest ancestor that declared itself a
// child subreaper, or else to PID 1. In the workspace pod PID 1 was
// "sleep infinity", which never calls wait, so every orphan of an agent session
// stayed a zombie: 20 000 of them in 2.5 days (#973). A zombie can only be
// removed by its parent, so the session's launcher must be that parent.
package subreaper

// Result is the outcome of one Run.
type Result struct {
	// Code is the exit status of the direct child: its own code, or 128 plus
	// the number of the signal that killed it, as a shell reports it.
	Code int
	// Subreaper is true when the kernel accepted the child subreaper flag.
	// False means orphans were not adopted here, and the command ran anyway.
	Subreaper bool
	// Reaped lists the pids of the orphans collected while the child ran,
	// in the order they were collected. Empty on platforms without a subreaper.
	Reaped []int
}
