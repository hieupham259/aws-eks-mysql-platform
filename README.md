# aws-eks-mysql-platform

Dự án này dựng lại bài 16 của khoá "DevOps Projects with Kubernetes on AWS" (một cụm MySQL do Percona Operator vận hành trên EKS, có backup và restore qua S3) thành một hạ tầng viết bằng code và triển khai qua CI/CD, thay cho chuỗi lệnh gõ tay trong runbook.

Chuỗi cần nối: **VPC → EKS → IAM → EBS CSI → MySQL → backup/restore (S3)**.

**Trạng thái ngày 19/11/2026:** plan 03 đã chạy xong trên GitHub và AWS: ba stack nền đã được tạo, workflow Bootstrap và OIDC test đã xanh cho cả `development` và `production`. Terraform chưa apply lần nào; bước tiếp theo là plan 04.

## Mục lục

- [Dự án gồm những lớp nào](#dự-án-gồm-những-lớp-nào)
- [Các file plan: vai trò và lý do có mặt](#các-file-plan-vai-trò-và-lý-do-có-mặt)
- [Trong thư mục đang có gì](#trong-thư-mục-đang-có-gì)
- [Quy ước của dự án](#quy-ước-của-dự-án)
- [Thư mục này và repo trên GitHub](#thư-mục-này-và-repo-trên-github)
- [Nguồn tham chiếu](#nguồn-tham-chiếu)
- [Quyết định còn mở](#quyết-định-còn-mở)
- [Những thứ cố ý không có](#những-thứ-cố-ý-không-có)

## Dự án gồm những lớp nào

CI/CD nằm trong thiết kế từ đầu, nhưng được dựng từng lớp. Lớp sau chỉ bắt đầu khi lớp trước đã chạy thật và qua kiểm chứng.

| Lớp | Nội dung | Công cụ | Plan |
|---|---|---|---|
| 0. Đăng nhập và pipeline | GitHub Actions vào AWS bằng OIDC và IAM role, không lưu access key. Pull request sinh plan; merge sinh apply, có người duyệt; dò lệch; xoá | CloudFormation cho phần nền, GitHub Actions | [03](plans/03-trien-khai-oidc-roi-cicd.md), đã có code |
| 1. Hạ tầng | VPC và bucket backup trước; rồi EKS, node group, IAM | Terraform | [04](plans/04-terraform-networking-va-s3-backup.md) cho VPC và bucket; EKS và IAM chưa có plan |
| 2. Nền tảng và MySQL | EBS CSI driver, Percona Operator, cụm MySQL, theo đúng thứ tự phụ thuộc | chưa chốt | chưa có plan |
| 3. Kiểm chứng vận hành | kết nối, ghi đọc, giữ dữ liệu, failover, backup, restore; quy trình dọn | chưa chốt | chưa có plan |

Hạ tầng đích lấy từ bản thiết kế [VPC public subnet cho runbook bài 16](https://github.com/hieupham259/DevOps-Projects-with-Kubernetes-on-AWS/blob/master/Section%202/bai16-mysql-operator/thiet-ke-vpc-public-subnet-theo-runbook-bai16.md): một VPC ở us-east-1, hai public subnet, không NAT Gateway, một managed node group 3 × `t3.large`, API endpoint public. Mục tiêu là đặt nguyên các bước của runbook bài 16 lên đó mà không phải đổi chart, số Pod, cách cấp ổ EBS hay cách backup.

## Các file plan: vai trò và lý do có mặt

Bốn plan chia làm hai loại. Hai plan đầu là **hướng dẫn đọc**: chúng không tạo ra gì, chỉ dẫn bạn đọc lại một dự án đã chạy thật. Hai plan sau là **hướng dẫn làm**: từng bước có chốt PASS và STOP.

| Plan | Loại | Trả lời câu hỏi | Vì sao phải có | Xong thì có gì |
|---|---|---|---|---|
| [01. Đọc lại OIDC của dự án mẫu](plans/01-doc-lai-oidc-cua-du-an-mau.md) | đọc | Dự án mẫu cho GitHub Actions vào AWS mà không có access key bằng cách nào? Repo đó được thiết lập theo thứ tự nào? | Dự án mới dùng lại đúng mô hình này. Nhưng ghi chú của dự án mẫu đã lệch so với code ở vài chỗ quan trọng, và có ba điều không thể chép nguyên. Phải biết trước khi dựng | hiểu ba lớp tin cậy; một bảng "ghi chú viết gì, code thật ra sao"; danh sách ba điều phải làm khác |
| [02. Đọc lại thiết kế CI/CD của dự án mẫu](plans/02-doc-lai-thiet-ke-cicd-cua-du-an-mau.md) | đọc | Một thay đổi đi từ feature branch tới AWS qua những cửa nào? Cửa nào nằm trong code, cửa nào nằm trong Settings của GitHub? | Phần Settings (nhánh, Environments, biến) không nằm trong repo nên dễ bị bỏ sót khi dựng lại. Plan cũng gom các điểm yếu của thiết kế cũ, và ghi dự án mới đổi điểm nào, giữ điểm nào | bảng sáu workflow; bảng nhánh nào ra môi trường nào; danh sách thiết lập GitHub cần ghi lại; mười điểm yếu kèm quyết định giữ hay đổi |
| [03. Dựng OIDC, rồi thử bằng một pull request](plans/03-trien-khai-oidc-roi-cicd.md) | làm | Làm sao đưa repo mới tới chỗ GitHub Actions vào được AWS bằng OIDC, và biết chắc nó chạy? | Đăng nhập phải đứng vững trước khi có hạ tầng tốn tiền. Plan dựng OIDC theo trình tự của dự án mẫu, rồi thử bằng một pull request thật vào `development` | ba stack nền, ba role, ba Environment; một workflow thử tự chạy khi merge và in ra danh tính nó nhận được trên AWS |
| [04. Mạng và bucket S3 cho backup](plans/04-terraform-networking-va-s3-backup.md) | làm | Phần Terraform đầu tiên gồm những gì và viết thế nào? Bucket backup khác bucket state ở đâu? | Mạng là thứ mọi lớp sau đứng lên. Bucket backup dễ bị nhầm với bucket state, nên cần tách bạch từ đầu | một VPC đúng bản thiết kế, một bucket backup; chưa tốn tiền |

Thứ tự làm là 01 → 02 → 03 → 04. Plan 03 có hai phần và phải đi đúng thứ tự: dựng OIDC xong mới thử bằng pull request.

Vì sao hai plan đọc đứng trước: plan 03 không giải thích lại khái niệm. Nó giả định bạn đã biết `sub` là gì, vì sao job khai `environment` thì `sub` đổi, và Environment chặn được gì, không chặn được gì.

## Trong thư mục đang có gì

```text
aws-eks-mysql-platform/
├── README.md
├── plans/                                # bốn plan
├── notes/                                # tài liệu giải thích
│   ├── OIDC-GUIDE.md                     #   kiến thức nền OIDC, dạng `sub` mới, role và trust policy của repo này
│   └── CICD-CHAIN-OF-TRUST.md            #   chuỗi tin cậy theo thời gian: job nào dùng role nào
├── bootstrap/                            # CloudFormation: phần nền mà Terraform cần trước khi chạy
│   ├── 01-trust-anchor.yaml              #   bước làm tay duy nhất: OIDC provider, role bootstrap
│   ├── 02-tfstate-backend.yaml           #   bucket và KMS key cho Terraform state
│   └── 03-github-oidc-roles.yaml         #   role plan (chỉ đọc), role apply
├── .github/
│   └── workflows/
│       ├── bootstrap.yaml                #   deploy stack 02 và 03
│       ├── oidc-test.yaml                #   thử đăng nhập: chạy khi merge vào nhánh môi trường
│       ├── terraform-plan.yaml           #   pull request: sync-check, fmt, validate, plan
│       ├── terraform-apply.yaml          #   merge: sync-check, chờ duyệt, plan, apply
│       ├── terraform-drift.yaml          #   dò lệch, cả hai môi trường
│       └── terraform-destroy.yaml        #   xoá cả một môi trường
├── envs/
│   ├── _shared/                          # code chung của mọi môi trường
│   ├── development/                      # backend, provider, giá trị riêng
│   └── production/                       # cùng năm file, khác key của state và giá trị
├── scripts/
│   └── verify-envs-in-sync.sh            # so main.tf và variables.tf của hai thư mục env
├── .gitignore
├── .gitattributes
└── .terraform-version
```

Toàn bộ code trên đi kèm plan 03. Resource Terraform duy nhất hiện có là một SSM parameter miễn phí; nó được tạo ở pull request đầu tiên của plan 04, khi các workflow Terraform chạy lần đầu. Thư mục `modules/` chưa có: plan 04 mô tả nó, code sẽ viết khi làm plan đó.

Code đã được kiểm tra thế nào, và chưa được kiểm tra thế nào, ghi ở mục "Những gì đã đối chiếu" của plan 03.

Hai file trong `notes/` là bản viết lại của hai tài liệu cùng tên ở dự án mẫu, theo dạng `sub` mới và theo code của repo này. `SETUP-GUIDE.md` của dự án mẫu không có bản viết lại riêng: việc của nó ở repo này do plan 03 đảm nhận.

## Quy ước của dự án

- **Tên nhánh, tên Environment và tên thư mục `envs/<tên>` trùng nhau.** Merge vào nhánh `development` là deploy lên `development`; merge vào `production` là deploy lên `production`.
- **Workflow chọn môi trường và account theo tên nhánh.** Tên nhánh cũng là tên Environment, tên thư mục `envs/<tên>` và phần đầu của biến account: nhánh `production` dùng `PRODUCTION_ACCOUNT_ID`, nhánh `development` dùng `DEVELOPMENT_ACCOUNT_ID`.
- **`master` là nhánh mặc định và không deploy.** Nó giữ file workflow cho các lần chạy theo lịch và bấm tay. Feature branch tách từ `development`; `production` và `master` nhận code từ `development`.
- **`main.tf` và `variables.tf` của hai thư mục env phải giống hệt nhau.** Job `sync-check` kiểm điều đó ở mỗi pull request và mỗi lần apply. Resource mới viết trong `envs/_shared/`.
- **Tên dự án được ghi thẳng** trong workflow, template và `backend.tf`, như cách dự án mẫu ghi tên role của nó.
- **Không có secret nào trong GitHub.** Chỉ có bốn biến cấp repo: `DEVELOPMENT_ACCOUNT_ID`, `PRODUCTION_ACCOUNT_ID`, `OIDC_SUBJECT_PREFIX` và `DEPLOY_ENVIRONMENTS`.
- **Account ID không nằm trong code.** Tên bucket của state kết thúc bằng account ID, nên `backend.tf` không ghi tên bucket: workflow truyền nó vào `terraform init` bằng `-backend-config`, lấy account ID từ biến `<TÊN>_ACCOUNT_ID`. Dự án mẫu thì ghi thẳng tên bucket trong `backend.tf`.
- **Region là `us-east-1`**, ghi rõ trong mọi lệnh.
- **Code và chú thích trong code viết bằng tiếng Anh; plan viết bằng tiếng Việt.**
- **Mọi thay đổi hạ tầng đi qua pull request.** Lệnh `aws` trên máy chỉ để xem, trừ bước làm tay duy nhất ở bước 4 của plan 03 và lần cố ý sửa tay để thử dò lệch ở plan 04.

## Thư mục này và repo trên GitHub

Dự án nằm ở `D:\code\aws-eks-mysql-platform`, là một thư mục riêng, không thuộc repo nào khác. Thư mục là một repo git trên nhánh `master`, đã gắn `origin` và đã đẩy lên repo `aws-eks-mysql-platform` trên GitHub. Việc tạo repo và lần push đầu tiên ứng với bước 1 của plan 03.

Thư mục này phải là gốc của repo, vì GitHub chỉ đọc `.github/workflows` ở gốc repo.

## Nguồn tham chiếu

| Nguồn | Lấy gì |
|---|---|
| Dự án mẫu [`3-tiers-app-infrastructure`](https://github.com/hieupham259/3-tiers-app-infrastructure) | mô hình OIDC ba lớp, nhánh theo môi trường, bố cục `envs/` và `_shared` |
| [Runbook bài 16](https://github.com/hieupham259/DevOps-Projects-with-Kubernetes-on-AWS/blob/master/Section%202/bai16-mysql-operator/runbook-mysql-operator.md) | những gì hạ tầng phải có, các chốt PASS dùng lại để kiểm chứng |
| [Bản thiết kế VPC public subnet](https://github.com/hieupham259/DevOps-Projects-with-Kubernetes-on-AWS/blob/master/Section%202/bai16-mysql-operator/thiet-ke-vpc-public-subnet-theo-runbook-bai16.md) | hình dạng mạng và cluster |
| `Section 1/Resources/Resources/terraform_kubeadm` trong repo khoá học | cách chia file trong một module Terraform |

## Quyết định còn mở

Đã chọn tạm trong các plan, cần bạn xác nhận hoặc đổi:

| # | Quyết định | Đang chọn | Ghi ở |
|---|---|---|---|
| 1 | Repo public hay private | public, vì gói Free, Pro và Team chỉ cho đặt người duyệt Environment ở repo public | plan 03, bước 1 |
| 2 | Số account AWS | hai môi trường chung một account: `PRODUCTION_ACCOUNT_ID` cùng giá trị với `DEVELOPMENT_ACCOUNT_ID`. Code đã sẵn cho hai account; `production` chưa deploy | plan 03, bước 3 |
| 3 | Role apply mang `AdministratorAccess` | giữ như dự án mẫu, bù bằng trust policy chỉ nhận Environment có tên trong `DEPLOY_ENVIRONMENTS`, và Environment có người duyệt | plan 03, giới hạn đã biết |
| 4 | Có tạo private subnet không | không, chỉ giữ chỗ dải địa chỉ | plan 04, mục 10 |
| 5 | Tên bucket backup | theo tên dự án và môi trường, không theo `dop-mysql-backup-<8 ký tự>` của runbook | plan 04, mục 10 |
| 6 | Tên cluster | chưa chốt: `basic-cluster` như bản thiết kế, hoặc theo tên dự án | plan 04, mục 10 |
| 7 | Công cụ cho lớp 2 và 3 | chưa chốt: Helm chạy trong workflow, hoặc provider Helm của Terraform | chưa có plan |

## Những thứ cố ý không có

- **Code của `Section 2/operators`** trong repo khoá học (`values-backup.yaml`, `backup.yaml`, `restore.yaml`) không được chép hay sinh lại ở đây. Lớp MySQL chưa có plan; khi có, plan đó sẽ quyết định dự án tham chiếu các file ấy thế nào.
- **Access key AWS** cho CI. Đây là điều dự án đặt ra để tránh.
- **Cluster, node, NAT Gateway.** Bốn plan đầu dừng trước mọi thứ tốn tiền theo giờ. Chi phí duy nhất là KMS key của state, 1 USD mỗi tháng.
