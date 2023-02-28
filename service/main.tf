locals {
  name = "dpgg-${terraform.workspace}"
}

resource "aws_cloudwatch_log_group" "this" {
  name_prefix       = "dpgg-"
  retention_in_days = 3
}

resource "aws_ecs_task_definition" "this" {
  family = "${local.name}-task"
  network_mode = "bridge"
  requires_compatibilities = ["EC2"]
  cpu = "1024"
  memory = "512"

  runtime_platform {
    cpu_architecture = "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = <<EOF
  [
    {
      "name": "${local.name}",
      "image": "196347350595.dkr.ecr.ap-northeast-2.amazonaws.com/${local.name}:latest",
      "cpu": 0,
      "portMappings": [
        {
          "containerPort": 3000,
          "hostPort": 80,
          "protocol": "tcp",
          "name":"${local.name}-3000-tcp"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-region": "ap-northeast-2",
          "awslogs-group": "${aws_cloudwatch_log_group.this.name}",
          "awslogs-stream-prefix": "ec2"
        }
      }
    }
  ]
  EOF
}

resource "aws_ecs_service" "this" {
  name = "${local.name}-service"
  cluster = var.cluster_id
  task_definition = aws_ecs_task_definition.this.arn

  desired_count = 1

  deployment_circuit_breaker {
    enable = true
    rollback = true
  }

  deployment_controller {
    type = "ECS"
  }

  deployment_maximum_percent = 200
  deployment_minimum_healthy_percent = 0
}

resource "aws_lb_target_group" "this" {
  deregistration_delay = 300

  health_check {
    enabled             = "true"
    healthy_threshold   = "2"
    interval            = "10"
    matcher             = "200"
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = "5"
    unhealthy_threshold = "2"
  }

  ip_address_type = "ipv4"
  load_balancing_algorithm_type = "round_robin"
  name = "${local.name}-ecs-tg"
  port = "79"
  protocol = "HTTP"
  protocol_version = "HTTP1"
  slow_start = "0"

  stickiness {
    cookie_duration = "86400"
    enabled         = "false"
    type            = "lb_cookie"
  }

  target_type = "instance"
  vpc_id = var.vpc_id
}