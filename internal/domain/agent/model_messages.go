package agent

import "fmt"

// message formats of devzone agent --model (#420); agent-model.messages.
const (
	MsgNoModel  = "no free model available"
	MsgChosen   = "=== requested model chosen: %s"
	MsgExcluded = "=== requested model %s excluded (%s), next"
	MsgUnknown  = "devzone agent: unknown model: %s ; free models:"
)

// modelRequestedP true when model asked with --model.
func modelRequestedP(model string, requested []string) bool {
	for _, m := range requested {
		if m == model {
			return true
		}
	}
	return false
}

// ModelRequestedChosen journal line when requested model starts (#420).
func ModelRequestedChosen(model, journal string, requested []string) {
	if modelRequestedP(model, requested) {
		appendLine(journal, fmt.Sprintf(MsgChosen, model))
	}
}

// ModelRequestedExcluded journal line when requested model excluded (#420).
func ModelRequestedExcluded(model, cause, journal string, requested []string) {
	if modelRequestedP(model, requested) {
		appendLine(journal, fmt.Sprintf(MsgExcluded, model, cause))
	}
}
