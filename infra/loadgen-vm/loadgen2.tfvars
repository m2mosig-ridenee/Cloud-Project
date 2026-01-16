project_id       = "m2-cloud-computing-478123"
region           = "europe-west6"
zone             = "europe-west6-a"

instance_name    = "loadgen-vm-2"
machine_type     = "e2-standard-4"

frontend_addr    = "34.65.171.116"
users            = 100
rate             = 20
duration         = "5m"

export_csv       = true
enable_locust_ui = true
use_spot         = true
