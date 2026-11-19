# Plan 04: Code Terraform đầu tiên, mạng và bucket S3 cho backup MySQL

Plan này đưa lên AWS phần Terraform đầu tiên có ích thật: một VPC đúng hình dạng mà bài 16 cần, và một bucket S3 để chứa backup MySQL. Cả hai đi qua pull request, plan, duyệt, apply, bằng bốn workflow Terraform mô tả ở [plan 03](03-trien-khai-oidc-roi-cicd.md#bốn-workflow-terraform-chạy-theo-nhánh-thế-nào). Chưa có cluster nào, nên chưa tốn tiền.

**Trạng thái ngày 20/11/2026:** code đã viết và đã deploy lên `development` bằng pull request #1. Hạ tầng đã được kiểm trên AWS và đạt. Còn một ô chưa chốt: chạy workflow dò lệch, xem [Chốt plan 04](#chốt-plan-04). `production` chưa deploy.

Bản đầu của plan này viết ngày 17/11/2026, trước khi có code. Code thật khác bản đó ở vài điểm, ghi ở mục [Khác bản thiết kế ban đầu ở đâu](#khác-bản-thiết-kế-ban-đầu-ở-đâu). Các mục còn lại mô tả code đang có trong repo.

## Mục lục

- [Những gì đã đối chiếu](#những-gì-đã-đối-chiếu)
- [Khác bản thiết kế ban đầu ở đâu](#khác-bản-thiết-kế-ban-đầu-ở-đâu)
- [Phạm vi](#phạm-vi)
- [1. Từ bản thiết kế VPC sang Terraform](#1-từ-bản-thiết-kế-vpc-sang-terraform)
- [2. Bố cục code](#2-bố-cục-code)
- [3. Module `network`](#3-module-network)
- [4. Module `mysql-backup`](#4-module-mysql-backup)
- [5. Hai bucket S3 của dự án khác nhau thế nào](#5-hai-bucket-s3-của-dự-án-khác-nhau-thế-nào)
- [6. Nối vào `envs/_shared` và hai thư mục env](#6-nối-vào-envs_shared-và-hai-thư-mục-env)
- [7. Triển khai và kiểm chứng](#7-triển-khai-và-kiểm-chứng)
- [8. Thử dò lệch trên tài nguyên thật](#8-thử-dò-lệch-trên-tài-nguyên-thật)
- [9. Dọn](#9-dọn)
- [10. Quyết định còn mở](#10-quyết-định-còn-mở)
- [11. Sau plan này](#11-sau-plan-này)
- [Nguồn](#nguồn)

## Những gì đã đối chiếu

Ngày **17/11/2026**, trước khi có code:

- Bản thiết kế [`thiet-ke-vpc-public-subnet-theo-runbook-bai16.md`](https://github.com/hieupham259/DevOps-Projects-with-Kubernetes-on-AWS/blob/master/Section%202/bai16-mysql-operator/thiet-ke-vpc-public-subnet-theo-runbook-bai16.md) trong repo khoá học, mục 1, 2, 3 và 9.
- [Runbook bài 16](https://github.com/hieupham259/DevOps-Projects-with-Kubernetes-on-AWS/blob/master/Section%202/bai16-mysql-operator/runbook-mysql-operator.md), bước 2 (tạo bucket) và bước 3 (policy của IAM user).
- Tài liệu EKS về yêu cầu VPC và subnet; tài liệu eksctl về VPC mặc định.

Ngày **20/11/2026**, sau khi viết code và deploy:

- `terraform fmt -check -recursive`, `scripts/verify-envs-in-sync.sh` và `terraform validate` cho cả hai thư mục env đều qua trên máy, với AWS provider 6.73.0.
- `terraform plan` chạy trên máy với state cục bộ, chỉ đọc AWS, ra `Plan: 11 to add, 0 to change, 0 to destroy.` cho mỗi môi trường.
- Pull request #1, từ `master` vào `development`, đã merge. Lần chạy #1 của workflow **Terraform Apply** xanh.
- State của `development` có 11 resource: 7 của mạng, 3 của bucket, 1 SSM parameter.
- Các lệnh kiểm chứng ở mục 7 đã chạy trên AWS; mọi chốt PASS.
- Tên của SSM parameter được đối chiếu với tài liệu `PutParameter` của AWS. Thử bằng lệnh chỉ đọc `get-parameters-by-path`: dịch vụ từ chối đường dẫn `/aws-eks-mysql-platform`, và nhận `/development/aws-eks-mysql-platform`.
- **Chưa làm:** chạy workflow dò lệch sau khi deploy; bài thử dò lệch ở mục 8; deploy `production`.

## Khác bản thiết kế ban đầu ở đâu

| | Bản thiết kế 17/11/2026 | Code đã deploy |
|---|---|---|
| Khung của module | chia file theo mối quan tâm: `vpc.tf`, `networking.tf` | theo dự án mẫu: `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` |
| Tên module bucket | `mysql-backup-bucket` | `mysql-backup` |
| Chọn zone | ghi rõ hai zone trong tfvars, có `precondition` chặn `use1-az3` | module tự lấy hai zone đầu tiên AWS trả về |
| Dải của subnet | `/19` | `/20` |
| Route ra Internet Gateway | một `aws_route` riêng | khai ngay trong `aws_route_table` |
| Tag `kubernetes.io/role/elb` trên subnet | có | không có |
| Parameter thử CI/CD (canary) | giữ | đã gỡ |
| Tên bucket và SSM parameter | ghép ở `envs/_shared` | ghép trong module `mysql-backup` |
| Đường dẫn của SSM parameter | `/<project>/<environment>/...` | `/<environment>/<project>/...` |
| `force_destroy` của bucket | `false` mặc định, `true` riêng cho `development` | `true` mặc định, cho mọi môi trường |
| Số resource | 13 | 11 |
| Số pull request | hai: mạng trước, bucket sau | một, chứa cả hai |

Ba dòng cần lời giải thích:

- **Đường dẫn SSM đổi vì AWS bắt buộc.** Parameter Store từ chối mọi tên bắt đầu bằng `aws` hoặc `ssm`, mà tên dự án là `aws-eks-mysql-platform`. Với đường dẫn cũ, plan vẫn qua nhưng apply lỗi sau khi bucket đã được tạo.
- **13 thành 11** vì canary bị gỡ (bớt 1), và route ra Internet Gateway không còn là một resource riêng (bớt 1).
- **`/20` không ảnh hưởng bài 16.** Mỗi subnet vẫn có hơn 4.000 địa chỉ. Đừng đổi lại `/19` sau khi đã deploy: đổi dải là thay cả hai subnet.

## Phạm vi

| Làm trong plan này | Không làm, thuộc plan sau |
|---|---|
| VPC, hai public subnet, Internet Gateway, route table | cluster EKS, node group, security group của cluster |
| Bucket S3 cho backup, chặn truy cập công khai, mã hoá mặc định | IAM user và policy cho backup, access key, Secret `s3-backup-creds` |
| Ghi tên bucket vào SSM Parameter Store cho các lớp sau đọc | EBS CSI driver, Pod Identity, operator, cụm MySQL |

**Điều kiện trước:** plan 03 đã xong: ba stack nền, ba role, ba Environment.

## 1. Từ bản thiết kế VPC sang Terraform

Bản thiết kế viết cho eksctl: eksctl tự dựng VPC khi tạo cluster. Ở dự án này Terraform dựng VPC trước, cluster đến sau. Việc cần làm là giữ đúng những tính chất mà bản thiết kế dựa vào, không phải chép từng tài nguyên eksctl sinh ra.

| Bản thiết kế quyết định | eksctl làm bằng | Terraform trong plan này |
|---|---|---|
| VPC riêng, `192.168.0.0/16`, bật DNS support và DNS hostnames | mặc định của eksctl | `aws_vpc` với `enable_dns_support = true`, `enable_dns_hostnames = true` |
| Hai AZ ở us-east-1 | eksctl tự chọn | biến `az_count = 2`; module lấy hai zone đầu tiên AWS trả về |
| Worker ở public subnet, mỗi node một public IPv4 | `privateNetworking: false` | hai `aws_subnet` có `map_public_ip_on_launch = true` |
| Ra ngoài qua Internet Gateway | mặc định | `aws_internet_gateway`, và route `0.0.0.0/0` trỏ tới nó |
| Không NAT Gateway | `vpc.nat.gateway: Disable` | không khai `aws_nat_gateway`, không khai `aws_eip` |
| Private subnet được tạo kèm nhưng không dùng | mặc định | không tạo |
| Giữ security group do EKS tạo | mặc định | plan này không tạo security group nào |
| Bucket backup riêng, không public, mã hoá AES256 | ba lệnh `aws s3api` ở bước 2 runbook | module `mysql-backup` |

Hai điều kiện mà node của managed node group ở public subnet cần, cả hai do subnet quyết định chứ không phải node group:

- subnet có route mặc định tới Internet Gateway;
- subnet bật tự cấp public IPv4. Managed node group không tự gán public IP cho node.

Thiếu một trong hai thì node không kéo được image và không đăng ký được vào cluster. Vì vậy phần kiểm chứng ở mục 7 kiểm đúng hai điều này.

## 2. Bố cục code

```text
modules/
├── network/
│   ├── main.tf           # VPC, subnet, Internet Gateway, route table, association
│   ├── variables.tf
│   ├── outputs.tf
│   ├── versions.tf
│   └── README.md         # bản thiết kế VPC, kèm lý do không có security group và NACL
└── mysql-backup/
    ├── main.tf           # bucket, chặn public, mã hoá, SSM parameter chứa tên bucket
    ├── variables.tf
    ├── outputs.tf
    ├── versions.tf
    └── README.md
envs/
├── _shared/              # gọi hai module
├── development/          # chuyển tiếp biến, terraform.tfvars
└── production/           # main.tf và variables.tf giống hệt development
```

Bố cục lấy từ dự án mẫu: mỗi module có `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`; thư mục `envs/<tên>` chỉ chuyển tiếp biến; code chung nằm ở `envs/_shared`. Nhờ vậy `production` dùng lại đúng code đó, không phải chép.

`versions.tf` của mỗi module chép từ `envs/_shared/versions.tf`: Terraform `>= 1.13.3, < 2.0.0`, provider `hashicorp/aws` bản `~> 6.73`. Bản provider thật sự được dùng nằm trong lock file.

## 3. Module `network`

### Biến

| Biến | Kiểu, mặc định | Ý nghĩa |
|---|---|---|
| `environment` | `string` | tên môi trường; nằm trong tên các tài nguyên |
| `project` | `string` | tên dự án; nằm trong tên của VPC |
| `vpc_cidr` | `string`, `10.0.0.0/16` | dải của VPC. `envs/_shared` truyền vào `192.168.0.0/16` |
| `az_count` | `number`, `2` | số zone, cũng là số public subnet |
| `tags` | `map(string)`, `{}` | tag chung cho các resource |

### Chia dải địa chỉ

VPC `/16` chia thành mười sáu khối `/20`; module dùng hai khối đầu. Mỗi khối có 4.096 địa chỉ, thừa cho 3 node và mọi Pod của bài.

| Khối | Dải | Dùng cho |
|---|---|---|
| 0 | `192.168.0.0/20` | public subnet, zone thứ nhất |
| 1 | `192.168.16.0/20` | public subnet, zone thứ hai |
| 2–15 | `192.168.32.0/20` tới `192.168.240.0/20` | chưa dùng. Private subnet, nếu sau này cần, lấy ở đây |

Công thức: `cidrsubnet(var.vpc_cidr, 4, count.index)`.

### Chọn hai zone

Module hỏi AWS danh sách zone đang `available` của region, rồi dùng `az_count` zone đầu tiên. Ở account của dự án, ngày 20/11/2026, đó là:

| Zone | Zone ID | EKS nhận | Có bán `t3.large` |
|---|---|---|---|
| `us-east-1a` | `use1-az1` | có | có |
| `us-east-1b` | `use1-az2` | có | có |

EKS không nhận subnet ở zone ID `use1-az3`. Ở account này `use1-az3` là `us-east-1e`, không nằm trong hai zone đầu.

Cách chọn tự động có hai điểm yếu, chấp nhận được ở lab:

- **Không có gì chặn `use1-az3`.** Chữ cái của zone ứng với zone vật lý khác nhau ở mỗi account, nên ở account khác `us-east-1a` hoặc `us-east-1b` có thể chính là `use1-az3`.
- **Danh sách zone đổi thì subnet bị thay thế**, kéo theo mọi thứ nằm trong nó.

Trước khi deploy vào một account khác, kiểm tra hai zone đầu tiên của account đó:

```bash
export AWS_REGION=us-east-1
aws ec2 describe-availability-zones --region "${AWS_REGION}" \
  --filters Name=opt-in-status,Values=opt-in-not-required \
  --query 'AvailabilityZones[].[ZoneName, ZoneId, State]' --output text | sort; echo "exit=${PIPESTATUS[0]}"
aws ec2 describe-instance-type-offerings --region "${AWS_REGION}" \
  --location-type availability-zone --filters Name=instance-type,Values=t3.large \
  --query 'InstanceTypeOfferings[].Location' --output text; echo "exit=$?"
```

**PASS:** hai lệnh `exit=0`. Hai dòng đầu của lệnh thứ nhất không mang `use1-az3`, và tên zone của chúng có mặt trong kết quả của lệnh thứ hai.

**STOP khi** một trong hai zone đầu là `use1-az3` hoặc không bán `t3.large`. Khi đó phải sửa module để ghi rõ zone, xem mục 10.

### Resource

Bảy resource:

| Resource | Số lượng | Ghi chú |
|---|---|---|
| `aws_vpc.this` | 1 | bật hai thuộc tính DNS; tag `Name = <project>-<environment>-vpc` |
| `aws_subnet.public` | 2 | `map_public_ip_on_launch = true`; tag `Name = <environment>-public-<zone>` |
| `aws_internet_gateway.this` | 1 | gắn vào VPC; tag `Name = <environment>-igw` |
| `aws_route_table.public` | 1 | một bảng dùng chung cho hai subnet, có sẵn route `0.0.0.0/0` tới Internet Gateway; tag `Name = <environment>-rt-public` |
| `aws_route_table_association.public` | 2 | mỗi subnet một cái |

- **Route được khai ngay trong `aws_route_table`.** Đừng thêm `aws_route` riêng cho cùng bảng: Terraform không cho dùng lẫn hai cách trên một route table.
- **`aws_vpc`, `aws_internet_gateway` và `aws_route_table` mang `count = 1`**, dấu vết của khung dự án mẫu. Vì vậy địa chỉ của chúng trong state có `[0]`, ví dụ `module.stack.module.network.aws_vpc.this[0]`.
- **Subnet không có tag `kubernetes.io/role/elb`.** Bài 16 không tạo load balancer nên chưa cần.
- **Không khai security group, NACL hay DHCP options.** Module giữ mặc định của VPC; lý do ghi ở [README của module](../modules/network/README.md).
- **Tag `Project`, `Environment`, `ManagedBy` được gắn hai lần** với cùng giá trị: một lần từ `default_tags` của provider, một lần từ `local.common_tags` mà `_shared` truyền vào biến `tags`.

### Output

| Output | Giá trị | Ai dùng |
|---|---|---|
| `vpc_id` | ID của VPC | lớp cluster |
| `vpc_cidr` | dải của VPC | tham khảo |
| `public_subnet_ids` | danh sách ID, cùng thứ tự với `azs` | cluster và node group |
| `azs` | các zone đang dùng | ghép zone với subnet |

Chưa output nào được đưa ra khỏi `envs/_shared`, và chưa có SSM parameter nào cho VPC ID hay subnet ID. Lớp cluster cần các giá trị này; xem mục 10.

## 4. Module `mysql-backup`

Module làm ba việc của bước 2 runbook bài 16, và thêm một SSM parameter chứa tên bucket:

| Lệnh ở bước 2 runbook | Resource Terraform | Thiết lập |
|---|---|---|
| `aws s3api create-bucket` | `aws_s3_bucket.this` | tên `<project>-<environment>-mysql-backup-<account ID>`; `force_destroy = var.force_destroy` |
| `aws s3api put-public-access-block` | `aws_s3_bucket_public_access_block.this` | cả bốn cờ là `true` |
| `aws s3api put-bucket-encryption` | `aws_s3_bucket_server_side_encryption_configuration.this` | `sse_algorithm = "AES256"`, `bucket_key_enabled = true` |
| không có trong runbook | `aws_ssm_parameter.bucket_name` | `/<environment>/<project>/mysql-backup/bucket_name`, giá trị là tên bucket |

| Biến | Kiểu, mặc định | Ý nghĩa |
|---|---|---|
| `project` | `string` | tên dự án; nằm trong tên bucket và đường dẫn của parameter |
| `environment` | `string` | tên môi trường; nằm trong tên bucket và đường dẫn của parameter |
| `force_destroy` | `bool`, `true` | cho `terraform destroy` xoá bucket cùng mọi backup bên trong |
| `tags` | `map(string)`, `{}` | tag chung cho các resource |

| Output | Ai dùng |
|---|---|
| `bucket_name` | file values của cụm MySQL (dòng `bucket:`), lệnh kiểm tra backup |
| `bucket_arn` | policy của IAM user backup |
| `bucket_name_parameter` | tên của SSM parameter chứa tên bucket |

- **Tên bucket được ghép trong module.** Module tự hỏi AWS account ID lúc chạy, nên tên bucket không nằm trong repo. Tên của `development` dài 60 ký tự, dưới giới hạn 63; dài quá thì plan dừng với một thông báo lỗi.
- **Đường dẫn của parameter bắt đầu bằng tên môi trường.** Lý do ở mục [Khác bản thiết kế ban đầu ở đâu](#khác-bản-thiết-kế-ban-đầu-ở-đâu).
- **SSM parameter là cách các lớp sau lấy tên bucket** mà không cần quyền đọc state.
- **`force_destroy` đang mặc định `true` cho mọi môi trường**, kể cả `production`. Bucket bị xoá cùng mọi backup khi destroy. Trước khi deploy `production`, xem mục 10.
- **Cố ý không thêm** versioning, bucket policy, lifecycle hay mã hoá KMS, để backup và restore chạy đúng như bài. Mỗi thứ là một lần siết hợp lý về sau, nhưng cũng là một biến số mới khi backup lỗi.

## 5. Hai bucket S3 của dự án khác nhau thế nào

Dự án có hai bucket. Chúng trông giống nhau trên Console nhưng khác nhau ở mọi điểm đáng kể.

| | Bucket state | Bucket backup MySQL |
|---|---|---|
| Chứa gì | file state của Terraform | các mảnh backup do XtraBackup đẩy lên |
| Ai tạo | CloudFormation, `bootstrap/02-tfstate-backend.yaml`, qua workflow Bootstrap | Terraform, module `mysql-backup`, qua workflow apply |
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

## 6. Nối vào `envs/_shared` và hai thư mục env

`envs/_shared/main.tf`:

```hcl
locals {
  common_tags = merge(var.tags, {
    Environment = var.environment
    Project     = var.project
    ManagedBy   = "terraform"
  })
}

module "network" {
  source = "../../modules/network"

  environment = var.environment
  tags        = local.common_tags
  project     = var.project
  vpc_cidr    = var.vpc_cidr
}
module "mysql_backup" {
  source = "../../modules/mysql-backup"

  environment = var.environment
  tags        = local.common_tags
  project     = var.project
}
```

Biến của `envs/_shared`:

| Biến | Kiểu, mặc định | Giá trị đến từ |
|---|---|---|
| `project` | `string` | `terraform.tfvars` của thư mục env |
| `environment` | `string` | `terraform.tfvars` của thư mục env |
| `region` | `string` | `terraform.tfvars` của thư mục env. `_shared` chưa dùng biến này; region của provider đặt ở `providers.tf` |
| `vpc_cidr` | `string`, `192.168.0.0/16` | mặc định của `_shared`; thư mục env không truyền |
| `tags` | `map(string)`, `{}` | mặc định của `_shared` |

- **Hai thư mục env chỉ có ba biến:** `project`, `environment`, `region`. `terraform.tfvars` của mỗi thư mục có đúng ba dòng đó.
- **`main.tf` và `variables.tf` của hai thư mục env giống hệt nhau**, nếu không job `sync-check` đỏ.
- **Hai môi trường chung account không đụng nhau:** tên VPC, tên bucket và đường dẫn SSM đều mang tên môi trường.
- **`envs/_shared/outputs.tf` đang rỗng.** Thư mục env không có `outputs.tf`, như ở dự án mẫu; lớp nào cần giá trị từ bên ngoài Terraform thì đọc SSM parameter.
- **Canary `aws_ssm_parameter.cicd_canary` đã được gỡ** trước lần apply đầu tiên, nên nó chưa từng tồn tại trên AWS.

Không phải sửa workflow nào: `terraform-plan.yaml` và `terraform-apply.yaml` đã theo dõi `modules/**`.

## 7. Triển khai và kiểm chứng

Mỗi thay đổi đi cùng một đường:

1. Tách feature branch từ `development`, sửa code, push, mở pull request vào `development`.
2. Workflow **Terraform Plan** chạy job `sync-check`, rồi job `plan`, và ghi plan thành comment tiêu đề ``Terraform Plan - `development` OK``. Đọc kỹ comment này: đây là bản plan duy nhất bạn thấy trước khi duyệt.
3. Merge. Workflow **Terraform Apply** tự chạy; job `apply` dừng ở **Waiting**. Bấm **Review deployments** → tick `development` → **Approve and deploy**. Job chạy `init`, `plan`, `apply`.

Plan này chỉ deploy `development`. Code của `production` đổi theo trong cùng pull request vì luật `sync-check`, nhưng `production` chỉ nhận thay đổi trên AWS khi có pull request từ `development` vào `production`.

Trước mỗi lần push, trên máy:

```bash
terraform fmt -recursive
terraform -chdir=envs/development init -backend=false
terraform -chdir=envs/development validate
bash scripts/verify-envs-in-sync.sh
```

Phải `init` lại khi có module mới. Các lệnh này không chạm AWS.

File khoá phiên bản provider đã có trong repo, cho cả Linux và Windows. Khi đổi phiên bản provider thì sinh lại, rồi commit cả hai file `.terraform.lock.hcl`:

```bash
terraform -chdir=envs/development init -backend=false
terraform -chdir=envs/development providers lock -platform=linux_amd64 -platform=windows_amd64
cp envs/development/.terraform.lock.hcl envs/production/.terraform.lock.hcl
```

Lệnh `providers lock` ghi thêm mã băm của bản Linux, là hệ điều hành của máy chạy workflow. Hai thư mục env gọi cùng một code với cùng ràng buộc phiên bản, nên dùng chung được một file khoá.

### Lần deploy đầu, ngày 20/11/2026

- **Pull request #1**, từ `master` vào `development`, chứa cả hai module. Code được viết trên `master`, nên lần này không đi qua một feature branch tách từ `development`.
- **Plan:** `Plan: 11 to add, 0 to change, 0 to destroy.` Bảy resource dưới `module.stack.module.network`, bốn dưới `module.stack.module.mysql_backup`. Không có `aws_nat_gateway`, không có `aws_eip`.
- **Apply:** lần chạy #1 của workflow **Terraform Apply** xanh, sau khi duyệt ở Environment `development`.

### Kiểm chứng trên AWS

Các lệnh dưới chỉ đọc. Trong Git Bash trên Windows, chạy `export MSYS_NO_PATHCONV=1` trước; nếu không, Git Bash đổi tên parameter bắt đầu bằng `/` thành đường dẫn Windows. WSL không cần dòng đó.

Mạng, đối chiếu mục 9 của bản thiết kế:

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

**PASS phần mạng:**

- `VPC_ID` là một ID `vpc-...`, đúng một cái.
- Dải là `192.168.0.0/16`; hai dòng thuộc tính DNS đều `True`.
- Đúng hai subnet, ở hai zone khác nhau, zone ID không phải `use1-az3`, dải `192.168.0.0/20` và `192.168.16.0/20`, cột cuối đều `True`.
- Hai route table. Một bảng gắn với hai subnet, có hai route: `192.168.0.0/16` tới `local`, và `0.0.0.0/0` tới một `igw-...`. Bảng còn lại là bảng mặc định của VPC, không gắn subnet nào, chỉ có route `local`.
- Lệnh NAT chỉ in `exit=0`.

**STOP khi** cột `MapPublicIpOnLaunch` là `False`, hoặc bảng gắn với hai subnet thiếu route `0.0.0.0/0`. Thiếu một trong hai thì node của lớp cluster không vào được cluster.

Bucket, dùng lại đúng chốt PASS của bước 2 runbook bài 16:

```bash
BUCKET="$(aws ssm get-parameter --region "${AWS_REGION}" \
  --name "/development/${PROJECT}/mysql-backup/bucket_name" --query Parameter.Value --output text)"
echo "BUCKET=${BUCKET} exit=$?"

aws s3api get-public-access-block --bucket "${BUCKET}" --region "${AWS_REGION}" \
  --query 'PublicAccessBlockConfiguration' --output json; echo "exit=$?"
aws s3api get-bucket-encryption --bucket "${BUCKET}" --region "${AWS_REGION}" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].[ApplyServerSideEncryptionByDefault.SSEAlgorithm, BucketKeyEnabled]' \
  --output text; echo "exit=$?"
aws s3 ls "s3://${BUCKET}/" --region "${AWS_REGION}"; echo "exit=$?"
aws s3api list-buckets --query "Buckets[?contains(Name, 'tfstate') || contains(Name, 'mysql-backup')].Name" --output text
```

**PASS phần bucket:**

- `BUCKET` là `aws-eks-mysql-platform-development-mysql-backup-<account-id>`.
- `get-public-access-block` in bốn dòng đều `true`. `get-bucket-encryption` in `AES256` và `True`. Hai kết quả này trùng với PASS bước 2 của runbook bài 16.
- `aws s3 ls` không in object nào, `exit=0`.
- Lệnh cuối in hai bucket của dự án, tên khác nhau rõ ràng. Nếu account còn bucket state của dự án mẫu thì nó cũng hiện ở đây.

**Kết quả ngày 20/11/2026:** mọi chốt ở trên đều đạt. Hai subnet nằm ở `us-east-1a` (`use1-az1`) và `us-east-1b` (`use1-az2`).

### Chốt plan 04

- [x] Terraform đang quản lý 11 resource ở `development`: 7 của mạng, 3 của bucket, 1 parameter tên bucket. Đếm trong state ngày 20/11/2026.
- [x] Mọi thay đổi đi qua pull request #1. Các lệnh `aws` chạy từ máy trong lúc kiểm chứng đều chỉ đọc.
- [ ] Workflow **Terraform Drift Detection** chạy từ `master` sau khi deploy: job của `development` xanh. Job của `production` còn đỏ cho tới khi `production` được deploy.
- [x] `master` và `development` có cùng nội dung. Code đi từ `master` vào `development` qua pull request #1, nên không cần pull request theo chiều ngược lại.

Ô còn lại làm thế này: **Actions → Terraform Drift Detection → Run workflow** → nhánh `master`. Nếu đã Disable workflow này ở plan 03 thì bật lại trước. Lần chạy theo lịch lúc 01:00 ngày 20/11/2026 diễn ra trước khi apply xong, nên không tính.

Job dò lệch chạy `terraform plan` cho từng môi trường bằng role chỉ đọc. Xanh nghĩa là AWS đang đúng như code; đỏ nghĩa là có thứ lệch, hoặc môi trường chưa được deploy.

## 8. Thử dò lệch trên tài nguyên thật

Bài thử này chưa làm. Nó cố ý sửa tay một tài nguyên, để thấy workflow dò lệch bắt được.

Tắt đúng thuộc tính mà bản thiết kế dựa vào, trên một subnet:

```bash
SUBNET_ID="$(aws ec2 describe-subnets --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" --query 'Subnets[0].SubnetId' --output text)"
aws ec2 modify-subnet-attribute --region "${AWS_REGION}" --subnet-id "${SUBNET_ID}" --no-map-public-ip-on-launch
echo "exit=$?"
```

**Actions → Terraform Drift Detection → Run workflow** → nhánh `master`.

**PASS phần phát hiện:** job của `development` đỏ; log của bước plan ghi một subnet `will be updated in-place` với `map_public_ip_on_launch` đổi từ `false` về `true`, và `Plan: 0 to add, 1 to change, 0 to destroy.`

Đưa về đúng code. Code không đổi nên không có gì để merge, mà workflow apply chỉ chạy khi có push. Cho chạy lại lần apply gần nhất: **Actions → Terraform Apply** → lần chạy mới nhất của nhánh `development` → **Re-run all jobs** → duyệt. Cách này lấy từ tài liệu GitHub, chưa được thử ở repo này. Chạy lại drift.

**PASS:** job dò lệch của `development` xanh; lệnh `describe-subnets` ở mục 7 in lại `True` cho cả hai subnet.

Lệch kiểu này khi đã có cluster thì không ồn ào: node cũ vẫn chạy, chỉ node mới không có public IP và không vào được cluster. Dò lệch hằng ngày là thứ bắt được nó trước khi một node bị thay.

## 9. Dọn

Tài nguyên của plan này không tốn tiền khi để yên: VPC, subnet, Internet Gateway và route table miễn phí; bucket rỗng không mất phí lưu trữ. Không cần dọn giữa các buổi.

Khi muốn dọn cả môi trường: **Actions → Terraform Destroy → Run workflow** → **Use workflow from** `development`, ô môi trường chọn `development`, ô xác nhận gõ `destroy`. Job `destroy` chờ duyệt ở Environment `development`.

- **Bucket bị xoá cùng mọi backup bên trong, không hỏi lại**, vì `force_destroy` đang là `true`. Workflow destroy không có bước xem trước, nên hãy kiểm bucket bằng `aws s3 ls` trước khi bấm chạy.
- **Nếu đổi `force_destroy` thành `false`** mà bucket còn object, destroy dừng ở bucket với lỗi `BucketNotEmpty`. Các resource khác đã bị xoá vẫn bị xoá. Dọn object rồi chạy lại.
- **Nếu đã có cluster trong VPC này**, xoá cluster trước. Subnet còn máy và card mạng của cluster thì AWS từ chối xoá.

**PASS dọn:** job `destroy` in `Destroy complete! Resources: 11 destroyed.` Hai lệnh `describe-vpcs` và `list-buckets` ở mục 7 không còn in VPC và bucket backup. Bucket state vẫn còn, đúng như thiết kế.

## 10. Quyết định còn mở

Trạng thái sau lần deploy ngày 20/11/2026:

| # | Câu hỏi | Trạng thái | Ghi chú |
|---|---|---|---|
| 1 | Có tạo hai private subnet như eksctl không? | đã chốt: không tạo | bản thiết kế ghi rõ chúng không được dùng và không có NAT phục vụ. Còn 14 khối `/20` trống nếu sau này cần |
| 2 | Tên bucket theo kiểu dự án, hay `dop-mysql-backup-<8 ký tự>` như runbook? | đã chốt: theo kiểu dự án | tên đoán được từ môi trường, không cần file biến trên máy. Hệ quả: các lệnh dò "còn sót" của runbook bài 16 tìm theo tiền tố `dop-mysql-backup-` sẽ không thấy bucket này; việc dọn do Terraform lo |
| 3 | `force_destroy` của bucket | đang `true` cho mọi môi trường | hợp với `development`, môi trường lab phải dọn được bằng một workflow. **Còn mở cho `production`:** muốn `false` ở đó thì phải thêm một biến đi qua `_shared` và hai thư mục env, làm trước khi deploy `production` |
| 4 | Giữ hay bỏ parameter thử CI/CD? | đã chốt: bỏ | pipeline giờ được thử bằng chính hạ tầng thật |
| 5 | Tên cluster: `basic-cluster` như bản thiết kế, hay theo tên dự án? | chưa chốt | mạng và bucket không mang tên cluster. Đặt `basic-cluster` thì chạy được nguyên văn các lệnh của runbook bài 16, nhưng không thể tồn tại cùng lúc với cluster dùng chung của khoá học trong cùng account |
| 6 | Zone: để module tự lấy, hay ghi rõ? | đang để tự lấy | ghi rõ hai zone trong tfvars và thêm `precondition` chặn `use1-az3` thì an toàn hơn khi đổi account. Đổi cách chọn mà vẫn ra đúng hai zone hiện tại thì subnet không bị thay |
| 7 | Tag `kubernetes.io/role/elb` trên public subnet | chưa có | cần khi một bài tạo load balancer. Thêm tag không thay subnet |
| 8 | Lớp cluster lấy VPC ID và subnet ID từ đâu? | chưa chốt | thêm SSM parameter trong module `network`, hoặc tra theo tag `Name` lúc chạy lệnh. Cũng là quyết định số 9 trong [README](../README.md#quyết-định-còn-mở) |

## 11. Sau plan này

Các lớp tiếp theo làm theo mục [Thiết kế chung](../README.md#thiết-kế-chung-phần-nào-bằng-iac-phần-nào-bằng-manifest-và-lệnh) của README. Mặc định, từ cluster trở đi không đi qua pipeline này nữa: chúng là manifest và lệnh gõ trên máy, theo hai runbook của khoá học.

1. **Cluster và node group** trên hai public subnet này, bằng `cluster.yaml` và `eksctl create cluster`: Kubernetes 1.36, một managed node group 3 × `t3.large`, API endpoint public. `cluster.yaml` phải trỏ vào VPC và hai subnet của plan này. Từ đây môi trường bắt đầu tốn tiền theo giờ.
2. **Add-on** Pod Identity Agent và EBS CSI driver, bằng `addons.yaml` và `eksctl create addon`: StorageClass mặc định, tag cho ổ EBS.
3. **IAM user, policy và access key của backup**, bằng lệnh như bước 3 runbook bài 16, giới hạn vào bucket của plan này. Tên bucket đọc từ SSM parameter.
4. **MySQL:** Percona Operator rồi cụm `shop`, theo đúng thứ tự phụ thuộc của bài 16.
5. **Kiểm chứng vận hành và dọn:** kết nối, ghi đọc, giữ dữ liệu, failover, backup, restore.

README còn mô tả một phương án tuỳ chọn, đưa cluster, add-on và IAM vào Terraform. Chọn phương án đó thì ba bước đầu đi qua pipeline này, mỗi lớp một plan riêng.

## Nguồn

- Bản thiết kế VPC và runbook bài 16 trong repo khoá học, đã dẫn ở đầu plan.
- AWS, [View Amazon EKS networking requirements for VPC and subnets](https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html): cần subnet ở ít nhất hai AZ; không nhận zone `use1-az3`; public subnet chứa node phải tự cấp public IPv4; tag `kubernetes.io/role/elb`.
- eksctl, [VPC Configuration](https://docs.aws.amazon.com/eks/latest/eksctl/vpc-configuration.html): VPC mặc định `192.168.0.0/16` chia tám khối `/19`; ở us-east-1 chỉ tạo hai public và hai private subnet; managed node group không tự gán public IPv4; cách dùng một VPC có sẵn.
- AWS Systems Manager, [PutParameter](https://docs.aws.amazon.com/systems-manager/latest/APIReference/API_PutParameter.html): tên parameter không được bắt đầu bằng `aws` hoặc `ssm`.
- Terraform Registry, [`hashicorp/aws`](https://registry.terraform.io/providers/hashicorp/aws/latest): bản 6.73.0 phát hành 11/11/2026.
