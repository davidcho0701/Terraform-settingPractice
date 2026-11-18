# =============================================================================
# eks.tf
# -----------------------------------------------------------------------------
# 이 파일이 하는 일
#   1) EKS 컨트롤플레인(클러스터) 생성
#   2) 클러스터 IAM 역할 / 노드 IAM 역할 생성 (공식 모듈이 자동 생성)
#   3) 보안 그룹 분리 생성: 클러스터용 SG / 노드용 SG (공식 모듈이 자동 생성)
#   4) 관리형 노드 그룹 (t3.medium, 1~2대)
#   5) 필수 add-on: VPC CNI / CoreDNS / kube-proxy
#   6) IRSA(OIDC) 설정 + EBS CSI / EFS CSI 용 IAM 역할
#      (CSI 드라이버 add-on 설치 자체는 storage.tf 에 있습니다)
#
# 💰 비용 발생 리소스
#   - EKS 클러스터(컨트롤플레인): 시간당 약 $0.10  (~ $73/월)  <- 켜져 있는 동안 계속 과금
#   - EC2 워커 노드: t3.medium 약 $0.054/시간 x 노드 수
#   - 노드 루트 EBS gp3: 20GiB 약 $1.9/월 x 노드 수
#   * IAM 역할/정책, OIDC Provider, 보안 그룹, add-on(기본 설정)은 무료
#
# [비용 절감을 위해 일부러 끈 것들]
#   - 컨트롤플레인 로깅(CloudWatch Logs): 로그 저장/수집 비용이 생기므로 비활성화
#   - Secrets KMS 암호화용 CMK: 키 1개당 월 $1 이라 비활성화 (실습용이므로)
#     -> 운영 환경에서는 둘 다 켜는 것이 권장됩니다.
# =============================================================================

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  # ---------------------------------------------------------------------------
  # 네트워크 배치
  # ---------------------------------------------------------------------------
  vpc_id = module.vpc.vpc_id

  # 워커 노드가 들어갈 서브넷 = 프라이빗 서브넷 (인터넷에서 직접 접근 불가, NAT 로만 외부 통신)
  subnet_ids = module.vpc.private_subnets

  # [ENI 관련] EKS 는 컨트롤플레인(AWS 소유 VPC)과 우리 VPC 를 잇기 위해
  # 여기 지정한 서브넷에 "EKS 관리형 ENI(네트워크 인터페이스)"를 만듭니다.
  # kubectl exec/logs, 웹훅 호출이 이 ENI 를 통해 노드로 전달됩니다.
  # (ENI 는 EKS 가 자동 생성/관리하며 별도 요금 없음 - 클러스터 삭제 시 함께 정리됨)
  control_plane_subnet_ids = module.vpc.private_subnets

  # ---------------------------------------------------------------------------
  # API 서버 엔드포인트
  # ---------------------------------------------------------------------------
  # public  = true : 내 PC 의 kubectl / Terraform(helm, kubernetes provider)이 접속하기 위해 필요
  # private = true : 노드 -> API 서버 통신을 VPC 내부로 처리 (NAT 데이터 요금 절감 + 보안)
  cluster_endpoint_public_access       = true
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  # ---------------------------------------------------------------------------
  # 접근 권한: 이 Terraform 을 실행한 IAM 주체에게 클러스터 관리자 권한 부여
  # ---------------------------------------------------------------------------
  # 이게 없으면 클러스터를 만든 본인조차 kubectl 로 못 들어가고,
  # helm/kubernetes provider 도 "Unauthorized" 로 실패합니다.
  # (MFA 로 assume 한 세션이어도 모듈이 원래 IAM 주체를 찾아서 등록해 줍니다)
  enable_cluster_creator_admin_permissions = true

  # ---------------------------------------------------------------------------
  # IRSA (IAM Roles for Service Accounts) 활성화
  # ---------------------------------------------------------------------------
  # 클러스터의 OIDC 발급자를 IAM 에 "신뢰할 수 있는 ID 공급자"로 등록합니다.
  # 이렇게 하면 파드(서비스어카운트)가 노드 전체 권한이 아니라
  # "자기 전용 IAM 역할"만 쓸 수 있습니다 -> 최소 권한 원칙.
  # 아래 EBS/EFS CSI 드라이버가 이 방식으로 AWS API(볼륨 생성 등)를 호출합니다.
  enable_irsa = true

  # ---- 비용 절감: 로그/KMS 비활성화 ----
  cluster_enabled_log_types   = []
  create_cloudwatch_log_group = false
  create_kms_key              = false
  cluster_encryption_config   = {}

  # ---------------------------------------------------------------------------
  # 필수 add-on (EKS 가 관리해 주는 클러스터 구성요소)
  # ---------------------------------------------------------------------------
  cluster_addons = {
    # VPC CNI: 파드에 "VPC 의 실제 IP"를 붙여 주는 네트워크 플러그인.
    #   - 노드의 ENI 에 보조 IP 를 여러 개 달아 파드에 하나씩 배정합니다.
    #   - t3.medium = ENI 3개 x (IP 6개 - 1) + 2 = 최대 파드 17개  <- 노드 크기를 정한 근거
    #   - before_compute = true : 노드가 뜨기 전에 먼저 설치해야 노드가 Ready 가 됩니다.
    vpc-cni = {
      most_recent    = true
      before_compute = true
      # (참고) 파드 밀도를 늘리고 싶다면 prefix delegation 을 켤 수 있지만
      #  관리형 노드 그룹의 max-pods 도 함께 조정해야 해서 실습 범위에서는 생략합니다.
    }

    # kube-proxy: 서비스(ClusterIP/NodePort) 트래픽을 파드로 전달하는 iptables 규칙 관리
    kube-proxy = {
      most_recent = true
    }

    # CoreDNS: 클러스터 내부 DNS (my-svc.default.svc.cluster.local). 노드가 있어야 뜨므로
    # 모듈이 노드 그룹 생성 이후에 설치합니다.
    coredns = {
      most_recent = true
    }
  }

  # ---------------------------------------------------------------------------
  # 관리형 노드 그룹
  # ---------------------------------------------------------------------------
  # "관리형"이란: 노드 AMI 업데이트/드레인/오토스케일링 그룹 구성을 EKS 가 대신 해 주는 방식.
  # 노드 IAM 역할은 모듈이 자동 생성하며 아래 AWS 관리형 정책이 붙습니다.
  #   - AmazonEKSWorkerNodePolicy           : 노드가 클러스터에 조인/통신
  #   - AmazonEKS_CNI_Policy                : VPC CNI 가 ENI/IP 관리
  #   - AmazonEC2ContainerRegistryReadOnly  : ECR 에서 이미지 pull
  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD" # Amazon Linux 2023 (AL2 는 최신 EKS 에서 지원 종료)
      instance_types = [var.node_instance_type]
      capacity_type  = var.node_capacity_type # 💰 SPOT 으로 바꾸면 크게 절감

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # 루트 볼륨: 작은 gp3 + 암호화(AWS 관리형 키 사용 -> 추가 비용 없음)
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.node_disk_size_gb
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true # 노드 종료 시 볼륨도 삭제 -> 비용 누수 방지
          }
        }
      }
    }
  }

  # ---------------------------------------------------------------------------
  # 보안 그룹 (클러스터용 / 노드용 분리)  -  모듈이 둘 다 자동 생성합니다.
  # ---------------------------------------------------------------------------
  # [클러스터 SG] 컨트롤플레인 ENI 에 붙는 SG.
  #   - 인바운드: 노드 SG -> 443 (노드의 kubelet 이 API 서버 호출)
  # [노드 SG] 워커 노드(EC2 + 파드 ENI)에 붙는 SG.
  #   - 인바운드: 클러스터 SG -> 10250(kubelet), 웹훅 포트들 / 노드끼리 서로 통신 / CoreDNS 53
  #   - 아웃바운드: 전체 허용 (NAT 경유 인터넷, EFS 2049 등)
  #   - 'kubernetes.io/cluster/<이름>=owned' 태그가 붙어 있어서, Service type=LoadBalancer 가
  #     만들어질 때 쿠버네티스가 이 SG 에 로드밸런서 -> NodePort 인바운드 규칙을 자동 추가합니다.
  # EFS 용 SG(노드 SG 에서 오는 NFS 2049 허용)는 storage.tf 에 별도로 있습니다.
  create_cluster_security_group = true
  create_node_security_group    = true

  # 노드가 파드 ENI 에도 같은 노드 SG 를 쓰도록 하는 기본 동작을 사용합니다.
  # (이 모듈의 기본값: 권장 규칙 세트 활성화)
  node_security_group_enable_recommended_rules = true
}

# =============================================================================
# IRSA 용 IAM 역할: EBS CSI 드라이버
# -----------------------------------------------------------------------------
# 왜 필요한가?
#   EBS CSI 컨트롤러 파드는 PVC 가 생길 때 ec2:CreateVolume / AttachVolume 등을 호출해야 합니다.
#   이 권한을 노드 IAM 역할에 몰아주면 노드의 모든 파드가 EBS 를 조작할 수 있게 되므로,
#   "kube-system/ebs-csi-controller-sa 서비스어카운트만" 이 역할을 맡을 수 있도록 신뢰 정책을 좁힙니다.
# 비용: IAM 역할은 무료
# =============================================================================
data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn] # 위 enable_irsa 로 만들어진 OIDC Provider
    }

    # 이 클러스터가 발급한 토큰 중, 특정 서비스어카운트의 것만 허용
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi-irsa"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json
}

# AWS 가 제공하는 EBS CSI 전용 관리형 정책 (볼륨/스냅샷 생성·연결·삭제 권한)
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# =============================================================================
# IRSA 용 IAM 역할: EFS CSI 드라이버
# -----------------------------------------------------------------------------
# 왜 필요한가?
#   EFS CSI 컨트롤러는 동적 프로비저닝 시 EFS Access Point 를 생성/삭제(elasticfilesystem:*)해야 합니다.
#   EFS add-on 은 서비스어카운트를 2개 만듭니다(controller / node) -> 둘 다 신뢰 정책에 포함.
# 비용: IAM 역할은 무료
# =============================================================================
data "aws_iam_policy_document" "efs_csi_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values = [
        "system:serviceaccount:kube-system:efs-csi-controller-sa",
        "system:serviceaccount:kube-system:efs-csi-node-sa",
      ]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "efs_csi" {
  name               = "${var.cluster_name}-efs-csi-irsa"
  assume_role_policy = data.aws_iam_policy_document.efs_csi_assume_role.json
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  role       = aws_iam_role.efs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}
