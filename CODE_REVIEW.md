# 코드 리뷰 노트

도쿄 리전(ap-northeast-1)에 EKS 실습 환경을 만드는 Terraform 코드를 한 번 훑어보고 정리한 메모다.
먼저 결론부터 적으면, 문법 검증은 통과했지만 실제로 `apply`는 해보지 않았다. 아래 "확인이 필요한 곳"은 첫 실행에서 막힐 수 있는 부분이다.

## 검증 상태

| 항목 | 결과 |
|---|---|
| `terraform init` | 통과 (aws 5.100.0, helm 2.17.0) |
| `terraform validate` | 통과 |
| `terraform fmt -check` | 통과 |
| `deploy.sh`, `destroy.sh` | `bash -n` 문법 검사만 통과, 실행은 안 해봄 |
| `terraform plan` / `apply` | 실행 안 함 |

`validate`는 문법과 참조만 보는 검사라서, 리소스가 AWS에서 실제로 만들어지는지는 알 수 없다.

## 구성 요약

생성 순서는 VPC, EKS, 스토리지, 모니터링이다. Terraform은 리소스 간 참조로 순서를 정하고, 삭제는 반대 순서로 진행된다.

| 파일 | 하는 일 |
|---|---|
| `provider.tf` | provider 버전 고정, helm/kubernetes provider를 EKS에 연결 (`aws eks get-token` 사용) |
| `vpc.tf` | VPC, 퍼블릭/프라이빗 서브넷 각 2개, IGW, NAT 1개 |
| `eks.tf` | 클러스터, 관리형 노드 그룹(t3.medium x 2), 보안 그룹, VPC CNI/CoreDNS/kube-proxy, EBS/EFS용 IRSA 역할 |
| `storage.tf` | EBS/EFS CSI add-on, EFS와 마운트 타겟, 테스트용 StorageClass/PVC/Pod |
| `monitoring.tf` | kube-prometheus-stack (Prometheus + Grafana), Grafana는 NLB로 노출 |
| `variables.tf`, `outputs.tf` | 입력 변수, 출력값(클러스터 이름, kubeconfig 명령 등) |
| `deploy.sh`, `destroy.sh` | 생성/삭제 자동화 |

몇 가지 설계 선택은 이유가 있다.

- 쿠버네티스 1.36을 썼다. 표준 지원이 끝난 버전은 클러스터 요금이 시간당 $0.10에서 $0.60으로 오른다.
- t3.small은 노드당 파드가 11개까지라 모니터링 스택과 CSI 드라이버를 올리기에 부족하다. t3.medium(17개) 2대로 잡았다.
- Prometheus는 디스크에 저장하지 않는다(`emptyDir`). PVC로 만든 EBS가 남아서 요금이 새는 걸 피하려는 선택이다.
- 클러스터 로깅과 KMS 키는 비용 때문에 껐다. 운영 환경이라면 켜야 한다.

## 확인이 필요한 곳

첫 `apply`에서 문제가 될 수 있는 부분들이다.

**1. 회사 계정의 IAM 권한**
`apply`는 IAM 역할 생성, OIDC provider 생성, 서비스 연결 역할 생성 권한이 필요하다. `PowerUserAccess`는 IAM 쓰기가 막혀 있어서 역할 생성 단계에서 `AccessDenied`가 날 수 있다. 이건 코드 문제가 아니라 계정 권한 문제다.
`terraform plan`은 조회 권한만 쓰기 때문에 생성 권한이 없어도 통과한다. 권한 문제는 `apply`에서야 드러난다.

**2. Grafana NLB**
`aws-load-balancer-type: nlb` 어노테이션(기존 in-tree 방식)에 의존하는데 직접 확인하지 못했다. 로드밸런서가 안 만들어지면 `grafana_service_type = "ClusterIP"`로 바꾸고 포트포워딩으로 접속한다.

**3. AL2023 노드 그룹**
AL2023 AMI와 모듈이 만드는 커스텀 launch template 조합이 실제로 노드를 띄우는지는 `apply`해 봐야 안다.

**4. 테스트 파드**
`kubernetes_pod_v1`은 파드가 `Running`이 될 때까지 기다린다. EBS나 EFS 마운트가 실패하면 클러스터는 이미 만들어졌는데 `apply`만 실패로 끝난다. 처음에는 `enable_storage_tests = false`로 클러스터부터 올려 보는 게 낫다.

## 보안과 운영에서 주의할 점

- `terraform.tfstate`에 Grafana 관리자 비밀번호가 평문으로 들어간다. state는 로컬 폴더에 생기고, 이 폴더는 OneDrive 동기화 대상이다. `.gitignore`는 git만 막아 줄 뿐 OneDrive는 막지 못한다.
- Grafana는 HTTP이고, 허용 범위 기본값이 `0.0.0.0/0`이다. `terraform.tfvars`에서 `grafana_allowed_cidrs`를 내 IP로 좁혀야 한다.
- 스크립트는 자격 증명이 유효한지 확인만 한다. MFA 임시 자격 증명을 발급하거나 갱신하지 않는다. `apply`가 20~25분 걸리므로 중간에 만료되면 실패하고, 갱신 후 다시 실행하면 이어서 진행된다.
- `provider.tf`의 `provider "helm"` 안 `kubernetes {}` 블록에 에디터가 빨간 줄을 표시한다. helm provider 2.x 문법이 맞고 `validate`도 통과한다. 언어 서버가 3.x 스키마를 기준으로 검사해서 생기는 오탐으로 보인다.

## 의도한 절충

실수가 아니라 비용 때문에 일부러 단순하게 둔 부분이다.

- NAT를 1개만 둔다. 그 AZ에 장애가 나면 두 AZ 모두 외부 통신이 끊긴다.
- Prometheus 데이터는 파드가 재시작되면 사라진다.
- `destroy.sh`는 삭제 순서를 보장하려고 `-target`을 쓴다. 평소에는 권장되지 않는 방식이다.

## 비용과 정리

켜 두면 시간당 약 $0.30, 하루 약 $7 정도다. EKS 컨트롤플레인 $0.10, 노드 2대 약 $0.11, NAT 약 $0.06, NLB 약 $0.02에 Elastic IP와 볼륨이 더해진다. 단가는 대략치라서 AWS 요금 페이지로 다시 확인해야 한다.

`bash destroy.sh`는 아래 순서로 정리한다.

1. Helm 릴리스, 파드, PVC, StorageClass를 먼저 삭제한다. 쿠버네티스가 만든 NLB와 EBS 볼륨은 Terraform이 모르는 리소스라서, 먼저 지우지 않으면 VPC 삭제를 막거나 계속 과금된다.
2. 로드밸런서와 EBS 볼륨이 AWS에서 실제로 사라질 때까지 기다린다.
3. `terraform destroy`로 나머지를 삭제한다.
4. 태그 `Project=<클러스터 이름>`으로 남은 리소스(EKS, NAT, EIP, EFS, VPC, EBS)를 점검한다.

끝난 뒤에도 도쿄 리전에서 NAT 게이트웨이, Elastic IP, 로드밸런서, EBS 볼륨, EFS, EKS 클러스터가 남아 있지 않은지 콘솔에서 한 번 더 본다.

## 다음에 할 일

1. 계정 관리자에게 IAM 권한 확인
2. `terraform init`, `validate`, `plan` 실행 (요금 없음)
3. 문제 없으면 `terraform.tfvars`에서 CIDR을 내 IP로 제한한 뒤 `apply`
4. `apply`가 실패하면 에러 메시지를 기준으로 위 "확인이 필요한 곳"부터 확인
