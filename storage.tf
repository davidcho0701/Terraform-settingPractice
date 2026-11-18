# =============================================================================
# storage.tf
# -----------------------------------------------------------------------------
# 이 파일이 하는 일
#   [EBS - 블록 스토리지]
#     1) EBS CSI Driver add-on 설치 (IRSA 역할 연결)
#     2) gp3 StorageClass + PVC + 테스트 Pod
#   [EFS - 공유 파일 스토리지(NFS)]
#     3) EFS 전용 보안 그룹 (노드 SG 에서 오는 NFS 2049 만 허용)
#     4) EFS 파일 시스템 + 프라이빗 서브넷마다 마운트 타겟
#     5) EFS CSI Driver add-on 설치 (IRSA 역할 연결)
#     6) EFS StorageClass + PVC + 테스트 Pod
#
# EBS vs EFS 한 줄 비교
#   - EBS: 한 AZ 안의 디스크 1개. 한 번에 한 노드만 붙임(ReadWriteOnce). 빠르고 DB 에 적합.
#   - EFS: 여러 AZ/여러 노드/여러 파드가 동시에 마운트(ReadWriteMany). 공유 파일에 적합.
#
# 💰 비용 발생 리소스
#   - EBS 볼륨(PVC): gp3 1GiB 약 $0.096/월 (테스트용이라 사실상 무시 가능)
#   - EFS: 저장한 데이터 GB 당 약 $0.30/월(Standard). 비어 있으면 거의 $0
#          마운트 타겟 자체는 무료. 30일 미접근 데이터는 IA 로 내려 저렴하게 보관
#   * add-on, 보안 그룹, StorageClass 는 무료
#   [주의] 다 쓰고 나면 PVC 를 지워야 EBS 볼륨이 같이 삭제됩니다 (destroy.sh 가 처리)
# =============================================================================

# =============================================================================
# 1) EBS CSI Driver (EKS add-on)
# -----------------------------------------------------------------------------
# CSI 드라이버가 없으면 PVC 를 만들어도 실제 EBS 디스크가 생성되지 않고 Pending 에 머뭅니다.
# service_account_role_arn : eks.tf 에서 만든 IRSA 역할을 컨트롤러 파드에 연결
# depends_on module.eks    : 노드가 먼저 떠 있어야 컨트롤러 파드가 스케줄됩니다.
#                            (destroy 때는 역순 -> 쿠버네티스 리소스가 먼저 지워진 뒤 add-on 삭제)
# =============================================================================
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [module.eks, aws_iam_role_policy_attachment.ebs_csi]
}

# =============================================================================
# 3) EFS 보안 그룹
# -----------------------------------------------------------------------------
# EFS 는 NFS(TCP 2049)로 접속합니다. 마운트 타겟(ENI)에 붙는 이 SG 가
# "노드 SG 에서 오는 2049 만" 허용하여 같은 VPC 의 다른 리소스는 접근하지 못하게 합니다.
# 비용: 무료
# =============================================================================
resource "aws_security_group" "efs" {
  name        = "${var.cluster_name}-efs-sg"
  description = "Allow NFS from EKS worker nodes to EFS mount targets"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${var.cluster_name}-efs-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "efs_from_nodes" {
  security_group_id            = aws_security_group.efs.id
  referenced_security_group_id = module.eks.node_security_group_id
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
  description                  = "NFS from EKS nodes"
}

# =============================================================================
# 4) EFS 파일 시스템 + 마운트 타겟
# -----------------------------------------------------------------------------
# 💰 EFS 저장 용량만큼 과금. throughput_mode=bursting 은 추가 처리량 요금이 없는 가장 저렴한 설정.
# =============================================================================
resource "aws_efs_file_system" "this" {
  creation_token   = "${var.cluster_name}-efs"
  encrypted        = true # AWS 관리형 키 (추가 비용 없음)
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  # 30일간 안 읽은 파일은 저렴한 IA 클래스로 이동 (장기 보관 시 절감)
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = {
    Name = "${var.cluster_name}-efs"
  }
}

# 마운트 타겟 = EFS 로 들어가는 "문(ENI)". AZ 마다 하나씩 있어야 그 AZ 의 노드가 마운트할 수 있습니다.
# 프라이빗 서브넷마다 1개씩 생성 (여기서 말하는 ENI 가 서브넷의 IP 를 1개씩 사용)
# 마운트 타겟 자체는 무료.
resource "aws_efs_mount_target" "this" {
  count = length(var.azs)

  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs.id]
}

# =============================================================================
# 5) EFS CSI Driver (EKS add-on)
# -----------------------------------------------------------------------------
# 마운트 타겟이 준비된 뒤에 설치/사용되도록 depends_on 을 겁니다.
# =============================================================================
resource "aws_eks_addon" "efs_csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-efs-csi-driver"
  service_account_role_arn = aws_iam_role.efs_csi.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [module.eks, aws_iam_role_policy_attachment.efs_csi, aws_efs_mount_target.this]
}

# =============================================================================
# 2) EBS 테스트: StorageClass / PVC / Pod
# =============================================================================
resource "kubernetes_storage_class_v1" "ebs_gp3" {
  count = var.enable_storage_tests ? 1 : 0

  metadata {
    name = "ebs-gp3"
  }

  storage_provisioner = "ebs.csi.aws.com"
  reclaim_policy      = "Delete" # PVC 삭제 시 EBS 볼륨도 삭제 -> 비용 누수 방지

  # WaitForFirstConsumer: 파드가 스케줄될 AZ 를 보고 "같은 AZ 에" 볼륨을 만듭니다.
  # (EBS 는 AZ 종속이라, 이 설정이 없으면 파드와 다른 AZ 에 볼륨이 생겨 마운트 실패할 수 있음)
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
    fsType    = "ext4"
  }

  depends_on = [aws_eks_addon.ebs_csi]
}

resource "kubernetes_persistent_volume_claim_v1" "ebs_test" {
  count = var.enable_storage_tests ? 1 : 0

  metadata {
    name      = "ebs-test-pvc"
    namespace = "default"
  }

  spec {
    access_modes       = ["ReadWriteOnce"] # EBS 는 한 번에 한 노드만
    storage_class_name = kubernetes_storage_class_v1.ebs_gp3[0].metadata[0].name

    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }

  # WaitForFirstConsumer 라서 파드가 생기기 전까지는 Pending 이 정상입니다.
  # true 로 두면 Terraform 이 "Bound 될 때까지" 무한정 기다리다 실패합니다.
  wait_until_bound = false
}

resource "kubernetes_pod_v1" "ebs_test" {
  count = var.enable_storage_tests ? 1 : 0

  metadata {
    name      = "ebs-test-pod"
    namespace = "default"
  }

  spec {
    container {
      name  = "writer"
      image = "public.ecr.aws/docker/library/busybox:1.36"
      # 5초마다 시간을 EBS 볼륨에 기록 -> 파드를 지우고 다시 만들어도 파일이 남아 있는지 확인 가능
      command = ["/bin/sh", "-c", "while true; do date >> /data/out.txt; sleep 5; done"]

      volume_mount {
        name       = "data"
        mount_path = "/data"
      }
    }

    volume {
      name = "data"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim_v1.ebs_test[0].metadata[0].name
      }
    }
  }

  depends_on = [aws_eks_addon.ebs_csi]
}

# =============================================================================
# 6) EFS 테스트: StorageClass / PVC / Pod
# =============================================================================
resource "kubernetes_storage_class_v1" "efs" {
  count = var.enable_storage_tests ? 1 : 0

  metadata {
    name = "efs-sc"
  }

  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Delete"
  volume_binding_mode = "Immediate"

  parameters = {
    provisioningMode = "efs-ap"                    # PVC 마다 EFS Access Point 를 자동 생성(동적 프로비저닝)
    fileSystemId     = aws_efs_file_system.this.id # 위에서 만든 EFS
    directoryPerms   = "700"
    basePath         = "/dynamic_provisioning"
  }

  depends_on = [aws_eks_addon.efs_csi]
}

resource "kubernetes_persistent_volume_claim_v1" "efs_test" {
  count = var.enable_storage_tests ? 1 : 0

  metadata {
    name      = "efs-test-pvc"
    namespace = "default"
  }

  spec {
    access_modes       = ["ReadWriteMany"] # EFS 는 여러 노드/파드가 동시에 읽고 쓸 수 있음
    storage_class_name = kubernetes_storage_class_v1.efs[0].metadata[0].name

    resources {
      requests = {
        storage = "1Gi" # EFS 는 탄력적이라 값이 의미 없지만 PVC 스펙상 필수
      }
    }
  }

  wait_until_bound = false
}

# 서로 다른 두 파드가 같은 EFS 볼륨을 공유하는 것을 보여 주기 위해 2개를 만듭니다.
#  - efs-writer : 파일에 계속 기록
#  - efs-reader : 같은 파일을 읽어서 출력 (kubectl logs efs-reader 로 확인)
resource "kubernetes_pod_v1" "efs_writer" {
  count = var.enable_storage_tests ? 1 : 0

  metadata {
    name      = "efs-writer"
    namespace = "default"
  }

  spec {
    container {
      name    = "writer"
      image   = "public.ecr.aws/docker/library/busybox:1.36"
      command = ["/bin/sh", "-c", "while true; do echo \"$(date) from $(hostname)\" >> /data/shared.txt; sleep 5; done"]

      volume_mount {
        name       = "data"
        mount_path = "/data"
      }
    }

    volume {
      name = "data"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim_v1.efs_test[0].metadata[0].name
      }
    }
  }

  depends_on = [aws_eks_addon.efs_csi, aws_efs_mount_target.this]
}

resource "kubernetes_pod_v1" "efs_reader" {
  count = var.enable_storage_tests ? 1 : 0

  metadata {
    name      = "efs-reader"
    namespace = "default"
  }

  spec {
    container {
      name    = "reader"
      image   = "public.ecr.aws/docker/library/busybox:1.36"
      command = ["/bin/sh", "-c", "touch /data/shared.txt; tail -f /data/shared.txt"]

      volume_mount {
        name       = "data"
        mount_path = "/data"
      }
    }

    volume {
      name = "data"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim_v1.efs_test[0].metadata[0].name
      }
    }
  }

  depends_on = [aws_eks_addon.efs_csi, aws_efs_mount_target.this]
}
