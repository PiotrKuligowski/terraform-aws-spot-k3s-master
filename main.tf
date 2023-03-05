data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "random_uuid" "hash" {}

resource "random_string" "k3s_token" {
  length  = 16
  special = false
}

module "spot-master" {
  source                      = "git::https://github.com/PiotrKuligowski/terraform-aws-spot-asg.git"
  ami_id                      = var.ami_id
  ssh_key_name                = var.ssh_key_name
  subnet_ids                  = var.subnet_ids
  vpc_id                      = var.vpc_id
  user_data                   = local.master_user_data
  policy_statements           = local.master_required_policy
  project                     = var.project
  component                   = var.component
  tags                        = var.tags
  instance_type               = var.instance_type
  private_domain              = var.private_domain
  record_name                 = var.record_name
  security_groups             = var.security_groups
  associate_public_ip_address = var.associate_public_ip_address
  asg_min_size                = var.asg_min_size
  asg_max_size                = var.asg_max_size
  asg_desired_capacity        = var.asg_desired_capacity
}

locals {
  hash = substr(random_uuid.hash.result, 0, 8)

  master_required_policy = merge({

    AllowDescribeOperations = {
      effect = "Allow"
      actions = [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeTags",
        "autoscaling:DescribeLaunchConfigurations"
      ]
      resources = ["*"]
    }

    AllowRoute53 = {
      effect = "Allow"
      actions = [
        "route53:ChangeResourceRecordSets"
      ]
      resources = ["*"]
    }

    AllowSendCommand = {
      effect = "Allow"
      actions = [
        "ssm:SendCommand"
      ]
      resources = [
        "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*",
        "arn:aws:ssm:${data.aws_region.current.name}::document/AWS-RunShellScript"
      ]
    }

    AllowPutParameter = {
      effect = "Allow"
      actions = [
        "ssm:PutParameter"
      ]
      resources = [
        "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/*"
      ]
    }

    AllowListCommandInvocations = {
      effect = "Allow"
      actions = [
        "ssm:ListCommandInvocations"
      ]
      resources = ["*"]
    }

  }, var.policy_statements)
}

locals {
  master_user_data = join("\n", [
    local.user_data_install_k3s,
    local.user_data_install_calico,
    local.user_data_put_new_id_to_ps,
    local.user_data_put_kubeconfig_to_ps,
    local.user_data_put_join_command_to_ps,
    local.user_data_join_nodes,
    var.user_data
  ])

  user_data_install_k3s = <<-EOF
curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE="644" INSTALL_K3S_VERSION=${var.k3s_version} sh -s - server \
  --token="${random_string.k3s_token.result}" \
  --datastore-endpoint="${var.datastore_endpoint}" \
  --flannel-backend=none \
  --disable-network-policy \
  --disable traefik
EOF

  user_data_install_calico = <<-EOF
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/calico.yaml
kubectl get pods --all-namespaces
kubectl wait deployment -n kube-system calico-kube-controllers --for condition=Available=True --timeout=90s
kubectl wait deployment -n kube-system coredns --for condition=Available=True --timeout=90s
EOF

  user_data_put_kubeconfig_to_ps = <<-EOF
sed 's/127.0.0.1:6443/${var.record_name}.${var.domain}/g' /etc/rancher/k3s/k3s.yaml > kubeconfig.yaml
aws ssm put-parameter \
  --name ${var.kubeconfig_param_name} \
  --value "$(cat kubeconfig.yaml)" \
  --overwrite
rm kubeconfig.yaml
EOF

  user_data_put_join_command_to_ps = <<-EOF
JOIN_COMMAND="curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${var.k3s_version} K3S_URL=https://${var.record_name}.${var.private_domain}:6443 K3S_TOKEN=\"${random_string.k3s_token.result}\" sh -"
aws ssm put-parameter \
  --name ${var.join_command_param_name} \
  --value "$JOIN_COMMAND" \
  --overwrite
EOF

  user_data_put_new_id_to_ps = <<-EOF
INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
aws ssm put-parameter \
  --name ${var.current_master_id_param_name} \
  --value "$INSTANCE_ID" \
  --overwrite
EOF

  # Adding nodes to cluster is safe, no harm done when node tries to join the cluster again
  user_data_join_nodes = <<-EOF
for id in $(aws autoscaling describe-auto-scaling-instances | jq '.AutoScalingInstances[] | select(.AutoScalingGroupName=="${var.nodes_asg_name}").InstanceId');
do
  INSTANCE_ID=$(echo $id | tr -d '"')
  echo "Sending join command to $INSTANCE_ID"
  aws ssm send-command \
    --document-name "AWS-RunShellScript" \
    --parameters "{\"commands\":[\"curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${var.k3s_version} K3S_URL=https://${var.record_name}.${var.private_domain}:6443 K3S_TOKEN=\\\"${random_string.k3s_token.result}\\\" sh -\"]}" \
    --timeout-seconds 180 \
    --instance-ids "$INSTANCE_ID" \
    --region ${data.aws_region.current.name} \
    --output text
done
EOF
}