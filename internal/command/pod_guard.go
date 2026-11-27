package command

import (
	"fmt"
	"io"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/agent"
)

// refuseInPod stops the host program when it is started inside the pod, before
// it dispatches or delegates anything: a devzone installed by npm in the pod
// hides the image program, and the old "pod command" reply wrongly told the
// user to enter the pod they were already in (#980).
func refuseInPod(errOut io.Writer) bool {
	if !agent.AgentInPod() {
		return false
	}
	fmt.Fprintln(errOut, "devzone: you are in the pod, this program is the host one; uninstall it here (npm uninstall -g devzone) to get the pod one back")
	return true
}
