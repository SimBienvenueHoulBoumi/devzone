package cluster

import (
	"context"
	"strings"
	"time"
)

// podName extracts the created pod name from kubectl debug output.
func podName(output []byte) string {
	for _, field := range strings.Fields(string(output)) {
		for _, prefix := range []string{"pod/", "Pod/"} {
			if i := strings.Index(field, prefix); i >= 0 {
				name := field[i+len(prefix):]
				if name != "" {
					return strings.Trim(name, ",")
				}
			}
		}
	}
	return ""
}

// waitPod waits for the debug pod to reach a final phase, at most 15 minutes.
func (c *client) waitPod(pod string) (string, error) {
	limited, cancel := context.WithTimeout(c.ctx, 15*time.Minute)
	defer cancel()
	interval := c.interval
	if interval <= 0 {
		interval = 2 * time.Second
	}
	for {
		res, err := c.kubectlCtx(limited, "get", "pod", pod, "-o", "jsonpath={.status.phase}")
		if err != nil {
			return "", err
		}
		phase := strings.TrimSpace(string(res.Stdout))
		if phase == "Succeeded" || phase == "Failed" {
			return phase, nil
		}
		select {
		case <-limited.Done():
			return "Failed", nil
		case <-time.After(interval):
		}
	}
}

// deletedLines returns the lines of crictl output that report deleted images.
func deletedLines(logs []byte) []string {
	var deleted []string
	for _, line := range strings.Split(string(logs), "\n") {
		if strings.Contains(line, "Deleted") {
			deleted = append(deleted, strings.TrimSpace(line))
		}
	}
	return deleted
}
