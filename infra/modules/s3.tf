variable "bucket_name" { type = string }
variable "environment" { type = string }

resource "aws_s3_bucket" "reports" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_versioning" "reports" {
  bucket = aws_s3_bucket.reports.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access — reports served via pre-signed URLs only
resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "bucket_arn"  { value = aws_s3_bucket.reports.arn }
output "bucket_name" { value = aws_s3_bucket.reports.id }
