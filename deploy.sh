#!/usr/bin/env bash
# =============================================================================
# deploy.sh
# -----------------------------------------------------------------------------
# 하는 일: init -> validate -> plan -> (확인) -> apply -> kubeconfig 등록 -> 상태 확인
# 사용법:  bash deploy.sh          # plan 확인 후 직접 yes 입력
#          bash deploy.sh -y       # 확인 없이 바로 apply (자동화용)
#
# 사전 조건: terraform, aws CLI, kubectl 설치 + MFA 임시 자격 증명이 설정된 터미널
#   - named profile 사용 시:  export AWS_PROFILE=내프로필   (이 값이 Terraform 에도 전달됩니다)
#   - 환경변수 방식이면 AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN 이 export 되어 있어야 함
# 💰 이 스크립트를 끝까지 실행하면 시간당 약 $0.3 (월 약 $200+) 비용이 발생하기 시작합니다.
#    실습이 끝나면 반드시 bash destroy.sh 를 실행하세요.
# =============================================================================
set -euo pipefail
export MSYS_NO_PATHCONV=1 # Windows Git Bash 가 인자를 경로로 오인해 바꾸는 것 방지

cd "$(dirname "${BASH_SOURCE[0]}")"

AUTO_APPROVE=false
[[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]] && AUTO_APPROVE=true

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
confirm() {
  $AUTO_APPROVE && return 0
  local ans
  read -r -p "$1 [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------- 0. 사전 점검
log "0/6 사전 점검 (도구 / AWS 자격 증명)"
for cmd in terraform aws kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' 가 설치되어 있지 않습니다."
done

# named profile 을 쓰고 있으면 Terraform(provider, eks get-token)에도 같은 profile 을 쓰게 함
if [[ -n "${AWS_PROFILE:-}" && -z "${TF_VAR_aws_profile:-}" ]]; then
  export TF_VAR_aws_profile="$AWS_PROFILE"
fi

if ! IDENTITY=$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>&1); then
  echo "$IDENTITY" >&2
  die "AWS 자격 증명이 없거나 만료되었습니다. MFA 임시 자격 증명을 다시 발급받아 설정하세요."
fi
echo "접속 계정/주체: $IDENTITY"

# get-caller-identity 는 MFA 없이도 성공하므로 MFA 인증 여부를 알 수 없습니다.
# MFA 필수 정책(ForceMFA)이 있는 계정이면 일반 API 가 거부되므로, 읽기 API 하나로 실제 확인합니다.
if ! MFA_CHECK=$(aws ec2 describe-vpcs --region ap-northeast-1 --max-items 1 2>&1); then
  echo "$MFA_CHECK" >&2
  die "AWS API 호출이 거부되었습니다. MFA 임시 자격 증명(액세스 키가 ASIA 로 시작)이 이 터미널에 설정되어 있는지 확인하세요."
fi
warn "회사 AWS 계정입니다. 위 계정이 의도한 계정인지 확인하세요."
warn "임시 자격 증명은 만료됩니다. apply 는 약 20~25분 걸리므로 만료까지 충분히 남았는지 확인하세요."
confirm "이 계정으로 계속할까요?" || die "중단했습니다."

# ---------------------------------------------------------------- 1. init
log "1/6 terraform init (provider/모듈 다운로드)"
terraform init -input=false

# ---------------------------------------------------------------- 2. validate
log "2/6 terraform validate (문법/참조 검사)"
terraform validate

# ---------------------------------------------------------------- 3. plan
log "3/6 terraform plan (변경 계획 미리보기, 비용 없음)"
terraform plan -input=false -out=tfplan

# ---------------------------------------------------------------- 4. apply
log "4/6 terraform apply (여기서부터 비용 발생)"
confirm "위 계획대로 리소스를 생성할까요? (EKS 포함 약 20~25분 소요)" || die "apply 를 취소했습니다. (plan 파일: tfplan)"
terraform apply -input=false tfplan
rm -f tfplan

# ---------------------------------------------------------------- 5. kubeconfig
log "5/6 kubeconfig 등록"
# outputs.tf 의 update_kubeconfig_command 를 그대로 실행
eval "$(terraform output -raw update_kubeconfig_command)"

# ---------------------------------------------------------------- 6. 상태 확인
log "6/6 클러스터 상태 확인"
kubectl get nodes -o wide
echo
kubectl get pods -A
echo
kubectl get storageclass,pvc 2>/dev/null || true

SVC_TYPE=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.spec.type}' 2>/dev/null || true)
GRAFANA_PW=$(terraform output -raw grafana_admin_password)

echo
if [[ "$SVC_TYPE" == "LoadBalancer" ]]; then
  echo "Grafana 로드밸런서 주소를 기다리는 중 (최대 5분)..."
  HOST=""
  for _ in $(seq 1 30); do
    HOST=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    [[ -n "$HOST" ]] && break
    sleep 10
  done
  if [[ -n "$HOST" ]]; then
    echo "Grafana URL : http://$HOST   (DNS 전파로 1~3분 뒤부터 접속될 수 있음)"
  else
    warn "아직 주소가 할당되지 않았습니다. 잠시 후: $(terraform output -raw grafana_loadbalancer_hostname_command)"
  fi
else
  echo "Grafana 는 ClusterIP 입니다. 접속: $(terraform output -raw grafana_port_forward_command)  -> http://localhost:3000"
fi
echo "Grafana 계정: admin / $GRAFANA_PW"

cat <<EOF

완료! 💰 지금부터 요금이 발생 중입니다. 실습이 끝나면 반드시:  bash destroy.sh

스토리지 테스트 확인:
  kubectl exec ebs-test-pod -- tail -3 /data/out.txt
  kubectl logs efs-reader --tail=5     # efs-writer 가 쓴 내용이 보이면 EFS 공유 성공
EOF
