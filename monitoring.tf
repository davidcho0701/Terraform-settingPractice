# =============================================================================
# monitoring.tf
# -----------------------------------------------------------------------------
# 이 파일이 하는 일
#   kube-prometheus-stack(Helm 차트 1개)으로 아래를 한 번에 설치합니다.
#     - Prometheus          : 노드/파드 메트릭 수집·저장
#     - Prometheus Operator : Prometheus 설정을 CRD 로 관리
#     - kube-state-metrics  : 디플로이먼트/파드 상태 메트릭
#     - node-exporter       : 노드(CPU/메모리/디스크) 메트릭 (노드마다 1개)
#     - Grafana             : 대시보드 (기본 쿠버네티스 대시보드가 미리 들어 있음)
#   Grafana 는 LoadBalancer(외부 접속) 또는 ClusterIP(포트포워딩)로 노출합니다.
#
# 💰 비용 발생 리소스
#   - Grafana 용 NLB (grafana_service_type = "LoadBalancer" 일 때):
#       시간당 약 $0.0225 + LCU/데이터 요금.  ※ 쓰지 않을 땐 ClusterIP 로 바꾸면 $0
#   - Prometheus/Grafana 파드는 기존 노드의 CPU/메모리를 쓰므로 추가 요금 없음
#   - 데이터를 영구 디스크에 저장하지 않으므로(emptyDir) EBS 요금도 없음
#     (대신 Prometheus 파드가 재시작되면 수집한 메트릭은 사라집니다 - 실습용 선택)
#
# [접속 방법]
#   - LoadBalancer: kubectl get svc -n monitoring kube-prometheus-stack-grafana  의 EXTERNAL-IP(DNS) 로 접속
#                   (생성 후 DNS 전파까지 1~3분 걸릴 수 있음)
#   - 포트포워딩  : kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
#                   -> 브라우저에서 http://localhost:3000
#   - 계정: admin / 비밀번호는  terraform output -raw grafana_admin_password
# =============================================================================

# Helm 이 만든 네임스페이스는 helm uninstall 때 남을 수 있어서, Terraform 이 직접 관리합니다.
resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
  }

  depends_on = [module.eks]
}

# Grafana 관리자 비밀번호: 코드에 평문으로 쓰지 않고 무작위 생성 (state 에 저장되며 output 은 sensitive)
resource "random_password" "grafana_admin" {
  length  = 20
  special = false
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_version
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  # 차트가 크고 이미지가 많아 첫 설치가 오래 걸릴 수 있어 넉넉히 15분
  timeout = 900
  wait    = true

  values = [yamlencode({
    # ---- Grafana ----
    grafana = {
      adminPassword = random_password.grafana_admin.result

      # 디스크 저장 없음: 대시보드 수정 내용은 파드 재시작 시 사라지지만 EBS 비용/정리 부담이 없음
      persistence = { enabled = false }

      service = {
        type = var.grafana_service_type
        port = 80

        # EKS 기본 컨트롤러(in-tree)가 클래식 LB 대신 NLB 를 만들도록 하는 어노테이션
        # (ClusterIP 일 때는 무시됩니다)
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-type" = "nlb"
        }

        # [보안] 이 CIDR 에서 오는 접속만 허용. 기본 0.0.0.0/0 은 전체 공개이므로 내 IP 로 제한 권장
        loadBalancerSourceRanges = var.grafana_allowed_cidrs
      }

      # 메모리 상한이 너무 낮으면(예: 256Mi) 시작 직후 OOMKilled 로 계속 재시작합니다.
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { memory = "768Mi" }
      }
    }

    # ---- Prometheus ----
    prometheus = {
      prometheusSpec = {
        retention = "6h" # 실습용이라 짧게 (emptyDir 이므로 어차피 영구 보관 아님)
        resources = {
          requests = { cpu = "200m", memory = "512Mi" }
          limits   = { memory = "1Gi" } # t3.medium(4GB) 노드에서 다른 파드와 공존하도록 상한
        }
        # 모든 ServiceMonitor/PodMonitor 를 (Helm 라벨 유무와 상관없이) 수집
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        # storageSpec 을 지정하지 않음 -> emptyDir 사용 (EBS PVC 가 남아 비용이 새는 일을 방지)
      }
    }

    # ---- 실습에 불필요한 구성요소 비활성화: 파드 수/메모리 절약 (t3.medium 파드 한도 17개) ----
    alertmanager = { enabled = false }

    # EKS 는 컨트롤플레인(etcd, scheduler, controller-manager, kube-proxy 메트릭)을
    # 외부에 노출하지 않으므로 수집 대상에서 제외 (켜 두면 항상 "Down" 으로 보임)
    kubeEtcd              = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeControllerManager = { enabled = false }
    kubeProxy             = { enabled = false }
  })]

  # CSI/노드가 모두 준비된 뒤 설치되도록
  depends_on = [module.eks, aws_eks_addon.ebs_csi, aws_eks_addon.efs_csi]
}
