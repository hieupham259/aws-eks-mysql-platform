# Chuỗi tin cậy của CI/CD: từ repo trống tới thay đổi hằng ngày

Tài liệu này kể theo thứ tự thời gian vì sao workflow `terraform-plan.yaml` và `terraform-apply.yaml` của repo `aws-eks-mysql-platform` vào được đúng account AWS, bắt đầu từ lúc chưa có gì.

Đây là bản viết lại của `notes/CICD-CHAIN-OF-TRUST.md` trong dự án mẫu [`3-tiers-app-infrastructure`](https://github.com/hieupham259/3-tiers-app-infrastructure/blob/4de50f9b3d740454eb72c6f957fe9bda0380cdee/notes/CICD-CHAIN-OF-TRUST.md?plain=1), theo code thật của repo này tại ngày **17/11/2026**. Khái niệm nền nằm ở [OIDC-GUIDE.md](OIDC-GUIDE.md); lệnh và chốt kiểm tra từng bước nằm ở [plan 03](../plans/03-trien-khai-oidc-roi-cicd.md).

Ký hiệu: **`<tiền tố>`** là `repo:<owner>@<owner_id>/aws-eks-mysql-platform@<repo_id>`, giá trị của biến repo `OIDC_SUBJECT_PREFIX`. `<account-id>` là account AWS.

## Mục lục

- [Khác bản gốc ở đâu](#khác-bản-gốc-ở-đâu)
- [Chuỗi tin cậy ba lớp](#chuỗi-tin-cậy-ba-lớp)
- [Dòng thời gian](#dòng-thời-gian)
- [Hình dung cả chuỗi](#hình-dung-cả-chuỗi)
- [Job nào dùng role nào, role đó từ đâu mà có](#job-nào-dùng-role-nào-role-đó-từ-đâu-mà-có)
- [Mỗi thứ chạy thường xuyên tới đâu](#mỗi-thứ-chạy-thường-xuyên-tới-đâu)
- [Thiếu lớp trên thì lớp dưới hỏng thế nào](#thiếu-lớp-trên-thì-lớp-dưới-hỏng-thế-nào)
- [Job tới đúng account và đúng môi trường bằng cách nào](#job-tới-đúng-account-và-đúng-môi-trường-bằng-cách-nào)
- [Sơ đồ tuần tự: từ merge tới tài nguyên trên AWS](#sơ-đồ-tuần-tự-từ-merge-tới-tài-nguyên-trên-aws)
- [Tóm lại](#tóm-lại)

## Khác bản gốc ở đâu

| Chủ đề | Bản gốc | Bản này |
|---|---|---|
| Số account | hai account, làm mọi bước hai lần | hai môi trường `development` và `production`, account chọn theo nhánh như bản gốc. Hai môi trường chung một account thì mốc 1 và mốc 2 chỉ làm một lần |
| Bước trước trust anchor | không có | mốc 0: lấy hai ID của repo, đặt biến, tạo Environment |
| Trust anchor | upload qua Console | deploy bằng `aws cloudformation deploy` từ máy; dùng lại provider nếu account đã có |
| Dạng `sub` | `repo:<org>/<repo>:...` | `<tiền tố>:...`, có ID của chủ repo và của repo |
| Điều kiện của role apply | ghi là theo nhánh `ref:refs/heads/<nhánh>` | theo Environment: `<tiền tố>:environment:development` và `<tiền tố>:environment:production` |
| Role do bootstrap tạo | bốn role, gồm hai role deploy của repo ứng dụng | hai role: plan và apply |
| Lỗi khi role chưa tồn tại | `NoSuchEntity ... does not exist` | dự kiến là `Not authorized to perform sts:AssumeRoleWithWebIdentity`, giống khi `sub` không khớp; chưa thấy tận mắt ở repo này |
| Region | `ap-southeast-1` | `us-east-1` |

---

## Chuỗi tin cậy ba lớp

```text
+--------------------------------------------------------------------+
| Lớp 0: TRUST ANCHOR (deploy tay, một lần)                          |
|   Tạo: OIDC provider (nếu account chưa có), role bootstrap         |
|   File: bootstrap/01-trust-anchor.yaml                             |
|   Ai chạy: bạn, bằng danh tính admin trên máy                      |
+----------------------------+---------------------------------------+
                             | là nền cho
                             v
+--------------------------------------------------------------------+
| Lớp 1: BOOTSTRAP (workflow bootstrap.yaml)                         |
|   Tạo: bucket S3 và KMS key cho state; role plan; role apply       |
|   File: bootstrap/02-tfstate-backend.yaml                          |
|         bootstrap/03-github-oidc-roles.yaml                        |
|   Ai chạy: GitHub Actions, bằng role bootstrap                     |
+----------------------------+---------------------------------------+
                             | là nền cho
                             v
+--------------------------------------------------------------------+
| Lớp 2: HẠ TẦNG (workflow terraform-*.yaml)                         |
|   Tạo: mọi thứ Terraform quản lý trong envs/<môi trường>           |
|   Ai chạy: GitHub Actions, bằng role plan và role apply            |
+--------------------------------------------------------------------+
```

Mỗi lớp dùng quyền do lớp ngay trên tạo ra. Vì vậy thứ tự là bắt buộc, và chỉ lớp 0 cần một con người có quyền admin.

Dưới lớp 0 còn một lớp nữa mà bản gốc không nói tới: phần thiết lập trên GitHub. Role của lớp 0 và lớp 1 tin vào tên của các Environment, nên Environment phải có luật trước khi role được tạo.

## Dòng thời gian

### Mốc 0: repo có trước, AWS chưa có gì

Plan 03, bước 1 tới 3.

1. Tạo repo public `aws-eks-mysql-platform`, đẩy code lên `main`.
2. Lấy ID của repo và ID của chủ repo từ API công khai của GitHub, rồi ghép thành `<tiền tố>`:

   ```text
   repo:<owner>@<owner_id>/aws-eks-mysql-platform@<repo_id>
   ```
3. Đặt ba biến cấp repo: `DEV_ACCOUNT_ID`, `PROD_ACCOUNT_ID` và `OIDC_SUBJECT_PREFIX`.
4. Tạo ba Environment, cả ba có người duyệt: `bootstrap` (chỉ nhánh `main`), `development` và `production` (mỗi cái chỉ nhận nhánh cùng tên).

Sau mốc 0: GitHub đã sẵn sàng, AWS chưa có gì của dự án. Chưa job nào vào được AWS.

### Mốc 1: trust anchor, bước làm tay duy nhất trên AWS

Plan 03, bước 4.

1. Kiểm tra account đã có OIDC provider của GitHub chưa. Mỗi account chỉ có một.
2. Deploy `bootstrap/01-trust-anchor.yaml` từ máy, bằng danh tính admin, với ba tham số: tên dự án, `<tiền tố>`, và có tạo provider hay không.
3. CloudFormation tạo:
   - OIDC provider, nếu account chưa có;
   - role `aws-eks-mysql-platform-gha-bootstrap`, chỉ nhận `sub` là `<tiền tố>:environment:bootstrap`.

Sau mốc 1: đúng một loại job vào được AWS, là job chạy trong Environment `bootstrap` của repo này.

### Mốc 2: workflow Bootstrap, lần đầu GitHub tự vào AWS

Plan 03, bước 5.

**Bước A: bấm chạy.** Tab Actions → **Bootstrap (CFN - state backend + OIDC roles)** → Run workflow, nhánh `main`, account `development`.

**Bước B: Environment chặn lại.** Job khai `environment: bootstrap`. GitHub kiểm hai luật: nhánh `main` được phép, và cần người duyệt. Job đứng chờ tới khi bạn bấm duyệt.

**Bước C: job vào role bootstrap.**

```yaml
- name: Configure AWS credentials (assume gha-bootstrap)
  uses: aws-actions/configure-aws-credentials@v6
  with:
    role-to-assume: arn:aws:iam::${{ env.ACCOUNT_ID }}:role/aws-eks-mysql-platform-gha-bootstrap
    aws-region: ${{ env.AWS_REGION }}
```

`ACCOUNT_ID` là biến môi trường của job. Nó được chọn theo account bạn bấm lúc chạy, như ở dự án mẫu:

```yaml
ACCOUNT_ID: ${{ inputs.account == 'production' && vars.PROD_ACCOUNT_ID || vars.DEV_ACCOUNT_ID }}
```

Chuyện xảy ra phía sau:

```text
1. GitHub cấp JWT:
     sub: <tiền tố>:environment:bootstrap
     aud: sts.amazonaws.com

2. Action gọi sts:AssumeRoleWithWebIdentity
     RoleArn: arn:aws:iam::<account-id>:role/aws-eks-mysql-platform-gha-bootstrap

3. AWS xét trust policy của role:
     aud == sts.amazonaws.com                       đúng
     sub == <tiền tố>:environment:bootstrap         đúng
   -> trả credentials tạm thời, hạn 1 giờ

4. Job giờ có quyền admin trong account, trong 1 giờ
```

**Bước D: deploy stack state backend.** `bootstrap/02-tfstate-backend.yaml` tạo KMS key với alias `alias/aws-eks-mysql-platform-tfstate`, bucket `aws-eks-mysql-platform-tfstate-<account-id>` (bật versioning, mã hoá KMS, chặn public), và bucket policy cấm kết nối không TLS cùng upload không mã hoá KMS.

**Bước E: đọc output của stack vừa tạo.** Job lấy ARN của bucket và ARN của KMS key.

**Bước F: deploy stack role.** `bootstrap/03-github-oidc-roles.yaml` nhận `<tiền tố>` và hai ARN trên, tạo hai role:

| Role | Quyền | `sub` được nhận |
|---|---|---|
| `aws-eks-mysql-platform-gha-plan` | `ReadOnlyAccess`; đọc state; ghi và xoá lock file; dùng KMS key của state | `<tiền tố>:pull_request`, `<tiền tố>:ref:refs/heads/main` |
| `aws-eks-mysql-platform-gha-apply` | `AdministratorAccess` | `<tiền tố>:environment:development`, `<tiền tố>:environment:production` |

Sau mốc 2: account có chỗ lưu state, và hai role cho Terraform. Workflow Bootstrap chỉ chạy lại khi sửa template 02 hoặc 03, hoặc khi production nằm ở một account khác và account đó cần bộ nền riêng.

Sau mốc này, plan 03 thử đường vào bằng một pull request: merge vào `development` làm workflow `oidc-test.yaml` chạy, vào role apply và in danh tính nhận được (plan 03, bước 7 và 8).

### Mốc 3: thay đổi hằng ngày

Từ plan 04 trở đi. Tới đây mới là việc lặp lại mỗi ngày, và ba mốc trước là lý do nó chạy được.

**Pull request vào `development` hoặc `production`.** `terraform-plan.yaml` chạy. Job `plan` không khai environment và sự kiện là `pull_request`, nên `sub` là `<tiền tố>:pull_request`. Giá trị này nằm trong danh sách của role plan. Job vào được role chỉ đọc vì:

1. provider tồn tại (mốc 1, hoặc có sẵn trong account);
2. role plan tồn tại (mốc 2);
3. `sub` của job khớp một dòng trong trust policy.

**Merge.** `terraform-apply.yaml` chạy. Sau job `sync-check`, chỉ một job vào AWS, như ở dự án mẫu:

| Job | Khai environment | `sub` | Role |
|---|---|---|---|
| `apply` | tên môi trường của nhánh: `development` hoặc `production` | `<tiền tố>:environment:<tên>` | apply |

Job `apply` đứng chờ ở Environment tới khi người duyệt bấm duyệt, rồi mới chạy `init`, `plan` và `apply`.

Một job không chạy trong Environment `development` hay `production` thì không vào được role apply, kể cả khi nó chạy trên nhánh `development`. Điều kiện của role là Environment, không phải nhánh. Việc "chỉ nhánh `development` mới dùng được Environment `development`" do luật nhánh của Environment giữ.

## Hình dung cả chuỗi

```text
                 +------------------------------------+
                 |  Issuer của GitHub                 |
                 |  token.actions.githubusercontent   |
                 |  .com                              |
                 +-----------------+------------------+
                                   | cấp JWT cho mỗi job
                                   v
       +-----------------------------------------------------------+
       |  Một job trên máy của GitHub                              |
       |  JWT: sub = <tiền tố>:<ngữ cảnh>, aud = sts.amazonaws.com |
       +----------------------------+------------------------------+
                                    |
                                    v
       +-----------------------------------------------------------+
       |  Account AWS <account-id>                                 |
       |                                                           |
       |  +-----------------------------------------------------+  |
       |  | OIDC provider (mốc 1, hoặc có sẵn)                  |  |
       |  +-------------------------+---------------------------+  |
       |                            |                              |
       |  +-------------------------v---------------------------+  |
       |  | role ...-gha-bootstrap           (mốc 1, deploy tay)|  |
       |  | nhận: environment:bootstrap                         |  |
       |  +-------------------------+---------------------------+  |
       |                            | workflow Bootstrap tạo       |
       |  +-------------------------v---------------------------+  |
       |  | bucket ...-tfstate-<account-id>, KMS key    (mốc 2) |  |
       |  +-----------------------------------------------------+  |
       |  | role ...-gha-plan                           (mốc 2) |  |
       |  | nhận: pull_request, nhánh main                      |  |
       |  +-----------------------------------------------------+  |
       |  | role ...-gha-apply                          (mốc 2) |  |
       |  | nhận: environment:development, :production          |  |
       |  +-------------------------+---------------------------+  |
       |                            | workflow terraform-* dùng    |
       |  +-------------------------v---------------------------+  |
       |  | hạ tầng của envs/<môi trường>               (mốc 3) |  |
       |  +-----------------------------------------------------+  |
       +-----------------------------------------------------------+
```

## Job nào dùng role nào, role đó từ đâu mà có

| Workflow | Job | Environment | Đuôi của `sub` | Role | Role do ai tạo |
|---|---|---|---|---|---|
| `bootstrap.yaml` | `bootstrap` | `bootstrap` | `:environment:bootstrap` | bootstrap | trust anchor, deploy tay |
| `oidc-test.yaml` | `test` | theo nhánh | `:environment:<tên>` | apply | workflow Bootstrap |
| `terraform-plan.yaml` | `plan` | không | `:pull_request` | plan | workflow Bootstrap |
| `terraform-apply.yaml` | `apply` | theo nhánh | `:environment:<tên>` | apply | workflow Bootstrap |
| `terraform-drift.yaml` | `drift`, mỗi môi trường một job | không | `:ref:refs/heads/main` | plan | workflow Bootstrap |
| `terraform-destroy.yaml` | `destroy` | theo ô chọn lúc bấm chạy | `:environment:<tên>` | apply | workflow Bootstrap |

`<tên>` là `development` hoặc `production`. Job `sync-check` của workflow plan và apply chỉ so file trong repo, không vào AWS, nên không có trong bảng.

Workflow drift chạy theo lịch nên dùng file của nhánh mặc định `main`, và `sub` mang tên nhánh `main`. Đó là lý do nhánh `main` có mặt trong danh sách của role plan dù `main` không deploy gì.

## Mỗi thứ chạy thường xuyên tới đâu

| Thứ | Tần suất | Ai khởi chạy |
|---|---|---|
| Trust anchor | một lần trong đời dự án | bạn, từ máy |
| `bootstrap.yaml` | một lần đầu, và mỗi khi sửa template 02 hoặc 03 | bấm tay, có duyệt |
| `terraform-plan.yaml` | mỗi pull request vào `development` hoặc `production` có đổi `envs/**`, `modules/**` hoặc `scripts/**` | sự kiện `pull_request` |
| `terraform-apply.yaml` | mỗi lần merge vào `development` hoặc `production` có đổi `envs/**` hoặc `modules/**` | sự kiện `push`, có duyệt |
| `terraform-drift.yaml` | 01:00 hằng ngày, hoặc bấm tay | lịch |
| `terraform-destroy.yaml` | khi dọn môi trường | bấm tay, có duyệt |
| `oidc-test.yaml` | mỗi lần merge vào `development` hoặc `production`, cho tới khi bị Disable | sự kiện `push`, có duyệt |

## Thiếu lớp trên thì lớp dưới hỏng thế nào

### Chưa có trust anchor mà chạy workflow Bootstrap

Job qua được cửa duyệt, rồi hỏng ở bước **Configure AWS credentials**:

- **Account chưa có OIDC provider của GitHub:** AWS trả `InvalidIdentityToken`, kèm câu báo không tìm thấy OpenID Connect provider cho `https://token.actions.githubusercontent.com` trong account.
- **Account đã có provider (do dự án khác tạo) nhưng chưa có role bootstrap:** dự kiến AWS trả `Not authorized to perform sts:AssumeRoleWithWebIdentity`, cùng câu với trường hợp `sub` không khớp, vì STS không tiết lộ một role có tồn tại hay không. Câu lỗi này chưa được thấy tận mắt ở repo này. Dù nó là gì, lệnh `aws iam get-role` ở cuối mục phân biệt được hai trường hợp.

Không có cách nào để workflow tự sửa: phải có một người có quyền admin deploy trust anchor. Trust anchor là gốc của chuỗi.

### Chưa chạy Bootstrap mà mở pull request

`terraform-plan.yaml` hỏng ở bước `aws-actions/configure-aws-credentials`, vì role plan chưa có.

### Role chưa có, hay `sub` không khớp

Hai trường hợp này dễ lẫn với nhau khi chỉ nhìn log của job. Cách phân biệt chắc chắn:

```bash
aws iam get-role --role-name aws-eks-mysql-platform-gha-plan \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition' --output json
```

- Lệnh báo `NoSuchEntity`: role chưa có, quay lại mốc 2.
- Lệnh in điều kiện: so nó với `sub` thật của job. `sub` đó nằm ở cột `Username` của sự kiện `AssumeRoleWithWebIdentity` trong CloudTrail (plan 03, mục "Khi gặp lỗi").

## Job tới đúng account và đúng môi trường bằng cách nào

Ba thông tin phải cùng chỉ về một chỗ:

```yaml
# .github/workflows/terraform-apply.yaml, rút gọn phần của job apply
environment: ${{ github.ref == 'refs/heads/production' && 'production' || 'development' }}
env:
  ENV_DIR: ${{ github.ref == 'refs/heads/production' && 'production' || 'development' }}
  ACCOUNT_ID: ${{ github.ref == 'refs/heads/production' && vars.PROD_ACCOUNT_ID || vars.DEV_ACCOUNT_ID }}
defaults:
  run:
    working-directory: envs/${{ env.ENV_DIR }}

steps:
  - uses: aws-actions/configure-aws-credentials@v6
    with:
      role-to-assume: arn:aws:iam::${{ env.ACCOUNT_ID }}:role/aws-eks-mysql-platform-gha-apply   # (1)
      aws-region: us-east-1                                                                      # (2)

  - name: Terraform init
    run: terraform init -no-color                                                                # (3)
```

```hcl
# envs/development/backend.tf
bucket = "aws-eks-mysql-platform-tfstate-<account-id>"
key    = "aws-eks-mysql-platform/development/terraform.tfstate"
```

1. **ARN của role** chứa account ID và tên role. Job vào role nằm trong account nào thì mọi thứ nó tạo nằm trong account đó.
2. **Region** quyết định lời gọi API đi tới đâu. Repo này ghi cứng `us-east-1`.
3. **State** gồm tên bucket và key, cả hai ghi trong `backend.tf` của thư mục env mà job đang đứng, ở đây là `envs/development`. `terraform init` đọc file đó.

Cách viết này giống dự án mẫu. Những gì quyết định đích đến, không thứ nào do người bấm chạy gõ vào:

| Nguồn | Cho ra |
|---|---|
| biến repo `DEV_ACCOUNT_ID` và `PROD_ACCOUNT_ID` | account trong ARN của role |
| tên nhánh | biến account nào được dùng, tên Environment, thư mục `envs/<môi trường>` |
| tên ghi thẳng trong file | tên role trong workflow; tên bucket và key trong `backend.tf` |

Account ID vì vậy xuất hiện ở hai nơi, biến repo và `backend.tf`, và hai nơi phải khớp nhau cho từng môi trường. Biểu thức chọn theo nhánh coi mọi nhánh không phải `production` là `development`; luật nhánh của Environment là thứ ngăn một nhánh lạ đi tiếp.

## Sơ đồ tuần tự: từ merge tới tài nguyên trên AWS

```text
Bạn              GitHub              Job apply          AWS STS            AWS API
 |                 |                    |                 |                  |
 | merge PR        |                    |                 |                  |
 | (development)   |                    |                 |                  |
 |---------------->|                    |                 |                  |
 |                 | job sync-check: so hai thư mục env   |                  |
 |                 |                    |                 |                  |
 |                 | job apply khai environment development                  |
 |                 | -> kiểm luật nhánh, chờ duyệt        |                  |
 | bấm duyệt       |                    |                 |                  |
 |---------------->|                    |                 |                  |
 |                 |------------------->|                 |                  |
 |                 |                    | xin JWT         |                  |
 |                 |                    | sub = ...:      |                  |
 |                 |                    | environment:    |                  |
 |                 |                    | development     |                  |
 |                 |                    |                 |                  |
 |                 |                    | AssumeRoleWithWebIdentity (role apply)
 |                 |                    |---------------->|                  |
 |                 |                    |<----------------|                  |
 |                 |                    | credentials ghi, hạn 1 giờ         |
 |                 |                    |                 |                  |
 |                 |                    | terraform init, plan, apply        |
 |                 |                    |----------------------------------->|
 |                 |                    |   giữ lock, tạo hoặc sửa tài       |
 |                 |                    |   nguyên, ghi state, nhả lock      |
 |                 |                    |<-----------------------------------|
 |                 |                    |                 |                  |
 |                 |                    | job xong, credentials hết hạn      |
```

## Tóm lại

- **Mốc 0, trên GitHub:** lấy hai ID của repo, đặt biến, tạo Environment có luật.
- **Mốc 1, làm tay:** trust anchor tạo role bootstrap, và provider nếu chưa có.
- **Mốc 2, workflow Bootstrap:** dùng role bootstrap để tạo chỗ lưu state và hai role cho Terraform.
- **Mốc 3, hằng ngày:** pull request dùng role chỉ đọc để plan; merge dùng role ghi để plan rồi apply, sau khi có người duyệt.

Lớp dưới không tồn tại được nếu lớp trên chưa xong. Và ở mọi mốc, thứ quyết định một job có vào được role hay không là chuỗi `sub` của nó.
