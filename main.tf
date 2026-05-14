provider "aws" {
  region = "us-east-1"
}

variable "my_ip" {
  type        = string
  description = "My global IP address without /32"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "ec2" {
  name = "ssh_sg"
  
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    security_groups = [aws_security_group.test.id]
  }

  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["${var.my_ip}/32"]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "test" {
  name = "test_sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 443
    to_port = 443
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb_target_group" "app" {
  name = "app-tg"
  port = 80
  protocol = "HTTP"
  vpc_id = data.aws_vpc.default.id

  health_check {
    path = "/health"
    matcher = "200"
  }
}

resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id = aws_instance.simple.id
  port = 80
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port = 80
  protocol = "HTTP"

  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_instance" "simple" {
  ami           = "ami-098e39bafa7e7303d"
  instance_type = "t3.micro"
  key_name      = "test"

  user_data_replace_on_change = true

  user_data = <<-EOF
#!/bin/bash
set -euxo pipefail

exec > >(tee -a /var/log/user-data.log) 2>&1

dnf update -y
dnf install -y python3 python3-pip

mkdir -p /opt/flask-app
cd /opt/flask-app

python3 -m venv venv
source /opt/flask-app/venv/bin/activate

pip install --upgrade pip
pip install flask gunicorn

cat > /opt/flask-app/app.py <<'PY'
from flask import Flask

app = Flask(__name__)

@app.route("/")
def index():
    return "Hello from Flask on EC2 behind ALB!"

@app.route("/health")
def health():
    return "OK", 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
PY

cat > /etc/systemd/system/flask-app.service <<'SERVICE'
[Unit]
Description=Flask App
After=network.target

[Service]
WorkingDirectory=/opt/flask-app
ExecStart=/opt/flask-app/venv/bin/gunicorn -w 2 -b 0.0.0.0:80 app:app
Restart=always
User=root

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable flask-app
systemctl restart flask-app

echo "user_data completed" > /tmp/user_data_done.txt
EOF

  vpc_security_group_ids = [aws_security_group.ec2.id]

  tags = {
    Name = "test_ec2"
  }
}

resource "aws_lb" "app" {
  name = "app-alb"
  internal = false
  load_balancer_type = "application"
  security_groups = [aws_security_group.test.id]
  
  subnets = data.aws_subnets.default.ids
}

resource "aws_cloudfront_distribution" "main" {
  enabled = true
  comment = "CloudFront for ALB origin"

  origin {
    domain_name = aws_lb.app.dns_name
    origin_id = "alb_origin"

    custom_origin_config {
      http_port = 80
      https_port = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id = "alb_origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    forwarded_values {
      query_string = true

      cookies {
        forward = "all"
      }
    }
    min_ttl = 0
    default_ttl = 0
    max_ttl = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

data "aws_route53_zone" "main" {
  name = "${var.root_domain_name}."
  private_zone = false
}

resource "aws_acm_certificate" "alb" {
  domain_name = var.origin.domain.name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
   
  tags {
    Name = "${var.project_name}-alb-cert"
  }
}

resource "aws_route53_record" "alb_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.alb.domain_validation_options :
    dvo.domain_name => {
      name = dvo.resource_record_name
      type = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id = data.aws_route53_zone.main.zone_id
  name = each.value.name
  type = each.value.type
  ttl = 60
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "alb" {
  certificate_arn = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for record in aws_route53_record.alb_cert_validation : record.fqdn]
}

output "ec2_public_ip" {
  value = aws_instance.simple.public_ip
}