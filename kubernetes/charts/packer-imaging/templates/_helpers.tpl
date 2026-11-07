{{/*
Labels every object this chart creates carries.
*/}}
{{- define "packer-imaging.labels" -}}
app.kubernetes.io/part-of: {{ .Values.labels.partOf }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name (.Chart.Version | toString) | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
The CronJob name for a project.

This is a contract with the web front end, not a private detail: the UI recovers
the project name by stripping this prefix (PROJECT_PREFIX in web/runs.py), and
shows every run it cannot strip as an orphan. Change it here only alongside that
constant.
*/}}
{{- define "packer-imaging.jobName" -}}
{{- printf "%s%s" .Values.jobPrefix .name -}}
{{- end }}

{{/*
The pkrvars Secret a project mounts. Named for the project so one Secret per
build can be provisioned independently; see docs/operations/secrets.md.
*/}}
{{- define "packer-imaging.pkrvarsSecret" -}}
{{- printf "pkrvars-%s" .name -}}
{{- end }}
