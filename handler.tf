data "aws_ssm_parameter" "current_master_id" {
  name = var.current_master_id_param_name
}

data "aws_ssm_parameter" "current_nlb_id" {
  name = var.current_nlb_id_param_name
}

module "k3s-interruption-handler" {
  source              = "git::https://github.com/PiotrKuligowski/terraform-aws-spot-k3s-interruption-handler.git"
  function_name       = "${var.project}-interruption-handler"
  component           = "interruption-handler"
  project             = var.project
  environment_vars    = local.interruption_handler_env_variables
  policy_statements   = local.interruption_handler_policy_statements
  eventbridge_trigger = local.spot_interruption_event_pattern
  tags                = var.tags
}

locals {
  interruption_handler_env_variables = {
    REGION                       = data.aws_region.current.name
    PROJECT                      = var.project
    CURRENT_MASTER_ID_PARAM_NAME = var.current_master_id_param_name
    CURRENT_NLB_ID_PARAM_NAME    = var.current_nlb_id_param_name
  }

  spot_interruption_event_pattern = <<PATTERN
{
  "detail-type": ["EC2 Spot Instance Interruption Warning"],
  "source": ["aws.ec2"]
}
  PATTERN

  interruption_handler_policy_statements = {
    AllowAttachAndDescribe = {
      effect = "Allow",
      actions = [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DetachInstances",
        "ssm:ListCommandInvocations",
        "ec2:DescribeInstances",
        "ec2:TerminateInstances"
      ]
      resources = ["*"]
    }
    AllowSendCommand = {
      effect  = "Allow",
      actions = ["ssm:SendCommand"]
      resources = [
        "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*",
        "arn:aws:ssm:${data.aws_region.current.name}::document/AWS-RunShellScript"
      ]
    }
    AllowSSM = {
      effect  = "Allow",
      actions = ["ssm:GetParameter"]
      resources = [
        data.aws_ssm_parameter.current_master_id.arn,
        data.aws_ssm_parameter.current_nlb_id.arn
      ]
    }
    AllowLogs = {
      effect    = "Allow",
      actions   = ["logs:*"]
      resources = ["arn:aws:logs:*:*:*"]
    }
  }
}