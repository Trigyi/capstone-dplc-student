{{- define "worldcup2026-app.fullname" -}}
{{ .Release.Name }}-app
{{- end -}}

{{- define "worldcup2026-app.postgresFullname" -}}
{{ .Release.Name }}-postgres
{{- end -}}

{{- define "worldcup2026-app.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
