{{/*
Expand the name of the chart.
*/}}
{{- define "ceph-jenkins.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "ceph-jenkins.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "ceph-jenkins.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "ceph-jenkins.labels" -}}
helm.sh/chart: {{ include "ceph-jenkins.chart" . }}
{{ include "ceph-jenkins.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "ceph-jenkins.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ceph-jenkins.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name
*/}}
{{- define "ceph-jenkins.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "ceph-jenkins.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Properties Secret name
*/}}
{{- define "ceph-jenkins.propertiesSecretName" -}}
{{- if .Values.propertiesExistingSecret }}
{{- .Values.propertiesExistingSecret }}
{{- else }}
{{- printf "%s-properties" (include "ceph-jenkins.fullname" .) }}
{{- end }}
{{- end }}
