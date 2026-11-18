# Plan 04: Code Terraform đầu tiên, mạng và bucket S3 cho backup MySQL

Plan này viết phần Terraform đầu tiên có ích thật: một VPC đúng hình dạng mà bài 16 cần, và một bucket S3 để chứa backup MySQL. Cả hai được đưa lên AWS qua pull request, plan, duyệt, apply, bằng bốn workflow Terraform mô tả ở [plan 03](03-trien-khai-oidc-roi-cicd.md#bốn-workflow-terraform-chạy-theo-nhánh-thế-nào). Đây là lần đầu các workflow đó chạy thật. Chưa có cluster nào, nên chưa tốn tiền.

Plan này mô tả code phải viết, chưa kèm file code. Các đoạn HCL bên dưới là phần khó sai nhất của thiết kế, chép vào đúng file được.

## Mục lục

- [Những gì đã đối chiếu](#những-gì-đã-đối-chiếu)
- [Phạm vi](#phạm-vi)
- [1. Từ bản thiết kế VPC sang Terraform](#1-từ-bản-thiết-kế-vpc-sang-terraform)
- [2. Bố cục code](#2-bố-cục-code)
- [3. Module `network`](#3-module-network)
- [4. Module `mysql-backup-bucket`](#4-module-mysql-backup-bucket)
- [5. Hai bucket S3 của dự án khác nhau thế nào](#5-hai-bucket-s3-của-dự-án-khác-nhau-thế-nào)
- [6. Nối vào `envs/_shared` và `envs/development`](#6-nối-vào-envs_shared-và-envsdevelopment)
- [7. Thứ tự triển khai](#7-thứ-tự-triển-khai)
- [8. Thử dò lệch trên tài nguyên thật](#8-thử-dò-lệch-trên-tài-nguyên-thật)
- [9. Dọn](#9-dọn)
- [10. Quyết định còn mở](#10-quyết-định-còn-mở)
- [11. Sau plan này](#11-sau-plan-này)
- [Nguồn](#nguồn)

## Những gì đã đối chiếu

Ngày **17/11/2026**:

- Bản thiết kế [`thiet-ke-vpc-public-subnet-theo-runbook-bai16.md`](https://github.com/hieupham259/DevOps-Projects-with-Kubernetes-on-AWS/blob/master/Section%202/bai16-mysql-operator/thiet-ke-vpc-public-subnet-theo-runbook-bai16.md) trong repo khoá học, mục 1, 2, 3 và 9.
- [Runbook bài 16](https://github.com/hieupham259/DevOps-Projects-with-Kubernetes-on-AWS/blob/master/Section%202/bai16-mysql-operator/runbook-mysql-operator.md), bước 2 (tạo bucket) và bước 3 (policy của IAM user).
- Code Terraform ở `Section 1/Resources/Resources/terraform_kubeadm` của repo khoá học, để lấy cách chia file.
- Tài liệu EKS về yêu cầu VPC và subnet; tài liệu eksctl về VPC mặc định.
- Các đoạn HCL trong plan đã qua `terraform fmt -check` và `terraform validate` trên một bản nháp, với AWS provider 5.100.0 có sẵn trong cache của dự án mẫu. Hàm `cidrsubnet` cho đúng bốn dải ghi ở mục 3.
- **Chưa viết vào dự án, chưa chạy thật.** Số resource trong các chốt PASS được đếm từ thiết kế.

## Phạm vi

| Làm trong plan này | Không làm, thuộc plan sau |
|---|---|
| VPC, hai public subnet, Internet Gateway, route table | cluster EKS, node group, security group của cluster |
| Bucket S3 cho backup, chặn truy cập công khai, mã hoá mặc định | IAM user và policy cho backup, access key, Secret `s3-backup-creds` |
| Ghi tên bucket vào SSM Parameter Store cho các lớp sau đọc | EBS CSI driver, Pod Identity, operator, cụm MySQL |

**Điều kiện trước:** plan 03 đã PASS tới bước 8. Terraform chưa apply lần nào, nên chưa có state và chưa có tài nguyên nào của Terraform trên AWS.

## 1. Từ bản thiết kế VPC sang Terraform

Bản thiết kế viết cho eksctl: eksctl tự dựng VPC khi tạo cluster. Ở dự án này Terraform dựng VPC trước, cluster đến sau. Việc cần làm là giữ đúng những tính chất mà bản thiết kế dựa vào, không phải chép từng tài nguyên eksctl sinh ra.

| Bản thiết kế quyết định | eksctl làm bằng | Terraform trong plan này |
|---|---|---|
| VPC riêng, `192.168.0.0/16`, bật DNS support và DNS hostnames | mặc định của eksctl | `aws_vpc` với `enable_dns_support = true`, `enable_dns_hostnames = true` |
| Hai AZ ở us-east-1 | eksctl tự chọn | biến `availability_zones`, ghi rõ hai zone trong `terraform.tfvars` |
| Worker ở public subnet, mỗi node một public IPv4 | `privateNetworking: false` | hai `aws_subnet` có `map_public_ip_on_launch = true` |
| Ra ngoài qua Internet Gateway | mặc định | `aws_internet_gateway`, và route `0.0.0.0/0` trỏ tới nó |
| Không NAT Gateway | `vpc.nat.gateway: Disable` | không khai `aws_nat_gateway`, không khai `aws_eip` |
| Private subnet được tạo kèm nhưng không dùng | mặc định | không tạo; chỉ giữ chỗ dải địa chỉ |
| Giữ security group do EKS tạo | mặc định | plan này không tạo security group nào |
| Bucket backup riêng, không public, mã hoá AES256 | ba lệnh `aws s3api` ở bước 2 runbook | module `mysql-backup-bucket` |

Hai điều kiện mà node của managed node group ở public subnet cần, cả hai do subnet quyết định chứ không phải node group:

- subnet có route mặc định tới Internet Gateway;
- subnet bật tự cấp public IPv4. Managed node group không tự gán public IP cho node.

Thiếu một trong hai thì node không kéo được image và không đăng ký được vào cluster. Vì vậy phần kiểm chứng ở mục 7 kiểm đúng hai điều này.

## 2. Bố cục code

```text
modules/
├── network/
│   ├── versions.tf
│   ├── variables.tf
│   ├── vpc.tf            # aws_vpc
│   ├── networking.tf     # subnet, Internet Gateway, route table, route, association
│   └── outputs.tf
└── mysql-backup-bucket/
    ├── versions.tf
    ├── variables.tf
    ├── main.tf           # bucket, chặn public, mã hoá
    └── outputs.tf
envs/
├── _shared/              # sửa: gọi hai module, thêm biến, thêm output, thêm SSM parameter
├── development/          # sửa: chuyển tiếp biến, thêm giá trị vào terraform.tfvars
└── production/           # sửa y hệt development ở main.tf và variables.tf; thêm giá trị vào terraform.tfvars
```

Hai nguồn, mỗi nguồn lấy một thứ:

- **Từ `Section 1/Resources`:** một module chia file theo mối quan tâm (`vpc.tf`, `networking.tf`, `variables.tf`, `outputs.tf`, `versions.tf`).
- **Từ dự án mẫu:** thư mục `envs/<tên>` chỉ chuyển tiếp biến, code chung nằm ở `envs/_shared`, module tái dùng nằm ở `modules/`. Nhờ vậy `production` dùng lại đúng code đó, không phải chép.

Mỗi `versions.tf` của module khai `required_providers` với `aws` nguồn `hashicorp/aws`, phiên bản `>= 6.73, < 7.0`. Ràng buộc chính xác đã nằm ở thư mục env và trong lock file.

## 3. Module `network`

### Biến

| Biến | Kiểu | Ý nghĩa |
|---|---|---|
| `name_prefix` | `string` | tiền tố tên tài nguyên, `<project>-<environment>` |
| `vpc_cidr` | `string` | dải của VPC; kiểm tra bằng `can(cidrnetmask(...))` |
| `availability_zones` | `list(string)` | đúng hai zone khác nhau |

### Chia dải địa chỉ

VPC `/16` chia thành tám khối `/19`, cùng cỡ với cách eksctl chia mặc định. Mỗi khối có khoảng 8.000 địa chỉ, thừa cho 3 node và mọi Pod của bài.

| Khối | Dải | Dùng cho |
|---|---|---|
| 0 | `192.168.0.0/19` | public subnet, zone thứ nhất trong danh sách |
| 1 | `192.168.32.0/19` | public subnet, zone thứ hai |
| 2 | `192.168.64.0/19` | giữ chỗ: private subnet, zone thứ nhất |
| 3 | `192.168.96.0/19` | giữ chỗ: private subnet, zone thứ hai |
| 4–7 | `192.168.128.0/17` | chưa dùng |

Công thức: `cidrsubnet(var.vpc_cidr, 3, <vị trí của zone trong danh sách>)`.

### Chọn hai zone

Ghi rõ hai zone trong `terraform.tfvars`, không để Terraform tự lấy "hai zone đầu tiên". Danh sách zone AWS trả về có thể đổi theo thời gian; subnet đổi zone là subnet bị thay thế, kéo theo mọi thứ nằm trong nó.

Trước khi chọn, kiểm tra ba điều: zone đang `available`, zone ID không phải `use1-az3` (EKS không nhận subnet ở zone này), và zone có bán `t3.large`.

```bash
export AWS_REGION=us-east-1
aws ec2 describe-availability-zones --region "${AWS_REGION}" \
  --filters Name=opt-in-status,Values=opt-in-not-required \
  --query 'AvailabilityZones[].[ZoneName, ZoneId, State]' --output text; echo "exit=$?"
aws ec2 describe-instance-type-offerings --region "${AWS_REGION}" \
  --location-type availability-zone --filters Name=instance-type,Values=t3.large \
  --query 'InstanceTypeOfferings[].Location' --output text; echo "exit=$?"
```

**PASS:** hai lệnh `exit=0`. Chọn hai tên zone có mặt ở cả hai kết quả, và dòng của chúng ở lệnh đầu không mang `use1-az3`. Chữ cái của zone ứng với zone vật lý khác nhau ở mỗi account, nên phải nhìn cột `ZoneId` của chính account này.

Terraform chặn thêm một lần nữa, phòng khi tfvars bị sửa sai về sau:

```hcl
data "aws_availability_zone" "selected" {
  for_each = toset(var.availability_zones)
  name     = each.value
}

resource "aws_subnet" "public" {
  for_each = toset(var.availability_zones)

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.value
  cidr_block              = cidrsubnet(var.vpc_cidr, 3, index(var.availability_zones, each.value))
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.name_prefix}-public-${each.value}"
    "kubernetes.io/role/elb" = "1"
  }

  lifecycle {
    precondition {
      condition     = data.aws_availability_zone.selected[each.value].zone_id != "use1-az3"
      error_message = "EKS does not accept subnets in zone ID use1-az3. Pick another Availability Zone."
    }
  }
}
```

Subnet đánh địa chỉ theo tên zone (`for_each`), không theo số thứ tự (`count`). Đổi thứ tự hay thay một zone thì chỉ subnet của zone đó bị ảnh hưởng.

### Resource

Tám resource:

| Resource | Số lượng | Ghi chú |
|---|---|---|
| `aws_vpc.this` | 1 | tag `Name = <name_prefix>-vpc` |
| `aws_subnet.public` | 2 | như đoạn HCL trên |
| `aws_internet_gateway.this` | 1 | gắn vào VPC |
| `aws_route_table.public` | 1 | một bảng dùng chung cho hai subnet |
| `aws_route.public_internet` | 1 | `0.0.0.0/0` tới Internet Gateway |
| `aws_route_table_association.public` | 2 | `for_each = aws_subnet.public` |

- Tag `kubernetes.io/role/elb = 1` đánh dấu public subnet cho load balancer. Bài 16 không tạo load balancer; tag được đặt sẵn vì không tốn gì và đúng với tài liệu EKS.
- Không khai `aws_default_security_group`, DHCP options hay NACL riêng. Bản thiết kế giữ mặc định của VPC.
- Tag `Project`, `Environment`, `ManagedBy` đến từ `default_tags` của provider, không lặp lại trong module.

### Output

| Output | Giá trị | Ai dùng |
|---|---|---|
| `vpc_id` | ID của VPC | module EKS ở plan sau |
| `vpc_cidr` | dải của VPC | tham khảo |
| `public_subnet_ids` | danh sách ID, theo thứ tự của `availability_zones` | cluster và node group |
| `availability_zones` | hai zone đang dùng | tham khảo |

## 4. Module `mysql-backup-bucket`

Module làm đúng ba việc của bước 2 runbook bài 16, không thêm bớt:

| Lệnh ở bước 2 runbook | Resource Terraform | Thiết lập |
|---|---|---|
| `aws s3api create-bucket` | `aws_s3_bucket.this` | `bucket = var.bucket_name`, `force_destroy = var.force_destroy` |
| `aws s3api put-public-access-block` | `aws_s3_bucket_public_access_block.this` | cả bốn cờ là `true` |
| `aws s3api put-bucket-encryption` | `aws_s3_bucket_server_side_encryption_configuration.this` | `sse_algorithm = "AES256"`, `bucket_key_enabled = true` |

| Biến | Kiểu, mặc định | Ý nghĩa |
|---|---|---|
| `bucket_name` | `string` | tên bucket, duy nhất trên toàn AWS |
| `force_destroy` | `bool`, `false` | cho phép `terraform destroy` xoá bucket cùng mọi backup bên trong |

| Output | Ai dùng |
|---|---|
| `bucket_name` | file values của cụm MySQL (`bucket:`), lệnh kiểm tra backup |
| `bucket_arn` | policy của IAM user backup ở plan sau |

Những thứ cố ý không thêm, để backup và restore chạy đúng như bài: versioning, bucket policy, lifecycle, mã hoá KMS. Mỗi thứ là một lần siết hợp lý về sau, nhưng mỗi thứ cũng là một biến số mới khi backup lỗi.

`force_destroy` mặc định `false`: bucket còn object thì Terraform không xoá được, và đó là lớp bảo vệ tự nhiên cho backup. Riêng `development` đặt `true`, vì đây là môi trường lab phải dọn sạch được bằng một workflow.

## 5. Hai bucket S3 của dự án khác nhau thế nào

Dự án có hai bucket. Chúng trông giống nhau trên Console nhưng khác nhau ở mọi điểm đáng kể.

| | Bucket state | Bucket backup MySQL |
|---|---|---|
| Chứa gì | file state của Terraform | các mảnh backup do XtraBackup đẩy lên |
| Ai tạo | CloudFormation, `bootstrap/02-tfstate-backend.yaml`, qua workflow Bootstrap | Terraform, module `mysql-backup-bucket`, qua workflow apply |
| Tạo bằng role nào | role bootstrap | role apply |
| Tên | `aws-eks-mysql-platform-tfstate-<account-id>` | `aws-eks-mysql-platform-<environment>-mysql-backup-<account-id>` |
| Số lượng | một cho cả account, mỗi môi trường một key | mỗi môi trường một bucket |
| Mã hoá | KMS key riêng | AES256, như bài 16 |
| Versioning | bật | tắt, như bài 16 |
| Bucket policy | cấm kết nối không TLS, cấm upload không mã hoá KMS | không có, như bài 16 |
| Ai đọc ghi lúc chạy | Terraform trong workflow | Pod backup và restore, bằng key của một IAM user chỉ được đụng bucket này |
| Vòng đời | `Retain`: xoá stack vẫn còn. Sống lâu hơn mọi môi trường | sống theo môi trường; `terraform destroy` xoá nó |
| Mất thì sao | Terraform quên hết hạ tầng đang có | mất các bản backup MySQL |

Vì sao không dùng chung một bucket:

- **Gà và trứng.** Terraform cần bucket state trước khi chạy được lệnh đầu tiên, nên bucket đó không thể do chính Terraform này tạo.
- **Quyền.** IAM user của backup có key nằm trong một Secret của cluster. Nếu nó trỏ vào bucket state thì ai đọc được Secret đó đọc được cả state.
- **Vòng đời.** Dọn một môi trường phải xoá được backup của nó mà không đụng tới state của môi trường khác.

## 6. Nối vào `envs/_shared` và `envs/development`

`envs/_shared/main.tf` thêm:

```hcl
data "aws_caller_identity" "current" {}

module "network" {
  source = "../../modules/network"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
}

module "mysql_backup_bucket" {
  source = "../../modules/mysql-backup-bucket"

  bucket_name   = "${local.name_prefix}-mysql-backup-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.mysql_backup_bucket_force_destroy
}

resource "aws_ssm_parameter" "mysql_backup_bucket_name" {
  name        = "/${var.project}/${var.environment}/mysql-backup/bucket_name"
  description = "Name of the S3 bucket that stores MySQL backups."
  type        = "String"
  value       = module.mysql_backup_bucket.bucket_name
}
```

- Tên bucket của `development` dài 60 ký tự, dưới giới hạn 63. Account ID được ghép lúc chạy, không nằm trong repo.
- SSM parameter là cách các lớp sau lấy tên bucket mà không cần quyền đọc state. Dự án mẫu dùng cùng cách này để chuyển giá trị sang repo ứng dụng.
- Giữ nguyên resource `aws_ssm_parameter.cicd_canary` đang có trong `envs/_shared/main.tf`. Nó chưa từng được apply, nên sẽ được tạo cùng pull request đầu tiên.

Biến mới, khai ở `envs/_shared/variables.tf` và ở `variables.tf` của **cả hai** thư mục env, rồi chuyển tiếp trong `main.tf` của cả hai. `main.tf` và `variables.tf` của hai thư mục env phải giống hệt nhau, nếu không job `sync-check` đỏ.

| Biến | Kiểu | Giá trị trong `envs/development/terraform.tfvars` |
|---|---|---|
| `vpc_cidr` | `string` | `"192.168.0.0/16"` |
| `availability_zones` | `list(string)` | hai zone đã chọn ở mục 3 |
| `mysql_backup_bucket_force_destroy` | `bool` | `true` |

`envs/production/terraform.tfvars` nhận cùng ba dòng, để plan của `production` không hỏng vì thiếu giá trị. Tên tài nguyên đã mang tên môi trường, nên hai môi trường chung account không đụng nhau.

Output mới ở `_shared`: `vpc_id`, `public_subnet_ids`, `mysql_backup_bucket_name`. Thư mục env không có `outputs.tf`, như ở dự án mẫu; lớp nào cần giá trị từ bên ngoài Terraform thì đọc SSM parameter.

Không phải sửa workflow nào: `terraform-plan.yaml` và `terraform-apply.yaml` đã theo dõi `modules/**`.

## 7. Thứ tự triển khai

Hai pull request, mỗi cái một lớp. Mỗi pull request đi cùng một đường:

1. Tách feature branch từ `development`, sửa code, push, mở pull request vào `development`.
2. Workflow **Terraform Plan** chạy job `sync-check`, rồi job `plan`, và ghi plan thành comment tiêu đề ``Terraform Plan - `development` OK``. Đọc kỹ comment này: đây là bản plan duy nhất bạn thấy trước khi duyệt.
3. Merge. Workflow **Terraform Apply** tự chạy; job `apply` dừng ở **Waiting**. Bấm **Review deployments** → tick `development` → **Approve and deploy**. Job chạy `init`, `plan`, `apply`.

Plan này chỉ deploy `development`. Code của `production` đổi theo trong cùng pull request vì luật `sync-check`, nhưng `production` chỉ nhận thay đổi trên AWS khi có pull request từ `development` vào `production`.

Trước pull request đầu tiên, sinh file khoá phiên bản provider, một lần, rồi commit cả hai file `.terraform.lock.hcl` cùng pull request đó:

```bash
terraform -chdir=envs/development init -backend=false
terraform -chdir=envs/development providers lock -platform=linux_amd64 -platform=windows_amd64
cp envs/development/.terraform.lock.hcl envs/production/.terraform.lock.hcl
```

Lệnh `providers lock` ghi thêm mã băm của bản Linux, là hệ điều hành của máy chạy workflow. Hai thư mục env gọi cùng một code với cùng ràng buộc phiên bản, nên dùng chung được một file khoá.

Trước mỗi lần push, trên máy:

```bash
terraform fmt -recursive
terraform -chdir=envs/development init -backend=false
terraform -chdir=envs/development validate
bash scripts/verify-envs-in-sync.sh
```

Phải `init` lại vì có module mới. Các lệnh này không chạm AWS.

### Pull request 1: mạng

1. Chạy hai lệnh kiểm tra zone ở mục 3, chọn hai zone.
2. Nhánh `feat/network` tách từ `development`. Viết module `network`, nối vào `_shared`, thêm `vpc_cidr` và `availability_zones` ở cả hai thư mục env.
3. Mở pull request vào `development`.

**PASS phần plan:** comment ghi `Plan: 9 to add, 0 to change, 0 to destroy.` Tám dòng `will be created` nằm dưới `module.stack.module.network`, dòng còn lại là `module.stack.aws_ssm_parameter.cicd_canary`. Không có `aws_nat_gateway`, không có `aws_eip`.

4. Merge, duyệt job `apply`.

**PASS phần apply:** `Apply complete! Resources: 9 added, 0 changed, 0 destroyed.`

Kiểm chứng trên AWS, đối chiếu mục 9 của bản thiết kế:

```bash
export AWS_REGION=us-east-1
export PROJECT=aws-eks-mysql-platform

VPC_ID="$(aws ec2 describe-vpcs --region "${AWS_REGION}" \
  --filters "Name=tag:Name,Values=${PROJECT}-development-vpc" --query 'Vpcs[].VpcId' --output text)"
echo "VPC_ID=${VPC_ID} exit=$?"

aws ec2 describe-vpcs --region "${AWS_REGION}" --vpc-ids "${VPC_ID}" --query 'Vpcs[0].CidrBlock' --output text
aws ec2 describe-vpc-attribute --region "${AWS_REGION}" --vpc-id "${VPC_ID}" \
  --attribute enableDnsSupport --query 'EnableDnsSupport.Value' --output text
aws ec2 describe-vpc-attribute --region "${AWS_REGION}" --vpc-id "${VPC_ID}" \
  --attribute enableDnsHostnames --query 'EnableDnsHostnames.Value' --output text

aws ec2 describe-subnets --region "${AWS_REGION}" --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[].[AvailabilityZone, AvailabilityZoneId, CidrBlock, MapPublicIpOnLaunch]' --output text
aws ec2 describe-route-tables --region "${AWS_REGION}" --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'RouteTables[].{Subnets: Associations[].SubnetId, Routes: Routes[].[DestinationCidrBlock, GatewayId]}' \
  --output json
aws ec2 describe-nat-gateways --region "${AWS_REGION}" --filter "Name=vpc-id,Values=${VPC_ID}" \
  --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text; echo "exit=$?"
```

**PASS pull request 1:**

- `VPC_ID` là một ID `vpc-...`, đúng một cái.
- Dải là `192.168.0.0/16`; hai dòng thuộc tính DNS đều `True`.
- Đúng hai subnet: hai zone đã chọn, zone ID không phải `use1-az3`, dải `192.168.0.0/19` và `192.168.32.0/19`, cột cuối đều `True`.
- Hai route table. Một bảng gắn với hai subnet, có hai route: `192.168.0.0/16` tới `local`, và `0.0.0.0/0` tới một `igw-...`. Bảng còn lại là bảng mặc định của VPC, không gắn subnet nào, chỉ có route `local`.
- Lệnh NAT chỉ in `exit=0`.

**STOP khi** cột `MapPublicIpOnLaunch` là `False`, hoặc bảng gắn với hai subnet thiếu route `0.0.0.0/0`. Thiếu một trong hai thì node của plan sau không vào được cluster.

### Pull request 2: bucket backup

1. Nhánh `feat/mysql-backup-bucket` tách từ `development` sau khi pull request 1 đã apply.
2. Viết module `mysql-backup-bucket`, nối vào `_shared`, thêm SSM parameter, thêm `mysql_backup_bucket_force_destroy` ở cả hai thư mục env.
3. Mở pull request vào `development`.

**PASS phần plan:** `Plan: 4 to add, 0 to change, 0 to destroy.` Ba resource dưới `module.stack.module.mysql_backup_bucket`, và một `module.stack.aws_ssm_parameter.mysql_backup_bucket_name`. Tám resource mạng không xuất hiện trong plan.

4. Merge, duyệt job `apply`.

Kiểm chứng, dùng lại đúng chốt PASS của bước 2 runbook bài 16:

```bash
BUCKET="$(aws ssm get-parameter --region "${AWS_REGION}" \
  --name "/${PROJECT}/development/mysql-backup/bucket_name" --query Parameter.Value --output text)"
echo "BUCKET=${BUCKET} exit=$?"

aws s3api get-public-access-block --bucket "${BUCKET}" --region "${AWS_REGION}" \
  --query 'PublicAccessBlockConfiguration' --output json; echo "exit=$?"
aws s3api get-bucket-encryption --bucket "${BUCKET}" --region "${AWS_REGION}" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].[ApplyServerSideEncryptionByDefault.SSEAlgorithm, BucketKeyEnabled]' \
  --output text; echo "exit=$?"
aws s3 ls "s3://${BUCKET}/" --region "${AWS_REGION}"; echo "exit=$?"
aws s3api list-buckets --query "Buckets[?contains(Name, 'tfstate') || contains(Name, 'mysql-backup')].Name" --output text
```

**PASS pull request 2:**

- `BUCKET` là `aws-eks-mysql-platform-development-mysql-backup-<account-id>`.
- `get-public-access-block` in bốn dòng đều `true`. `get-bucket-encryption` in `AES256` và `True`. Hai kết quả này trùng với PASS bước 2 của runbook bài 16.
- `aws s3 ls` không in object nào, `exit=0`.
- Lệnh cuối in hai bucket của dự án, tên khác nhau rõ ràng. Nếu account còn bucket state của dự án mẫu thì nó cũng hiện ở đây.

### Chốt plan 04

- [ ] Terraform đang quản lý 13 resource ở `development`: 1 parameter thử CI/CD, 8 của mạng, 3 của bucket, 1 parameter tên bucket.
- [ ] Mọi thay đổi đi qua pull request; không lệnh `aws` nào tạo hay sửa tài nguyên từ máy.
- [ ] Workflow **Terraform Drift Detection** chạy từ `master`: job của `development` xanh. Job của `production` còn đỏ cho tới khi `production` được deploy.
- [ ] Đã mở pull request `development` vào `master` và merge.

## 8. Thử dò lệch trên tài nguyên thật

Tắt đúng thuộc tính mà bản thiết kế dựa vào, trên một subnet:

```bash
SUBNET_ID="$(aws ec2 describe-subnets --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" --query 'Subnets[0].SubnetId' --output text)"
aws ec2 modify-subnet-attribute --region "${AWS_REGION}" --subnet-id "${SUBNET_ID}" --no-map-public-ip-on-launch
echo "exit=$?"
```

**Actions → Terraform Drift Detection → Run workflow** → nhánh `master`. Nếu đã Disable workflow này ở plan 03 thì bật lại trước.

**PASS phần phát hiện:** job của `development` đỏ; log của bước plan ghi một subnet `will be updated in-place` với `map_public_ip_on_launch` đổi từ `false` về `true`, và `Plan: 0 to add, 1 to change, 0 to destroy.`

Đưa về đúng code. Code không đổi nên không có gì để merge, mà workflow apply chỉ chạy khi có push. Cho chạy lại lần apply gần nhất: **Actions → Terraform Apply** → lần chạy mới nhất của nhánh `development` → **Re-run all jobs** → duyệt. Cách này lấy từ tài liệu GitHub, chưa được thử ở repo này. Chạy lại drift.

**PASS:** job dò lệch của `development` xanh; lệnh `describe-subnets` ở mục 7 in lại `True` cho cả hai subnet.

Lệch kiểu này khi đã có cluster thì không ồn ào: node cũ vẫn chạy, chỉ node mới không có public IP và không vào được cluster. Dò lệch hằng ngày là thứ bắt được nó trước khi một node bị thay.

## 9. Dọn

Tài nguyên của plan này không tốn tiền khi để yên: VPC, subnet, Internet Gateway và route table miễn phí; bucket rỗng không mất phí lưu trữ. Không cần dọn giữa các buổi.

Khi muốn dọn cả môi trường: **Actions → Terraform Destroy → Run workflow** → **Use workflow from** `development`, ô môi trường chọn `development`, ô xác nhận gõ `destroy`. Job `destroy` chờ duyệt ở Environment `development`.

- Với `mysql_backup_bucket_force_destroy = true`, bucket bị xoá **cùng mọi backup bên trong**, không hỏi lại. Workflow destroy không có bước xem trước, nên hãy kiểm bucket bằng `aws s3 ls` trước khi bấm chạy.
- Nếu đặt `false` mà bucket còn object, destroy dừng ở bucket với lỗi `BucketNotEmpty`. Các resource khác đã bị xoá vẫn bị xoá. Dọn object rồi chạy lại.

**PASS dọn:** job `destroy` in `Destroy complete! Resources: 13 destroyed.` Hai lệnh `describe-vpcs` và `list-buckets` ở mục 7 không còn in VPC và bucket backup. Bucket state vẫn còn, đúng như thiết kế.

## 10. Quyết định còn mở

Mỗi mục có đề xuất. Chốt trước khi viết code.

| # | Câu hỏi | Đề xuất | Lý do |
|---|---|---|---|
| 1 | Có tạo hai private subnet như eksctl không? | Không tạo, chỉ giữ chỗ hai dải | bản thiết kế ghi rõ chúng không được dùng và không có NAT phục vụ. Thêm sau không ảnh hưởng public subnet |
| 2 | Tên bucket theo kiểu dự án, hay `dop-mysql-backup-<8 ký tự>` như runbook? | Theo kiểu dự án | tên đoán được từ môi trường, không cần file biến trên máy. Hệ quả: các lệnh dò "còn sót" của runbook bài 16 tìm theo tiền tố `dop-mysql-backup-` sẽ không thấy bucket này; việc dọn do Terraform lo |
| 3 | `force_destroy` của `development` | `true` | môi trường lab phải dọn được bằng một workflow. Production phải là `false` |
| 4 | Giữ hay bỏ parameter thử CI/CD? | Giữ | nó miễn phí, và là thứ để thử pipeline mà không đụng hạ tầng thật |
| 5 | Tên cluster ở plan EKS: `basic-cluster` như bản thiết kế, hay theo tên dự án? | Chưa cần chốt ở plan này | mạng và bucket không mang tên cluster. Đặt `basic-cluster` thì chạy được nguyên văn các lệnh của runbook bài 16, nhưng không thể tồn tại cùng lúc với cluster dùng chung của khoá học trong cùng account |

## 11. Sau plan này

Thứ tự dự kiến của các lớp tiếp theo, mỗi lớp một plan riêng và đi qua cùng pipeline:

1. EKS và node group trên hai public subnet này: Kubernetes 1.36, một managed node group 3 × `t3.large`, API endpoint public. Từ đây môi trường bắt đầu tốn tiền theo giờ.
2. IAM: role của EBS CSI driver qua Pod Identity; IAM user và policy cho backup, giới hạn vào `bucket_arn` của plan này.
3. Nền tảng: add-on Pod Identity Agent và EBS CSI driver, StorageClass mặc định, tag cho ổ EBS.
4. MySQL: Percona Operator rồi cụm `shop`, theo đúng thứ tự phụ thuộc của bài 16.
5. Kiểm chứng vận hành và dọn: kết nối, ghi đọc, giữ dữ liệu, failover, backup, restore.

Khi có cluster và bucket chứa dữ liệu thật, thêm chốt chặn xoá tài nguyên có dữ liệu, theo ý tưởng `check-state-preservation` của dự án mẫu (plan 02, chặng 5).

## Nguồn

- Bản thiết kế VPC và runbook bài 16 trong repo khoá học, đã dẫn ở đầu plan.
- AWS, [View Amazon EKS networking requirements for VPC and subnets](https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html): cần subnet ở ít nhất hai AZ; không nhận zone `use1-az3`; public subnet chứa node phải tự cấp public IPv4; tag `kubernetes.io/role/elb`.
- eksctl, [VPC Configuration](https://docs.aws.amazon.com/eks/latest/eksctl/vpc-configuration.html): VPC mặc định `192.168.0.0/16` chia tám khối `/19`; ở us-east-1 chỉ tạo hai public và hai private subnet; managed node group không tự gán public IPv4.
- Terraform Registry, [`hashicorp/aws`](https://registry.terraform.io/providers/hashicorp/aws/latest): bản 6.73.0 phát hành 11/11/2026.
