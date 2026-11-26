package agent

import (
	"os"
	"strconv"
	"strings"
	"time"
)

// readFileBytes reads a file, returning empty when it cannot.
func readFileBytes(p string) ([]byte, error) {
	b, err := os.ReadFile(p)
	if err != nil {
		return nil, err
	}
	return b, nil
}

// readFileString reads a file, returning empty when it cannot.
func readFileString(p string) string {
	b, _ := os.ReadFile(p)
	return string(b)
}

// appendLine appends a line to a file (journal), creating it when missing.
func appendLine(p, line string) {
	if p == "" {
		return
	}
	f, err := os.OpenFile(p, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	f.WriteString(line + "\n")
}

// writeFile writes content, creating parents.
func writeFile(p, content string, perm os.FileMode) error {
	if dir := parentDir(p); dir != "" {
		os.MkdirAll(dir, 0o755)
	}
	return os.WriteFile(p, []byte(content), perm)
}

func parentDir(p string) string {
	for i := len(p) - 1; i >= 0; i-- {
		if p[i] == '/' || p[i] == '\\' {
			return p[:i]
		}
	}
	return ""
}

func envInt(name string, def int) int {
	if v := os.Getenv(name); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func envFloat(name string, def float64) float64 {
	if v := os.Getenv(name); v != "" {
		if n, err := strconv.ParseFloat(v, 64); err == nil {
			return n
		}
	}
	return def
}

func envStr(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

func durationSec(sec float64) time.Duration {
	return time.Duration(sec * float64(time.Second))
}

// trimRight trims trailing whitespace.
func trimRight(s string) string { return strings.TrimRight(s, " \t\r\n") }
