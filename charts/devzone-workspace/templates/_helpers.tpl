{{- define "devzone-workspace.name" -}}
devzone-workspace
{{- end -}}

{{- define "devzone-workspace.fullname" -}}
devzone-workspace
{{- end -}}

{{- define "devzone-workspace.serviceAccountName" -}}
{{ .Values.serviceAccount.name }}
{{- end -}}
