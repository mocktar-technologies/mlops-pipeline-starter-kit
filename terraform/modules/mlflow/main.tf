###############################################################################
# MLflow tracking server
#
# Three pieces, and the split between them is the design:
#
#   RDS PostgreSQL   the backend store: runs, params, metrics, the model registry
#                    and its aliases. This is the database whose loss costs you
#                    your experiment history and your record of which model
#                    version is champion.
#   S3 prefix        the artifact store: the ONNX files themselves. Large, cheap,
#                    already versioned and encrypted by the artifacts module.
#   Deployment       the server. Stateless. Kill it, and you lose nothing.
#
# Running MLflow with the default SQLite backend is the mistake this module exists
# to prevent. SQLite works until two pipeline runs register a model at the same
# moment, at which point one of them fails with a database lock error, and it
# offers no backup you can restore from.
#
# The server is reachable only inside the cluster and, when enabled, through an
# internal load balancer. It is never exposed to the internet: MLflow has no
# authentication in its open source form, so network reachability is the whole
# access control story.
###############################################################################

locals {
  namespace = var.namespace
  labels = {
    "app.kubernetes.io/name"       = "mlflow"
    "app.kubernetes.io/component"  = "tracking-server"
    "app.kubernetes.io/part-of"    = var.name
    "app.kubernetes.io/managed-by" = "terraform"
  }
  tracking_uri = "http://mlflow.${var.namespace}.svc.cluster.local:${var.service_port}"
}

###############################################################################
# Database
###############################################################################

resource "aws_db_subnet_group" "mlflow" {
  name_prefix = "${var.name}-mlflow-"
  subnet_ids  = var.private_subnet_ids
  description = "Private subnets for the MLflow backend store"

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "database" {
  name_prefix = "${var.name}-mlflow-db-"
  description = "MLflow backend store, reachable only from the cluster nodes"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-mlflow-db" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "database_from_nodes" {
  security_group_id = aws_security_group.database.id
  description       = "PostgreSQL from the EKS node security group"

  # Source is a security group, not a CIDR. The pod's traffic leaves through a
  # node, so the node security group is the correct source, and referencing it by
  # id means this rule keeps working when subnets change.
  referenced_security_group_id = var.node_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"

  tags = var.tags
}

resource "aws_db_parameter_group" "mlflow" {
  name_prefix = "${var.name}-mlflow-"
  family      = var.db_parameter_group_family
  description = "MLflow backend store parameters"

  parameter {
    # Refuse any connection that is not using TLS. The default allows plaintext,
    # and a plaintext connection carries the registry contents across the VPC in
    # the clear.
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    # Log any statement slower than a second. MLflow's run search queries degrade
    # as the experiment table grows, and this is how you find out before the UI
    # becomes unusable.
    name         = "log_min_duration_statement"
    value        = "1000"
    apply_method = "immediate"
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "mlflow" {
  identifier_prefix = "${var.name}-mlflow-"

  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  # gp3 rather than gp2: more baseline throughput for the same money, and IOPS
  # that do not scale with volume size, so a small database is not slow.
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  db_name  = "mlflow"
  username = "mlflow"

  # No password in Terraform and none in state. RDS generates it, stores it in
  # Secrets Manager, and rotates it. The provider documentation is explicit that
  # password cannot be set at the same time as this, so it does not appear here
  # at all, not even commented out.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  db_subnet_group_name   = aws_db_subnet_group.mlflow.name
  vpc_security_group_ids = [aws_security_group.database.id]
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.mlflow.name

  multi_az = var.db_multi_az

  backup_retention_period  = var.db_backup_retention_days
  backup_window            = "03:00-04:00"
  maintenance_window       = "sun:04:30-sun:05:30"
  copy_tags_to_snapshot    = true
  delete_automated_backups = false

  # Both of these are the difference between losing your model registry and not.
  # deletion_protection stops a terraform destroy from taking the database with
  # it; skip_final_snapshot = false means even a deliberate destroy leaves a
  # restorable snapshot behind.
  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name}-mlflow-final"

  # IAM authentication is enabled but not used by the server, which authenticates
  # with the managed password. It is here so an operator can connect with their
  # own IAM identity for a query without being handed the master password.
  iam_database_authentication_enabled = true

  performance_insights_enabled          = var.db_performance_insights
  performance_insights_retention_period = var.db_performance_insights ? 7 : null
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  auto_minor_version_upgrade = true
  apply_immediately          = false

  tags = merge(var.tags, { Name = "${var.name}-mlflow" })

  lifecycle {
    # The engine version moves under you with auto minor upgrades enabled, and a
    # plan that wants to move it back is a plan that reboots your registry
    # database for no reason.
    ignore_changes = [engine_version]
  }
}

###############################################################################
# Kubernetes
###############################################################################

resource "kubernetes_namespace_v1" "mlflow" {
  metadata {
    name = local.namespace

    labels = merge(local.labels, {
      # Pod Security Admission. enforce=restricted is the strictest built-in
      # profile: no privilege escalation, no root, a seccomp profile required,
      # all capabilities dropped. Setting it at the namespace means a future
      # manifest cannot quietly opt out.
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    })
  }
}

resource "kubernetes_service_account_v1" "mlflow" {
  metadata {
    name        = var.service_account_name
    namespace   = kubernetes_namespace_v1.mlflow.metadata[0].name
    labels      = local.labels
    annotations = { "eks.amazonaws.com/role-arn" = var.irsa_role_arn }
  }

  # The server reads its S3 credentials from the projected IRSA token, not from a
  # long-lived secret, so no token secret is needed or wanted here.
  automount_service_account_token = true
}

# The database credentials reach the pod from Secrets Manager rather than from a
# Kubernetes Secret this module writes, so the password is never in Terraform
# state, never in a manifest and never in git. The init container resolves it at
# start time with the pod's own IRSA identity.
resource "kubernetes_config_map_v1" "mlflow" {
  metadata {
    name      = "mlflow-config"
    namespace = kubernetes_namespace_v1.mlflow.metadata[0].name
    labels    = local.labels
  }

  data = {
    DB_SECRET_ARN        = aws_db_instance.mlflow.master_user_secret[0].secret_arn
    DB_HOST              = aws_db_instance.mlflow.address
    DB_PORT              = tostring(aws_db_instance.mlflow.port)
    DB_NAME              = aws_db_instance.mlflow.db_name
    MLFLOW_ARTIFACT_ROOT = "s3://${var.artifact_bucket}/${var.artifact_prefix}"
    MLFLOW_PORT          = tostring(var.service_port)
    AWS_REGION           = var.region
    AWS_DEFAULT_REGION   = var.region
    MLFLOW_S3_UPLOAD_EXTRA_ARGS = jsonencode({
      # Every artifact the server writes is encrypted with the platform key, which
      # is what keeps the bucket policy's DenyWrongEncryptionKey statement from
      # rejecting the upload.
      ServerSideEncryption = "aws:kms"
      SSEKMSKeyId          = var.kms_key_arn
    })
  }
}

resource "kubernetes_deployment_v1" "mlflow" {
  metadata {
    name      = "mlflow"
    namespace = kubernetes_namespace_v1.mlflow.metadata[0].name
    labels    = local.labels
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = { "app.kubernetes.io/name" = "mlflow" }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = 1
        max_unavailable = 0
      }
    }

    template {
      metadata {
        labels = local.labels
        annotations = {
          # Rolls the pods when the config map changes. Without this a changed
          # database endpoint leaves the old pods running against the old value
          # until something else happens to restart them.
          "checksum/config" = sha256(jsonencode(kubernetes_config_map_v1.mlflow.data))
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.mlflow.metadata[0].name

        security_context {
          run_as_non_root = true
          run_as_user     = 10001
          run_as_group    = 10001
          fs_group        = 10001
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        node_selector = { "workload" = "system" }

        # Waits for the database to accept connections and runs the schema
        # migration once, before any server replica starts. Running `mlflow db
        # upgrade` from the server's own entrypoint means N replicas race to
        # migrate the same schema on every rollout.
        init_container {
          name              = "db-upgrade"
          image             = var.image
          image_pull_policy = "IfNotPresent"
          command           = ["/bin/sh", "-c"]
          args = [<<-SHELL
            set -eu
            echo "resolving database credentials from secrets manager"
            SECRET=$(aws secretsmanager get-secret-value \
              --secret-id "$DB_SECRET_ARN" \
              --query SecretString --output text)
            DB_USER=$(printf '%s' "$SECRET" | python -c 'import json,sys; print(json.load(sys.stdin)["username"])')
            DB_PASS=$(printf '%s' "$SECRET" | python -c 'import json,sys; print(json.load(sys.stdin)["password"])')
            unset SECRET
            # sslmode=require, matching rds.force_ssl on the parameter group. The
            # default for libpq is prefer, which silently falls back to plaintext.
            export MLFLOW_BACKEND="postgresql://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME?sslmode=require"
            echo "running schema migration"
            mlflow db upgrade "$MLFLOW_BACKEND"
            echo "migration complete"
          SHELL
          ]

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.mlflow.metadata[0].name
            }
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = 10001
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { memory = "512Mi" }
          }
        }

        container {
          name              = "mlflow"
          image             = var.image
          image_pull_policy = "IfNotPresent"
          command           = ["/bin/sh", "-c"]
          args = [<<-SHELL
            set -eu
            SECRET=$(aws secretsmanager get-secret-value \
              --secret-id "$DB_SECRET_ARN" \
              --query SecretString --output text)
            DB_USER=$(printf '%s' "$SECRET" | python -c 'import json,sys; print(json.load(sys.stdin)["username"])')
            DB_PASS=$(printf '%s' "$SECRET" | python -c 'import json,sys; print(json.load(sys.stdin)["password"])')
            unset SECRET
            exec mlflow server \
              --backend-store-uri "postgresql://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME?sslmode=require" \
              --artifacts-destination "$MLFLOW_ARTIFACT_ROOT" \
              --serve-artifacts \
              --host 0.0.0.0 \
              --port "$MLFLOW_PORT" \
              --workers ${var.gunicorn_workers}
          SHELL
          ]

          # --serve-artifacts proxies artifact reads and writes through the server,
          # so only this pod's IRSA role needs S3 access. Clients talk to MLflow
          # and never to the bucket, which means a pipeline running outside the
          # cluster needs no bucket permissions of its own.

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.mlflow.metadata[0].name
            }
          }

          port {
            name           = "http"
            container_port = var.service_port
            protocol       = "TCP"
          }

          # The health endpoint answers without touching the database, so a
          # liveness probe on it will not restart every replica during a brief
          # database failover. Readiness uses the same path; a database outage
          # shows up as failing requests and in the RDS alarms, not as a restart
          # loop that destroys the evidence.
          liveness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            initial_delay_seconds = 30
            period_seconds        = 15
            timeout_seconds       = 5
            failure_threshold     = 4
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 3
            failure_threshold     = 3
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = 10001
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          resources {
            requests = {
              cpu    = var.resources.cpu_request
              memory = var.resources.memory_request
            }
            limits = {
              # No CPU limit, deliberately. A CPU limit on a gunicorn server
              # produces throttling that looks exactly like a slow database, and
              # the request already guarantees the share it needs. Memory is
              # limited, because a memory limit is the only thing that stops one
              # large artifact upload from evicting a neighbour.
              memory = var.resources.memory_limit
            }
          }
        }

        # read_only_root_filesystem is on, so anything that writes needs an
        # explicit volume. gunicorn and boto3 both write to /tmp.
        volume {
          name = "tmp"
          empty_dir {
            medium     = "Memory"
            size_limit = "512Mi"
          }
        }
      }
    }
  }

  timeouts {
    create = "10m"
    update = "10m"
  }
}

resource "kubernetes_service_v1" "mlflow" {
  metadata {
    name      = "mlflow"
    namespace = kubernetes_namespace_v1.mlflow.metadata[0].name
    labels    = local.labels
  }

  spec {
    type     = "ClusterIP"
    selector = { "app.kubernetes.io/name" = "mlflow" }

    port {
      name        = "http"
      port        = var.service_port
      target_port = "http"
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "mlflow" {
  count = var.replicas > 1 ? 1 : 0

  metadata {
    name      = "mlflow"
    namespace = kubernetes_namespace_v1.mlflow.metadata[0].name
    labels    = local.labels
  }

  spec {
    min_available = 1
    selector {
      match_labels = { "app.kubernetes.io/name" = "mlflow" }
    }
  }
}

# Default deny, then two explicit allowances. Without a default-deny policy the
# MLflow pod can reach every other pod in the cluster, and every pod can reach it.
resource "kubernetes_network_policy_v1" "default_deny" {
  metadata {
    name      = "default-deny"
    namespace = kubernetes_namespace_v1.mlflow.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy_v1" "mlflow" {
  metadata {
    name      = "mlflow"
    namespace = kubernetes_namespace_v1.mlflow.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "mlflow" }
    }

    policy_types = ["Ingress", "Egress"]

    ingress {
      ports {
        port     = var.service_port
        protocol = "TCP"
      }

      dynamic "from" {
        for_each = var.allowed_client_namespaces
        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = from.value }
          }
        }
      }
    }

    egress {
      # DNS. Omitting this is the classic mistake: every other rule looks correct
      # and nothing works, because the pod cannot resolve a hostname.
      ports {
        port     = 53
        protocol = "UDP"
      }
      ports {
        port     = 53
        protocol = "TCP"
      }
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
      }
    }

    egress {
      # PostgreSQL, S3, Secrets Manager and STS. All of those are outside the
      # cluster, and a Kubernetes NetworkPolicy cannot name an AWS service, so
      # the destination is expressed as the ports rather than the addresses. The
      # security group on the database is what actually restricts the PostgreSQL
      # destination.
      ports {
        port     = 443
        protocol = "TCP"
      }
      ports {
        port     = 5432
        protocol = "TCP"
      }
      to {
        ip_block {
          cidr = "0.0.0.0/0"
          except = [
            # Keep the pod from reaching the instance metadata service. With IRSA
            # it has no reason to, and blocking it removes the node role as an
            # escalation path.
            "169.254.169.254/32",
          ]
        }
      }
    }
  }
}
