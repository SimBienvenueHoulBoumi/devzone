package agent

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// AgentLaunch runs opencode on brief with free-model rotation, resume, rights
// protection, shared rank, network wait; returns exit code. Shell agent_launch.
func AgentLaunch(ctx context.Context, opts Options, folder, brief string) int {
	clock := opts.clock()
	r := opts.runner()
	errOut := opts.err()
	// paths relative to calling folder made absolute before any cd/lock/state
	if !dirExists(folder) {
		return refuse(errOut, "folder not found: "+folder+" (searched from "+cwd()+")")
	}
	if !fileReadable(brief) {
		return refuse(errOut, "brief not found: "+brief+" (searched from "+cwd()+")")
	}
	folder = realPath(folder)
	brief = absFile(brief)
	// ai module required
	if !aiEnabled(ctx, r, opts.DevcontainerDir) {
		return refuse(errOut, "ai module disabled: devzone enable ai")
	}
	// safe configuration
	cfg, err := Configure(opts.DevcontainerDir, os.Getenv("OPENCODE_CONFIG_CONTENT"))
	if err != nil {
		return refuse(errOut, err.Error())
	}
	os.Setenv("OPENCODE_CONFIG_CONTENT", cfg)
	journal := JournalOf(opts.Racine, folder)
	os.Setenv("AGENT_JOURNAL", journal)
	state := opts.StateDir
	os.MkdirAll(filepath.Dir(journal), 0o755)
	os.MkdirAll(state, 0o755)
	RightsSnapshot(ctx, r, state, folder)
	// models
	freeModels := ListModels(ctx, r, nil)
	if len(freeModels) == 0 {
		return refuse(errOut, MsgNoModel)
	}
	requested := []string{}
	if opts.ModelList != "" {
		for _, nom := range strings.Split(opts.ModelList, ",") {
			if !contains(freeModels, nom) {
				fmt.Fprintf(errOut, MsgUnknown+"\n", nom)
				for _, m := range freeModels {
					fmt.Fprintf(errOut, "  %s\n", m)
				}
				return 2
			}
			requested = append(requested, nom)
		}
	}
	appendLine(journal, "=== --model : "+orNone(opts.ModelList))
	// local host model (#586)
	var local LocalModel
	if nom := Premier(ctx, r, opts.Home); nom != "" {
		local.LocalHostReal = nom
		local.LocalHostInternal = InternalName(nom)
		local.LocalModel = local.LocalHostInternal
	}
	total := ModelsTotal(freeModels, local.LocalModel)
	// shared rank
	start, ok := RankTake(ctx, r, state, journal, clock, os.Getpid(), total, requested, func(m string) bool { return ModelExcluded(state, m, clock.Now()) })
	if !ok {
		return refuse(errOut, "model rank locked: retry later")
	}
	atRank := func(rank int) string { return ModelAtRank(rank, start, freeModels, local.LocalModel) }
	order := ModelOrder(start, requested, total, atRank)
	briefCurrent := brief
	resumed := false
	resume := func() {
		if resumed {
			return
		}
		resumed = true
		c, _ := os.CreateTemp("", "devzone-agent-resume-*")
		if c != nil {
			c.WriteString(readFileString(briefCurrent) + ResumeSuffix)
			name := c.Name()
			c.Close()
			briefCurrent = name
		}
	}
	silenceSec := envFloat("DEVZONE_AGENT_SILENCE", 45)
	frozenSec := envFloat("DEVZONE_AGENT_FROZEN", 600)
	step := durationSec(envFloat("DEVZONE_AGENT_STEP", 1))
	networkFor := ""
	networkN := 0
	i := 0
	for i < len(order) {
		m := order[i]
		if m != networkFor {
			networkFor = m
			networkN = 0
		}
		if ModelExcluded(state, m, clock.Now()) {
			ModelRequestedExcluded(m, ModelExclusionCause(state, m), journal, requested)
			i++
			continue
		}
		ModelRequestedChosen(m, journal, requested)
		appendLine(journal, "=== model opencode/"+m+" start "+clock.Now().UTC().Format("2006-01-02T15:04:05Z"))
		offset := int64(fileSize(journal))
		proc, err := OpenCodeLaunch(ctx, r, opts.lookPath(), opts.starter(), folder, m, briefCurrent, journal, state, local)
		if err != nil {
			// could not start: treat as error on this model, next
			appendLine(journal, "=== opencode/"+m+" stopped on error (code 127): next model")
			resume()
			i++
			continue
		}
		started := false
		discard := false
		startT := clock.Now()
		// silence-at-start loop
		for proc.Alive() {
			if SessionFatalError(ctx, r, proc, journal, offset, m, folder, state, requested, journal, clock) {
				discard = true
				break
			}
			if fileSize(journal) > offset {
				newText := tailFrom(journal, offset)
				if ErrorCause(ErrorLines(newText)) != CauseQuota {
					started = true
					break
				}
			}
			if clock.Now().Sub(startT) >= durationSec(silenceSec) {
				break
			}
			clock.Sleep(step)
		}
		if discard {
			resume()
			i++
			continue
		}
		if proc.Alive() && !started {
			proc.Kill()
			RightsVerify(ctx, r, state, folder, journal)
			appendLine(journal, "=== opencode/"+m+" silent at start: excluded 1 h, next model")
			ModelExclude(state, m, CauseMute, clock.Now())
			ModelRequestedExcluded(m, CauseMute, journal, requested)
			resume()
			i++
			continue
		}
		// frozen session
		freeze := false
		if proc.Alive() && started {
			last := clock.Now()
			size := fileSize(journal)
			for proc.Alive() {
				if SessionFatalError(ctx, r, proc, journal, offset, m, folder, state, requested, journal, clock) {
					discard = true
					break
				}
				clock.Sleep(step)
				now := clock.Now()
				if fileSize(journal) > size {
					size = fileSize(journal)
					last = now
				}
				if now.Sub(last) > durationSec(frozenSec) {
					proc.Kill()
					RightsVerify(ctx, r, state, folder, journal)
					freeze = true
					break
				}
			}
		}
		if discard {
			resume()
			i++
			continue
		}
		if freeze {
			appendLine(journal, fmt.Sprintf("=== opencode/%s frozen (%d s without writing): new session, next model", m, int(frozenSec)))
			resume()
			i++
			continue
		}
		code := proc.Wait()
		RightsVerify(ctx, r, state, folder, journal)
		// only output of this attempt; only last 30 lines; only when non-zero or error line
		output := tailFrom(journal, offset)
		recent := LastTail(output, 30)
		if code != 0 || hasErrorLine(recent) {
			if matches := errorMatches(recent); len(matches) > 0 {
				cause := ErrorCause(matches[len(matches)-1])
				if cause == CauseNetwork && NetworkReachable(ctx, r) {
					appendLine(journal, "=== network error reported but network reachable: treated as other")
					cause = CauseOther
				}
				if cause == CauseNetwork && networkN >= NetworkRetries {
					appendLine(journal, fmt.Sprintf("=== opencode/%s network down %d times: next model, no exclusion", m, NetworkRetries))
					cause = CauseOther
				}
				if cause == CauseNetwork {
					if NetworkWait(ctx, r, clock, journal) {
						networkN++
						resume()
						continue
					}
					appendLine(journal, "=== network unavailable")
					return 4
				}
				if cause == CauseOther {
					appendLine(journal, "=== opencode/"+m+" error, no exclusion: next model")
				} else {
					ModelExclude(state, m, cause, clock.Now())
					ModelRequestedExcluded(m, cause, journal, requested)
					appendLine(journal, "=== opencode/"+m+" excluded ("+CauseLabel(cause)+", "+ExclusionLabel(cause)+"): next model")
				}
				resume()
				i++
				continue
			}
		}
		if code != 0 {
			appendLine(journal, fmt.Sprintf("=== opencode/%s stopped on error (code %d): next model", m, code))
			resume()
			i++
			continue
		}
		appendLine(journal, fmt.Sprintf("=== end with opencode/%s (code %d)", m, code))
		return code
	}
	appendLine(journal, "=== no free model available")
	return 3
}
