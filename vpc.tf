# =============================================================================
# vpc.tf
# -----------------------------------------------------------------------------
# 이 파일이 하는 일
#   기존 VPC 없이 "처음부터" EKS 가 올라갈 네트워크 바닥을 만듭니다.
#
#     인터넷
#       │
#   [Internet Gateway]
#       │
#   ┌───┴──────────────────────────────┐
#   │ 퍼블릭 서브넷 x2 (1a, 1c)         │  <- 로드밸런서(Grafana NLB), NAT GW 가 위치
#   │   라우팅: 0.0.0.0/0 -> IGW        │
#   └───┬──────────────────────────────┘
#       │ [NAT Gateway x1]  (💰 비용 발생)
#   ┌───┴──────────────────────────────┐
#   │ 프라이빗 서브넷 x2 (1a, 1c)       │  <- 워커 노드, EKS 컨트롤플레인 ENI, EFS 마운트 타겟
#   │   라우팅: 0.0.0.0/0 -> NAT GW     │
#   └──────────────────────────────────┘
#
#   공식 모듈 terraform-aws-modules/vpc/aws 가 아래를 한 번에 만들어 줍니다.
#     - VPC, 서브넷 4개, Internet Gateway, NAT Gateway + Elastic IP
#     - 퍼블릭/프라이빗 라우팅 테이블 및 서브넷 연결 (퍼블릭/프라이빗 분리)
#
# 💰 비용 발생 리소스
#   - NAT Gateway: 시간당 약 $0.062 + 처리 데이터 GB당 약 $0.062  (이 코드에서 가장 비싼 네트워크 리소스)
#   - NAT 용 Elastic IP(퍼블릭 IPv4): 시간당 약 $0.005
#   * VPC / 서브넷 / IGW / 라우팅 테이블 / 보안 그룹 자체는 무료입니다.
#   * 금액은 대략치입니다. 정확한 단가는 AWS 요금 페이지를 확인하세요.
# =============================================================================

locals {
  # 서브넷 CIDR 을 VPC CIDR 로부터 자동 계산합니다.
  #  - 프라이빗: /20 (4,091 IP) -> 파드는 VPC CNI 때문에 "VPC IP"를 직접 소비하므로 넉넉하게
  #  - 퍼블릭  : /24 (251 IP)   -> 로드밸런서/NAT 정도만 있으면 되므로 작게
  private_subnets = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 4, i)]       # 10.0.0.0/20, 10.0.16.0/20
  public_subnets  = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 8, 100 + i)] # 10.0.100.0/24, 10.0.101.0/24
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.21"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr
  azs  = var.azs

  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  # ---- NAT Gateway: 비용 최소화를 위해 "전체에서 1개만" ----
  # 프라이빗 서브넷의 노드가 인터넷(컨테이너 이미지 pull, AWS API 호출)에 나가려면 NAT 가 필요합니다.
  # 원래 운영 환경은 AZ 별로 1개씩(고가용성) 두지만, 실습이므로 1개를 공유합니다.
  #  - 단점 1: NAT 가 있는 AZ(1a)가 장애나면 두 AZ 모두 외부 통신 불가 (실습에선 감수)
  #  - 단점 2: 1c 의 노드가 1a 의 NAT 를 쓰므로 AZ 간 데이터 전송료가 약간 발생
  enable_nat_gateway     = true # 💰
  single_nat_gateway     = true # 💰 NAT 1개만 생성
  one_nat_gateway_per_az = false

  # ---- DNS 설정 (필수) ----
  # EKS 노드가 API 서버를 찾고, EFS 마운트 타겟의 DNS 이름(fs-xxx.efs.<region>.amazonaws.com)을
  # 해석하려면 VPC 의 DNS 지원/호스트네임이 켜져 있어야 합니다.
  enable_dns_support   = true
  enable_dns_hostnames = true

  # ---- 서브넷 태그: 로드밸런서가 "어느 서브넷에 만들어질지" 쿠버네티스에게 알려주는 표식 ----
  # 퍼블릭: 인터넷 향(external) 로드밸런서가 놓일 서브넷 -> Grafana NLB 가 여기에 생성됨
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  # 프라이빗: 내부(internal) 로드밸런서용
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}
