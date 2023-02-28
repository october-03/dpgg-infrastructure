provider "aws" {
  region = local.region
  profile = "terraform"
}

locals {
  region = "ap-northeast-2"
  name = "dpgg-${terraform.workspace}"
  tags = {
    Name = local.name
    Terraform = "True"
  }

  user_data = <<-EOT
    #!/bin/bash
    cat <<'EOF' >> /etc/ecs/ecs.config
    ECS_CLUSTER=${local.name}-ecs
    ECS_LOGLEVEL=debug
    EOF
  EOT
}

module "ecs" {
  source = "terraform-aws-modules/ecs/aws"

  cluster_name = "${local.name}-ecs"

  cluster_configuration = {
    execute_command_configuration = {
      logging = "OVERRIDE"
      log_configuration = {
        cloud_watch_log_group_name = aws_cloudwatch_log_group.this.name
      }
    }
  }

  autoscaling_capacity_providers = {
    one = {
      auto_scaling_group_arn = module.autoscaling.autoscaling_group_arn

      managed_scaling = {
        maximum_scaling_step_size = 3
        minimum_scaling_step_size = 1
        status                    = "ENABLED"
        target_capacity           = 60
      }

      default_capacity_provider_strategy = {
        weight = 60
        base   = 20
      }
    }
  }

  tags = local.tags
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name = "name"

    values = [
      "amzn2-ami-*-hvm-*-arm64-gp2",
    ]
  }
}

data "aws_ssm_parameter" "ecs_optimized_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/arm64/recommended"
}


module "autoscaling" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 6.5"

  name = "${local.name}-asg"

  security_groups = [module.autoscaling_sg.security_group_id]
  ignore_desired_capacity_changes = true

  image_id = jsondecode(data.aws_ssm_parameter.ecs_optimized_ami.value)["image_id"]
  instance_type = "t4g.small"
  key_name = "dpgg-match"

  user_data = base64encode(local.user_data)
  
  network_interfaces = [
    {
      associate_public_ip_address = true
      delete_on_termination       = true
    }
  ]

  block_device_mappings = [
    {
      device_name = "/dev/xvda"
      ebs = {
        volume_size = 40
        volume_type = "gp2"
      }
    }
  ]

  create_iam_instance_profile = true
  iam_role_name               = local.name
  iam_role_description        = "ECS role for ${local.name}"
  iam_role_policies = {
    AmazonEC2ContainerServiceforEC2Role = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
    AmazonSSMManagedInstanceCore        = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  vpc_zone_identifier = module.vpc.public_subnets
  health_check_type   = "EC2"
  min_size            = 0
  max_size            = 3
  desired_capacity    = 1

  termination_policies = ["OldestInstance"]

  autoscaling_group_tags = {
    ECS = "True"
    Terraform = "True"
  }

  tags = local.tags
}

module "autoscaling_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = local.name
  description = "${local.name}-asg security group"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["https-443-tcp", "http-80-tcp"]

  ingress_with_cidr_blocks = [
    {
      cidr_blocks = "0.0.0.0/0"
      from_port   = 3000
      protocol    = "tcp"
      to_port     = 3000
    },
    {
      cidr_blocks = "121.135.199.128/32"
      from_port   = 22
      protocol    = "tcp"
      to_port     = 22
    }
  ]

  egress_rules = ["all-all"]

  tags = local.tags
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = local.name
  cidr = "10.1.0.0/16"

  azs             = ["${local.region}a", "${local.region}b"]
  public_subnets  = ["10.1.0.0/20", "10.1.16.0/20",]
  private_subnets = ["10.1.128.0/20", "10.1.144.0/20",]

  enable_nat_gateway = false
  single_nat_gateway = false
  enable_dns_hostnames = true
  enable_dns_support = true
  map_public_ip_on_launch = false

  tags = local.tags
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id       = module.vpc.vpc_id
  service_name = "com.amazonaws.ap-northeast-2.s3"

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "this" {
  name = "/aws/ecs/${local.name}"
  retention_in_days = 7

  tags = local.tags
}

module "service" {
  source = "./service"

  cluster_id = module.ecs.cluster_id
  vpc_id = module.vpc.vpc_id
}

resource "aws_lb_target_group" "this" {
  deregistration_delay = "300"

  health_check {
    enabled             = "true"
    healthy_threshold   = "5"
    interval            = "30"
    matcher             = "200"
    path                = "/"
    port                = "80"
    protocol            = "HTTP"
    timeout             = "5"
    unhealthy_threshold = "5"
  }

  name = "${local.name}-tg"
  ip_address_type = "ipv4"
  load_balancing_algorithm_type = "round_robin"
  port = "80"
  protocol = "HTTP"
  protocol_version = "HTTP1"
  slow_start = "0"

  stickiness {
    cookie_duration = "86400"
    enabled         = "false"
    type            = "lb_cookie"
  }

  target_type = "instance"
  vpc_id = module.vpc.vpc_id
}