# aws-eks-mysql-platform

Dự án này dựng lại bài 16 của khoá "DevOps Projects with Kubernetes on AWS" (một cụm MySQL do Percona Operator vận hành trên EKS, có backup và restore qua S3) theo hai phần: những thứ phải có trước cluster (đăng nhập cho CI, mạng, bucket backup) được viết bằng code và triển khai qua CI/CD; từ cluster trở đi (EKS, add-on, MySQL, backup và restore) làm bằng manifest và lệnh, như runbook.

Chuỗi cần nối: **VPC → EKS → IAM → EBS CSI → MySQL → backup/restore (S3)**.

**Trạng thái ngày 19/11/2026:** plan 03 đã chạy xong trên GitHub và AWS: ba stack nền đã được tạo, workflow Bootstrap và OIDC test đã xanh cho cả `development` và `production`. Terraform chưa apply lần nào; bước tiếp theo là plan 04.

## Mục lục

- [Dự án gồm những lớp nào](#dự-án-gồm-những-lớp-nào)
- [Thiết kế chung: phần nào bằng IaC, phần nào bằng manifest và lệnh](#thiết-kế-chung-phần-nào-bằng-iac-phần-nào-bằng-manifest-và-lệnh)
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
| 1. Mạng và bucket | VPC với hai public subnet; bucket S3 cho backup | Terraform | [04](plans/04-terraform-networking-va-s3-backup.md) |
| 2. Cluster và MySQL | cluster EKS, node group, add-on EBS CSI; rồi Percona Operator, cụm MySQL, theo đúng thứ tự phụ thuộc | file cấu hình eksctl, chart Helm, manifest và lệnh gõ trên máy, theo hai runbook. Tuỳ chọn: cluster, add-on và IAM bằng Terraform | chưa có plan |
| 3. Kiểm chứng vận hành | kết nối, ghi đọc, giữ dữ liệu, failover, backup, restore; quy trình dọn | lệnh gõ trên máy, theo runbook | chưa có plan |

Từng thành phần được triển khai bằng cách nào, xem mục [Thiết kế chung](#thiết-kế-chung-phần-nào-bằng-iac-phần-nào-bằng-manifest-và-lệnh) ngay dưới.

Hạ tầng đích lấy từ bản thiết kế [VPC public subnet cho runbook bài 16](https://github.com/hieupham259/DevOps-Projects-with-Kubernetes-on-AWS/blob/master/Section%202/bai16-mysql-operator/thiet-ke-vpc-public-subnet-theo-runbook-bai16.md): một VPC ở us-east-1, hai public subnet, không NAT Gateway, một managed node group 3 × `t3.large`, API endpoint public. Mục tiêu là đặt nguyên các bước của runbook bài 16 lên đó mà không phải đổi chart, số Pod, cách cấp ổ EBS hay cách backup.

## Thiết kế chung: phần nào bằng IaC, phần nào bằng manifest và lệnh

Dự án chia việc theo một mốc: **cluster**. Những thứ phải có trước cluster (đăng nhập cho CI, mạng, bucket backup) viết bằng IaC và đi qua pull request. Từ cluster trở đi (tạo EKS, cài add-on, cài MySQL, backup, restore, dọn) làm bằng manifest và lệnh gõ trên máy, đúng như hai runbook. Cuối mục có một [phương án tuỳ chọn](#tuỳ-chọn-dựng-cluster-add-on-và-iam-bằng-terraform) đưa cả cluster, add-on và IAM vào Terraform.

Hai runbook đó nằm trong repo khoá học: [runbook hạ tầng dùng chung](https://github.com/hieupham259/DevOps-Projects-with-Kubernetes-on-AWS/blob/master/shared-infrastructure/runbook-shared-infrastructure.md), tạo cluster và cài add-on bằng eksctl, và [runbook bài 16](https://github.com/hieupham259/DevOps-Projects-with-Kubernetes-on-AWS/blob/master/Section%202/bai16-mysql-operator/runbook-mysql-operator.md), cài MySQL operator rồi backup và restore. Trong các bảng dưới, "chung" chỉ runbook thứ nhất, "bài 16" chỉ runbook thứ hai.

| Cách triển khai | Dùng cho | Chạy ở đâu |
|---|---|---|
| **IaC**, CloudFormation | phần nền mà Terraform cần trước khi chạy được | workflow Bootstrap; riêng stack 01 làm tay một lần |
| **IaC**, Terraform | VPC và bucket backup. Ở phương án tuỳ chọn, thêm cluster, add-on và IAM | workflow plan và apply, qua pull request |
| **Manifest** | file mô tả điều muốn có: cấu hình cluster và add-on cho eksctl, values của chart, object backup, object restore | file YAML, nộp bằng lệnh |
| **Lệnh** | tạo cluster, cài add-on, cài chart, tạo IAM user và Secret của backup, thao tác vận hành, kiểm chứng, dọn | máy của người vận hành, trong WSL như hai runbook |

Ở README này, "manifest" gồm cả file cấu hình của eksctl (`cluster.yaml`, `addons.yaml`), không chỉ YAML của Kubernetes.

### Triển khai bằng IaC

| Thành phần | Runbook làm bằng | Dự án này | Plan |
|---|---|---|---|
| OIDC provider, các IAM role của CI (bootstrap, plan, apply), bucket và KMS key của state | không có: runbook dùng quyền của người gõ lệnh | CloudFormation, `bootstrap/` | 03, đã chạy |
| VPC, hai public subnet, Internet Gateway, route table; không NAT Gateway | eksctl tự dựng khi tạo cluster, với `vpc.nat.gateway: Disable` (chung, bước 3 và 6) | Terraform | 04 |
| Bucket backup, chặn truy cập công khai, mã hoá AES256 | ba lệnh `aws s3api` (bài 16, bước 2) | Terraform | 04 |

- **Dự án chỉ đổi công cụ so với runbook ở hai chỗ:** VPC và bucket backup. Mọi bước còn lại của hai runbook giữ nguyên cách làm.
- **VPC không tốn tiền khi để yên, bucket rỗng cũng vậy**, nên dựng một lần rồi giữ. Cluster tốn tiền theo giờ; nó được tạo và xoá bằng lệnh, theo nhịp của runbook dùng chung.
- **Workflow dò lệch chỉ thấy phần này.** Cluster, add-on và MySQL nằm ngoài state của Terraform.

### Triển khai bằng manifest

| Manifest | Nói gì | Nộp bằng | Bước runbook |
|---|---|---|---|
| `cluster.yaml`, cấu hình cluster cho eksctl | tên, region, Kubernetes 1.36; xác thực kiểu `API`, người tạo là admin; một managed node group `ng-1`, 3 × `t3.large`, Amazon Linux 2023 | `eksctl create cluster -f` | chung, 3 và 6 |
| `addons.yaml`, cấu hình add-on cho eksctl | `eks-pod-identity-agent` và `aws-ebs-csi-driver`, ghim phiên bản; IAM role của driver qua Pod Identity; StorageClass mặc định `ebs-csi-default-sc`; tag `lab-cluster` trên mọi ổ EBS | `eksctl create addon -f` | chung, 3 và 8.2 |
| `values-backup.yaml`, values của chart `ps-db` | bật backup, nơi lưu tên `s3-us-east-1`, bucket nào, thư mục con `shop`, key nằm ở Secret nào | `helm install shop percona/ps-db --version 1.2.0 -n ps -f` | bài 16, 5 |
| `backup.yaml`, object `PerconaServerMySQLBackup` tên `backup1` | backup cụm `shop-ps-db` vào nơi lưu `s3-us-east-1` | `kubectl apply -f` | bài 16, 9 |
| `restore.yaml`, object `PerconaServerMySQLRestore` tên `restore1` | khôi phục cụm `shop-ps-db` từ `backup1` | `kubectl apply -f` | bài 16, 11 |

- **`cluster.yaml` khác runbook ở đúng một khối, `vpc:`.** Runbook để eksctl tự dựng VPC và chỉ ghi `nat.gateway: Disable`. Ở đây VPC đã có sẵn, nên khối `vpc:` ghi ID của VPC và của hai public subnet. Khi đó eksctl không tạo route table, Internet Gateway hay NAT Gateway nào; phần mạng nó còn tạo là security group cho control plane và node group.
- **Giá trị do Terraform sinh ra không ghi sẵn trong manifest:** VPC ID, subnet ID và tên bucket. Manifest giữ chỗ cho chúng, lệnh điền vào lúc chạy, như runbook sinh `cluster.yaml` bằng `cat <<EOF` và thay tên bucket bằng `sed`. Tên bucket đọc từ SSM parameter `/aws-eks-mysql-platform/<môi trường>/mysql-backup/bucket_name` (plan 04). VPC ID và subnet ID chưa có parameter nào; xem [Quyết định còn mở](#quyết-định-còn-mở).
- **Không có manifest cho IAM role của cluster, của node và của EBS CSI driver:** eksctl tự tạo. Cũng không có manifest cho StatefulSet, Service, PVC hay mật khẩu MySQL: operator tự dựng chúng từ object của cụm.
- Các file nằm ở đâu trong repo do plan của lớp cluster và lớp MySQL quyết định.

### Chạy bằng lệnh

| Việc | Lệnh chính | Bước runbook |
|---|---|---|
| Kiểm tra công cụ, quyền IAM và hạn mức vCPU | `eksctl version`, `aws sts get-caller-identity`, `aws service-quotas get-service-quota` | chung, 0 và 2 |
| Xem trước, rồi tạo cluster | `eksctl create cluster -f cluster.yaml --dry-run`, rồi chạy lại không có `--dry-run` | chung, 4 → 6 |
| Kiểm tra cluster: 3 node `Ready`, đúng phiên bản | `kubectl get nodes`, `aws eks describe-cluster` | chung, 7 |
| Cài add-on; kiểm tra StorageClass mặc định và tag của driver | `eksctl create addon -f addons.yaml`, `kubectl get storageclass` | chung, 8.2 |
| IAM user và policy của backup, chỉ được đụng đúng bucket backup | `aws iam create-user`, `create-policy`, `attach-user-policy` | bài 16, 3 |
| Namespace `ps`; access key đưa thẳng vào Secret `s3-backup-creds` | `kubectl create namespace ps`; `aws iam create-access-key` nối vào `kubectl create secret` | bài 16, 3 |
| Cài operator | `helm repo add`, `helm install ps-operator percona/ps-operator --version 1.2.0 -n ps` | bài 16, 4 |
| Cài cụm MySQL, chạy backup, chạy restore | `helm install shop ... -f`, `kubectl apply -f` | bài 16, 5, 9, 11 |
| Ghi dữ liệu, xoá pod primary, xoá bảng, so checksum | SQL qua pod `mysql-client`; `kubectl delete pod` | bài 16, 6 → 8, 10, 12 |
| Dọn MySQL | theo đúng thứ tự của bước 13, trừ phần xoá bucket | bài 16, 13 |
| Xoá cluster, kiểm tra không còn sót | `eksctl delete cluster -f cluster.yaml --wait`; `aws ec2 describe-volumes` lọc theo tag `lab-cluster` | chung, 10 |

- **Người gõ `eksctl create cluster` là người tạo cluster**, nên tự có quyền admin, như runbook. Việc này cần quyền IAM rộng trên máy: bước 0 của runbook dùng chung khuyên `AdministratorAccess`.
- **eksctl vẫn dựng cluster bằng CloudFormation**, qua hai stack `eksctl-<tên cluster>-cluster` và `eksctl-<tên cluster>-nodegroup-ng-1`. Hai stack này do lệnh trên máy tạo, không đi qua pull request và không nằm trong `bootstrap/`.
- **IAM user và policy của backup làm như bước 3 của runbook**, chỉ khác ở tên bucket: lấy từ SSM thay vì sinh ngẫu nhiên.

### Thứ tự dựng và dọn

Dựng, từ ngoài vào trong:

1. **IaC nền** (đã xong): ba stack CloudFormation của plan 03.
2. **Terraform, qua pull request**: VPC và bucket backup (plan 04).
3. **Manifest và lệnh, runbook dùng chung**: tạo cluster trong VPC đó, rồi cài add-on.
4. **Manifest và lệnh, runbook bài 16**: IAM user của backup, namespace, Secret, operator, cụm MySQL; rồi các bước kiểm chứng.

Dọn, đi ngược lại:

1. **Dọn MySQL** theo bước 13 của runbook bài 16: restore, backup, cụm, operator, PVC, IAM user và policy, namespace, 4 CRD. Không xoá bucket bằng lệnh.
2. **Xoá cluster** theo bước 10 của runbook dùng chung, rồi kiểm tra không còn ổ EBS mang tag `lab-cluster`.
3. **Workflow Terraform Destroy**, chỉ khi bỏ cả môi trường: xoá VPC và bucket backup.

Ba điều giữ cho thứ tự dọn đúng:

- **Xoá PVC trước khi xoá cluster.** Ổ EBS của PVC chỉ mất khi PVC bị xoá lúc driver còn chạy; xoá cluster trước thì ổ ở lại và tính tiền tiếp.
- **Xoá cluster trước khi destroy.** Subnet còn máy và card mạng của cluster thì AWS từ chối xoá, nên destroy sẽ dừng giữa chừng.
- **Bucket chỉ do Terraform xoá.** Bước 13.5 của runbook xoá bucket bằng lệnh; ở đây bỏ phần đó, nếu không state của Terraform lệch với AWS.

### Những phần của hai runbook không mang sang

- **VPC do eksctl tự dựng**, cùng dòng `vpc.nat.gateway: Disable`: VPC do Terraform dựng, không có NAT Gateway ngay từ thiết kế.
- **Các lệnh kiểm tra VPC của runbook dùng chung** (bước 5, 7 và 10.3: tìm VPC theo tag `alpha.eksctl.io/cluster-name`, đọc tài nguyên `VPC` trong stack): VPC không nằm trong stack của eksctl nên không mang tag đó. Sau khi xoá cluster, VPC vẫn còn là đúng.
- **Ba lệnh tạo bucket** (bài 16, bước 2) và phần xoá bucket ở bước 13.5: Terraform làm.
- **Tên `dop-mysql-backup-<8 ký tự>` sinh ngẫu nhiên**: tên bucket theo dự án và môi trường, đọc từ SSM.
- **Snapshot controller** (chung, bước 8.1) và cluster thứ hai `dr-cluster` ở eu-west-1: chỉ Section 5 cần, bài 16 không dùng.

### Tuỳ chọn: dựng cluster, add-on và IAM bằng Terraform

Phương án này thay eksctl bằng Terraform: cluster, node group, add-on và IAM cũng đi qua pull request, như VPC và bucket. Lớp MySQL và phần kiểm chứng không đổi, vẫn là manifest và lệnh của runbook bài 16.

Cách mặc định của dự án vẫn là eksctl, như các mục trên. Mỗi môi trường chọn một trong hai cách cho cluster, không dùng lẫn: cluster do eksctl tạo thì không nằm trong state của Terraform. Phương án này chưa có plan và chưa có code.

| Thành phần | Cách mặc định, theo runbook | Phương án Terraform |
|---|---|---|
| Cluster EKS 1.36, API endpoint public, xác thực kiểu `API` | `cluster.yaml` và `eksctl create cluster` (chung, bước 3 và 6) | Terraform |
| Managed node group 3 × `t3.large`, Amazon Linux 2023; IAM role của cluster và của node | khối `managedNodeGroups`; role do eksctl tự tạo | Terraform, khai rõ từng role |
| Add-on nền `vpc-cni`, `coredns`, `kube-proxy` | eksctl tự cài, kèm `metrics-server` (chung, bước 6) | Terraform; bài 16 không dùng tới `metrics-server` |
| Quyền admin cluster cho người gõ `kubectl` | `bootstrapClusterCreatorAdminPermissions: true`: người tạo cluster chính là người gõ lệnh | Terraform, một access entry riêng |
| Add-on `eks-pod-identity-agent` và `aws-ebs-csi-driver`, ghim phiên bản; StorageClass mặc định `ebs-csi-default-sc`; tag `lab-cluster` trên mọi ổ EBS | `addons.yaml` và `eksctl create addon` (chung, bước 8.2) | Terraform, add-on EKS kèm cấu hình |
| IAM role của EBS CSI driver, gắn vào service account của driver qua Pod Identity | `useDefaultPodIdentityAssociations: true`: eksctl tự tạo | Terraform, khai rõ |
| IAM user và policy của backup, chỉ được đụng đúng bucket backup | `aws iam create-user`, `create-policy`, `attach-user-policy` (bài 16, bước 3) | Terraform |
| Access key của IAM user backup, đưa vào Secret `s3-backup-creds` | `aws iam create-access-key` nối vào `kubectl create secret` (bài 16, bước 3) | không đổi, vẫn bằng lệnh |

- **eksctl làm ngầm nhiều việc**: tạo IAM role, cài add-on nền, cấp quyền admin cho người tạo cluster. Terraform không làm ngầm việc nào, nên mỗi việc đó là một dòng riêng ở bảng trên.
- **Access entry là chỗ khác runbook nhiều nhất.** Với eksctl, bạn gõ lệnh tạo cluster nên tự có quyền admin. Ở phương án này role apply của CI tạo cluster. Thiếu access entry cho IAM principal bạn dùng trên máy thì mọi lệnh `kubectl` ở phần sau đều bị từ chối.
- **EBS CSI driver và StorageClass mặc định chạy trong cluster nhưng Terraform khai được.** Chúng là add-on do EKS quản lý, bật qua API của AWS.
- **Access key vẫn tạo bằng lệnh.** Terraform tạo thì phần bí mật của key nằm trong state. Lệnh ở bước 3 của runbook bài 16 đưa key thẳng vào Secret, không qua file nào.

So với cách mặc định, những thứ sau đổi theo:

| | Cách mặc định | Phương án Terraform |
|---|---|---|
| Manifest cần có | năm file | ba file của bài 16; không cần `cluster.yaml` và `addons.yaml` |
| Công cụ trên máy | eksctl, `kubectl`, Helm, AWS CLI | không cần eksctl |
| Quyền IAM trên máy | rộng, để eksctl tạo cluster | không cần quyền tạo cluster; vẫn cần quyền tạo access key cho IAM user backup |
| Kubeconfig | eksctl tự ghi | lấy bằng `aws eks update-kubeconfig` |
| VPC ID và subnet ID | phải điền vào `cluster.yaml` | Terraform tự nối, không phải tra |
| Xem trước khi tạo | `eksctl create cluster --dry-run` | job plan ở pull request |
| Dò lệch | không thấy cluster | thấy cả cluster, add-on và IAM |
| Xoá cluster | `eksctl delete cluster` | workflow Terraform Destroy |

Dựng:

1. **IaC nền** (đã xong): ba stack CloudFormation của plan 03.
2. **Terraform, qua pull request**: VPC và bucket backup; rồi cluster, node group, access entry; rồi add-on, IAM role của driver, IAM user và policy của backup. Kiểm tra hạn mức vCPU (chung, bước 2) trước lần apply cluster đầu tiên.
3. **Lệnh**: lấy kubeconfig, kiểm tra cluster và add-on (chung, bước 7 và phần kiểm tra của 8.2).
4. **Manifest và lệnh, runbook bài 16**: namespace, access key và Secret, operator, cụm MySQL; rồi các bước kiểm chứng. Bỏ ba lệnh tạo IAM user và policy ở bước 3.

Dọn:

1. **Dọn MySQL** theo bước 13 của runbook bài 16, trừ phần xoá bucket, IAM user và policy. Access key vẫn xoá bằng lệnh.
2. **Lệnh**: kiểm tra không còn ổ EBS mang tag `lab-cluster`.
3. **Workflow Terraform Destroy**: xoá cluster, add-on, IAM, VPC và bucket backup.

- **Xoá PVC và access key trước khi destroy.** Cả hai nằm ngoài state. Ổ EBS của PVC ở lại và tính tiền tiếp nếu cluster mất trước. User còn access key thì AWS từ chối xoá user (`DeleteConflict`), nên destroy dừng ở đó, trừ khi plan IAM đặt `force_destroy` cho user.
- **Workflow destroy xoá cả môi trường**, gồm VPC và bucket backup. Runbook dùng chung tạo cluster đầu buổi và xoá cuối buổi để đỡ tốn tiền. Muốn giữ nhịp đó ở phương án này, plan của lớp cluster phải có cách xoá riêng cluster.

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
- **Mọi thay đổi của phần IaC đi qua pull request.** Phần IaC gồm CI/CD nền, VPC và bucket backup. Với chúng, lệnh `aws` trên máy chỉ để xem, trừ bước làm tay duy nhất ở bước 4 của plan 03 và lần cố ý sửa tay để thử dò lệch ở plan 04. Từ cluster trở đi thì làm bằng lệnh trên máy, theo hai runbook; nếu chọn phương án tuỳ chọn thì cluster, add-on và IAM cũng đi qua pull request. Xem [Thiết kế chung](#thiết-kế-chung-phần-nào-bằng-iac-phần-nào-bằng-manifest-và-lệnh).

## Thư mục này và repo trên GitHub

Dự án nằm ở `D:\code\aws-eks-mysql-platform`, là một thư mục riêng, không thuộc repo nào khác. Thư mục là một repo git trên nhánh `master`, đã gắn `origin` và đã đẩy lên repo `aws-eks-mysql-platform` trên GitHub. Việc tạo repo và lần push đầu tiên ứng với bước 1 của plan 03.

Thư mục này phải là gốc của repo, vì GitHub chỉ đọc `.github/workflows` ở gốc repo.

## Nguồn tham chiếu

| Nguồn | Lấy gì |
|---|---|
| Dự án mẫu [`3-tiers-app-infrastructure`](https://github.com/hieupham259/3-tiers-app-infrastructure) | mô hình OIDC ba lớp, nhánh theo môi trường, bố cục `envs/` và `_shared` |
| [Runbook hạ tầng dùng chung](https://github.com/hieupham259/DevOps-Projects-with-Kubernetes-on-AWS/blob/master/shared-infrastructure/runbook-shared-infrastructure.md) | file cấu hình và lệnh để tạo cluster, cài add-on, xoá cluster và kiểm tra không còn sót |
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
| 7 | Công cụ cho lớp 2 và 3 | mặc định: file cấu hình eksctl, chart Helm, manifest và lệnh gõ trên máy, theo hai runbook. Tuỳ chọn: cluster, add-on và IAM bằng Terraform. Cả hai cách đều không chạy Helm trong workflow | README, mục Thiết kế chung |
| 8 | IAM user, policy và access key của backup tạo bằng gì | mặc định: bằng lệnh, như bước 3 của runbook bài 16. Ở phương án tuỳ chọn: user và policy bằng Terraform, access key vẫn bằng lệnh | README, mục Thiết kế chung |
| 9 | `cluster.yaml` lấy VPC ID và subnet ID từ đâu (chỉ ở cách mặc định) | chưa chốt: thêm SSM parameter ở plan 04, hoặc tra theo tag lúc chạy lệnh | chưa có plan |
| 10 | IAM principal nào nhận access entry admin của cluster (chỉ ở phương án tuỳ chọn) | chưa chốt. ARN của nó chứa account ID nên không ghi thẳng trong code | chưa có plan |

## Những thứ cố ý không có

- **Các manifest của mục Thiết kế chung** chưa được chép hay sinh lại ở đây: `cluster.yaml` và `addons.yaml` của runbook dùng chung, cùng ba file của `Section 2/operators/mysql` trong repo khoá học (`values-backup.yaml`, `backup.yaml`, `restore.yaml`). Lớp cluster và lớp MySQL chưa có plan; khi có, plan đó sẽ quyết định các file nằm ở đâu trong repo và lấy giá trị từ Terraform thế nào.
- **Access key AWS** cho CI. Đây là điều dự án đặt ra để tránh.
- **Cluster, node, NAT Gateway.** Bốn plan đầu dừng trước mọi thứ tốn tiền theo giờ. Chi phí duy nhất là KMS key của state, 1 USD mỗi tháng.
