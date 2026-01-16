variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "europe-west6"
}

variable "zone" {
  type    = string
  default = "europe-west6-a"
}

variable "instance_name" {
  type    = string
  default = "loadgen-vm"
}

variable "machine_type" {
  type    = string
  default = "e2-medium"
}

variable "frontend_addr" {
  type        = string
  description = "Frontend IP or DNS (without http://)."
}

variable "users" {
  type    = number
  default = 20
}

variable "rate" {
  type    = number
  default = 5
}

variable "duration" {
  type    = string
  default = "2m"
}

variable "export_csv" {
  type    = bool
  default = true
}

variable "enable_locust_ui" {
  type    = bool
  default = false
}

variable "use_spot" {
  type    = bool
  default = true
}
