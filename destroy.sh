#!/usr/bin/env bash
# =============================================================================
# destroy.sh
# -----------------------------------------------------------------------------
# 하는 일 (생성의 역순으로 안전하게 정리)
#   1) 클러스터 접속 준비
#   2) 클러스터 "안의" 리소스 먼저 삭제: Helm(Grafana NLB 포함) / Pod / PVC / StorageClass
#        -> 이걸 먼저 하지 않으면 쿠버네티스가 만든 NLB, EBS 볼륨이 Terraform 관리 밖에서
#           남아 VPC 삭제를 막거나 계속 과금됩니다.
#   3) 로드밸런서 / PVC 로 만들어진 EBS 볼륨이 AWS 에서 실제로 사라질 때까지 대기
#   4) terraform destroy (EFS, 노드 그룹, EKS, NAT, VPC ...)
#   5) 남은 과금 리소스가 없는지 점검
# 사용법: bash destroy.sh        # 클러스터 이름을 직접 입력해 확인
#         bash destroy.sh -y     # 확인 없이 진행
# =============================================================================
set -euo pipefail
export MSYS_NO_PATHCONV=1

cd "$(dirname "${BASH_SOURCE[0]}")"

AUTO_APPROVE=false
[[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]] && AUTO_APPROVE=true

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. 사전 점검
log "0/5 사전 점검"
for cmd in terraform aws kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' 가 설치되어 있지 않습니다."
done
if [[ -n "${AWS_PROFILE:-}" && -z "${TF_VAR_aws_profile:-}" ]]; then
  export TF_VAR_aws_profile="$AWS_PROFILE"
fi
IDENTITY=$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>&1) \
  || { echo "$IDENTITY" >&2; die "AWS 자격 증명이 없거나 만료되었습니다. MFA 임시 자격 증명을 다시 설정하세요."; }
echo "접속 계정/주체: $IDENTITY"

# get-caller-identity 는 MFA 없이도 성공하므로, 읽기 API 하나로 MFA 인증 여부를 실제 확인합니다.
if ! MFA_CHECK=$(aws ec2 describe-vpcs --region ap-northeast-1 --max-items 1 2>&1); then
  echo "$MFA_CHECK" >&2
  die "AWS API 호출이 거부되었습니다. MFA 임시 자격 증명(액세스 키가 ASIA 로 시작)이 이 터미널에 설정되어 있는지 확인하세요."
fi

terraform init -input=false >/dev/null

if [[ -z "$(terraform state list 2>/dev/null)" ]]; then
  echo "Terraform state 가 비어 있습니다. 삭제할 리소스가 없습니다."
  exit 0
fi

# destroy 도중 값이 사라지기 전에 미리 읽어 둡니다.
CLUSTER=$(terraform output -raw cluster_name 2>/dev/null || true)
REGION=$(terraform output -raw region 2>/dev/null || echo "ap-northeast-1")
VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || true)
[[ -n "$CLUSTER" ]] || die "state 에서 cluster_name 을 읽지 못했습니다. 'terraform destroy' 를 직접 실행하세요."

echo "삭제 대상 클러스터: $CLUSTER (리전: $REGION, VPC: ${VPC_ID:-unknown})"
if ! $AUTO_APPROVE; then
  read -r -p "정말 삭제하려면 클러스터 이름($CLUSTER)을 입력하세요: " ANS
  [[ "$ANS" == "$CLUSTER" ]] || die "이름이 일치하지 않아 취소했습니다."
fi

# 클러스터 안(Helm / kubernetes_*)에 해당하는 Terraform 리소스 주소를 state 에서 수집
K8S_RESOURCES=()
while IFS= read -r line; do
  [[ -n "$line" ]] && K8S_RESOURCES+=("$line")
done < <(terraform state list | grep -E '^(helm_release|kubernetes_)' || true)

# ---------------------------------------------------------------- 1. 클러스터 접속
log "1/5 클러스터 접속 준비"
CLUSTER_EXISTS=true
if aws eks describe-cluster --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1; then
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null
  echo "kubeconfig 갱신 완료"
else
  CLUSTER_EXISTS=false
  warn "AWS 에 클러스터가 이미 없습니다. 클러스터 안 리소스는 state 에서만 제거합니다."
fi

# ---------------------------------------------------------------- 2. 클러스터 내부 리소스 삭제
log "2/5 클러스터 내부 리소스 삭제 (Helm/Grafana NLB, Pod, PVC, StorageClass)"
if ((${#K8S_RESOURCES[@]} > 0)); then
  if $CLUSTER_EXISTS; then
    TARGETS=()
    for r in "${K8S_RESOURCES[@]}"; do TARGETS+=("-target=$r"); done
    # -target 은 평소엔 권장되지 않지만, 여기서는 "삭제 순서 보장" 목적으로만 의도적으로 사용합니다.
    terraform destroy -input=false -auto-approve "${TARGETS[@]}"
  else
    for r in "${K8S_RESOURCES[@]}"; do terraform state rm "$r" >/dev/null; done
  fi
else
  echo "클러스터 내부 리소스가 state 에 없습니다. (건너뜀)"
fi

# ---------------------------------------------------------------- 3. AWS 쪽 잔여물 대기
log "3/5 로드밸런서 / PVC 볼륨이 AWS 에서 삭제될 때까지 대기"

# 3-a) 이 VPC 안의 로드밸런서 (Terraform 이 만들지 않았으므로 있다면 전부 Service type=LoadBalancer 가 만든 것)
if [[ -n "$VPC_ID" ]]; then
  for i in $(seq 1 40); do # 최대 약 10분
    NLB=$(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null || true)
    CLB=$(aws elb describe-load-balancers --region "$REGION" \
      --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" --output text 2>/dev/null || true)
    if [[ -z "$NLB" && -z "$CLB" ]]; then
      echo "VPC 내 로드밸런서 없음 ✔"
      break
    fi
    echo "  로드밸런서 삭제 대기 중... ($i/40)"
    sleep 15
    if [[ "$i" == "40" ]]; then
      warn "로드밸런서가 남아 있습니다: $NLB $CLB  -> 콘솔에서 확인/삭제 후 다시 실행하세요. (VPC 삭제가 실패할 수 있음)"
    fi
  done
fi

# 3-b) 테스트 PVC 로 만들어진 EBS 볼륨 (reclaimPolicy=Delete 이므로 사라져야 정상)
for i in $(seq 1 12); do # 최대 약 3분
  VOLS=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:kubernetes.io/created-for/pvc/name,Values=ebs-test-pvc" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)
  if [[ -z "$VOLS" ]]; then
    echo "테스트 EBS 볼륨 없음 ✔"
    break
  fi
  echo "  EBS 볼륨 삭제 대기 중: $VOLS ($i/12)"
  sleep 15
  if [[ "$i" == "12" ]]; then
    warn "EBS 볼륨이 남아 있습니다: $VOLS  -> destroy 후에도 남으면 콘솔에서 직접 삭제하세요. (남으면 계속 과금)"
  fi
done

# ---------------------------------------------------------------- 4. terraform destroy
log "4/5 terraform destroy (EFS, 노드 그룹, EKS, NAT, VPC ...) - 10~15분 소요"
terraform destroy -input=false -auto-approve

# ---------------------------------------------------------------- 5. 잔여 리소스 점검
log "5/5 잔여 과금 리소스 점검 (태그 Project=$CLUSTER)"
LEFT=0
check() { # 설명, 결과값
  if [[ -n "$2" && "$2" != "None" ]]; then
    warn "$1 남아 있음: $2"
    LEFT=1
  else
    echo "  $1: 없음 ✔"
  fi
}

check "EKS 클러스터" "$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" --query 'cluster.name' --output text 2>/dev/null || true)"
check "NAT 게이트웨이" "$(aws ec2 describe-nat-gateways --region "$REGION" \
  --filter "Name=tag:Project,Values=$CLUSTER" "Name=state,Values=pending,available,deleting" \
  --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null || true)"
check "Elastic IP" "$(aws ec2 describe-addresses --region "$REGION" \
  --filters "Name=tag:Project,Values=$CLUSTER" --query 'Addresses[].AllocationId' --output text 2>/dev/null || true)"
check "EFS 파일 시스템" "$(aws efs describe-file-systems --region "$REGION" \
  --query "FileSystems[?Tags[?Key=='Project' && Value=='$CLUSTER']].FileSystemId" --output text 2>/dev/null || true)"
check "VPC" "$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Project,Values=$CLUSTER" --query 'Vpcs[].VpcId' --output text 2>/dev/null || true)"
check "테스트 EBS 볼륨" "$(aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=tag:kubernetes.io/created-for/pvc/name,Values=ebs-test-pvc" \
  --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)"

echo
if [[ "$LEFT" == "0" ]]; then
  echo "모든 리소스가 정리되었습니다 ✔  (kubeconfig 에 남은 항목은 'kubectl config delete-context' 로 지울 수 있습니다)"
else
  warn "일부 리소스가 남아 있습니다. 위 항목을 AWS 콘솔에서 확인/삭제하세요."
  exit 1
fi
