# Module `mysql-backup`

Module này tạo bucket S3 chứa các bản backup của cụm MySQL, và ghi tên bucket vào SSM Parameter Store để các lệnh cài MySQL đọc được.

Nó thay cho ba lệnh `aws s3api` ở bước 2 của [runbook bài 16](https://github.com/hieupham259/DevOps-Projects-with-Kubernetes-on-AWS/blob/master/Section%202/bai16-mysql-operator/runbook-mysql-operator.md). Thiết kế đầy đủ nằm ở mục 4 và 5 của [plan 04](../../plans/04-terraform-networking-va-s3-backup.md).

## Module tạo gì

| Lệnh ở bước 2 runbook | Resource | Thiết lập |
|---|---|---|
| `aws s3api create-bucket` | `aws_s3_bucket.this` | tên `<project>-<environment>-mysql-backup-<account ID>` |
| `aws s3api put-public-access-block` | `aws_s3_bucket_public_access_block.this` | cả bốn cờ là `true` |
| `aws s3api put-bucket-encryption` | `aws_s3_bucket_server_side_encryption_configuration.this` | `AES256`, bật bucket key |
| không có trong runbook | `aws_ssm_parameter.bucket_name` | `/<environment>/<project>/mysql-backup/bucket_name`, giá trị là tên bucket |

Module cố ý không bật versioning, không có lifecycle, bucket policy hay mã hoá KMS, để backup và restore chạy đúng như bài 16.

## Biến

| Biến | Kiểu, mặc định | Ý nghĩa |
|---|---|---|
| `project` | `string` | tên dự án; nằm trong tên bucket và đường dẫn của parameter |
| `environment` | `string` | tên môi trường; nằm trong tên bucket và đường dẫn của parameter |
| `force_destroy` | `bool`, `false` | cho `terraform destroy` xoá bucket cùng mọi backup bên trong |
| `tags` | `map(string)`, `{}` | tag chung cho các resource |

## Output

| Output | Ai dùng |
|---|---|
| `bucket_name` | file values của cụm MySQL (dòng `bucket:`), lệnh kiểm tra backup |
| `bucket_arn` | policy của IAM user backup |
| `bucket_name_parameter` | tên của SSM parameter chứa tên bucket |

## Cách gọi

```hcl
module "mysql_backup" {
  source = "../../modules/mysql-backup"

  project     = var.project
  environment = var.environment
  tags        = local.common_tags
}
```

## Điều cần biết

- **Tên bucket kết thúc bằng account ID.** Module tự lấy account ID lúc chạy, nên tên bucket không nằm trong repo. Tên dài quá 63 ký tự thì plan dừng với thông báo lỗi.
- **`force_destroy` mặc định là `false`.** Bucket còn object thì `terraform destroy` dừng ở bucket với lỗi `BucketNotEmpty`; đó là lớp bảo vệ cho backup. Đặt `true` ở môi trường lab nếu muốn dọn sạch bằng một lần destroy.
- **Đường dẫn của parameter bắt đầu bằng tên môi trường, không phải tên dự án.** Parameter Store từ chối mọi tên bắt đầu bằng `aws` hoặc `ssm`, mà tên dự án là `aws-eks-mysql-platform`. Đặt `/aws-eks-mysql-platform/...` thì plan vẫn qua nhưng apply lỗi.
- **Đọc tên bucket trên máy:**

  ```bash
  aws ssm get-parameter --region us-east-1 \
    --name /development/aws-eks-mysql-platform/mysql-backup/bucket_name \
    --query Parameter.Value --output text
  ```

  Trong Git Bash trên Windows, đặt `MSYS_NO_PATHCONV=1` trước lệnh; nếu không, Git Bash đổi tên bắt đầu bằng `/` thành đường dẫn Windows.
