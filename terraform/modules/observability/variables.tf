variable "name" {
  description = "Platform name prefix, used in labels."
  type        = string
}

variable "cluster_name" {
  description = "Cluster name, attached to every metric as an external label so a series is attributable once you federate or remote-write."
  type        = string
}

variable "environment" {
  description = "Environment name, attached as an external label."
  type        = string
}

variable "namespace" {
  description = "Namespace for the monitoring stack. It gets its own namespace because the node exporter needs the privileged Pod Security profile, which no workload namespace should have."
  type        = string
  default     = "monitoring"
}

variable "kube_prometheus_stack_version" {
  description = "kube-prometheus-stack chart version. This chart installs the Prometheus Operator CRDs, so a major bump can require a CRD upgrade step; read the chart's upgrade notes before changing it."
  type        = string
  default     = "90.1.1"
}

variable "nvidia_device_plugin_version" {
  description = "NVIDIA k8s-device-plugin chart version. Must be at least as new as the driver in the node AMI."
  type        = string
  default     = "0.20.0"
}

variable "enable_gpu_device_plugin" {
  description = "Install the NVIDIA device plugin. Required on any cluster with GPU nodes: without it the node advertises no nvidia.com/gpu resource and every GPU pod stays Pending with a message that reads like a quota problem."
  type        = bool
  default     = true
}

variable "scrape_interval" {
  description = "Prometheus scrape interval. 30s is the right trade for a model serving path: fine enough to see a latency regression inside an SLO window, coarse enough that cardinality stays manageable."
  type        = string
  default     = "30s"
}

variable "prometheus_retention" {
  description = "How long Prometheus keeps samples locally. Two weeks answers 'what changed since the last deploy'. For anything longer, remote-write to a long-term store instead of growing this volume."
  type        = string
  default     = "15d"
}

variable "prometheus_retention_size" {
  description = "Size-based retention, which is the one that actually protects the volume. Set it below the volume size, because Prometheus needs headroom for compaction and a full volume is an unrecoverable Prometheus."
  type        = string
  default     = "40GB"
}

variable "prometheus_storage_size" {
  description = "Prometheus volume size. Keep it comfortably above prometheus_retention_size."
  type        = string
  default     = "50Gi"
}

variable "prometheus_memory_request" {
  description = "Prometheus memory request. Memory scales with active series, and an ML platform adds per-model-version series on every deploy."
  type        = string
  default     = "2Gi"
}

variable "prometheus_memory_limit" {
  description = "Prometheus memory limit. A limit is set on memory and deliberately not on CPU: CPU throttling during rule evaluation presents as missed scrapes, which look like target outages."
  type        = string
  default     = "4Gi"
}

variable "storage_class" {
  description = "Storage class for the Prometheus, Alertmanager and Grafana volumes. gp3 needs the EBS CSI driver, which the EKS module installs as an add-on."
  type        = string
  default     = "gp3"
}

variable "enable_grafana" {
  description = "Install Grafana. Turn it off if your organisation runs a central Grafana that reads this Prometheus as a data source."
  type        = bool
  default     = true
}

variable "grafana_admin_secret_name" {
  description = "Name of an existing Kubernetes Secret in the monitoring namespace holding admin-user and admin-password. Created out of band on purpose: a chart-generated password ends up in terraform state, and a literal ends up in git."
  type        = string
  default     = "grafana-admin"
}

variable "dashboard_directory" {
  description = "Local directory of dashboard JSON files to load. Every .json file becomes a ConfigMap the Grafana sidecar picks up."
  type        = string
}

variable "dashboard_folder" {
  description = "Grafana folder the dashboards are filed under."
  type        = string
  default     = "MLOps"
}

variable "drift_receiver_name" {
  description = "Alertmanager receiver for drift alerts. Drift is not a page: it needs a decision within a working day, and paging for it trains people to ignore the channel."
  type        = string
  default     = "drift-notifications"
}

variable "enable_retrain_webhook" {
  description = "Route a sustained critical drift alert to a webhook that opens a retraining run. The webhook only starts a pipeline; the promotion gate still decides whether the result ships and the GitHub environment still needs an approval."
  type        = bool
  default     = false
}

variable "retrain_webhook_secret_name" {
  description = "Name of the secret, mounted into Alertmanager, holding a file named url with the webhook target. Referenced as url_file rather than url so the token never enters terraform state or git."
  type        = string
  default     = "retrain-webhook"
}
