# =============================================================================
# variables.tf
# -----------------------------------------------------------------------------
# 이 파일이 하는 일
#   - 인프라의 "조절 손잡이"를 모아 둔 입력 변수 정의.
#   - 값을 바꾸고 싶으면 코드를 고치지 말고 terraform.tfvars 로 덮어쓰세요.
#     (terraform.tfvars.example 참고)
#
# 비용: 변수 정의 자체는 무료. 단, node_* / grafana_service_type 등은 비용에 직접 영향을 줍니다.
# =============================================================================

# ---------------------------- 기본 -------------------------------------------
variable "region" {
  description = "AWS 리전 (도쿄)"
  type        = string
  default     = "ap-northeast-1"
}

variable "aws_profile" {
  description = "AWS CLI named profile 이름. 환경변수로 임시 자격 증명을 쓰면 null 로 둡니다."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "EKS 클러스터 이름. 모든 리소스 이름/태그의 접두어로도 쓰입니다."
  type        = string
  default     = "eks-lab"
}

# ---------------------------- VPC --------------------------------------------
variable "vpc_cidr" {
  description = "새로 만들 VPC 의 CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "사용할 가용 영역 (서로 다른 AZ 2개). t3 계열이 지원되는 1a/1c 사용."
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c"]
}

# ---------------------------- EKS --------------------------------------------
variable "kubernetes_version" {
  description = <<-EOT
    EKS 쿠버네티스 버전.
    [비용 주의] 표준 지원(standard support)이 끝난 버전은 extended support 로 들어가
    클러스터 요금이 시간당 $0.10 -> $0.60 으로 6배가 됩니다.
    최신 표준 지원 버전은 아래 명령으로 확인하세요.
      aws eks describe-cluster-versions --query "clusterVersions[?status=='STANDARD_SUPPORT'].clusterVersion"
  EOT
  type        = string
  default     = "1.36"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = <<-EOT
    EKS API 서버(퍼블릭 엔드포인트)에 접속을 허용할 CIDR.
    기본값은 전체 허용(0.0.0.0/0)이라 실습 편의용입니다. 가능하면 내 공인 IP/32 로 좁히세요.
    (IAM 인증이 있어 즉시 위험하진 않지만, 노출 면적을 줄이는 것이 좋습니다.)
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ---------------------------- 노드 그룹 --------------------------------------
variable "node_instance_type" {
  description = <<-EOT
    워커 노드 인스턴스 타입.
    t3.small(2GB)은 ENI 제한으로 노드당 파드 최대 11개라 kube-prometheus-stack +
    CSI 드라이버를 올리기에 부족합니다. t3.medium(4GB, 파드 17개)이 실습에 충분한 최저선입니다.
  EOT
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "노드 개수(희망). t3.medium 1대는 파드 한도(17)에 빠듯해서 기본 2대."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "노드 최소 개수"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "노드 최대 개수"
  type        = number
  default     = 2
}

variable "node_capacity_type" {
  description = "ON_DEMAND(안정적) 또는 SPOT(약 60~70% 저렴하지만 언제든 회수될 수 있음)"
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type 은 ON_DEMAND 또는 SPOT 이어야 합니다."
  }
}

variable "node_disk_size_gb" {
  description = "노드 루트 EBS(gp3) 크기(GiB)"
  type        = number
  default     = 20
}

# ---------------------------- 스토리지 테스트 --------------------------------
variable "enable_storage_tests" {
  description = "EBS/EFS 테스트용 StorageClass + PVC + Pod 를 만들지 여부"
  type        = bool
  default     = true
}

# ---------------------------- 모니터링 ---------------------------------------
variable "grafana_service_type" {
  description = <<-EOT
    Grafana Service 타입.
      - "LoadBalancer": 외부 접속용 NLB 생성 (시간당 약 $0.0225 + 데이터 요금 발생)
      - "ClusterIP"   : 로드밸런서 없음(무료). kubectl port-forward 로만 접속
  EOT
  type        = string
  default     = "LoadBalancer"

  validation {
    condition     = contains(["LoadBalancer", "ClusterIP"], var.grafana_service_type)
    error_message = "grafana_service_type 은 LoadBalancer 또는 ClusterIP 이어야 합니다."
  }
}

variable "grafana_allowed_cidrs" {
  description = <<-EOT
    Grafana 로드밸런서에 접속을 허용할 CIDR 목록.
    [보안] 기본값 0.0.0.0/0 은 인터넷 전체 공개입니다. 반드시 내 공인 IP/32 로 바꾸세요.
    (예: ["203.0.113.10/32"])  내 IP 확인: curl https://checkip.amazonaws.com
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "kube_prometheus_stack_version" {
  description = "kube-prometheus-stack Helm 차트 버전 (재현성을 위해 고정)"
  type        = string
  default     = "93.3.1"
}
