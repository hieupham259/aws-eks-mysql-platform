# Runbook: Dựng cluster EKS trên VPC của Terraform

Runbook này dựng một cluster EKS bằng eksctl bên trong VPC mà Terraform của repo đã tạo, cài add-on lưu trữ, rồi xoá cluster và kiểm tra không còn gì tính tiền. Cluster này là nơi [runbook MySQL operator](runbook-mysql-operator.md) chạy.

Đây là bản viết lại, cho dự án này, của [runbook hạ tầng dùng chung](https://github.com/hieupham259/DevOps-Projects-with-Kubernetes-on-AWS/blob/master/shared-infrastructure/runbook-shared-infrastructure.md) trong repo khoá học, dưới đây gọi là **runbook gốc**. Số bước được giữ nguyên để đối chiếu. Cluster không chạy liên tục: đầu buổi tạo, cuối buổi xoá. VPC và bucket backup thì để yên giữa các buổi, vì chúng do Terraform quản lý và không tốn tiền theo giờ.

**Thứ tự:** bước 0–4 chỉ làm một lần. Mỗi buổi làm từ bước 5 đến bước 10.

## Mục lục

- [Khác gì so với runbook gốc](#khác-gì-so-với-runbook-gốc)
- [Đã kiểm những gì](#đã-kiểm-những-gì)
- [Chi phí ước tính](#chi-phí-ước-tính)
- [Bước 0: Chuẩn bị (làm một lần)](#bước-0-chuẩn-bị-làm-một-lần)
- [Bước 1: Tạo file biến môi trường (làm một lần)](#bước-1-tạo-file-biến-môi-trường-làm-một-lần)
- [Bước 2: Kiểm tra hạn mức vCPU (làm một lần)](#bước-2-kiểm-tra-hạn-mức-vcpu-làm-một-lần)
- [Bước 3: Lấy VPC của Terraform và viết file cấu hình (làm một lần)](#bước-3-lấy-vpc-của-terraform-và-viết-file-cấu-hình-làm-một-lần)
  - [3.1. Lấy VPC ID và subnet ID](#31-lấy-vpc-id-và-subnet-id)
  - [3.2. Viết `cluster.yaml` và `addons.yaml`](#32-viết-clusteryaml-và-addonsyaml)
- [Bước 4: Xem trước bằng dry-run (làm một lần, hoặc sau khi sửa file)](#bước-4-xem-trước-bằng-dry-run-làm-một-lần-hoặc-sau-khi-sửa-file)
- [Bước 5: Kiểm tra trước khi tạo (mỗi buổi)](#bước-5-kiểm-tra-trước-khi-tạo-mỗi-buổi)
- [Bước 6: Tạo cluster (mỗi buổi)](#bước-6-tạo-cluster-mỗi-buổi)
- [Bước 7: Kiểm tra cluster (mỗi buổi)](#bước-7-kiểm-tra-cluster-mỗi-buổi)
- [Bước 8: Cài add-on (mỗi buổi)](#bước-8-cài-add-on-mỗi-buổi)
- [Bước 9: Chạy runbook MySQL operator](#bước-9-chạy-runbook-mysql-operator)
- [Bước 10: Dọn cuối buổi](#bước-10-dọn-cuối-buổi)
  - [10.1. Dọn bên trong cluster](#101-dọn-bên-trong-cluster)
  - [10.2. Xoá cluster](#102-xoá-cluster)
  - [10.3. Kiểm tra không còn sót](#103-kiểm-tra-không-còn-sót)
- [Bước 11 (tuỳ chọn): Dọn kubeconfig](#bước-11-tuỳ-chọn-dọn-kubeconfig)
- [Dọn khi bỏ cả môi trường](#dọn-khi-bỏ-cả-môi-trường)
- [Khi gặp lỗi](#khi-gặp-lỗi)
- [Nguồn](#nguồn)

## Khác gì so với runbook gốc

| | Runbook gốc | Runbook này |
|---|---|---|
| Dùng cho | mọi bài lab Section 2–5 của khoá học | bài 16 (MySQL operator) của dự án này |
| VPC | eksctl tự dựng khi tạo cluster, với `vpc.nat.gateway: Disable` | VPC do Terraform dựng ở [plan 04](../plans/04-terraform-networking-va-s3-backup.md); `cluster.yaml` trỏ vào VPC và hai public subnet có sẵn |
| Tên cluster | `basic-cluster` | `aws-eks-mysql-platform-development` |
| Thư mục, file biến | `~/shared-infrastructure/`, `~/shared-infrastructure.env` | `~/platform-cluster/`, `~/platform-cluster.env` |
| File cấu hình | `cluster.yaml`, `addons.yaml`, `snapshot-addon.yaml` | `cluster.yaml`, `addons.yaml` |
| Add-on | 8.1 snapshot controller (Section 5), 8.2 Pod Identity agent và EBS CSI driver | chỉ Pod Identity agent và EBS CSI driver |
| VPC ID | đọc từ stack của eksctl, sau khi tạo cluster | tra theo tag `Name` của VPC, trước khi tạo cluster |
| VPC lúc dọn | phải mất cùng cluster | phải còn nguyên; kiểm tra thêm trong VPC không còn card mạng và security group của cluster |
| Cluster thứ hai `dr-cluster` ở eu-west-1 | có, cho bài S5-L04 | không có |
| Kubernetes, eksctl, loại máy, quyền vào cluster | 1.36, 0.231.0, 3 × t3.large, access entry | giữ nguyên |

- **Vì sao tên cluster khác `basic-cluster`:** để cluster này và cluster dùng chung của khoá học không lẫn với nhau trong cùng account. Lệnh dọn của runbook gốc xoá theo tên `basic-cluster`, nên sẽ không đụng tới cluster này, và ngược lại.
- **Vì sao không để eksctl tự dựng VPC:** VPC là phần do Terraform quản lý, đi qua pull request. Xem mục [Thiết kế chung](../README.md#thiết-kế-chung-phần-nào-bằng-iac-phần-nào-bằng-manifest-và-lệnh) của README.

## Đã kiểm những gì

Ngày **20/11/2026**, trên máy và bằng lệnh chỉ đọc AWS:

- Công cụ trong WSL `Ubuntu`: AWS CLI 2.38.2, eksctl 0.231.0, kubectl 1.35.9. Tài khoản đang dùng có `AdministratorAccess`.
- Hạn mức vCPU ở us-east-1 là 16, đang dùng 0.
- VPC và hai subnet của Terraform đạt mọi điều kiện ở bước 3.1.
- Hai add-on ở bước 3.2 có đúng phiên bản đó cho Kubernetes 1.36.
- Các khối lệnh của bước 1, 3 và 4 đã chạy thử với thư mục nhà tạm: file sinh ra đúng, và `eksctl create cluster --dry-run` qua với cấu hình trỏ vào VPC của Terraform.
- Mọi khối lệnh qua `bash -n`.

**Chưa chạy thật:** bước 6 trở đi trên VPC này. Runbook gốc đã chạy thật bước 5–7 và bước 10 (nhánh A) ngày 03/11 và 04/11/2026, nhưng với VPC do eksctl dựng. Bước 8 chưa chạy thật ở cả hai runbook. Hai điều cần để ý ở lần chạy thật đầu tiên:

- node có vào được cluster trong VPC này không (bước 7);
- tạo cluster có làm job dò lệch của Terraform đỏ không. Nếu EKS hay eksctl gắn thêm tag lên subnet, `terraform plan` sẽ thấy tag đó là thứ lệch.

## Chi phí ước tính

Giá niêm yết On-Demand ở us-east-1, lấy theo runbook gốc. Kiểm tra lại trên trang giá AWS trước khi làm.

| Hạng mục | Số lượng | Đơn giá | USD/giờ |
|---|---|---|---|
| Cluster EKS (control plane, hỗ trợ chuẩn) | 1 | 0,10 USD/giờ | 0,100 |
| EC2 t3.large (worker) | 3 | 0,0832 USD/giờ | 0,250 |
| IPv4 công khai | 3 (mỗi worker 1) | 0,005 USD/giờ | 0,015 |
| EBS gp3 (ổ của worker) | 240 GB (3 × 80 GB, mặc định của eksctl) | 0,08 USD/GB-tháng | ~0,026 |
| **Tổng** | | | **~0,39** |

- Một buổi 3 giờ: khoảng 1,2 USD. **Quên xoá 1 ngày: khoảng 9,4 USD.**
- VPC, subnet, Internet Gateway và route table của Terraform không tốn tiền. Không có NAT Gateway.
- Tính thêm khi chạy runbook MySQL: ổ EBS của PVC (0,08 USD/GB-tháng) và dung lượng backup trên S3, đều rất nhỏ.
- Chưa tính: lưu lượng ra Internet và giữa các zone, phí CPU vượt mức của dòng T3 khi chạy nặng liên tục.

---

## Bước 0: Chuẩn bị (làm một lần)

Mọi lệnh chạy trong **WSL `Ubuntu`**. Không chạy trong PowerShell hay Git Bash. Mở terminal Windows, gõ `wsl -d Ubuntu`, rồi:

```bash
cd ~
pwd
aws --version
aws sts get-caller-identity --query '[Account, Arn]' --output text
eksctl version
kubectl version --client
```

**PASS bước 0:**

- `pwd` in ra thư mục nhà của người dùng Ubuntu, ví dụ `/home/hieupham`. Đang ở `/mnt/c/...` hay `/mnt/d/...` thì chạy lại `cd ~`.
- `aws --version` in ra `aws-cli/2...`. Lệnh `sts` in đúng số account đã deploy plan 04.
- `eksctl version` in ra `0.231.0`.
- `kubectl` có Client Version là 1.35.x, 1.36.x hoặc 1.37.x, tức lệch tối đa 1 bản minor so với cluster 1.36.

Ba điều kiện khác:

- **Plan 04 đã deploy lên `development`.** VPC và bucket backup phải có sẵn; bước 3.1 kiểm lại điều này.
- **Quyền IAM.** eksctl tạo IAM role, security group, stack CloudFormation và cluster. Runbook MySQL còn tạo IAM user và policy. Tài khoản nên có `AdministratorAccess`.
- **Helm 4** cần cho runbook MySQL. Cài trước buổi làm, để không phải trả tiền cluster trong lúc cài.

## Bước 1: Tạo file biến môi trường (làm một lần)

Lệnh dưới chỉ tạo file khi chưa có, chạy lại không ghi đè:

```bash
if [ ! -f ~/platform-cluster.env ]; then
  cat > ~/platform-cluster.env <<'EOF'
export AWS_REGION=us-east-1
export PROJECT=aws-eks-mysql-platform
export ENVIRONMENT=development
export CLUSTER_NAME=aws-eks-mysql-platform-development
export K8S_VERSION=1.36
export EKS_DIR="$HOME/platform-cluster"
EOF
  echo "Đã tạo ~/platform-cluster.env"
else
  echo "~/platform-cluster.env đã có, giữ nguyên"
fi

source ~/platform-cluster.env
cat ~/platform-cluster.env
echo "EKS_DIR=${EKS_DIR}"
```

**PASS bước 1:** in ra `Đã tạo ...` (hoặc `đã có, giữ nguyên` khi chạy lại). `cat` hiện đủ 6 dòng như trên; nếu đã làm bước 3 thì có thêm 5 dòng `VPC_ID`, `AZ_...`, `SUBNET_...`. Dòng cuối in `EKS_DIR=/home/<tên>/platform-cluster`.

- **Mỗi lần mở terminal mới chỉ chạy `cd ~ && source ~/platform-cluster.env`.**
- **Không `source ~/shared-infrastructure.env` hay `~/eks-lab.env` của khoá học trong cùng terminal.** Các file này dùng chung tên biến, nên `CLUSTER_NAME=basic-cluster` và `EKS_DIR` của khoá học sẽ ghi đè lên giá trị ở đây.
- **`PROJECT` và `ENVIRONMENT`** phải khớp với `terraform.tfvars` của môi trường đã deploy. Runbook dùng hai biến này để tìm VPC theo tag và đọc tên bucket.

## Bước 2: Kiểm tra hạn mức vCPU (làm một lần)

3 máy t3.large cần 6 vCPU, mỗi máy 2 vCPU:

```bash
aws service-quotas get-service-quota --region "${AWS_REGION}" \
  --service-code ec2 --quota-code L-1216C47A \
  --query 'Quota.Value' --output text; echo "exit=$?"

aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters Name=instance-state-name,Values=pending,running \
  --query 'Reservations[].Instances[].[CpuOptions.CoreCount, CpuOptions.ThreadsPerCore]' \
  --output text | awk '{s += $1 * $2} END {print s + 0}'; echo "exit=${PIPESTATUS[0]}"
```

**PASS bước 2:** cả hai lệnh in `exit=0`, và hạn mức (số của lệnh đầu) trừ số vCPU đang dùng (số của lệnh sau) **≥ 6**.

**STOP khi** có `exit` khác 0. Lệnh sau đưa kết quả của AWS CLI qua `awk` để cộng; AWS CLI lỗi thì `awk` vẫn in `0`. Vì vậy dòng `exit` ở đây lấy mã thoát của chính AWS CLI (`PIPESTATUS[0]`), và phải xem nó trước khi tin con số.

## Bước 3: Lấy VPC của Terraform và viết file cấu hình (làm một lần)

Làm lại cả bước này mỗi khi Terraform dựng lại mạng, ví dụ sau một lần Terraform Destroy rồi apply lại: VPC ID và subnet ID sẽ đổi.

### 3.1. Lấy VPC ID và subnet ID

```bash
VPC_ID="$(aws ec2 describe-vpcs --region "${AWS_REGION}" \
  --filters "Name=tag:Name,Values=${PROJECT}-${ENVIRONMENT}-vpc" \
  --query 'Vpcs[].VpcId' --output text)"; echo "exit=$?"
echo "VPC_ID=${VPC_ID}"

aws ec2 describe-vpc-attribute --region "${AWS_REGION}" --vpc-id "${VPC_ID}" \
  --attribute enableDnsSupport --query 'EnableDnsSupport.Value' --output text
aws ec2 describe-vpc-attribute --region "${AWS_REGION}" --vpc-id "${VPC_ID}" \
  --attribute enableDnsHostnames --query 'EnableDnsHostnames.Value' --output text

aws ec2 describe-subnets --region "${AWS_REGION}" --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'sort_by(Subnets, &AvailabilityZone)[].[AvailabilityZone, AvailabilityZoneId, SubnetId, MapPublicIpOnLaunch]' \
  --output text; echo "exit=$?"
aws ec2 describe-route-tables --region "${AWS_REGION}" --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'RouteTables[].{Subnets: Associations[].SubnetId, Routes: Routes[].[DestinationCidrBlock, GatewayId]}' \
  --output json; echo "exit=$?"
```

**PASS 3.1, phần kiểm tra:**

- `VPC_ID` là đúng một ID `vpc-...`, và mọi dòng `exit` là `0`.
- Hai dòng thuộc tính DNS đều `True`.
- Đúng hai subnet, ở hai zone khác nhau. Cột thứ hai (zone ID) không phải `use1-az3`: EKS không nhận subnet ở zone đó. Cột cuối đều `True`: subnet tự cấp IP public cho máy.
- Một route table gắn với đủ hai subnet và có route `0.0.0.0/0` tới một `igw-...`.

**STOP khi:**

- `VPC_ID` rỗng: plan 04 chưa deploy, hoặc đang ở sai account, sai `PROJECT`, sai `ENVIRONMENT`.
- `VPC_ID` có hai ID trở lên: có hai VPC cùng tên. Tìm ra cái nào của Terraform trước khi làm tiếp.
- Cột cuối là `False`, hoặc thiếu route `0.0.0.0/0`: node sẽ không kéo được image và không vào được cluster. Sửa ở phía Terraform, không sửa tay.

Lưu các ID vào file biến:

```bash
read -r AZ_1 SUBNET_1 AZ_2 SUBNET_2 < <(aws ec2 describe-subnets --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'sort_by(Subnets, &AvailabilityZone)[].[AvailabilityZone, SubnetId]' \
  --output text | tr '\n' ' ')

if [ -n "${VPC_ID}" ] && [ -n "${SUBNET_1}" ] && [ -n "${SUBNET_2}" ]; then
  sed -i -e '/^export VPC_ID=/d' -e '/^export AZ_[12]=/d' -e '/^export SUBNET_[12]=/d' ~/platform-cluster.env
  cat >> ~/platform-cluster.env <<EOF
export VPC_ID=${VPC_ID}
export AZ_1=${AZ_1}
export SUBNET_1=${SUBNET_1}
export AZ_2=${AZ_2}
export SUBNET_2=${SUBNET_2}
EOF
  echo "Đã lưu VPC và subnet vào ~/platform-cluster.env"
else
  echo "STOP: thiếu VPC_ID hoặc subnet, chưa lưu gì"
fi

source ~/platform-cluster.env
grep -E '^export (VPC_ID|AZ_[12]|SUBNET_[12])=' ~/platform-cluster.env
```

**PASS 3.1, phần lưu:** in `Đã lưu ...`. Lệnh `grep` in đúng 5 dòng: một `VPC_ID=vpc-...`, hai `AZ_...` là hai zone ở trên, hai `SUBNET_...=subnet-...`. Chạy lại thì các dòng cũ được thay, không bị lặp.

### 3.2. Viết `cluster.yaml` và `addons.yaml`

```bash
mkdir -p "${EKS_DIR}"

cat > "${EKS_DIR}/cluster.yaml" <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "${K8S_VERSION}"

accessConfig:
  authenticationMode: API
  bootstrapClusterCreatorAdminPermissions: true

vpc:
  id: "${VPC_ID}"
  subnets:
    public:
      ${AZ_1}:
        id: "${SUBNET_1}"
      ${AZ_2}:
        id: "${SUBNET_2}"

managedNodeGroups:
  - name: ng-1
    amiFamily: AmazonLinux2023
    instanceType: t3.large
    desiredCapacity: 3
    minSize: 3
    maxSize: 3
EOF

cat > "${EKS_DIR}/addons.yaml" <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}

addons:
  - name: eks-pod-identity-agent
    version: v1.3.10-eksbuild.3
  - name: aws-ebs-csi-driver
    version: v1.66.0-eksbuild.1
    useDefaultPodIdentityAssociations: true
    configurationValues: |-
      defaultStorageClass:
        enabled: true
      controller:
        extraVolumeTags:
          lab-cluster: ${CLUSTER_NAME}
EOF

ls -1 "${EKS_DIR}"
grep -n '\${' "${EKS_DIR}"/*.yaml || echo "Không còn biến chưa thay"
grep -n 'lab-cluster' "${EKS_DIR}/addons.yaml"
cat "${EKS_DIR}/cluster.yaml"
```

File `addons.yaml` cài thêm cho cluster khả năng tạo ổ đĩa lưu dữ liệu trên AWS. Tự Kubernetes không làm được việc này, nên cụm MySQL sẽ đứng chờ mãi nếu thiếu nó. File cài một thành phần chuyên đi tạo ổ đĩa EBS, cùng một thành phần cấp cho thành phần đó quyền gọi AWS. Mỗi ổ đĩa được tạo ra đều mang nhãn `lab-cluster` bằng tên cluster, để lúc dọn tìm đúng ổ còn sót mà xoá.

**PASS 3.2:** `ls` in ra `addons.yaml` và `cluster.yaml`. Dòng `grep` đầu in `Không còn biến chưa thay`, dòng `grep` sau in `lab-cluster: aws-eks-mysql-platform-development`. `cat` hiện khối `vpc:` có `id: "vpc-..."` và hai zone, mỗi zone một `id: "subnet-..."`, đúng các giá trị đã lưu ở 3.1.

**STOP khi** khối `vpc:` có chỗ rỗng, ví dụ `id: ""`: terminal này chưa có biến của bước 3.1. Chạy `source ~/platform-cluster.env` rồi chạy lại khối lệnh.

- **Lệnh này chưa tạo gì trên AWS**, chỉ ghi file trên máy. Chạy lại sẽ ghi đè cả hai file.
- **Khối `vpc:` là chỗ duy nhất `cluster.yaml` khác runbook gốc.** Khi VPC đã có sẵn, eksctl không tạo route table, Internet Gateway hay NAT Gateway nào; phần mạng nó còn tạo là security group cho control plane và node group.
- **Node nằm ở public subnet** (`privateNetworking: false` là mặc định), có IP public, nên kéo image và gọi AWS API qua Internet Gateway. Vì vậy không cần NAT.
- **`useDefaultPodIdentityAssociations: true`:** eksctl tự tạo IAM role cho EBS CSI driver và gắn vào service account của nó qua Pod Identity. Vì vậy `eks-pod-identity-agent` phải có cùng lúc.
- **`defaultStorageClass.enabled: true`:** driver tạo StorageClass `ebs-csi-default-sc` và đánh dấu là mặc định. PVC nào không ghi StorageClass sẽ dùng nó.
- **`controller.extraVolumeTags`:** driver gắn tag `lab-cluster=<tên cluster>` lên mọi ổ EBS và snapshot nó tạo. Bước 10.3 tìm ổ còn sót theo tag này.

## Bước 4: Xem trước bằng dry-run (làm một lần, hoặc sau khi sửa file)

```bash
eksctl utils describe-cluster-versions --region "${AWS_REGION}" \
  | grep -oE '"ClusterVersion": "[0-9.]+"' | sort -u

eksctl create cluster -f "${EKS_DIR}/cluster.yaml" --dry-run \
  | grep -E 'authenticationMode|amiFamily|instanceType|desiredCapacity|privateNetworking|volumeSize|gateway|version: "|id: vpc-|id: subnet-|publicAccess|privateAccess'
```

**PASS bước 4:**

- Lệnh đầu có dòng `"ClusterVersion": "1.36"`.
- Lệnh thứ hai chỉ in ra cấu hình đầy đủ, **không tạo gì trên AWS**. Kết quả phải có:
  - `authenticationMode: API`, `amiFamily: AmazonLinux2023`, `instanceType: t3.large`, `desiredCapacity: 3`, `version: "1.36"`;
  - `privateNetworking: false` và `volumeSize: 80`;
  - `id: vpc-...` đúng `VPC_ID`, và hai dòng `id: subnet-...` đúng hai subnet đã lưu;
  - `gateway: Disable`, `publicAccess: true`, `privateAccess: false`.

**STOP khi** eksctl báo lỗi về VPC hay subnet. Thường là ID trong file đã cũ: làm lại bước 3.

---

## Bước 5: Kiểm tra trước khi tạo (mỗi buổi)

```bash
cd ~ && source ~/platform-cluster.env
aws sts get-caller-identity --query Account --output text; echo "exit=$?"

# Cluster EKS trùng tên
aws eks list-clusters --region "${AWS_REGION}" \
  --query "clusters[?@=='${CLUSTER_NAME}']" --output text; echo "exit=$?"

# Stack CloudFormation mang tag đúng tên cluster này
aws cloudformation describe-stacks --region "${AWS_REGION}" \
  --query "Stacks[?Tags[?Key=='alpha.eksctl.io/cluster-name' && Value=='${CLUSTER_NAME}'] && StackStatus!='DELETE_COMPLETE'].[StackName, StackStatus]" \
  --output text; echo "exit=$?"

# VPC của Terraform còn đó, và vẫn là VPC đã lưu ở bước 3
aws ec2 describe-vpcs --region "${AWS_REGION}" \
  --filters "Name=tag:Name,Values=${PROJECT}-${ENVIRONMENT}-vpc" \
  --query 'Vpcs[].VpcId' --output text; echo "exit=$?"
echo "VPC_ID=${VPC_ID}"

# Trong VPC chưa có card mạng nào: chưa có cluster hay máy nào đang dùng nó
aws ec2 describe-network-interfaces --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'NetworkInterfaces[].[NetworkInterfaceId, Description]' --output text; echo "exit=$?"
```

**PASS bước 5:**

- Lệnh đầu in đúng số account. Mọi lệnh in `exit=0`.
- Lệnh cluster và lệnh stack không in gì khác ngoài `exit=0`.
- Lệnh VPC in đúng một ID, trùng với dòng `VPC_ID=...` ngay dưới.
- Lệnh card mạng không in gì khác ngoài `exit=0`.

**STOP khi:**

- Có lệnh in `exit` khác 0 hoặc báo lỗi (hết hạn đăng nhập, `AccessDenied`, mất mạng). Lúc đó kết quả rỗng không có nghĩa là chưa có cluster. Sửa lỗi rồi chạy lại.
- Thấy cluster hay stack mang tên này: cluster của buổi trước chưa xoá (**đang tính tiền**), hoặc một lần xoá bị lỗi. Dọn theo bước 10. Stack ở `DELETE_FAILED` thì xem mục [Khi gặp lỗi](#khi-gặp-lỗi).
- ID của VPC khác `VPC_ID` đã lưu: Terraform đã dựng lại mạng. Làm lại bước 3 và bước 4; `cluster.yaml` đang trỏ vào VPC cũ.
- Còn card mạng trong VPC: có thứ gì đó vẫn đang dùng VPC. Cột mô tả cho biết nó của ai; tìm ra và dọn trước khi tạo cluster.

## Bước 6: Tạo cluster (mỗi buổi)

```bash
eksctl create cluster -f "${EKS_DIR}/cluster.yaml"
```

- Lệnh tạo control plane và 3 worker, mất khoảng 15 phút. **Đừng đóng terminal** trong lúc chạy.
- eksctl nhờ CloudFormation dựng qua hai stack: `eksctl-<tên cluster>-cluster` (control plane và security group) và `eksctl-<tên cluster>-nodegroup-ng-1` (worker). Stack cluster không chứa VPC: VPC là của Terraform.
- Xong, eksctl ghi thông tin kết nối vào `~/.kube/config` và chuyển kubectl sang cluster mới. Người chạy lệnh được quyền admin cluster qua access entry (`bootstrapClusterCreatorAdminPermissions: true`).
- eksctl tự cài các add-on mặc định: `vpc-cni`, `coredns`, `kube-proxy`, `metrics-server`.

**PASS bước 6:** lệnh kết thúc không lỗi, dòng cuối báo cluster ở `us-east-1` đã sẵn sàng (ready).

Nếu lệnh báo lỗi:

- **Báo cluster hoặc stack đã tồn tại (`already exists`):** **STOP**, không xoá vội. Quay lại bước 5.
- **Lỗi khác:** bước 5 vừa xác nhận chưa có gì mang tên này, nên phần đang có là do lần chạy này tạo ra. eksctl để CloudFormation tự gỡ phần đã tạo của stack lỗi, nhưng stack lỗi vẫn còn và phải xoá. Xem mục [Khi gặp lỗi](#khi-gặp-lỗi), dọn theo bước 10.2 (khối lệnh đầu cho biết làm nhánh nào) và 10.3, rồi tạo lại.

## Bước 7: Kiểm tra cluster (mỗi buổi)

```bash
kubectl config current-context
kubectl get nodes -o wide -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone
kubectl get pods -A

aws eks describe-cluster --region "${AWS_REGION}" --name "${CLUSTER_NAME}" \
  --query 'cluster.{version: version, auth: accessConfig.authenticationMode, vpc: resourcesVpcConfig.vpcId, subnets: resourcesVpcConfig.subnetIds}' \
  --output json
echo "VPC_ID=${VPC_ID} SUBNET_1=${SUBNET_1} SUBNET_2=${SUBNET_2}"
```

**PASS bước 7:**

- Context hiện tại có chữ `aws-eks-mysql-platform-development`.
- Có đúng 3 node, đều `Ready`. Cột `INSTANCE-TYPE` là `t3.large`, cột `VERSION` bắt đầu bằng `v1.36.`, cột `EXTERNAL-IP` có IP, cột `ZONE` là một trong hai zone của bước 3.
- Các pod hệ thống (`aws-node`, `kube-proxy`, `coredns`, `metrics-server`) đều `Running`.
- `describe-cluster` in ra `"version": "1.36"` và `"auth": "API"`. `vpc` trùng `VPC_ID`, và `subnets` là đúng hai subnet ở dòng cuối.

**STOP khi** thiếu node, node không `Ready`, hoặc `EXTERNAL-IP` là `<none>`. Xem mục [Khi gặp lỗi](#khi-gặp-lỗi). Đây là chỗ đầu tiên cho thấy VPC của Terraform có đỡ được cluster hay không.

## Bước 8: Cài add-on (mỗi buổi)

```bash
eksctl create addon -f "${EKS_DIR}/addons.yaml"
eksctl get addon --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}"
kubectl get storageclass
kubectl -n kube-system get deploy ebs-csi-controller \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="ebs-plugin")].args}' \
  | grep -o -- '--extra-tags=[^"]*'
```

**PASS bước 8:**

- `eksctl get addon` có `eks-pod-identity-agent` và `aws-ebs-csi-driver` ở trạng thái `ACTIVE`.
- `kubectl get storageclass` có dòng `ebs-csi-default-sc (default)`. Mới thấy `gp2` thôi thì chờ khoảng 10 giây rồi chạy lại: StorageClass mặc định có thể hiện chậm vài giây.
- Lệnh cuối in `--extra-tags=lab-cluster=aws-eks-mysql-platform-development`: driver đã nhận tag của bước 3.2. Không in gì thì chưa đánh PASS. Xem lại `addons.yaml`, rồi cập nhật add-on bằng `eksctl update addon -f "${EKS_DIR}/addons.yaml"`.

Thiếu bước này thì mọi PVC của MySQL sẽ đứng `Pending` mãi. Lý do: Kubernetes đã bỏ phần hỗ trợ EBS có sẵn, và trên AWS chỉ EBS CSI driver mới tạo được ổ đĩa.

Runbook gốc còn bước 8.1 cài snapshot controller. Bài 16 backup bằng XtraBackup lên S3, không dùng snapshot của ổ EBS, nên runbook này bỏ bước đó.

## Bước 9: Chạy runbook MySQL operator

Làm theo [runbook MySQL operator](runbook-mysql-operator.md), từ bước 0 của nó. Bước dọn của runbook đó (bước 13) phải xong trước khi sang bước 10 dưới đây.

## Bước 10: Dọn cuối buổi

Kết thúc buổi thì làm ngay, đừng để cluster chạy qua đêm. Chạy mọi lệnh của bước này trong terminal đã `cd ~ && source ~/platform-cluster.env`.

### 10.1. Dọn bên trong cluster

Làm xong bước 13 của [runbook MySQL operator](runbook-mysql-operator.md#bước-13-dọn-sau-bài). **Nếu tạo cluster thất bại trước khi triển khai gì:** bỏ qua 10.1, đi thẳng tới 10.2.

Sau khi dọn workload trên cluster đang hoạt động, kiểm tra:

```bash
kubectl config current-context
kubectl get svc -A \
  -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
echo "exit=$?"
kubectl get pvc -A; echo "exit=$?"
kubectl get pv; echo "exit=$?"
```

**PASS 10.1:**

- Context hiện tại có chữ `aws-eks-mysql-platform-development`.
- Lệnh `svc` chỉ in `exit=0`: không còn Service kiểu LoadBalancer.
- Lệnh `pvc` và lệnh `pv` in `No resources found` và `exit=0`.

**STOP khi** có lệnh in `exit` khác 0, hoặc báo `Unable to connect to the server` hay lỗi đăng nhập. Lúc đó kubectl không hỏi được cluster, nên "không thấy gì" không có nghĩa là đã dọn xong. Context sai hoặc mất thì chạy `aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"` rồi chạy lại.

**Vì sao phải xoá PVC trước khi xoá cluster:** eksctl tự dọn load balancer do Service tạo ra trước khi xoá cluster, nhưng **không đụng tới ổ EBS**. Ổ của PVC chỉ được xoá khi PVC bị xoá lúc EBS CSI driver còn chạy. Xoá cluster trước thì ổ ở lại và tiếp tục tính tiền.

### 10.2. Xoá cluster

Xem trạng thái control plane, để chọn nhánh xoá:

```bash
echo "VPC_ID=${VPC_ID}"
aws eks describe-cluster --region "${AWS_REGION}" --name "${CLUSTER_NAME}" \
  --query 'cluster.status' --output text; echo "exit=$?"
```

**Chọn nhánh** theo lệnh `describe-cluster`:

- In `ACTIVE` hoặc `FAILED`, kèm `exit=0`: control plane còn, làm **nhánh A**.
- Báo `ResourceNotFoundException`: không có control plane, làm **nhánh B**.
- In `CREATING`, `UPDATING` hay `DELETING`: chờ vài phút rồi chạy lại.
- Lỗi khác (hết hạn đăng nhập, `AccessDenied`, mất mạng): **STOP**, sửa lỗi rồi chạy lại.

**Nhánh A, control plane còn:**

```bash
eksctl delete cluster -f "${EKS_DIR}/cluster.yaml" --wait
```

- eksctl dọn load balancer của Service, rồi xoá các stack: IAM role của add-on (nếu đã làm bước 8), nhóm máy, cuối cùng là stack cluster. **VPC không bị xoá**: nó không nằm trong stack nào của eksctl.
- `--wait` để eksctl chờ xoá xong mới thoát. Không có cờ này, xoá lỗi bạn sẽ không thấy.
- `ng-1` là managed node group, nên EKS rút pod khỏi node. Node nào sau 5 phút chưa rút xong thì EKS vẫn tắt máy. Đứng quá lâu thì xem mục [Khi gặp lỗi](#khi-gặp-lỗi), đừng bấm Ctrl+C.
- Lệnh bị ngắt giữa chừng thì chạy lại. Chạy lại mà báo `ResourceNotFoundException` (control plane đã xoá, có thể còn stack) thì chuyển sang nhánh B.

**PASS nhánh A:** lệnh kết thúc không lỗi, có dòng `all cluster resources were deleted`.

**Nhánh B, không có control plane:** xoá thẳng các stack còn lại bằng CloudFormation. Thường gặp khi bước 6 lỗi trước khi tạo xong control plane; lúc đó lệnh xoá của eksctl v0.231.0 dừng ngay ở bước tìm control plane, chưa xoá stack nào. Chỉ làm nhánh này khi bước 5 của lần tạo đó đã PASS, và bạn đang ở đúng account, tên cluster và region.

Liệt kê stack của cluster, lọc đúng tag tên cluster:

```bash
aws cloudformation describe-stacks --region "${AWS_REGION}" \
  --query "Stacks[?Tags[?Key=='alpha.eksctl.io/cluster-name' && Value=='${CLUSTER_NAME}'] && StackStatus!='DELETE_COMPLETE'].[StackName, StackStatus]" \
  --output text; echo "exit=$?"
```

- `exit` khác 0 hoặc báo lỗi: **STOP**, sửa lỗi rồi chạy lại.
- Chỉ in `exit=0`: không còn stack nào, sang 10.3.
- Có stack: xoá **lần lượt từng stack**, các stack khác trước, stack `eksctl-<tên cluster>-cluster` sau cùng. Stack ở `ROLLBACK_COMPLETE` cũng phải xoá; còn để đó thì lần tạo sau báo `already exists`.

Với mỗi stack, chép đúng tên từ danh sách vừa in vào dòng đầu, rồi chạy:

```bash
STACK='<tên-stack-chép-từ-danh-sách-trên>'
aws cloudformation update-termination-protection --region "${AWS_REGION}" \
    --stack-name "${STACK}" --no-enable-termination-protection \
  && aws cloudformation delete-stack --region "${AWS_REGION}" --stack-name "${STACK}" \
  && aws cloudformation wait stack-delete-complete --region "${AWS_REGION}" --stack-name "${STACK}"
echo "exit=$?"
```

- eksctl bật bảo vệ xoá (termination protection) cho mọi stack nó tạo, nên phải tắt trước. Ba lệnh nối bằng `&&`: lệnh sau chỉ chạy khi lệnh trước thành công.
- Stack đang `DELETE_IN_PROGRESS` thì chỉ chạy `aws cloudformation wait stack-delete-complete --region "${AWS_REGION}" --stack-name "${STACK}"; echo "exit=$?"`.
- **Chỉ xoá stack có tên bắt đầu bằng `eksctl-`.** Ba stack `aws-eks-mysql-platform-...` trong cùng region là phần nền của CI/CD, không được đụng tới; bộ lọc theo tag ở trên không in chúng ra.

**PASS mỗi stack:** `exit=0`. **STOP** khi `exit` khác 0: stack thường đã sang `DELETE_FAILED`, xem mục [Khi gặp lỗi](#khi-gặp-lỗi).

**PASS nhánh B:** chạy lại lệnh liệt kê stack, chỉ in `exit=0`.

### 10.3. Kiểm tra không còn sót

```bash
echo "== ${CLUSTER_NAME} @ ${AWS_REGION}, VPC_ID=${VPC_ID:-<rỗng>}"

# Cluster và stack CloudFormation
aws eks list-clusters --region "${AWS_REGION}" \
  --query "clusters[?@=='${CLUSTER_NAME}']" --output text; echo "exit=$?"
aws cloudformation describe-stacks --region "${AWS_REGION}" \
  --query "Stacks[?Tags[?Key=='alpha.eksctl.io/cluster-name' && Value=='${CLUSTER_NAME}'] && StackStatus!='DELETE_COMPLETE'].[StackName, StackStatus]" \
  --output text; echo "exit=$?"

# VPC của Terraform phải còn nguyên
aws ec2 describe-vpcs --region "${AWS_REGION}" --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Vpcs[].VpcId' --output text; echo "exit=$?"

# Trong VPC không còn card mạng và security group nào của cluster
aws ec2 describe-network-interfaces --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'NetworkInterfaces[].[NetworkInterfaceId, Description]' --output text; echo "exit=$?"
aws ec2 describe-security-groups --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[?GroupName!=`default`].[GroupId, GroupName]' --output text; echo "exit=$?"

# Ổ EBS và snapshot do EBS CSI driver của cluster này tạo (tag lab-cluster, bước 3.2).
# Chúng nằm ngoài cluster, không tự mất theo cluster
aws ec2 describe-volumes --region "${AWS_REGION}" \
  --filters "Name=tag:lab-cluster,Values=${CLUSTER_NAME}" \
  --query 'Volumes[].[VolumeId, Size, State, Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value]' \
  --output text; echo "exit=$?"
aws ec2 describe-snapshots --region "${AWS_REGION}" --owner-ids self \
  --filters "Name=tag:lab-cluster,Values=${CLUSTER_NAME}" \
  --query 'Snapshots[].[SnapshotId, VolumeSize, StartTime]' --output text; echo "exit=$?"
```

**PASS 10.3:**

- Mọi lệnh in `exit=0`.
- Lệnh VPC in đúng `VPC_ID`: VPC của Terraform còn đó.
- Các lệnh còn lại không in gì khác ngoài `exit=0`: không còn cluster, stack, card mạng, security group, ổ EBS hay snapshot.

**STOP, chưa đánh PASS khi** có lệnh in `exit` khác 0 hoặc báo lỗi. AWS CLI gặp lỗi thì không in kết quả, nên lúc đó "không thấy gì" không chứng minh đã xoá hết.

Còn sót thì xử lý như sau:

- **Stack chưa xoá xong:** chờ 1–2 phút rồi chạy lại. Stack ở `DELETE_FAILED` thì xem mục [Khi gặp lỗi](#khi-gặp-lỗi).
- **VPC không còn:** có ai đó đã xoá VPC ngoài Terraform. Workflow dò lệch sẽ đỏ; dựng lại bằng cách cho chạy lại workflow Terraform Apply, rồi làm lại bước 3.
- **Card mạng hay security group còn trong VPC:** chờ vài phút rồi chạy lại, vì EKS dọn chúng chậm hơn stack một chút. Vẫn còn thì cột mô tả và tên cho biết của ai; thường là của một load balancer chưa dọn, hoặc `eks-cluster-sg-...` của cluster vừa xoá. Xoá chúng trên Console. Để lại thì lần Terraform Destroy sau sẽ lỗi ở VPC.
- **Ổ EBS:** lệnh chỉ lọc ổ mang tag `lab-cluster` bằng đúng tên cluster; cột cuối là tên PVC. Trạng thái `available` là ổ của PVC chưa xoá trước khi xoá cluster: chép ID rồi xoá bằng `aws ec2 delete-volume --region "${AWS_REGION}" --volume-id vol-...`. Trạng thái `in-use` là ổ còn gắn vào máy, tức cluster chưa xoá xong: chờ rồi chạy lại.
- **Đừng xoá theo tag `ebs.csi.aws.com/cluster`.** Tag đó có cùng giá trị `true` ở mọi cluster dùng EBS CSI driver, nên không cho biết ổ thuộc cluster nào.

## Bước 11 (tuỳ chọn): Dọn kubeconfig

Xoá theo **nhánh A** của 10.2 thì eksctl tự gỡ context của cluster khỏi `~/.kube/config`. Context có thể còn sót khi xoá theo nhánh B, hoặc khi đã từng chạy `aws eks update-kubeconfig`: lệnh đó ghi một context riêng, tên dạng `arn:aws:eks:us-east-1:<account>:cluster/<tên cluster>`.

```bash
kubectl config get-contexts
kubectl config delete-context 'TÊN-CONTEXT-CHÉP-TỪ-CỘT-NAME'
```

Thay chuỗi trong dấu nháy bằng đúng tên ở cột `NAME`, là tên có chữ `aws-eks-mysql-platform-development`. Context của cluster khác thì giữ nguyên.

---

## Dọn khi bỏ cả môi trường

Sau bước 10, trên AWS chỉ còn phần của Terraform: VPC và bucket backup, không tốn tiền khi để yên. Muốn bỏ cả phần đó:

1. Bước 10.3 phải PASS: VPC còn card mạng hay security group của cluster thì Terraform không xoá được nó.
2. Chạy workflow **Terraform Destroy**, theo mục 9 của [plan 04](../plans/04-terraform-networking-va-s3-backup.md#9-dọn). Bucket backup bị xoá cùng mọi object bên trong.
3. Xoá file trên máy: `rm -rf ~/platform-cluster ~/platform-cluster.env`.

## Khi gặp lỗi

- **Bước 6 báo `UnsupportedAvailabilityZoneException`:** một subnet nằm ở zone mà EKS không nhận. Bước 3.1 đã kiểm zone ID nên lỗi này không nên xảy ra; nếu gặp, dọn theo 10.2 và 10.3. Chỗ phải sửa là zone của subnet, ở phía Terraform: xem mục 10 của [plan 04](../plans/04-terraform-networking-va-s3-backup.md#10-quyết-định-còn-mở).
- **Nhóm máy báo thiếu hạn mức (`VcpuLimitExceeded`):** dọn theo bước 10.2 và 10.3, quay lại bước 2.
- **Stack nhóm máy lỗi vì node không vào được cluster** (`NodeCreationFailure`, hoặc bước 7 thiếu node): node không ra được Internet. Chạy lại khối kiểm tra của bước 3.1: cột `MapPublicIpOnLaunch` phải `True`, và route table của hai subnet phải có route `0.0.0.0/0` tới Internet Gateway. Sai thì sửa ở phía Terraform, dọn theo 10.2 và 10.3, rồi tạo lại.
- **kubectl không thấy cluster** (terminal khác, lỡ xoá `~/.kube/config`): chạy `aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"`.
- **`eksctl create addon` báo add-on đã tồn tại:** add-on đã được cài trong buổi này. Xem bằng `eksctl get addon --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}"`. Đã `ACTIVE` thì không cần làm gì.
- **PVC đứng `Pending`:** chưa làm bước 8, hoặc `kubectl get storageclass` không có dòng `(default)`. Làm lại bước 8.
- **Pod đứng `Pending` với lý do `Insufficient memory`, `Insufficient cpu` hay `Too many pods`:** cluster đang chạy chồng nhiều thứ. Mỗi node t3.large nhận tối đa 35 pod. Xem bằng `kubectl describe pod <tên> -n <namespace>`.
- **Bước 10.2 (nhánh A) đứng lâu khi xoá nhóm máy:** eksctl in lặp lại dòng chờ stack `eksctl-<tên cluster>-nodegroup-ng-1`. Đừng bấm Ctrl+C. Mở terminal khác, chạy `cd ~ && source ~/platform-cluster.env`, rồi xem trạng thái nhóm máy và các sự kiện mới nhất của stack:

  ```bash
  aws eks describe-nodegroup --region "${AWS_REGION}" --cluster-name "${CLUSTER_NAME}" \
    --nodegroup-name ng-1 --query 'nodegroup.[status, health.issues]' --output json; echo "exit=$?"
  aws cloudformation describe-stack-events --region "${AWS_REGION}" \
    --stack-name "eksctl-${CLUSTER_NAME}-nodegroup-ng-1" --max-items 10 \
    --query 'StackEvents[].[Timestamp, LogicalResourceId, ResourceStatus, ResourceStatusReason]' \
    --output text; echo "exit=$?"
  ```

  - Nhóm máy `DELETING` và Events không có `DELETE_FAILED`: vẫn đang xoá, chờ tiếp.
  - Lệnh đầu báo `ResourceNotFoundException`: nhóm máy đã xoá xong, CloudFormation sắp xong stack. Chờ tiếp.
  - Nhóm máy `DELETE_FAILED`, hoặc Events có `DELETE_FAILED`: đọc `health.issues` và cột lý do ở cuối để biết vì sao. Xử lý nguyên nhân, chờ eksctl dừng, rồi chạy lại lệnh xoá ở nhánh A.
- **Stack ở `DELETE_FAILED`:** còn tài nguyên chặn, thường là security group còn được một card mạng dùng. Mở tab **Events** của stack trên CloudFormation Console xem tài nguyên nào chặn, xoá nó (chỉ xoá những gì nằm trong `VPC_ID`), rồi chạy lại lệnh xoá.
- **Job dò lệch của Terraform đỏ trong lúc cluster đang chạy:** mở log của job xem thứ gì lệch. Nếu chỉ là tag do EKS hay eksctl gắn lên subnet thì đó là hệ quả của việc tạo cluster, chưa phải sự cố; ghi lại để xử lý ở phía Terraform. Trường hợp này chưa được kiểm trên cluster thật.

## Nguồn

- [Runbook hạ tầng dùng chung](https://github.com/hieupham259/DevOps-Projects-with-Kubernetes-on-AWS/blob/master/shared-infrastructure/runbook-shared-infrastructure.md) của repo khoá học: runbook gốc, kèm nguồn chi tiết cho từng lệnh và từng hành vi của eksctl v0.231.0.
- [Plan 04](../plans/04-terraform-networking-va-s3-backup.md): VPC và bucket backup của dự án; [README của module `network`](../modules/network/README.md): bản thiết kế VPC và lý do không có security group, NACL.
- [eksctl: VPC configuration](https://docs.aws.amazon.com/eks/latest/eksctl/vpc-configuration.html): dùng VPC có sẵn bằng `vpc.id` và `vpc.subnets`; khi đó eksctl không tạo route table hay gateway, nhưng vẫn tạo security group; public subnet phải bật `MapPublicIpOnLaunch`.
- [eksctl: Addons](https://docs.aws.amazon.com/eks/latest/eksctl/addons.html), [Pod Identity associations](https://docs.aws.amazon.com/eks/latest/eksctl/pod-identity-associations.html), [Access entries](https://docs.aws.amazon.com/eks/latest/eksctl/access-entries.html), [Dry run](https://docs.aws.amazon.com/eks/latest/eksctl/dry-run.html).
- [EKS: networking requirements for VPC and subnets](https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html), [security group requirements](https://docs.aws.amazon.com/eks/latest/userguide/sec-group-reqs.html), [EBS CSI driver](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html), [Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html).
