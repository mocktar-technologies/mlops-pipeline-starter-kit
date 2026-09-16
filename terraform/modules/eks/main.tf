###############################################################################
# EKS cluster and node groups
#
# Three node groups, because ML workloads and platform workloads have different
# failure tolerances and very different prices:
#
#   system     small on-demand nodes for CoreDNS, the metrics stack, MLflow and
#              the controllers. Untainted, so anything without a node selector
#              lands here. Never scales to zero: the cluster is unusable without it.
#   inference  on-demand nodes for the serving Deployment. On-demand rather than
#              spot on purpose: a spot reclamation on a two-minute notice during
#              a traffic peak is a customer-visible latency event, and the saving
#              on a handful of small nodes does not justify it.
#   gpu        spot GPU nodes for training, min_size 0. Tainted, so nothing lands
#              here by accident. Training is interruptible and restartable, which
#              is exactly the workload spot is for, and GPU spot is where the real
#              money is saved: a reclaimed training job costs you a restart, and
#              running training on-demand can be several times the price.
#
# The taint on the GPU group is the single most valuable line in this file. Without
# it, the Kubernetes scheduler will place an ordinary CPU pod on a GPU node because
# it has free CPU and memory, and you pay GPU rates to run a sidecar. With it, only
# a pod that explicitly tolerates the taint can land there.
###############################################################################

locals {
  # nvidia.com/gpu is the resource name the NVIDIA device plugin advertises, and
  # using it as the taint key means a pod that requests a GPU and tolerates this
  # taint reads as one coherent statement.
  gpu_taint = {
    dedicated = {
      key    = "nvidia.com/gpu"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.25"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id = var.vpc_id
  # Two separate variables on purpose. The control plane ENIs go in the intra
  # subnets, which have no route to the internet; the nodes go in the private
  # subnets, which reach the internet through NAT. Passing the same list to both
  # works and gives the control plane an egress path it does not need.
  control_plane_subnet_ids = var.control_plane_subnet_ids
  subnet_ids               = var.node_subnet_ids

  # Private by default. A public endpoint is authenticated, so it is not a
  # catastrophe, but it is reachable from the internet and it is not needed once
  # CI assumes a role and connects from inside the VPC or through a bastion.
  endpoint_private_access      = true
  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  # api, not the config map. The aws-auth config map is the old mechanism, is
  # a single point of failure that people lock themselves out of by editing, and
  # cannot be managed with normal IAM. Access entries are IAM resources.
  authentication_mode = "API"

  # The identity running terraform becomes a cluster admin. Without this the
  # cluster is created and nobody can talk to it until an access entry is added
  # by hand, which is an awkward position to be in on a first apply.
  enable_cluster_creator_admin_permissions = true

  access_entries = var.access_entries

  # All five log types. Control plane logs are cheap relative to what they tell
  # you, and the authenticator log is the only way to answer "who did that" for
  # a cluster API action after the fact.
  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # Envelope encryption for Kubernetes secrets with a key you control. Without
  # it, secret data is encrypted with an AWS-owned key and you have no audit
  # trail on decryption and no ability to revoke.
  encryption_config = {
    provider_key_arn = var.kms_key_arn
    resources        = ["secrets"]
  }

  # IRSA. The module creates the OIDC provider, and its ARN is what every role
  # in modules/irsa trusts.
  enable_irsa = true

  addons = {
    # before_compute matters for these two. The CNI has to be configured before a
    # node joins, or the first nodes come up with the default CNI configuration
    # and have to be replaced.
    vpc-cni = {
      before_compute = true
      most_recent    = true
      configuration_values = jsonencode({
        env = {
          # Prefix delegation. Without it the number of pods per node is capped
          # by the number of ENIs the instance type supports, and on an ML
          # cluster you hit that ceiling long before you run out of CPU. With it,
          # a node gets /28 prefixes instead of individual addresses.
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    eks-pod-identity-agent = {
      before_compute = true
      most_recent    = true
    }
    coredns = {
      most_recent = true
      configuration_values = jsonencode({
        # Two replicas with anti-affinity. A single CoreDNS pod means every DNS
        # lookup in the cluster depends on one pod surviving a node drain.
        replicaCount = 2
      })
    }
    kube-proxy = {
      most_recent = true
    }
    # Needed by anything with a PersistentVolumeClaim: Prometheus, Grafana, and
    # MLflow's local scratch. Without a CSI driver those PVCs sit Pending
    # forever with no obvious cause.
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = var.ebs_csi_irsa_role_arn
    }
    # Surfaces kernel and container-runtime level node problems as Kubernetes
    # conditions. On GPU nodes this is how you find out that a driver has fallen
    # over, rather than inferring it from failing pods.
    eks-node-monitoring-agent = {
      most_recent = true
    }
    # The HorizontalPodAutoscaler reads pod CPU through the metrics API, and
    # nothing serves that API unless metrics-server is installed. Without it the
    # HPA reports "unknown" for its target and never scales, which is a quiet
    # failure: the Deployment looks healthy and simply never grows under load.
    #
    # AWS classifies this one as a community add-on rather than an AWS add-on,
    # meaning install support but not full support. That is the trade for not
    # maintaining another Helm release, and the fallback is the project's own
    # chart at https://kubernetes-sigs.github.io/metrics-server/.
    metrics-server = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.system_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = 2
      max_size     = 4
      desired_size = 2

      labels = {
        "workload" = "system"
      }

      # 50 GB with gp3. The default gp3 throughput and IOPS are enough for
      # platform components, and gp2 costs more for less.
      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            encrypted             = true
            kms_key_id            = var.kms_key_arn
            delete_on_termination = true
          }
        }
      }
    }

    inference = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.inference_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.inference_min_size
      max_size     = var.inference_max_size
      desired_size = var.inference_min_size

      labels = {
        "workload" = "inference"
      }

      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            encrypted             = true
            kms_key_id            = var.kms_key_arn
            delete_on_termination = true
          }
        }
      }
    }

    gpu = {
      # The NVIDIA variant of the AL2023 AMI ships the driver. It does not ship
      # the Kubernetes device plugin, and without that plugin the node never
      # advertises an nvidia.com/gpu resource and every GPU pod stays Pending
      # with no error that mentions GPUs. The plugin is installed by the
      # observability module's helm releases.
      ami_type       = "AL2023_x86_64_NVIDIA"
      instance_types = var.gpu_instance_types
      capacity_type  = "SPOT"

      # Zero, so an idle cluster costs nothing for GPU capacity. A training job
      # scales the group up; it scales back down when the job finishes.
      min_size     = 0
      max_size     = var.gpu_max_size
      desired_size = 0

      labels = {
        "workload"               = "training"
        "nvidia.com/gpu.present" = "true"
      }

      taints = local.gpu_taint

      # GPU images are large. 200 GB is not generous, it is the size at which a
      # CUDA base image plus a couple of model checkpoints stops filling the disk
      # and triggering kubelet image garbage collection mid-training.
      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.gpu_root_volume_size
            volume_type           = "gp3"
            iops                  = 4000
            throughput            = 250
            encrypted             = true
            kms_key_id            = var.kms_key_arn
            delete_on_termination = true
          }
        }
      }
    }
  }

  tags = var.tags
}
