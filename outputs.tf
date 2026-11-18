# =============================================================================
# outputs.tf
# -----------------------------------------------------------------------------
# 이 파일이 하는 일
#   apply 가 끝난 뒤 터미널에 보여 줄 값들(클러스터 이름, 엔드포인트, kubeconfig 갱신 명령어 등).
#   deploy.sh / destroy.sh 도 이 출력값을 읽어 사용합니다.
#   비용: 없음
# =============================================================================

output "region" {
  description = "AWS 리전"
  value       = var.region
}

output "cluster_name" {
  description = "EKS 클러스터 이름"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API 서버 엔드포인트"
  value       = module.eks.cluster_endpoint
}

output "update_kubeconfig_command" {
  description = "kubectl 이 이 클러스터에 접속하도록 kubeconfig 를 갱신하는 명령어"
  value = join(" ", concat(
    ["aws eks update-kubeconfig --region", var.region, "--name", module.eks.cluster_name],
    var.aws_profile == null ? [] : ["--profile", var.aws_profile]
  ))
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "프라이빗 서브넷 ID (노드/EFS 마운트 타겟)"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID (로드밸런서/NAT)"
  value       = module.vpc.public_subnets
}

output "cluster_security_group_id" {
  description = "클러스터(컨트롤플레인)용 보안 그룹 ID"
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "워커 노드용 보안 그룹 ID"
  value       = module.eks.node_security_group_id
}

output "node_iam_role_arn" {
  description = "관리형 노드 그룹 IAM 역할 ARN"
  value       = module.eks.eks_managed_node_groups["default"].iam_role_arn
}

output "cluster_iam_role_arn" {
  description = "EKS 클러스터 IAM 역할 ARN"
  value       = module.eks.cluster_iam_role_arn
}

output "ebs_csi_irsa_role_arn" {
  description = "EBS CSI 드라이버용 IRSA 역할 ARN"
  value       = aws_iam_role.ebs_csi.arn
}

output "efs_csi_irsa_role_arn" {
  description = "EFS CSI 드라이버용 IRSA 역할 ARN"
  value       = aws_iam_role.efs_csi.arn
}

output "efs_file_system_id" {
  description = "EFS 파일 시스템 ID"
  value       = aws_efs_file_system.this.id
}

output "grafana_service_name" {
  description = "Grafana Service 이름 (네임스페이스: monitoring)"
  value       = "kube-prometheus-stack-grafana"
}

output "grafana_loadbalancer_hostname_command" {
  description = "Grafana 로드밸런서 주소 조회 명령어 (LoadBalancer 타입일 때, 생성 후 1~3분 뒤)"
  value       = "kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}

output "grafana_port_forward_command" {
  description = "로드밸런서 없이 접속하는 포트포워딩 명령어 -> http://localhost:3000"
  value       = "kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
}

output "grafana_admin_user" {
  description = "Grafana 관리자 계정"
  value       = "admin"
}

output "grafana_admin_password" {
  description = "Grafana 관리자 비밀번호 (terraform output -raw grafana_admin_password)"
  value       = random_password.grafana_admin.result
  sensitive   = true
}
