###############################################################################
# Observability
#
# kube-prometheus-stack, the NVIDIA device plugin, and the platform's own Grafana
# dashboards. Three notes that matter more than the Helm values:
#
# 1. The Prometheus Operator's CRDs are installed by this chart. That means the
#    ServiceMonitor and PrometheusRule objects the inference chart creates cannot
#    exist until this release has been applied. The dependency is real and runs
#    the other way from how people usually order their applies, so the inference
#    chart is deployed after this module, not alongside it.
#
# 2. serviceMonitorSelectorNilUsesHelmValues is set to false. Left at its default
#    of true, Prometheus only discovers ServiceMonitors carrying this release's own
#    label, and a ServiceMonitor you create from a different chart is silently
#    ignored. Nothing errors. The target simply never appears, the dashboard panel
#    is empty, and the alert never fires because its query returns no series. This
#    single value is the most common reason a team believes their model metrics are
#    being collected when they are not.
#
# 3. The NVIDIA device plugin is not optional on a cluster with GPU nodes. The
#    AL2023 NVIDIA AMI ships the driver, but until the device plugin runs, the node
#    advertises no nvidia.com/gpu resource and every GPU pod stays Pending with an
#    "Insufficient nvidia.com/gpu" message that reads like a quota problem.
###############################################################################

locals {
  labels = {
    "app.kubernetes.io/part-of"    = var.name
    "app.kubernetes.io/managed-by" = "terraform"
  }

  # Read from disk rather than inlined, so the dashboards are ordinary JSON files
  # that can be edited in Grafana, exported, and committed back.
  dashboards = {
    for file in fileset(var.dashboard_directory, "*.json") :
    replace(file, ".json", "") => file(abspath("${var.dashboard_directory}/${file}"))
  }
}

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = var.namespace
    labels = merge(local.labels, {
      # The Prometheus node exporter needs host networking and the host PID
      # namespace, which the restricted profile forbids. privileged is required
      # here and is the reason monitoring gets its own namespace rather than
      # sharing one with a workload.
      "pod-security.kubernetes.io/enforce" = "privileged"
    })
  }
}

###############################################################################
# kube-prometheus-stack
###############################################################################

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_version

  # A chart that half-applies leaves CRDs present and the operator absent, which
  # is the worst state to debug. atomic rolls the whole release back on failure.
  atomic          = true
  cleanup_on_fail = true
  timeout         = 900

  values = [yamlencode({
    crds = {
      # The chart installs and upgrades the CRDs. The alternative, installing
      # prometheus-operator-crds separately, decouples their lifecycle at the cost
      # of a second release to keep in step; for one cluster this is simpler.
      enabled = true
    }

    prometheus = {
      prometheusSpec = {
        retention     = var.prometheus_retention
        retentionSize = var.prometheus_retention_size

        # The three selector lines that make cross-chart discovery work. Without
        # them Prometheus ignores every ServiceMonitor, PodMonitor and
        # PrometheusRule that this Helm release did not create, with no error.
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false
        probeSelectorNilUsesHelmValues          = false

        # Watch every namespace. An empty list means all; naming namespaces here
        # is a trap, because the next namespace someone creates is invisible.
        serviceMonitorNamespaceSelector = {}
        podMonitorNamespaceSelector     = {}
        ruleNamespaceSelector           = {}

        scrapeInterval = var.scrape_interval
        # The evaluation interval has to be at least the scrape interval, or a
        # rule evaluates against a window that has not been refreshed and produces
        # flapping alerts.
        evaluationInterval = var.scrape_interval

        # external_labels, so a metric from this cluster is attributable once you
        # federate or remote-write to a second location.
        externalLabels = {
          cluster     = var.cluster_name
          environment = var.environment
        }

        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = var.storage_class
              accessModes      = ["ReadWriteOnce"]
              resources = {
                requests = {
                  storage = var.prometheus_storage_size
                }
              }
            }
          }
        }

        resources = {
          requests = {
            cpu    = "500m"
            memory = var.prometheus_memory_request
          }
          limits = {
            # Memory limited, CPU not. Prometheus is bursty at rule evaluation and
            # compaction; a CPU limit turns those bursts into throttling that
            # shows up as missed scrapes, which look like target outages.
            memory = var.prometheus_memory_limit
          }
        }

        nodeSelector = { workload = "system" }

        # The GPU node group is tainted, and without a toleration the node
        # exporter cannot run there. A GPU node with no node exporter is invisible
        # in the infrastructure layer, which is the node you most want to see.
        securityContext = {
          runAsNonRoot = true
          runAsUser    = 1000
          fsGroup      = 2000
        }
      }
    }

    alertmanager = {
      alertmanagerSpec = {
        retention    = "120h"
        nodeSelector = { workload = "system" }
        storage = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = var.storage_class
              accessModes      = ["ReadWriteOnce"]
              resources        = { requests = { storage = "10Gi" } }
            }
          }
        }
      }

      config = {
        global = {
          resolve_timeout = "5m"
        }

        # Grouping and inhibition, not one route per alert. Without grouping, a
        # node failure that trips twelve rules sends twelve notifications and the
        # one that matters is the eleventh.
        route = {
          group_by        = ["alertname", "namespace", "severity"]
          group_wait      = "30s"
          group_interval  = "5m"
          repeat_interval = "12h"
          receiver        = "default"

          routes = concat(
            [
              {
                # Drift is not a page. It is a condition that needs a decision
                # within a working day, and waking someone for it trains them to
                # ignore the channel.
                matchers        = ["alertname=~\"ModelDrift.*\""]
                receiver        = var.drift_receiver_name
                group_wait      = "2m"
                repeat_interval = "24h"
              },
            ],
            var.enable_retrain_webhook ? [
              {
                # The automation path. A sustained drift alert opens a retrain
                # workflow; it does not deploy anything, because the promotion gate
                # still has to pass and a human still approves the environment.
                matchers        = ["alertname=\"ModelDriftCritical\""]
                receiver        = "retrain-webhook"
                group_wait      = "5m"
                repeat_interval = "24h"
                continue        = true
              },
            ] : [],
          )
        }

        inhibit_rules = [
          {
            # If the model is not loaded, its latency and error rules will also
            # fire. Suppressing the consequences keeps the cause at the top of the
            # notification.
            source_matchers = ["alertname=\"InferenceModelNotLoaded\""]
            target_matchers = ["alertname=~\"Inference(HighErrorRate|LatencyHigh)\""]
            equal           = ["namespace", "service"]
          },
          {
            source_matchers = ["severity=\"critical\""]
            target_matchers = ["severity=\"warning\""]
            equal           = ["alertname", "namespace"]
          },
        ]

        receivers = concat(
          [
            { name = "default" },
            { name = var.drift_receiver_name },
          ],
          var.enable_retrain_webhook ? [
            {
              name = "retrain-webhook"
              webhook_configs = [
                {
                  # The URL carries a token, so it is referenced from a file that
                  # the External Secrets operator or your secret tooling writes.
                  # It is never a literal here, because a literal would land in
                  # terraform state and in git.
                  url_file      = "/etc/alertmanager/secrets/${var.retrain_webhook_secret_name}/url"
                  send_resolved = false
                  max_alerts    = 1
                },
              ]
            },
          ] : [],
        )
      }
    }

    grafana = {
      enabled = var.enable_grafana

      # No hardcoded password and no chart-generated one in state. The chart reads
      # the admin credentials from a secret you create out of band; the runbook
      # documents retrieving it.
      admin = {
        existingSecret = var.grafana_admin_secret_name
        userKey        = "admin-user"
        passwordKey    = "admin-password"
      }

      nodeSelector = { workload = "system" }

      # ClusterIP. Grafana is reached with kubectl port-forward or through your
      # organisation's ingress and identity proxy, never by a LoadBalancer Service
      # that puts an unauthenticated dashboard on the internet.
      service = {
        type = "ClusterIP"
      }

      persistence = {
        enabled          = true
        storageClassName = var.storage_class
        size             = "10Gi"
      }

      sidecar = {
        dashboards = {
          enabled = true
          # The label the sidecar looks for on a ConfigMap. The dashboards created
          # below carry it.
          label      = "grafana_dashboard"
          labelValue = "1"
          # Scan every namespace, so a team can ship a dashboard with their own
          # chart instead of editing this module.
          searchNamespace  = "ALL"
          folderAnnotation = "grafana_folder"
          provider = {
            foldersFromFilesStructure = true
          }
        }
        datasources = {
          enabled = true
        }
      }

      "grafana.ini" = {
        analytics = {
          reporting_enabled = false
          check_for_updates = false
        }
        users = {
          # No anonymous access and no self-signup. The defaults are already safe;
          # stating them means a future chart default change cannot loosen it.
          allow_sign_up = false
        }
        auth = {
          disable_login_form = false
        }
      }
    }

    # kube-state-metrics is what turns Kubernetes object state into metrics:
    # replica counts, pod phases, container restarts. The infrastructure layer of
    # the dashboards depends on it entirely.
    kube-state-metrics = {
      nodeSelector = { workload = "system" }
      metricLabelsAllowlist = [
        # Surface the workload label so a panel can split by node group. Left off,
        # every pod metric is unattributable to a node group.
        "pods=[app.kubernetes.io/name,app.kubernetes.io/component,model_version]",
      ]
    }

    prometheus-node-exporter = {
      # Tolerate everything. The node exporter has to run on every node including
      # the tainted GPU group, or your most expensive nodes are the ones you
      # cannot see.
      tolerations = [{ operator = "Exists" }]
    }

    prometheusOperator = {
      nodeSelector = { workload = "system" }
    }

    # These two ship rules and dashboards for control plane components that a
    # managed EKS control plane does not expose. Left enabled they produce alerts
    # that can never clear and dashboards that are permanently empty, which
    # trains everyone to ignore red panels.
    kubeControllerManager = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeEtcd              = { enabled = false }
    kubeProxy             = { enabled = false }
  })]

  depends_on = [kubernetes_namespace_v1.monitoring]
}

###############################################################################
# NVIDIA device plugin
###############################################################################

resource "helm_release" "nvidia_device_plugin" {
  count = var.enable_gpu_device_plugin ? 1 : 0

  name       = "nvidia-device-plugin"
  namespace  = "kube-system"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  version    = var.nvidia_device_plugin_version

  atomic          = true
  cleanup_on_fail = true
  timeout         = 600

  values = [yamlencode({
    # Only on GPU nodes. Without the selector the DaemonSet schedules a pod onto
    # every node in the cluster, where it crash-loops for want of a driver.
    nodeSelector = {
      "nvidia.com/gpu.present" = "true"
    }

    tolerations = [
      {
        key      = "nvidia.com/gpu"
        operator = "Exists"
        effect   = "NoSchedule"
      },
    ]

    # Expose the plugin's own metrics so the GPU layer of the dashboard has a
    # source. Without this the only GPU signal available is node CPU, which tells
    # you nothing about utilisation of the part you are paying for.
    gfd = {
      enabled = true
    }
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}

###############################################################################
# Dashboards
###############################################################################

resource "kubernetes_config_map_v1" "dashboards" {
  for_each = local.dashboards

  metadata {
    name      = "grafana-dashboard-${each.key}"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name

    labels = merge(local.labels, {
      # The label the Grafana sidecar watches. A dashboard ConfigMap without it is
      # never loaded and the omission produces no error anywhere.
      grafana_dashboard = "1"
    })

    annotations = {
      grafana_folder = var.dashboard_folder
    }
  }

  data = {
    "${each.key}.json" = each.value
  }

  depends_on = [helm_release.kube_prometheus_stack]
}
