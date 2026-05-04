# local.tfvars — used for `terraform plan` validation only (never deploy from here)
# All sensitive values are placeholders — real values come from Secrets Manager at deploy time
environment         = "staging"
aws_region          = "us-east-1"
app_image           = "123456789.dkr.ecr.us-east-1.amazonaws.com/contoso-web:latest"
batch_image         = "123456789.dkr.ecr.us-east-1.amazonaws.com/contoso-batch:latest"
vpc_id              = "vpc-placeholder"
private_subnet_ids  = ["subnet-placeholder-a", "subnet-placeholder-b"]
public_subnet_ids   = ["subnet-placeholder-pub-a", "subnet-placeholder-pub-b"]
db_instance_class   = "db.t3.medium"
