output "namespace" {
  description = "Monitoring namespace."
  value       = kubernetes_namespace_v1.monitoring.metadata[0].name
}

output "prometheus_service" {
  description = "In-cluster Prometheus address. Useful for a port-forward and as a data source URL for an external Grafana."
  value       = "http://kube-prometheus-stack-prometheus.${kubernetes_namespace_v1.monitoring.metadata[0].name}.svc.cluster.local:9090"
}

output "alertmanager_service" {
  description = "In-cluster Alertmanager address."
  value       = "http://kube-prometheus-stack-alertmanager.${kubernetes_namespace_v1.monitoring.metadata[0].name}.svc.cluster.local:9093"
}

output "grafana_service" {
  description = "In-cluster Grafana address, or null when Grafana is disabled. Reach it with kubectl port-forward; it is a ClusterIP on purpose."
  value       = var.enable_grafana ? "http://kube-prometheus-stack-grafana.${kubernetes_namespace_v1.monitoring.metadata[0].name}.svc.cluster.local:80" : null
}

output "loaded_dashboards" {
  description = "Dashboard names loaded from the dashboard directory. An empty list here means the directory was empty or the path was wrong, and Grafana will come up with no MLOps folder."
  value       = keys(local.dashboards)
}

output "stack_version" {
  description = "kube-prometheus-stack chart version applied, recorded so the runbook can state what is running."
  value       = helm_release.kube_prometheus_stack.version
}
