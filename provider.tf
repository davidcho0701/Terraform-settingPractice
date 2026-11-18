# =============================================================================
# provider.tf
# -----------------------------------------------------------------------------
# 이 파일이 하는 일
#   1) Terraform 및 사용할 Provider(aws / helm / kubernetes / random)의 버전을 고정
#   2) AWS Provider 설정 (도쿄 리전, MFA 임시 자격 증명 사용)
#   3) EKS 클러스터가 만들어진 뒤 그 안에 리소스(Helm 차트, StorageClass, PVC 등)를
#      배포할 수 있도록 helm / kubernetes Provider를 EKS에 연결
#
# 비용: 이 파일 자체는 비용이 발생하지 않습니다.
#
# [인증 관련 메모]
#   - AWS CLI에 MFA 임시 자격 증명(환경변수 AWS_ACCESS_KEY_ID/SECRET/SESSION_TOKEN
#     또는 named profile)을 이미 설정해 두었다면, Terraform도 같은 자격 증명을 그대로 씁니다.
#   - named profile을 쓴다면 terraform.tfvars 에 aws_profile = "내프로필" 을 지정하세요.
#   - 임시 자격 증명은 만료됩니다(보통 1~12시간). EKS apply는 20~25분 걸리므로
#     만료까지 충분히 남았는지 확인하고 시작하세요.
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # AWS 리소스(VPC, EKS, IAM, EFS 등)를 만드는 Provider
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95" # terraform-aws-modules eks v20 / vpc v5 와 호환되는 5.x 대
    }

    # 클러스터 안에 Helm 차트(kube-prometheus-stack)를 설치하는 Provider
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }

    # 클러스터 안에 StorageClass / PVC / Pod 같은 쿠버네티스 오브젝트를 만드는 Provider
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }

    # Grafana 관리자 비밀번호를 무작위로 생성하기 위한 Provider
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# -----------------------------------------------------------------------------
# AWS Provider
# -----------------------------------------------------------------------------
provider "aws" {
  region  = var.region
  profile = var.aws_profile # null 이면 기본 자격 증명 체인(환경변수 등)을 사용

  # 이 Terraform 코드로 만든 모든 AWS 리소스에 공통 태그를 자동으로 붙입니다.
  # -> 나중에 콘솔/Cost Explorer에서 "Project=eks-lab" 태그로 비용을 추적할 수 있습니다.
  default_tags {
    tags = {
      Project   = var.cluster_name
      ManagedBy = "terraform"
      Purpose   = "eks-learning-lab"
    }
  }
}

# -----------------------------------------------------------------------------
# helm / kubernetes Provider 를 EKS 에 연결
# -----------------------------------------------------------------------------
# 정적 토큰 대신 "aws eks get-token" 을 실행해 호출 시점마다 토큰을 새로 받습니다.
#  - 토큰이 15분마다 만료되기 때문에 장시간 apply 에서도 안전합니다.
#  - 로컬에 aws CLI 가 설치되어 있어야 합니다 (이미 사용 중이므로 OK).
locals {
  eks_exec_args = concat(
    ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region],
    var.aws_profile == null ? [] : ["--profile", var.aws_profile]
  )
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.eks_exec_args
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.eks_exec_args
    }
  }
}
