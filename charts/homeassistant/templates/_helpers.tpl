{{/* Expand the name of the chart. */}}
{{- define "homeassistant.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to
this (by the DNS naming spec). If release name contains chart name it will be
used as a full name.
*/}}
{{- define "homeassistant.fullname" -}}
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

{{/* Create chart name and version as used by the chart label. */}}
{{- define "homeassistant.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Common labels */}}
{{- define "homeassistant.labels" -}}
helm.sh/chart: {{ include "homeassistant.chart" . }}
{{ include "homeassistant.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Selector labels */}}
{{- define "homeassistant.selectorLabels" -}}
app.kubernetes.io/name: {{ include "homeassistant.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Create the name of the service account to use */}}
{{- define "homeassistant.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "homeassistant.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the ConfigMap mounted by the bootstrap init container at
/bootstrap-config. The chart renders <fullname>-bootstrap-config unless the
user provides an alternative via bootstrapConfig.existingConfigMap.
*/}}
{{- define "homeassistant.bootstrapConfigMapName" -}}
{{- if .Values.bootstrapConfig.existingConfigMap }}
{{- .Values.bootstrapConfig.existingConfigMap }}
{{- else }}
{{- printf "%s-bootstrap-config" (include "homeassistant.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Whether the pinned Home Assistant version supports the HTTP config store
(/config/.storage/http, store version 3, introduced with 2026.11.0). The
bootstrap init container seeds that store only when this is true: HA's
storage loader rejects store files newer than the running version supports
(UnsupportedStorageVersionError), which would break the http integration on
older versions. Non-semver tags ("latest", "stable") are assumed current.
*/}}
{{- define "homeassistant.httpStoreSeedEnabled" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion | toString -}}
{{- if regexMatch "^[0-9]+\\.[0-9]+\\.[0-9]+$" $tag -}}
{{- ternary "true" "false" (semverCompare ">= 2026.11.0" $tag) -}}
{{- else -}}
true
{{- end -}}
{{- end }}
