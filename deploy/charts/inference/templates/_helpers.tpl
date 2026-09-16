{{/*
Helpers.

The only interesting one is inference.modelVersion. Every metric this service
emits carries the model version as a label, and the label has to come from the
same place the container's MODEL_VERSION environment variable comes from, or a
dashboard joins on a value the service never emits.
*/}}

{{- define "inference.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "inference.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "inference.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "inference.labels" -}}
app.kubernetes.io/name: {{ include "inference.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: mlops-platform
{{- end -}}

{{- define "inference.selectorLabels" -}}
app.kubernetes.io/name: {{ include "inference.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "inference.driftSelectorLabels" -}}
app.kubernetes.io/name: {{ include "inference.name" . }}-drift
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Fails the render when the image is a bare tag with no digest and
requireDigestPinning is on. A mutable tag means the pod that restarts at 3 a.m.
can run different code from the pod you tested, and ECR tag immutability only
protects you inside one repository.
*/}}
{{- define "inference.image" -}}
{{- $image := printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- if .Values.image.digest -}}
{{- $image = printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else if .Values.image.requireDigestPinning -}}
{{- fail "image.digest is empty and image.requireDigestPinning is true. Set the digest, or set requireDigestPinning=false for a development install." -}}
{{- end -}}
{{- $image -}}
{{- end -}}

{{- define "inference.modelVersion" -}}
{{- required "model.version is required: every metric is labelled with it, and 'unknown' makes a regression unattributable" .Values.model.version | quote -}}
{{- end -}}
