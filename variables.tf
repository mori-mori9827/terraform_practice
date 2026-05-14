variable "origin_domain_name" {
  type = string
  description = "ALBに向けるオリジン用ドメイン。例: origin.example.com"
  default = "origin.cloudlaboratory.click"
}

variable "root_domain_name" {
  type    = string
  default = "cloudlaboratory.click"
}

variable "project_name" {
  type        = string
  description = "リソース名のprefixとして使うプロジェクト名"
  default     = "flask-ops-lab"
}