terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.32"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
    }
  }
  backend "s3" {
    bucket         = "fiap-fase4-tfstate-004025521107"
    key            = "infra-k8s/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "fiap-fase4-tflock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" { state = "available" }

# ============================================================================
# VPC
# ============================================================================
resource "aws_vpc" "main" {
  cidr_block           = "10.30.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "fiap-fase4-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "fiap-fase4-igw" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name                                        = "fiap-fase4-public-${count.index}"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "fiap-fase4-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ============================================================================
# EKS
# ============================================================================
data "aws_iam_roles" "eks_cluster" { name_regex = "LabEksClusterRole.*" }
data "aws_iam_roles" "eks_node"    { name_regex = "LabEksNodeRole.*" }

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = "1.30"
  role_arn = tolist(data.aws_iam_roles.eks_cluster.arns)[0]

  vpc_config {
    subnet_ids              = aws_subnet.public[*].id
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  bootstrap_self_managed_addons = false

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-ng"
  node_role_arn   = tolist(data.aws_iam_roles.eks_node.arns)[0]
  subnet_ids      = aws_subnet.public[*].id
  instance_types  = ["t3.small"]

  scaling_config {
    desired_size = 2
    max_size     = 4
    min_size     = 2
  }
}

# ============================================================================
# Providers Kubernetes + Helm
# ============================================================================
data "aws_eks_cluster_auth" "main" {
  name = aws_eks_cluster.main.name
}

provider "kubernetes" {
  host                   = aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.main.token
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}

# ============================================================================
# NGINX Ingress (Helm — chart mainstream, sem IRSA)
# ============================================================================
resource "helm_release" "nginx_ingress" {
  depends_on       = [aws_eks_node_group.main]
  name             = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.11.3"

  values = [yamlencode({
    controller = {
      service = {
        type = "LoadBalancer"
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-type" = "nlb"
        }
      }
      admissionWebhooks = { enabled = false }
    }
  })]
}

# ============================================================================
# Namespaces
# ============================================================================
resource "kubernetes_namespace" "oficina" {
  depends_on = [aws_eks_node_group.main]
  metadata { name = "oficina" }
}

resource "kubernetes_namespace" "data" {
  depends_on = [aws_eks_node_group.main]
  metadata { name = "data" }
}

resource "kubernetes_namespace" "messaging" {
  depends_on = [aws_eks_node_group.main]
  metadata { name = "messaging" }
}

# ============================================================================
# MongoDB + RabbitMQ — aplicados via kubectl após cluster estar pronto
# (kubernetes_manifest do TF exige cluster existente em plan time)
# ============================================================================
resource "null_resource" "infra_manifests" {
  depends_on = [
    aws_eks_node_group.main,
    kubernetes_namespace.data,
    kubernetes_namespace.messaging,
    helm_release.nginx_ingress,
  ]

  triggers = {
    manifest_hash = filesha256("${path.module}/../k8s/infra-stack.yaml")
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig --name ${aws_eks_cluster.main.name} --region ${var.region} --kubeconfig /tmp/kubeconfig-fase4
      KUBECONFIG=/tmp/kubeconfig-fase4 kubectl apply -f ${path.module}/../k8s/infra-stack.yaml
    EOT
  }
}

# ============================================================================
# Outputs
# ============================================================================
output "cluster_name"     { value = aws_eks_cluster.main.name }
output "cluster_endpoint" { value = aws_eks_cluster.main.endpoint }
output "vpc_id"           { value = aws_vpc.main.id }
output "subnet_ids"       { value = aws_subnet.public[*].id }
