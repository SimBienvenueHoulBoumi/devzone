// Package output provides the shared human readable and JSON output helpers.
package output

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"
)

const (
	prefixOK   = "✔"
	prefixWarn = "⚠"
	prefixFail = "✖"
	prefixInfo = "ℹ"
)

func emit(w io.Writer, prefix, format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	if !strings.HasSuffix(msg, "\n") {
		msg += "\n"
	}
	fmt.Fprintf(w, "%s %s", prefix, msg)
}

// OK writes a success line.
func OK(w io.Writer, format string, args ...any) { emit(w, prefixOK, format, args...) }

// Warn writes a warning line.
func Warn(w io.Writer, format string, args ...any) { emit(w, prefixWarn, format, args...) }

// Fail writes an error line.
func Fail(w io.Writer, format string, args ...any) { emit(w, prefixFail, format, args...) }

// Info writes an informational line.
func Info(w io.Writer, format string, args ...any) { emit(w, prefixInfo, format, args...) }

// JSON writes v as indented JSON with a trailing newline.
func JSON(w io.Writer, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	_, err = w.Write(data)
	return err
}
