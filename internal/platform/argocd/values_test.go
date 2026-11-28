package argocd

import (
	"reflect"
	"testing"
)

// TestValidateWorkspaceValues checks the plain-language warnings of the pure
// reader, including nested keys, commented defaults and quoted quantities.
func TestValidateWorkspaceValues(t *testing.T) {
	for _, tc := range []struct {
		name string
		data string
		want []string
	}{
		{
			name: "comments only",
			data: "# livenessProbe.thresholdPercent: 85\n# resources.limits.memory: 8Gi\n",
			want: nil,
		},
		{
			name: "valid values",
			data: "livenessProbe:\n  thresholdPercent: 90\n  periodSeconds: 60\nresources:\n  requests:\n    memory: 4Gi\n",
			want: nil,
		},
		{
			name: "quoted values and comments",
			data: "livenessProbe:\n  thresholdPercent: \"90\" # user note\nresources:\n  limits:\n    memory: '8Gi'\n",
			want: nil,
		},
		{
			name: "unknown key",
			data: "livenessProbe:\n  tresholdPercent: 90\n",
			want: []string{"line 2: unknown key livenessProbe.tresholdPercent"},
		},
		{
			name: "unknown nested key",
			data: "foo:\n  bar: 1\n",
			want: []string{"line 2: unknown key foo.bar"},
		},
		{
			name: "threshold too high",
			data: "livenessProbe:\n  thresholdPercent: 96\n",
			want: []string{"line 2: livenessProbe.thresholdPercent must be between 50 and 95 (got 96)"},
		},
		{
			name: "threshold too low",
			data: "livenessProbe:\n  thresholdPercent: 49\n",
			want: []string{"line 2: livenessProbe.thresholdPercent must be between 50 and 95 (got 49)"},
		},
		{
			name: "probe value not a number",
			data: "livenessProbe:\n  periodSeconds: often\n",
			want: []string{"line 2: livenessProbe.periodSeconds must be a whole number: \"often\""},
		},
		{
			name: "unreadable memory",
			data: "resources:\n  limits:\n    memory: 8GB\n",
			want: []string{"line 3: resources.limits.memory is not a readable memory quantity: \"8GB\""},
		},
		{
			name: "several problems",
			data: "livenessProbe:\n  thresholdPercent: 99\nresources:\n  requests:\n    memory: lots\n",
			want: []string{
				"line 2: livenessProbe.thresholdPercent must be between 50 and 95 (got 99)",
				"line 5: resources.requests.memory is not a readable memory quantity: \"lots\"",
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := ValidateWorkspaceValues([]byte(tc.data))
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("problems = %q, want %q", got, tc.want)
			}
		})
	}
}
