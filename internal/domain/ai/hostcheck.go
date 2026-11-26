package ai

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"

	dzexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// modelState compares the registry manifest digest with the local one. A name
// with a slash, a missing digest or an unreachable registry is not verifiable.
func modelState(ctx context.Context, o Options, name, digest string) string {
	if strings.Contains(name, "/") || digest == "" {
		return msgUnknown
	}
	short, tag := name, "latest"
	if i := strings.LastIndex(name, ":"); i >= 0 {
		short, tag = name[:i], name[i+1:]
	}
	url := o.registryURL() + "/v2/library/" + short + "/manifests/" + tag
	res, err := o.runner().Run(ctx, "curl", []string{
		"-fsS", "--max-time", "5", "-H", "Accept: " + manifestType, url,
	}, dzexec.Opts{})
	if err != nil || res.Code != 0 {
		return msgUnknown
	}
	sum := sha256.Sum256(res.Stdout)
	local := hex.EncodeToString(sum[:])
	remote := strings.TrimPrefix(digest, "sha256:")
	if strings.EqualFold(local, remote) {
		return msgCurrent
	}
	return msgUpdate
}

// reason returns why a model was chosen: variable, measurement or rule.
func reason(o Options, names []string) string {
	if o.hostModel() != "" {
		return msgByVar
	}
	if measuredChoice(o, names) != "" {
		return "measurement"
	}
	return msgByRule
}

// none prints the message shown when the workstation service does not answer.
func none(o Options) {
	fmt.Fprintln(o.out(), strings.Replace(msgNone, "{url}", o.url(), 1))
}

// Check prints the update state of every detected model without downloading.
func Check(ctx context.Context, o Options) {
	all := Infos(ctx, o)
	if len(all) == 0 {
		none(o)
		return
	}
	for _, m := range all {
		state := modelState(ctx, o, m.name, m.digest)
		fmt.Fprintf(o.out(), "%s : %s\n", m.name, state)
		if state == msgUpdate {
			fmt.Fprintln(o.out(), strings.Replace(msgPull, "{modele}", m.name, 1))
		}
	}
}

// Report prints sizes, update states, measurements and the chosen default.
func Report(ctx context.Context, o Options) {
	all := Infos(ctx, o)
	if len(all) == 0 {
		none(o)
		return
	}
	var names []string
	for _, m := range all {
		names = append(names, m.name)
	}
	fmt.Fprintln(o.out(), msgTitle)
	for _, m := range all {
		state := modelState(ctx, o, m.name, m.digest)
		fmt.Fprintf(o.out(), "  %s : %s ; %s %d\n", m.name, state, msgSize, m.size)
		if reussite, speed, ok := measurementFor(o, m.name); ok {
			line := strings.Replace(msgMeasure, "{reussite}", fmt.Sprint(reussite), 1)
			line = strings.Replace(line, "{tok_s}", fmt.Sprint(speed), 1)
			fmt.Fprintf(o.out(), "    %s\n", line)
		}
		if state == msgUpdate {
			fmt.Fprintln(o.out(), strings.Replace(msgPull, "{modele}", m.name, 1))
		}
	}
	line := strings.Replace(msgChosen, "{modele}", First(ctx, o, names), 1)
	line = strings.Replace(line, "{raison}", reason(o, names), 1)
	fmt.Fprintln(o.out(), line)
}
