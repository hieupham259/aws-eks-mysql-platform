# Plan 03: Dựng đăng nhập OIDC, rồi thử bằng một pull request

Plan này đưa repo mới tới chỗ GitHub Actions vào được AWS mà không lưu access key nào, rồi thử điều đó bằng một pull request thật: merge vào `development` thì một workflow tự chạy và in ra danh tính nó nhận được trên AWS.

- **Phần 1, dựng OIDC (bước 1–6):** cùng trình tự với dự án mẫu: deploy tay một stack, đặt biến và Environment, chạy workflow Bootstrap.
- **Phần 2, thử (bước 7–8):** nhánh `feat/setup-deployment` thêm một workflow nhỏ, mở pull request vào `development`, merge, xem kết quả.

Đọc [plan 01](01-doc-lai-oidc-cua-du-an-mau.md) và [plan 02](02-doc-lai-thiet-ke-cicd-cua-du-an-mau.md) trước. Plan này dùng lại các khái niệm ở đó mà không giải thích lại.

## Mục lục

- [Những gì đã đối chiếu](#những-gì-đã-đối-chiếu)
- [Tên dùng trong plan](#tên-dùng-trong-plan)
- [Khác dự án mẫu ở đâu](#khác-dự-án-mẫu-ở-đâu)
- [Phần 1: Dựng OIDC](#phần-1-dựng-oidc)
- [Phần 2: Thử bằng một pull request](#phần-2-thử-bằng-một-pull-request)
- [Bốn workflow Terraform chạy theo nhánh thế nào](#bốn-workflow-terraform-chạy-theo-nhánh-thế-nào)
- [Dọn toàn bộ](#dọn-toàn-bộ)
- [Khi gặp lỗi](#khi-gặp-lỗi)
- [Giới hạn đã biết](#giới-hạn-đã-biết)
- [Nguồn](#nguồn)

## Những gì đã đối chiếu

Ngày **17/11/2026**:

- Đọc toàn bộ bootstrap, workflow và ghi chú của dự án mẫu ở commit `4de50f9`, nhánh `development`. Cấu hình Environment `development` của repo mẫu lấy từ ảnh trang Settings.
- Kiểm tra tĩnh trên máy, đều qua: `terraform fmt -check -recursive`; `terraform validate` cho cả hai thư mục env, trên một bản sao, với AWS provider 5.100.0 có sẵn trong cache của dự án mẫu; sáu workflow qua `act --validate --strict`; ba template được kiểm mọi `!Ref`, `!Sub`, `!GetAtt`; `scripts/verify-envs-in-sync.sh` in `OK`.
- Ngày **18/11/2026**, sau khi đổi cách chọn môi trường trong sáu workflow và điều kiện của role apply: sáu workflow qua lại `act --validate --strict`; template 03 được kiểm bằng cách đọc lại hai khối `Condition`. Điều kiện trên claim `environment` mới chỉ đối chiếu với tài liệu IAM.
- **Chưa chạy thật.** Chưa có workflow nào chạy trên GitHub và chưa có stack nào được tạo trên AWS. Tài liệu của GitHub chỉ cho ví dụ dạng `sub` có ID với ngữ cảnh nhánh; plan giả định job khai `environment` dùng cùng tiền tố. Bước 5 và bước 8 là hai lần thử thật.

## Tên dùng trong plan

| Thứ | Giá trị |
|---|---|
| Repo GitHub | `aws-eks-mysql-platform`, **public** |
| Region | `us-east-1` |
| Nhánh | `master` (mặc định, không deploy); `development` và `production` (mỗi nhánh ứng với môi trường cùng tên) |
| Environment trên GitHub | `bootstrap` (chỉ nhánh `master`); `development` và `production` (mỗi cái chỉ nhận nhánh cùng tên) |
| Biến cấp repo | `DEVELOPMENT_ACCOUNT_ID`, `PRODUCTION_ACCOUNT_ID`, `OIDC_SUBJECT_PREFIX`, `DEPLOY_ENVIRONMENTS` |
| Stack CloudFormation | `aws-eks-mysql-platform-trust-anchor`, `-tfstate-backend`, `-github-oidc-roles` |
| Role IAM | `aws-eks-mysql-platform-gha-bootstrap`, `-gha-plan`, `-gha-apply` |
| Bucket state | `aws-eks-mysql-platform-tfstate-<account-id>` |

## Khác dự án mẫu ở đâu

| | Dự án mẫu | Dự án này |
|---|---|---|
| Dạng `sub` | `repo:<org>/<repo>:...` | `repo:<owner>@<id>/<repo>@<id>:...`, vì repo tạo sau 15/07/2026. Tiền tố đưa vào tham số `OidcSubjectPrefix` |
| Điều kiện vào role plan | `repo:<org>/<repo>:*` | như mẫu: tiền tố nối với `:*`, tức mọi ngữ cảnh của repo |
| Điều kiện vào role apply | `repo:<org>/<repo>:*` | job phải chạy trong một Environment có tên nằm trong biến `DEPLOY_ENVIRONMENTS` |
| Chọn môi trường và account trong workflow | biểu thức "`production` hay không", với hai biến `DEV_ACCOUNT_ID` và `PROD_ACCOUNT_ID` | dùng thẳng tên: tên nhánh là tên Environment, tên thư mục `envs/<tên>` và phần đầu của biến `<TÊN>_ACCOUNT_ID` |
| OIDC provider | template luôn tạo | tham số `CreateOidcProvider`: account đã có thì dùng lại |
| Tên role, stack, alias KMS | `gha-bootstrap`, `trust-anchor`, `alias/tfstate`... | có tiền tố tên dự án, để sống chung account với dự án mẫu |
| Deploy trust anchor | upload qua Console | một lệnh `aws cloudformation deploy` |
| Workflow thử đăng nhập | không có | `oidc-test.yaml` |

## Phần 1: Dựng OIDC

Lệnh chạy trong một terminal bash (WSL `Ubuntu` hoặc Git Bash), đứng ở thư mục dự án: `/mnt/d/code/aws-eks-mysql-platform` trong WSL, `/d/code/aws-eks-mysql-platform` trong Git Bash. Mỗi terminal mới chạy lại khối dưới:

```bash
export AWS_REGION=us-east-1
export PROJECT=aws-eks-mysql-platform
aws sts get-caller-identity --query '[Account, Arn]' --output text; echo "exit=$?"
```

**PASS:** in đúng account lab và `exit=0`. Danh tính này cần quyền admin: nó tạo role IAM ở bước 4.

### Bước 1: Tạo repo public và đẩy code lên `master`

Trên GitHub: **New repository** → tên `aws-eks-mysql-platform` → **Public** → không tick thêm README, .gitignore hay license. Repo phải public nếu bạn dùng gói Free, Pro hoặc Team: chỉ repo public mới đặt được người duyệt cho Environment.

Điền account ID vào tên bucket của state, rồi commit mọi thứ trừ workflow thử:

```bash
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
sed -i "s/<account-id>/${ACCOUNT_ID}/" envs/development/backend.tf envs/production/backend.tf

git add -A
git rm --cached -q .github/workflows/oidc-test.yaml
git status --short | grep -v '^A '
git commit -m "chore: bootstrap templates, CI workflows and Terraform skeleton"
git push -u origin master
```

Thư mục đã được `git init` trên nhánh `master` và đã gắn `origin`. File `oidc-test.yaml` cố ý chưa commit: nó là thay đổi của feature branch ở bước 7.

**PASS bước 1:** lệnh `git status` chỉ in một dòng, `?? .github/workflows/oidc-test.yaml`. Sau khi push, tab **Actions** của repo liệt kê năm workflow.

### Bước 2: Lấy hai ID của repo

Repo tạo sau 15/07/2026 phát `sub` có kèm ID của chủ repo và ID của repo. Lấy hai số đó từ API công khai của GitHub:

```bash
curl -s "https://api.github.com/repos/<tên-github-của-bạn>/aws-eks-mysql-platform" | grep -m2 '"id"'
```

**PASS bước 2:** lệnh in hai dòng `"id": <số>,`. **Dòng đầu là ID của repo, dòng sau là ID của chủ repo.** Ghép thành tiền tố, chú ý thứ tự ngược với thứ tự lệnh in ra:

```text
repo:<tên-github-của-bạn>@<ID của chủ repo>/aws-eks-mysql-platform@<ID của repo>
```

### Bước 3: Biến và Environment trên GitHub

**Settings → Secrets and variables → Actions → tab Variables**, tạo bốn biến:

| Tên | Giá trị |
|---|---|
| `DEVELOPMENT_ACCOUNT_ID` | 12 chữ số của account development |
| `PRODUCTION_ACCOUNT_ID` | account của production. Dùng chung một account thì điền cùng giá trị, như dự án mẫu đang làm |
| `OIDC_SUBJECT_PREFIX` | tiền tố ghép ở bước 2 |
| `DEPLOY_ENVIRONMENTS` | `development,production` |

Hai quy tắc về tên:

- **Biến account mang tên môi trường.** Workflow đọc biến `<tên môi trường>_account_id`, ví dụ `development_account_id` khi chạy cho nhánh `development`. GitHub lưu tên biến bằng chữ hoa và không phân biệt hoa thường khi đọc, nên trên màn hình bạn thấy `DEVELOPMENT_ACCOUNT_ID`.
- **`DEPLOY_ENVIRONMENTS` là danh sách Environment được vào role apply**, cách nhau bằng dấu phẩy. Workflow Bootstrap truyền nó vào stack 03 ở bước 5. Tên trong danh sách chỉ gồm chữ, số và gạch dưới.

**Settings → Environments**, tạo `bootstrap`, `development` và `production`, cấu hình như Environment `development` của repo mẫu:

| Mục | Giá trị |
|---|---|
| Required reviewers | tick, thêm chính bạn |
| Prevent self-review | không tick |
| Wait timer | không tick |
| Allow administrators to bypass configured protection rules | để tick, như mặc định |
| Deployment branches and tags | **Selected branches and tags**, một luật: `master` cho `bootstrap`, `development` cho `development`, `production` cho `production` |

**PASS bước 3:** bốn biến ở tab Variables, tab Secrets trống; ba Environment, mỗi cái nhận đúng một nhánh.

Làm bước này trước bước 4, vì role tin vào tên Environment: Environment chưa có luật thì workflow nào khai tên đó cũng được role nhận.

### Bước 4: Trust anchor, bước làm tay duy nhất trên AWS

Mỗi account chỉ có một OIDC provider cho GitHub. Xem account đã có chưa:

```bash
aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?ends_with(Arn, ':oidc-provider/token.actions.githubusercontent.com')].Arn" \
  --output text; echo "exit=$?"
```

Lệnh in một ARN thì dùng `CREATE_OIDC_PROVIDER=false` (ví dụ account đã chạy dự án mẫu); không in gì thì dùng `true`.

```bash
export OIDC_SUBJECT_PREFIX='<tiền tố ghép ở bước 2>'
export CREATE_OIDC_PROVIDER=false

aws cloudformation deploy --region "${AWS_REGION}" \
  --stack-name "${PROJECT}-trust-anchor" \
  --template-file bootstrap/01-trust-anchor.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    "OidcSubjectPrefix=${OIDC_SUBJECT_PREFIX}" \
    "CreateOidcProvider=${CREATE_OIDC_PROVIDER}"; echo "exit=$?"

aws iam get-role --role-name "${PROJECT}-gha-bootstrap" \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition' --output json
```

**PASS bước 4:** `deploy` in `Successfully created/updated stack` và `exit=0`. Điều kiện của role có `...:aud` là `sts.amazonaws.com` và `...:sub` là tiền tố của bạn nối với `:environment:bootstrap`.

### Bước 5: Chạy workflow Bootstrap

**Actions → Bootstrap (CFN - state backend + OIDC roles) → Run workflow** → nhánh `master`, **Target AWS account** chọn `development`. Lần chạy dừng ở **Waiting**: bấm **Review deployments** → tick `bootstrap` → **Approve and deploy**.

Workflow vào role bootstrap bằng OIDC, tạo bucket và KMS key cho state, rồi tạo role plan và role apply. Đây là lần đầu GitHub vào AWS.

**PASS bước 5:**

- Bước **Verify caller identity** in `Arn` là `arn:aws:sts::<account-id>:assumed-role/aws-eks-mysql-platform-gha-bootstrap/GitHubActions`.
- Bước cuối, **Print role ARNs**, in `PlanRoleArn` và `ApplyRoleArn`.

Production nằm ở account khác thì đăng nhập AWS CLI vào account đó, làm lại bước 4, rồi chạy lại bước này với lựa chọn `production`. Cùng account thì một lần là đủ.

### Bước 6: Tạo nhánh `development` và `production`

```bash
git branch development
git branch production
git push -u origin development production
```

**PASS bước 6:** repo trên GitHub có ba nhánh, cùng một commit.

Mở tab **Actions**: nếu push nhánh mới làm **Terraform Apply** khởi chạy, job `apply` của nó dừng ở **Waiting**. Đừng duyệt, bấm **Cancel workflow**; Terraform chưa thuộc plan này.

Tới đây OIDC đã dựng xong: ba stack, ba role, và không có access key nào trong GitHub.

## Phần 2: Thử bằng một pull request

File thử là `.github/workflows/oidc-test.yaml`. Nó chạy khi có push vào `development` hoặc `production`, in tên nhánh, kiểm biến account, vào role apply bằng OIDC, rồi hỏi AWS "tôi đang là ai":

```yaml
on:
  push:
    branches: [development, production]

jobs:
  test:
    runs-on: ubuntu-latest
    environment: ${{ github.ref_name }}
    env:
      ACCOUNT_ID: ${{ vars[format('{0}_account_id', github.ref_name)] }}
    steps:
      - name: Print branch
        run: echo "Running on branch ${{ github.ref_name }}"

      - name: Check the account variable
        run: |
          if [ -z "${ACCOUNT_ID}" ]; then
            echo "::error::Repository variable ${GITHUB_REF_NAME}_account_id is not set."
            exit 1
          fi

      - uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: arn:aws:iam::${{ env.ACCOUNT_ID }}:role/aws-eks-mysql-platform-gha-apply
          aws-region: us-east-1

      - name: Verify caller identity
        run: aws sts get-caller-identity
```

Tên nhánh được dùng làm tên Environment và để tìm biến account `<tên nhánh>_account_id`, đúng như `terraform-apply.yaml` làm. Bước **Check the account variable** dừng job với thông báo rõ khi biến đó chưa có.

### Bước 7: Nhánh `feat/setup-deployment` và pull request

```bash
git switch -c feat/setup-deployment development
git add .github/workflows/oidc-test.yaml
git commit -m "ci: add OIDC test workflow"
git push -u origin feat/setup-deployment
```

Trên GitHub: mở pull request với **base** là `development`, **compare** là `feat/setup-deployment`.

**PASS bước 7:** pull request có đúng một file thay đổi. Chưa workflow nào chạy: `oidc-test` chỉ chạy khi có push vào nhánh môi trường.

### Bước 8: Merge và xem kết quả

Trong pull request: **Merge pull request** → **Confirm merge**. Lần merge là một push vào `development`, nên workflow **OIDC test** tự chạy. Job `test` chọn Environment `development` theo nhánh và dừng ở **Waiting**: bấm **Review deployments** → tick `development` → **Approve and deploy**.

**PASS bước 8:**

- Bước **Print branch** in `Running on branch development`.
- Bước **Verify caller identity** in `Arn` là `arn:aws:sts::<account-id>:assumed-role/aws-eks-mysql-platform-gha-apply/GitHubActions`.
- Trang chủ repo, cột phải, mục **Deployments** có `bootstrap` và `development`.

Vậy là xong: code đi từ feature branch qua pull request vào `development`, và workflow trên nhánh đó vào được AWS bằng role, không có access key nào.

- **Thử `production` (tuỳ chọn):** mở pull request với base `production`, compare `development`, rồi merge. Cùng workflow chạy, lần này chọn Environment `production` và `PRODUCTION_ACCOUNT_ID`, in `Running on branch production`.
- **Sau khi thử:** workflow này chạy ở mọi lần merge vào hai nhánh môi trường. Không cần nữa thì **Actions → OIDC test → ··· → Disable workflow**.

## Bốn workflow Terraform chạy theo nhánh thế nào

Bốn file này viết theo khung của dự án mẫu, chỉ khác cách chọn môi trường và account, và đã nằm trong repo. Plan này không chạy chúng; lần dùng thật đầu tiên là [plan 04](04-terraform-networking-va-s3-backup.md).

| Workflow | Chạy khi | Chọn môi trường và account theo | Role |
|---|---|---|---|
| `terraform-plan.yaml` | pull request vào `development` hoặc `production`, có đổi `envs/`, `modules/` hoặc `scripts/` | nhánh đích của pull request | plan |
| `terraform-apply.yaml` | merge vào `development` hoặc `production`, có đổi `envs/` hoặc `modules/` | nhánh vừa nhận push; job chờ duyệt ở Environment cùng tên | apply |
| `terraform-drift.yaml` | 01:00 hằng ngày, hoặc bấm tay | mỗi môi trường một job | plan |
| `terraform-destroy.yaml` | bấm tay, phải gõ `destroy` | ô chọn môi trường; job chờ duyệt ở Environment cùng tên | apply |

Quy tắc chọn giống nhau ở mọi file: một cái tên dùng cho mọi thứ. Tên `production` ra thư mục `envs/production`, Environment `production` và biến `PRODUCTION_ACCOUNT_ID`; tên `development` ra bộ tương ứng. Cái tên đó là nhánh đích của pull request (plan), nhánh vừa nhận push (apply), tên trong ma trận (drift) hoặc ô chọn lúc bấm chạy (destroy).

Không có chuyện một nhánh lạ rơi về `development`: mỗi job vào AWS có bước **Check the account variable**, dừng ngay khi thiếu biến `<tên>_account_id`.

Danh sách môi trường vẫn ghi tay ở ba kiểu chỗ, vì GitHub bắt chúng phải viết tĩnh: `branches:` của plan, apply và `oidc-test`; ô chọn của destroy và Bootstrap; ma trận của drift. Thêm một môi trường mới thì sửa các chỗ đó, tạo biến account, tạo Environment có luật, rồi thêm tên vào `DEPLOY_ENVIRONMENTS` và chạy lại Bootstrap.

Workflow dò lệch có lịch chạy mỗi đêm kể từ lúc file nằm trên `master`, và sẽ đỏ cho tới khi môi trường được deploy ở plan 04. Muốn tránh email báo đỏ thì **Actions → Terraform Drift Detection → ··· → Disable workflow**, rồi bật lại ở plan 04.

## Dọn toàn bộ

Chỉ làm khi bỏ hẳn dự án. Nếu Terraform đã tạo hạ tầng (từ plan 04 trở đi) thì chạy workflow **Terraform Destroy** trước, khi role còn tồn tại.

```bash
aws cloudformation delete-stack --region "${AWS_REGION}" --stack-name "${PROJECT}-github-oidc-roles"
aws cloudformation wait stack-delete-complete --region "${AWS_REGION}" --stack-name "${PROJECT}-github-oidc-roles"; echo "exit=$?"

aws cloudformation delete-stack --region "${AWS_REGION}" --stack-name "${PROJECT}-tfstate-backend"
aws cloudformation wait stack-delete-complete --region "${AWS_REGION}" --stack-name "${PROJECT}-tfstate-backend"; echo "exit=$?"

aws cloudformation delete-stack --region "${AWS_REGION}" --stack-name "${PROJECT}-trust-anchor"
aws cloudformation wait stack-delete-complete --region "${AWS_REGION}" --stack-name "${PROJECT}-trust-anchor"; echo "exit=$?"
```

Ba thứ được giữ lại sau khi xoá stack, phải xử lý tay:

- **Bucket state:** đang bật versioning. Dùng Console: **S3** → chọn `aws-eks-mysql-platform-tfstate-<account-id>` → **Empty** → **Delete**.
- **KMS key:** **KMS → Customer managed keys** → key có mô tả `Encrypts the Terraform state of aws-eks-mysql-platform` → **Schedule key deletion**, 7 ngày. Key tốn 1 USD mỗi tháng cho tới lúc đặt lịch xoá; đây là chi phí duy nhất của plan này.
- **OIDC provider:** để nguyên nếu account còn dự án khác dùng GitHub OIDC, ví dụ dự án mẫu.

Trên GitHub: xoá ba Environment và bốn biến.

## Khi gặp lỗi

| Thấy gì | Nguyên nhân thường gặp | Làm gì |
|---|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | `sub` của job không khớp điều kiện của role, hoặc role chưa tồn tại | In điều kiện: `aws iam get-role --role-name <role> --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'`. Báo `NoSuchEntity` thì role chưa có. Có role thì xem `sub` thật của job: **CloudTrail → Event history**, lọc **Event name** = `AssumeRoleWithWebIdentity`, cột `Username`. So từng ký tự; hay gặp nhất là hai ID bị đảo chỗ. Sửa biến `OIDC_SUBJECT_PREFIX`, làm lại bước 4 và bước 5 |
| Cùng câu lỗi đó, chỉ với role apply, dù `sub` đúng tiền tố | tên Environment của job không nằm trong `DEPLOY_ENVIRONMENTS` lúc Bootstrap chạy | sửa biến `DEPLOY_ENVIRONMENTS`, làm lại bước 5 |
| Job đỏ ở bước **Check the account variable** | chưa có biến `<tên>_account_id` cho môi trường đó, hoặc tên biến sai | tạo biến ở bước 3; tên phải là tên nhánh nối với `_ACCOUNT_ID` |
| Bootstrap hỏng ở stack 03, CloudFormation từ chối tham số `ApplyEnvironments` hoặc `OidcSubjectPrefix` | biến `DEPLOY_ENVIRONMENTS` hoặc `OIDC_SUBJECT_PREFIX` rỗng, hoặc sai dạng | sửa biến ở bước 3, chạy lại bước 5 |
| `sub` thật không có `@<số>` | repo đang phát dạng cũ | tiền tố là `repo:<tên-github-của-bạn>/aws-eks-mysql-platform`; sửa biến, làm lại bước 4 và bước 5 |
| Bước 4 báo `EntityAlreadyExists` với provider | account đã có provider | xoá stack đang ở `ROLLBACK_COMPLETE` bằng `aws cloudformation delete-stack`, đặt `CREATE_OIDC_PROVIDER=false`, chạy lại |
| Job đỏ ngay: nhánh không được deploy vào environment | luật nhánh của Environment không khớp nhánh đang chạy | sửa luật nhánh ở bước 3; Bootstrap phải chạy từ `master` |
| Job chờ duyệt mãi, không có nút Approve | bạn không nằm trong Required reviewers, hoặc đã tick Prevent self-review | sửa Environment như bảng ở bước 3 |
| Merge xong mà **OIDC test** không chạy | file `oidc-test.yaml` không nằm trong pull request, hoặc workflow đang bị Disable | xem tab **Files changed** của pull request; bật lại workflow |

## Giới hạn đã biết

- Role apply và role bootstrap mang `AdministratorAccess`, như dự án mẫu. Thứ giới hạn chúng là trust policy chỉ nhận Environment đã chọn, và luật của Environment.
- Role plan nhận mọi ngữ cảnh của repo, như dự án mẫu: workflow trên nhánh bất kỳ vào được role chỉ đọc này.
- Điều kiện trên claim `environment` của role apply dùng một condition key AWS hỗ trợ từ 02/2026. Nó chưa được chạy thật ở repo này; bước 8 là lần thử đầu tiên.
- Hai môi trường chung một account thì dùng chung role plan và role apply.
- Plan này chỉ thử trường hợp vào được role. Không có bước thử các trường hợp phải bị từ chối.
- Các điểm đến từ việc giữ đúng khung workflow Terraform của dự án mẫu:
  - job `apply` chờ duyệt trước khi chạy plan, nên bản plan để đọc là comment ở pull request;
  - bộ lọc `paths` khiến job `plan` không đặt làm check bắt buộc được;
  - workflow apply chỉ chạy khi có push;
  - workflow destroy không in trước những gì sẽ xoá;
  - job dò lệch của một môi trường chưa deploy sẽ đỏ.

## Nguồn

- GitHub Docs: [OpenID Connect reference](https://docs.github.com/en/actions/reference/security/oidc); [Managing environments for deployment](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments); [Events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows).
- GitHub Changelog 23/04/2026: [Immutable subject claims for GitHub Actions OIDC tokens](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/).
- AWS IAM: [Create a role for OpenID Connect federation](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-idp_oidc.html).
- Action: [`aws-actions/configure-aws-credentials`](https://github.com/aws-actions/configure-aws-credentials).
- Dự án mẫu: [`3-tiers-app-infrastructure`](https://github.com/hieupham259/3-tiers-app-infrastructure/tree/4de50f9b3d740454eb72c6f957fe9bda0380cdee).
