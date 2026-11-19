# Runbook: Để operator chạy MySQL, xoá primary, backup và restore

Runbook này cài Percona Operator for MySQL bằng Helm, để nó dựng một cụm MySQL ba pod, xoá pod primary để xem cụm tự bầu primary mới, rồi backup lên S3, xoá nhầm một bảng và restore. Nó chạy trên cluster của [runbook cluster](runbook-shared-infrastructure.md), và backup vào bucket mà Terraform của repo đã tạo.

Đây là bản viết lại, cho dự án này, của [runbook bài 16](https://github.com/hieupham259/DevOps-Projects-with-Kubernetes-on-AWS/blob/master/Section%202/bai16-mysql-operator/runbook-mysql-operator.md) trong repo khoá học, dưới đây gọi là **runbook gốc**. Số bước được giữ nguyên để đối chiếu. Chưa rõ operator, CRD, custom resource và reconcile thì đọc phần kiến thức nền của bài 14 trong repo khoá học trước.

## Mục lục

- [Khác gì so với runbook gốc](#khác-gì-so-với-runbook-gốc)
- [Đã kiểm những gì](#đã-kiểm-những-gì)
- [Vài khái niệm dùng trong bài](#vài-khái-niệm-dùng-trong-bài)
- [Chi phí ước tính](#chi-phí-ước-tính)
- [Bước 0: Cluster đã sẵn sàng](#bước-0-cluster-đã-sẵn-sàng)
- [Bước 1: Tên bucket, thư mục làm việc và ba file YAML](#bước-1-tên-bucket-thư-mục-làm-việc-và-ba-file-yaml)
- [Bước 2: Kiểm tra bucket của Terraform](#bước-2-kiểm-tra-bucket-của-terraform)
- [Bước 3: IAM user, namespace `ps` và Secret](#bước-3-iam-user-namespace-ps-và-secret)
- [Bước 4: Cài operator](#bước-4-cài-operator)
- [Bước 5: Mô tả cụm muốn có, rồi cài](#bước-5-mô-tả-cụm-muốn-có-rồi-cài)
- [Bước 6: Kết nối và ghi dữ liệu](#bước-6-kết-nối-và-ghi-dữ-liệu)
- [Bước 7: Xoá pod primary](#bước-7-xoá-pod-primary)
- [Bước 8: Ghi tiếp và xem pod tự hồi phục](#bước-8-ghi-tiếp-và-xem-pod-tự-hồi-phục)
- [Bước 9: Backup lên S3](#bước-9-backup-lên-s3)
- [Bước 10: Lỗi cố ý, xoá bảng](#bước-10-lỗi-cố-ý-xoá-bảng)
- [Bước 11: Restore](#bước-11-restore)
- [Bước 12: Kiểm chứng những gì quay lại](#bước-12-kiểm-chứng-những-gì-quay-lại)
- [Bước 13: Dọn sau bài](#bước-13-dọn-sau-bài)
- [Khi gặp lỗi](#khi-gặp-lỗi)
- [Nguồn](#nguồn)

## Khác gì so với runbook gốc

| | Runbook gốc | Runbook này |
|---|---|---|
| Cluster | `basic-cluster` của runbook dùng chung | `aws-eks-mysql-platform-development`, dựng theo [runbook cluster](runbook-shared-infrastructure.md) |
| File biến | `~/shared-infrastructure.env` và `~/bai16-mysql-operator.env` | `~/platform-cluster.env` và `~/platform-mysql.env` |
| Thư mục làm việc | `~/bai16-mysql-operator`, chép ba file YAML từ repo khoá học | `~/platform-mysql`, ba file sinh bằng `cat <<EOF` |
| Bucket | bước 2 tạo `dop-mysql-backup-<8 ký tự>` bằng ba lệnh `aws s3api` | đã có, do Terraform tạo ở [plan 04](../plans/04-terraform-networking-va-s3-backup.md); bước 2 chỉ kiểm tra |
| Tên bucket | sinh ngẫu nhiên, lưu trong file biến | đọc từ SSM parameter `/development/aws-eks-mysql-platform/mysql-backup/bucket_name` |
| Tên IAM user và policy | trùng tên bucket | `aws-eks-mysql-platform-development-mysql-backup` |
| `values-backup.yaml` | chép file có tên bucket mẫu, rồi `sed` thay | sinh sẵn với tên bucket thật |
| Dọn bucket | xoá object rồi xoá bucket | chỉ xoá object dưới `shop/`; bucket do Terraform giữ |
| Dọn cluster | bước 10 của runbook dùng chung | [bước 10 của runbook cluster](runbook-shared-infrastructure.md#bước-10-dọn-cuối-buổi) |

Chart, số pod, cách cấp ổ EBS, cách backup và restore, các câu SQL và thứ tự dọn đều giữ nguyên.

## Đã kiểm những gì

Runbook gốc được viết ngày 11–12/11/2026 từ transcript bài 16, handout S02-L07, giá trị mặc định của chart `ps-db` 1.2.0 và mã nguồn operator v1.2.0. Ba file YAML của nó khớp hash Git với code của tác giả khoá học. Nội dung ba file ở bước 1 dưới đây chép từ đó.

Ngày **20/11/2026**, cho runbook này:

- Bucket và SSM parameter của Terraform đạt các chốt ở bước 2, bằng lệnh chỉ đọc.
- Khối lệnh của bước 1 đã chạy thử với thư mục nhà tạm: đọc được tên bucket, sinh đúng ba file YAML và file biến.
- Mọi khối lệnh qua `bash -n`.

**Chưa chạy thật** từ bước 3 trở đi, ở cả runbook gốc lẫn runbook này. Mọi PASS của các bước đó lấy từ handout, transcript, giá trị mặc định của chart và mã nguồn operator. Những PASS sau cần xác nhận ở lần chạy thật đầu tiên:

- pod MySQL và HAProxy hiện `2/2`;
- nhãn `mysql.percona.com/primary=true` và trường `.status.backupSource`;
- `AGE` của PVC sau restore;
- nguyên văn các dòng Helm 4 in ra khi `repo add`, `repo update`, `search repo`;
- cách cứu namespace `Terminating` bằng operator tạm ở namespace khác.

## Vài khái niệm dùng trong bài

- **Primary và secondary:** ba pod MySQL giữ ba bản dữ liệu giống nhau. Một pod nhận lệnh ghi (primary), hai pod còn lại chép theo (secondary).
- **Group replication và đa số:** ba pod tự bỏ phiếu với nhau. Còn 2 trên 3 pod sống là còn đa số, nên chúng tự bầu primary mới mà không cần ai ra lệnh. Mất 2 pod cùng lúc thì hết đa số, cụm ngừng nhận ghi.
- **HAProxy:** cửa trước của cụm. App chỉ nối tới một Service `shop-ps-db-haproxy`; HAProxy biết pod nào đang là primary và chuyển kết nối tới đó.
- **Failover:** vài giây giữa lúc primary chết và lúc primary mới nhận ghi. Trong lúc đó kết nối bị rớt; app thật phải tự thử lại.
- **StatefulSet và PVC:** mỗi pod MySQL có một ổ EBS riêng, gắn qua PVC. Pod bị xoá thì pod mới cùng tên gắn lại đúng ổ cũ, dữ liệu còn nguyên.
- **Finalizer:** một cái khoá chờ trên object. Kubernetes chưa xoá hẳn object cho tới khi chương trình giữ khoá, ở đây là operator, dọn xong và gỡ khoá. Gỡ operator trước thì không còn ai gỡ khoá, object kẹt mãi. Vì vậy bước dọn có thứ tự bắt buộc.
- **Backup vật lý:** XtraBackup chép các file dữ liệu của MySQL lên S3 thành nhiều mảnh, không phải một file `.sql`. Restore thay toàn bộ dữ liệu của cụm bằng bản đó; nó không "undo" riêng một bảng.

## Chi phí ước tính

| Hạng mục | Ước tính |
|---|---|
| Cluster (~0,39 USD/giờ, xem [runbook cluster](runbook-shared-infrastructure.md#chi-phí-ước-tính)) | khoảng 0,4–0,6 USD nếu cluster chạy 60–90 phút cho bài này |
| 3 ổ EBS 3 GiB của PVC (0,08 USD/GB-tháng) | dưới 0,01 USD; tính tiền tới khi xoá PVC ở bước 13 |
| Object backup trong bucket | không đáng kể: dữ liệu của lab rất nhỏ; tính tiền tới khi xoá object ở bước 13 |

- Bài không tạo load balancer: mọi Service của cụm là loại chỉ gọi được từ trong cluster. IAM user và policy không tốn tiền.
- Bước 1–2 chỉ dùng AWS CLI, làm được trong lúc một terminal khác đang tạo cluster. Bước 3 trở đi cần cluster, nên bước 0 phải PASS trước bước 3.

---

## Bước 0: Cluster đã sẵn sàng

Bài cần cluster đang chạy và đã có add-on lưu trữ. Buổi này chưa tạo cluster thì làm bước 5 → 8 của [runbook cluster](runbook-shared-infrastructure.md#bước-5-kiểm-tra-trước-khi-tạo-mỗi-buổi), khoảng 15–20 phút. Chưa làm bước 0–4 của runbook đó lần nào thì làm trước, một lần.

Mọi lệnh chạy trong **WSL `Ubuntu`** (`wsl -d Ubuntu`), không chạy trong PowerShell hay Git Bash. Mỗi lần mở terminal mới, chạy `cd ~ && source ~/platform-cluster.env` trước mọi lệnh khác. Không `source` file biến của khoá học trong cùng terminal.

```bash
cd ~ && source ~/platform-cluster.env
printf 'cluster=%s region=%s VPC_ID=%s\n' "${CLUSTER_NAME}" "${AWS_REGION}" "${VPC_ID}"
kubectl config current-context; echo "exit=$?"
kubectl get nodes; echo "exit=$?"

# Add-on của bước 8 runbook cluster: StorageClass mặc định và tag lab-cluster
kubectl get storageclass; echo "exit=$?"
kubectl -n kube-system get deploy ebs-csi-controller \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="ebs-plugin")].args}' \
  | grep -o -- '--extra-tags=[^"]*'

# Còn sót từ lần làm trước
kubectl get ns ps --ignore-not-found; echo "exit=$?"
kubectl get crd -o name | grep 'ps\.percona\.com'
printf 'kubectl=%s grep=%s\n' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}"
kubectl get pvc -A; echo "exit=$?"

# Công cụ của bài
helm version --short
```

**PASS bước 0:**

- Biến là `aws-eks-mysql-platform-development` / `us-east-1`, kèm một `VPC_ID`. Context có chữ tên cluster đó, **3 node `Ready`**. Operator đặt mỗi pod MySQL trên một node riêng, nên thiếu một node là cụm không dựng đủ.
- `kubectl get storageclass` có dòng `ebs-csi-default-sc (default)`.
- Lệnh `grep` in `--extra-tags=lab-cluster=aws-eks-mysql-platform-development`.
- Lệnh namespace không in tài nguyên nào, `exit=0`. Lệnh CRD in `kubectl=0 grep=1`: không có CRD nào của Percona. Lệnh `pvc` in `No resources found`, `exit=0`.
- `helm version --short` in `v4...`.

**STOP khi:**

- Có lệnh in `exit` khác 0, hoặc báo `Unable to connect to the server` hay lỗi đăng nhập. Context sai hoặc mất thì chạy `aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"` rồi chạy lại.
- Không có dòng `(default)`, hoặc không in `--extra-tags=...`: chưa làm bước 8 của runbook cluster, hoặc add-on chưa nhận tag. Làm lại [bước 8](runbook-shared-infrastructure.md#bước-8-cài-add-on-mỗi-buổi) cho tới khi PASS của nó đủ.
- Còn namespace `ps`, CRD `...ps.percona.com` hay PVC: lần làm trước chưa dọn. Làm [bước 13](#bước-13-dọn-sau-bài) rồi chạy lại bước này.
- Thiếu `helm`: cài Helm 4 theo tài liệu của Helm trước khi làm tiếp.

## Bước 1: Tên bucket, thư mục làm việc và ba file YAML

Đọc tên bucket từ SSM parameter mà Terraform đã ghi, rồi lưu vào file biến của bài:

```bash
cd ~ && source ~/platform-cluster.env
BUCKET="$(aws ssm get-parameter --region "${AWS_REGION}" \
  --name "/${ENVIRONMENT}/${PROJECT}/mysql-backup/bucket_name" \
  --query Parameter.Value --output text)"; echo "exit=$?"

if [ -n "${BUCKET}" ] && [ "${BUCKET}" != "None" ]; then
  cat > ~/platform-mysql.env <<EOF
export BUCKET=${BUCKET}
export BACKUP_IAM_NAME=${PROJECT}-${ENVIRONMENT}-mysql-backup
EOF
  echo "Đã ghi ~/platform-mysql.env"
else
  echo "STOP: không đọc được tên bucket, chưa ghi gì"
fi

source ~/platform-mysql.env
cat ~/platform-mysql.env
```

**PASS phần tên bucket:** `exit=0`, in `Đã ghi ...`. File biến có hai dòng: `export BUCKET=aws-eks-mysql-platform-development-mysql-backup-<số account>` và `export BACKUP_IAM_NAME=aws-eks-mysql-platform-development-mysql-backup`.

- `BUCKET` là tên bucket. `BACKUP_IAM_NAME` là tên dùng chung cho IAM user và IAM policy của backup ở bước 3.
- Chạy lại khối này thì file biến được ghi lại từ SSM. Tên bucket không đổi chừng nào Terraform chưa dựng lại bucket, nên chạy lại là an toàn. Dòng `POLICY_ARN` mà bước 3 thêm vào sẽ mất; bước 13 tự tra lại ARN theo tên nên không cần nó.

**STOP khi** in dòng `STOP:` hoặc `exit` khác 0: plan 04 chưa deploy, hoặc `PROJECT`, `ENVIRONMENT` trong `~/platform-cluster.env` sai.

Tạo thư mục làm việc và sinh ba file YAML:

```bash
mkdir -p ~/platform-mysql && cd ~/platform-mysql
source ~/platform-cluster.env && source ~/platform-mysql.env

cat > values-backup.yaml <<EOF
backup:
  enabled: true
  storages:
    s3-us-east-1:
      type: s3
      verifyTLS: true
      s3:
        bucket: ${BUCKET}
        prefix: shop
        region: ${AWS_REGION}
        credentialsSecret: s3-backup-creds
EOF

cat > backup.yaml <<'EOF'
apiVersion: ps.percona.com/v1
kind: PerconaServerMySQLBackup
metadata:
  name: backup1
  namespace: ps
spec:
  clusterName: shop-ps-db
  storageName: s3-us-east-1
EOF

cat > restore.yaml <<'EOF'
apiVersion: ps.percona.com/v1
kind: PerconaServerMySQLRestore
metadata:
  name: restore1
  namespace: ps
spec:
  clusterName: shop-ps-db
  backupName: backup1
EOF

pwd
ls -1
grep -n 'bucket:' values-backup.yaml
grep -n '\${' ./*.yaml || echo "Không còn biến chưa thay"
```

**PASS phần thư mục:** `pwd` in `/home/<tên>/platform-mysql`. `ls` có `backup.yaml`, `restore.yaml`, `values-backup.yaml`. Dòng `bucket:` mang đúng tên trong `BUCKET`. Dòng cuối in `Không còn biến chưa thay`.

- Ba file có cùng nội dung với ba file của bài 16; chỉ khác dòng `bucket:` mang tên thật thay cho tên mẫu.
- **Từ đây, mỗi terminal mới chạy:** `cd ~/platform-mysql && source ~/platform-cluster.env && source ~/platform-mysql.env`. Hai file biến không trùng tên biến nào.

Kiểm tra tài khoản và những thứ còn sót từ lần làm trước:

```bash
aws sts get-caller-identity --query Account --output text; echo "exit=$?"
aws iam list-users \
  --query "Users[?UserName=='${BACKUP_IAM_NAME}'].UserName" --output text; echo "exit=$?"
aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='${BACKUP_IAM_NAME}'].Arn" --output text; echo "exit=$?"
aws s3 ls "s3://${BUCKET}/shop/" --recursive --region "${AWS_REGION}" | wc -l
echo "exit=${PIPESTATUS[0]}"
```

**PASS bước 1:** lệnh đầu in đúng số account. Hai lệnh IAM chỉ in `exit=0`. Lệnh `s3 ls` in `0`: dưới `shop/` chưa có object nào.

**STOP khi:**

- Hai lệnh IAM in ra tên user hay ARN của policy: lần trước làm dở. Dọn theo [bước 13](#bước-13-dọn-sau-bài), rồi làm lại bước này.
- Lệnh `s3 ls` in số khác `0`: còn backup của lần trước. Bước 9 nhận biết backup mới bằng cách tìm file trong bucket, nên object cũ sẽ làm chốt đó PASS nhầm. Xoá chúng bằng phần object của chặng 13.5.
- Dòng `exit` cuối là `1` kèm số `0`: bình thường. `aws s3 ls` trả mã `1` khi thư mục con chưa có gì.
- Dòng `exit` cuối khác `0` và khác `1`, hoặc lệnh báo lỗi: AWS CLI không đọc được bucket. Sửa lỗi rồi chạy lại.

## Bước 2: Kiểm tra bucket của Terraform

Runbook gốc tạo bucket ở bước này. Ở đây bucket đã có; chỉ kiểm tra nó đúng như bài 16 cần:

```bash
aws s3api get-public-access-block --bucket "${BUCKET}" --region "${AWS_REGION}" \
  --query 'PublicAccessBlockConfiguration' --output json; echo "exit=$?"
aws s3api get-bucket-encryption --bucket "${BUCKET}" --region "${AWS_REGION}" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].[ApplyServerSideEncryptionByDefault.SSEAlgorithm, BucketKeyEnabled]' \
  --output text; echo "exit=$?"
aws s3api get-bucket-location --bucket "${BUCKET}" --query 'LocationConstraint' --output text; echo "exit=$?"
```

**PASS bước 2:**

- Cả ba lệnh in `exit=0`.
- `get-public-access-block` in bốn dòng đều `true`. `get-bucket-encryption` in `AES256` và `True`.
- `get-bucket-location` in `None`. Đó là cách S3 gọi us-east-1, khớp với dòng `region:` trong `values-backup.yaml`.

**STOP khi** có `exit` khác 0 hoặc giá trị khác. Bucket do Terraform quản lý: sai thì sửa ở phía Terraform, không sửa bằng lệnh.

## Bước 3: IAM user, namespace `ps` và Secret

Backup cần một danh tính AWS **chỉ được đụng vào đúng bucket này**. Key của nó sẽ nằm trong một Secret của cluster, nên quyền càng hẹp càng ít rủi ro.

Viết policy và tạo user:

```bash
cat > policy.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Sid":"ListTheBackupBucket","Effect":"Allow","Action":"s3:ListBucket","Resource":"arn:aws:s3:::${BUCKET}"},
 {"Sid":"ReadWriteBackupObjects","Effect":"Allow","Action":["s3:PutObject","s3:GetObject"],"Resource":"arn:aws:s3:::${BUCKET}/*"}]}
EOF
grep -c "arn:aws:s3:::${BUCKET}" policy.json

aws iam create-user --user-name "${BACKUP_IAM_NAME}" --query 'User.UserName' --output text; echo "exit=$?"
POLICY_ARN=$(aws iam create-policy --policy-name "${BACKUP_IAM_NAME}" \
    --policy-document file://policy.json --query Policy.Arn --output text) \
  && sed -i '/^export POLICY_ARN=/d' ~/platform-mysql.env \
  && echo "export POLICY_ARN=${POLICY_ARN}" >> ~/platform-mysql.env
echo "exit=$?"
aws iam attach-user-policy --user-name "${BACKUP_IAM_NAME}" --policy-arn "${POLICY_ARN}"; echo "exit=$?"
cat ~/platform-mysql.env
```

**PASS phần IAM:** `grep -c` in `2`. `create-user` in lại tên user. Ba dòng `exit=0`. File biến giờ có ba dòng: `BUCKET`, `BACKUP_IAM_NAME` và `export POLICY_ARN=arn:aws:iam::<account>:policy/aws-eks-mysql-platform-development-mysql-backup`.

Policy cho ba quyền: liệt kê bucket, ghi object, đọc object. Không có quyền xoá và không đụng được bucket nào khác.

**STOP khi** có `exit` khác 0. `EntityAlreadyExists` nghĩa là user hay policy đã có từ lần trước: quay lại phần kiểm tra còn sót ở bước 1.

Tạo namespace, và xem user chưa có access key nào:

```bash
kubectl config current-context; echo "exit=$?"
kubectl create namespace ps; echo "exit=$?"
aws iam list-access-keys --user-name "${BACKUP_IAM_NAME}" \
  --query 'length(AccessKeyMetadata)' --output text; echo "exit=$?"
```

**PASS trước khi tạo key:** context có chữ `aws-eks-mysql-platform-development`, in `namespace/ps created`, số key là `0`, ba dòng `exit=0`. Chưa PASS thì **không** chạy khối dưới: phần bí mật của key chỉ lấy được đúng một lần, lúc tạo.

Tạo access key và đưa thẳng vào Secret, không in ra màn hình và không ghi ra file:

```bash
read -r AK SK < <(aws iam create-access-key --user-name "${BACKUP_IAM_NAME}" \
  --query "AccessKey.[AccessKeyId,SecretAccessKey]" --output text)
if [ -n "${AK}" ] && [ -n "${SK}" ]; then
  kubectl -n ps create secret generic s3-backup-creds \
    --from-literal=AWS_ACCESS_KEY_ID="${AK}" --from-literal=AWS_SECRET_ACCESS_KEY="${SK}"
  echo "exit=$?"
else
  echo "STOP: không nhận được access key, chưa tạo Secret"
fi
unset AK SK
```

**PASS phần Secret:** in `secret/s3-backup-creds created` và `exit=0`.

**Không chạy `kubectl get secret ... -o yaml` hay `-o json` lên Secret này**, và tránh cả `kubectl describe secret`. Giá trị trong Secret chỉ được đổi sang base64, ai đọc được cũng giải ngược được, nên in ra là lộ key.

**STOP khi** in dòng `STOP:` hoặc `exit` khác 0. Key có thể đã được tạo mà không vào được Secret: xem mục [Khi gặp lỗi](#khi-gặp-lỗi) để xoá key đó rồi tạo lại.

Kiểm tra nền của bài:

```bash
kubectl get nodes
kubectl -n ps get secret s3-backup-creds
kubectl -n ps get secret s3-backup-creds \
  -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}'
aws iam list-access-keys --user-name "${BACKUP_IAM_NAME}" \
  --query 'length(AccessKeyMetadata)' --output text
kubectl get storageclass
```

**PASS bước 3:** 3 node `Ready`. Secret có cột `DATA` là `2`. Lệnh `go-template` in đúng hai tên `AWS_ACCESS_KEY_ID` và `AWS_SECRET_ACCESS_KEY`; nó chỉ in tên, không in giá trị. Số access key là `1`. StorageClass có dòng `ebs-csi-default-sc (default)`.

## Bước 4: Cài operator

```bash
helm repo add percona https://percona.github.io/percona-helm-charts/
helm repo update
helm search repo percona/ps- --version 1.2.0
```

**PASS phần repo:** Helm báo đã thêm repo `percona` (hoặc repo đã có với cùng cấu hình), cập nhật xong. `helm search` có hai dòng `percona/ps-db` và `percona/ps-operator`, cột `CHART VERSION` đều là `1.2.0`.

```bash
helm install ps-operator percona/ps-operator --version 1.2.0 -n ps --wait; echo "exit=$?"
kubectl -n ps get pods
kubectl get crd -o name | grep 'ps\.percona\.com'
```

**`helm install ps-operator ...`:** cài chương trình operator và dạy Kubernetes 4 loại object mới. Xong bước này chưa có MySQL nào.

**PASS bước 4:**

- `helm install` in `NAME: ps-operator`, `NAMESPACE: ps`, `STATUS: deployed`, `REVISION: 1`, rồi `exit=0`.
- Có một pod `ps-operator-...`, `1/1 Running`.
- Có đúng 4 CRD: `perconaservermysqls`, `perconaservermysqlbackups`, `perconaservermysqlrestores`, `perconaservermysqlclustersets`, đều đuôi `.ps.percona.com`.

Ghi chú:

- Ghim `--version 1.2.0` là cố ý: để operator tự lên bản mới bên dưới một database đang chạy là cách dễ biến một lần nâng chart thành sự cố.
- Operator này chỉ theo dõi namespace nó được cài vào (`watchAllNamespaces: false` là mặc định của chart). Vì vậy cụm MySQL ở bước sau cũng phải nằm trong `ps`.

**STOP khi** `helm install` báo lỗi, pod không lên `Running`, hoặc thiếu CRD.

## Bước 5: Mô tả cụm muốn có, rồi cài

Xem lại file values đã sinh ở bước 1:

```bash
cat values-backup.yaml
echo "BUCKET=${BUCKET}"
```

**PASS file values:** dòng `bucket:` là đúng tên trong `BUCKET`, dòng `region:` là `us-east-1`.

File này chỉ nói: bật backup, có một nơi lưu tên `s3-us-east-1`, kiểu S3, bucket nào, thư mục con `shop`, region nào, key nằm ở Secret nào. Nó không nhắc gì tới replication, failover hay HAProxy: giá trị mặc định của chart đã xin 3 pod MySQL và 3 pod HAProxy, phần còn lại operator tự lo.

Cài cụm và theo dõi:

```bash
helm install shop percona/ps-db --version 1.2.0 -n ps -f values-backup.yaml; echo "exit=$?"
kubectl -n ps get ps -w
```

**`helm install shop ...`:** nộp một object ghi "tôi muốn một cụm MySQL, backup vào bucket này". Operator đọc object đó rồi mới dựng 3 pod MySQL, 3 pod HAProxy, ổ đĩa và mật khẩu.

`shop` là tên bạn đặt cho lần cài này, Helm gọi là tên release. Nó không phải tên chart, tên namespace hay tên database.

`helm install` in phần `NOTES:` có gợi ý vào thẳng pod `shop-ps-db-mysql-0`. Đừng chạy gợi ý đó: runbook nối qua HAProxy.

Lệnh thứ hai đứng theo dõi, mỗi lần trạng thái đổi thì in thêm một dòng. Cột `STATE` lúc đầu có thể trống, rồi `initializing`, cuối cùng là `ready`. Mất vài phút, phần lớn là kéo image. **Khi thấy `ready` thì nhấn Ctrl+C.**

Xem những gì operator đã dựng:

```bash
kubectl -n ps get pods,svc,pvc
kubectl -n ps get pods -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName
aws ec2 describe-volumes --region "${AWS_REGION}" \
  --filters "Name=tag:lab-cluster,Values=${CLUSTER_NAME}" \
  --query 'Volumes[].[VolumeId, Size, State, Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value]' \
  --output text; echo "exit=$?"
```

**PASS bước 5:**

- Dòng cuối của lệnh theo dõi: `shop-ps-db`, cột `REPLICATION` là `group-replication`, `ENDPOINT` có `shop-ps-db-haproxy`, `STATE` là `ready`, `MYSQL` là `3`, `HAPROXY` là `3`.
- Pod: `shop-ps-db-mysql-0/1/2` và `shop-ps-db-haproxy-0/1/2`, đều `2/2 Running`, cùng pod operator.
- **5 Service**: `shop-ps-db-haproxy` (cái duy nhất app nối vào), và `shop-ps-db-mysql`, `shop-ps-db-mysql-primary`, `shop-ps-db-mysql-proxy`, `shop-ps-db-mysql-unready` mà operator dùng nội bộ. Không có cái nào kiểu `LoadBalancer`.
- 3 PVC `datadir-shop-ps-db-mysql-0/1/2`, đều `Bound`, `3Gi`, StorageClass `ebs-csi-default-sc`.
- Bảng `POD`/`NODE`: ba pod MySQL nằm trên ba node khác nhau, ba pod HAProxy cũng vậy.
- Lệnh `aws` in 3 dòng: ổ 3 GiB, `in-use`, cột cuối là tên ba PVC trên, rồi `exit=0`.

**Sau bước 5, cluster có thêm Secret `shop-ps-db-secrets`.** Bạn không tạo nó. Operator tự tạo lúc dựng cụm: nó sinh mật khẩu ngẫu nhiên cho các tài khoản hệ thống của MySQL (`root`, `operator`, `xtrabackup`, ...) rồi cất vào Secret này.

**STOP khi** cụm đứng ở `initializing` quá 10 phút, hoặc `STATE` là `error`. Xem pod bằng `kubectl -n ps get pods` và mục [Khi gặp lỗi](#khi-gặp-lỗi).

**Lệnh `aws` không in dòng nào trong khi PVC đã `Bound`:** driver chưa gắn tag `lab-cluster`. Bài vẫn làm tiếp được, nhưng bước 10.3 của runbook cluster sẽ không thấy ổ còn sót. Ghi lại để ở bước 13 kiểm tra kỹ bằng `kubectl get pv`.

## Bước 6: Kết nối và ghi dữ liệu

Từ đây dùng hai terminal: **terminal kubectl** là terminal đang dùng từ đầu, **terminal SQL** là terminal mở mới ở bước này.

Mở một terminal **WSL `Ubuntu`** mới làm terminal SQL:

```bash
cd ~/platform-mysql && source ~/platform-cluster.env
kubectl config current-context; echo "exit=$?"
ROOT_PWD=$(kubectl -n ps get secret shop-ps-db-secrets -o jsonpath='{.data.root}' | base64 -d)
[ -n "${ROOT_PWD}" ] && echo "ROOT_PWD: đã có" || echo "STOP: ROOT_PWD rỗng"
```

**PASS trước khi nối:** context có chữ `aws-eks-mysql-platform-development`, in `ROOT_PWD: đã có`. Operator đã tự sinh mật khẩu root ngẫu nhiên vào Secret `shop-ps-db-secrets`; lệnh đọc nó vào biến mà không in ra. Đừng `echo` biến này.

```bash
kubectl -n ps run mysql-client -it --rm --restart=Never --image=percona/percona-server:8.4.10-10.1 \
  --env="MYSQL_PWD=$ROOT_PWD" --command -- mysql -h shop-ps-db-haproxy -P 3306 -uroot
```

Lệnh chạy một pod tạm tên `mysql-client`, trong đó là chương trình `mysql` nối tới Service HAProxy ở cổng 3306. Khi thấy dấu nhắc `mysql>` là đã vào. Không thấy gì thì nhấn Enter một lần. Mật khẩu nằm trong cấu hình của pod tạm này, nên đừng chạy `kubectl describe pod mysql-client` hay `get pod mysql-client -o yaml` khi đang chia sẻ màn hình.

Tại dấu nhắc `mysql>`:

```sql
SELECT @@version;
CREATE DATABASE weather;
CREATE TABLE weather.cities (id INT PRIMARY KEY, name VARCHAR(40), temp_c DECIMAL(4,1));
INSERT INTO weather.cities VALUES (1,'Cairo',34.5),(2,'London',14.0),(3,'Tokyo',22.3),(4,'Sydney',18.9),(5,'Toronto',9.2);
SELECT MEMBER_HOST, MEMBER_ROLE, MEMBER_STATE FROM performance_schema.replication_group_members;
SELECT @@hostname;
```

**PASS bước 6:**

- `@@version` là `8.4.10-10`.
- Ba lệnh tạo và ghi đều `Query OK`; lệnh `INSERT` báo `5 rows affected`.
- Bảng thành viên có 3 dòng, `MEMBER_HOST` bắt đầu bằng `shop-ps-db-mysql-0`, `-1`, `-2`: một `PRIMARY`, hai `SECONDARY`, cả ba `ONLINE`.
- `@@hostname` in tên một pod, ví dụ `shop-ps-db-mysql-0`. Đó là pod HAProxy đang đưa bạn tới, tức primary. **Ghi lại tên này**, bước sau xoá đúng pod đó.

**STOP khi** báo `ERROR 1045 ... Access denied`: `ROOT_PWD` rỗng hoặc sai. Xem mục [Khi gặp lỗi](#khi-gặp-lỗi). Giữ terminal SQL mở tới hết bước 12.

## Bước 7: Xoá pod primary

Ở **terminal kubectl**, xem operator đang coi pod nào là primary:

```bash
kubectl -n ps get pods -l mysql.percona.com/primary=true -o name; echo "exit=$?"
```

**PASS trước khi xoá:** in đúng một dòng `pod/shop-ps-db-mysql-<số>`, trùng với `@@hostname` ở bước 6. Nếu lệnh không in tên nào thì lấy tên theo `@@hostname`: nhãn này đọc từ mã nguồn operator, chưa kiểm trên cluster thật. Hai tên **khác nhau** thì STOP, chạy lại `SELECT @@hostname;` và lệnh trên.

Sửa số cuối ở dòng đầu cho đúng tên pod primary, rồi chạy:

```bash
PRIMARY_POD=shop-ps-db-mysql-0
kubectl -n ps delete pod "${PRIMARY_POD}"
```

**Không chờ lệnh xoá trả về.** Chuyển ngay sang **terminal SQL** và chạy lại:

```sql
SELECT @@hostname;
```

**PASS bước 7:**

- Terminal SQL báo mất kết nối trước, kiểu:

  ```text
  ERROR 2013 (HY000): Lost connection to MySQL server during query
  No connection. Trying to reconnect...
  ```

  rồi tự nối lại và in tên **một pod khác** với pod vừa xoá. Thông báo mất kết nối có thể mang mã khác (2006, 2003); điều cần thấy là kết nối bị rớt rồi có lại. Nếu lần nối lại đầu thất bại, chờ vài giây rồi chạy lại câu lệnh.
- Terminal kubectl báo pod đã `deleted`.

Hai trên ba thành viên vẫn là đa số, nên nhóm tự bầu primary mới trong hai pod còn lại, và HAProxy chuyển kết nối mới sang đó. Vài giây rớt kết nối không phải lỗi cần sửa: đó chính là khoảng failover, và mọi app nói chuyện với cụm này phải biết thử lại.

**STOP khi** sau khoảng một phút vẫn không nối lại được, hoặc `@@hostname` vẫn in tên pod cũ.

## Bước 8: Ghi tiếp và xem pod tự hồi phục

Ở **terminal SQL**, chứng minh cụm đã nhận ghi trở lại:

```sql
INSERT INTO weather.cities VALUES (6,'Berlin',16.4);
```

Ở **terminal kubectl**:

```bash
kubectl -n ps get pods -w
```

Pod vừa xoá quay lại: `Terminating`, `Pending`, `Init`, rồi `2/2 Running`. Tuỳ lúc bắt đầu xem, có thể chỉ thấy các trạng thái sau. **Khi pod đó `2/2 Running` thì nhấn Ctrl+C**, rồi:

```bash
kubectl -n ps get pods -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName
kubectl -n ps get pvc
```

Ở **terminal SQL**:

```sql
SELECT MEMBER_HOST, MEMBER_ROLE, MEMBER_STATE FROM performance_schema.replication_group_members;
```

**PASS bước 8:**

- `INSERT` báo `Query OK, 1 row affected`.
- Pod đã xoá chạy lại `2/2 Running`, trên cùng node như bảng ở bước 5.
- 3 PVC vẫn `Bound`, cột `AGE` của cả ba vẫn tính từ bước 5: pod mới gắn lại đúng ổ cũ, không có ổ nào bị tạo lại.
- Bảng thành viên: cả ba `ONLINE`, pod vừa xoá giờ là `SECONDARY`. Còn thấy `RECOVERING` thì chờ vài giây rồi chạy lại.

Không ai phải làm tay việc nào trong số này.

**STOP khi** pod không lên lại, hoặc sau vài phút vẫn chưa đủ ba thành viên `ONLINE`.

## Bước 9: Backup lên S3

Ở **terminal SQL**, ghi lại checksum của bảng để lát nữa so:

```sql
CHECKSUM TABLE weather.cities;
```

**Chép con số ở cột `Checksum` ra giấy hoặc ghi chú.** Bước 12 so lại với nó.

Ở **terminal kubectl**:

```bash
cat backup.yaml
kubectl apply -f backup.yaml; echo "exit=$?"
kubectl -n ps get ps-backup -w
```

Cột `STATE` đi qua `Starting`, `Running`, tới `Succeeded`. **Khi thấy `Succeeded` thì nhấn Ctrl+C**, rồi:

```bash
kubectl -n ps get ps-backup
kubectl -n ps get ps-backup backup1 -o jsonpath='{.status.backupSource}{"\n"}'
kubectl -n ps get pods -l mysql.percona.com/primary=true -o name
aws s3 ls "s3://${BUCKET}/shop/" --recursive --region "${AWS_REGION}" | grep cities
printf 'aws=%s grep=%s\n' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}"
```

**PASS bước 9:**

- `backup.yaml` là kind `PerconaServerMySQLBackup`, tên `backup1`, `clusterName: shop-ps-db`, `storageName: s3-us-east-1`, đúng tên nơi lưu đã khai ở bước 1.
- `apply` in `perconaservermysqlbackup.ps.percona.com/backup1 created`, `exit=0`.
- `get ps-backup`: `backup1`, `STORAGE` là `s3-us-east-1`, `DESTINATION` bắt đầu bằng `s3://` kèm tên bucket và `shop/`, `STATE` là `Succeeded`.
- Dòng `backupSource` là tên một pod MySQL **khác** pod primary mà lệnh ngay dưới in ra: backup chạy trên một secondary, nên primary vẫn phục vụ suốt lúc đó.
- Lệnh `aws s3 ls` in ít nhất một dòng có chữ `cities`, rồi `aws=0 grep=0`. Bảng nằm trong bucket dưới dạng các mảnh của bản backup, không phải file `.sql`.

**STOP khi** `STATE` là `Failed` hay `Error`, hoặc không có dòng `cities`. Xem mục [Khi gặp lỗi](#khi-gặp-lỗi). **Chưa sang bước 10 khi backup chưa `Succeeded`:** cả bài dựa vào việc dòng Madrid được ghi *sau* backup.

## Bước 10: Lỗi cố ý, xoá bảng

Ở **terminal SQL**:

```sql
INSERT INTO weather.cities VALUES (7,'Madrid',24.1);
DROP TABLE weather.cities;
SHOW TABLES FROM weather;
SELECT COUNT(*) FROM weather.cities;
```

**PASS bước 10:** hai lệnh đầu `Query OK`. `SHOW TABLES` in `Empty set`. Lệnh cuối lỗi, đúng như mong đợi:

```text
ERROR 1146 (42S02): Table 'weather.cities' doesn't exist
```

Dòng Madrid được ghi **sau** khi backup xong. Nhớ điều này cho bước 12.

## Bước 11: Restore

Ở **terminal kubectl**:

```bash
cat restore.yaml
kubectl apply -f restore.yaml; echo "exit=$?"
kubectl -n ps get ps -w
```

Lệnh cuối chỉ để **quan sát** cụm đi xuống rồi lên lại. Cột `STATE` thường đi qua `stopping`, `paused`, `initializing`, rồi `ready`; mất vài phút. Hai điều dễ nhầm:

- Dòng đầu tiên in ra có thể vẫn là `ready`. Đó là trạng thái **cũ**, lúc operator chưa bắt tay vào restore. Đừng coi đó là xong.
- Lệnh theo dõi bắt đầu từ trạng thái lúc bạn gõ, nên có thể không thấy `stopping` hay `paused`. Không thấy đủ cũng không sao.

Nhấn Ctrl+C lúc nào cũng được. Restore xong hay chưa là do object `restore1` cho biết:

```bash
kubectl -n ps get ps-restore -w
```

**Khi `restore1` có `STATE` là `Succeeded` thì nhấn Ctrl+C.** Nếu nó đã `Succeeded` từ trước thì dòng đó hiện ngay. Rồi kiểm tra cụm:

```bash
kubectl -n ps get ps
kubectl -n ps get pods
kubectl -n ps get pvc
```

**PASS bước 11:**

- `restore.yaml` là kind `PerconaServerMySQLRestore`, tên `restore1`, `clusterName: shop-ps-db`, `backupName: backup1`.
- `apply` in `perconaservermysqlrestore.ps.percona.com/restore1 created`, `exit=0`.
- `restore1` có `STATE` là `Succeeded`. **Đây là chốt hoàn tất của bước này**; thấy hay không thấy các trạng thái trung gian không quyết định PASS.
- `get ps`: `STATE` là `ready`, `MYSQL` là `3`, `HAPROXY` là `3`.
- 6 pod của cụm `2/2 Running`. 3 PVC `Bound`.
- Theo mã nguồn operator, `datadir-shop-ps-db-mysql-0` giữ `AGE` cũ, còn PVC của `-1` và `-2` có `AGE` mới vài phút: operator khôi phục bản backup vào một thành viên, xoá ổ của hai thành viên kia, rồi để chúng chép lại toàn bộ từ thành viên đầu. Chi tiết này chưa kiểm trên cluster thật; `AGE` khác đi thì ghi lại, chưa phải lý do STOP.

Restore không phải nút "undo" cho một bảng. Nó hạ **cả cụm**: database không nối được trong khoảng 2 phút.

**STOP khi** `restore1` là `Failed` hay `Error`, hoặc sau 15 phút vẫn chưa `Succeeded`. Xem mục [Khi gặp lỗi](#khi-gặp-lỗi).

## Bước 12: Kiểm chứng những gì quay lại

Ở **terminal SQL**. Kết nối cũ đã rớt lúc restore, nên câu lệnh đầu có thể báo mất kết nối rồi tự nối lại; nếu chỉ thấy lỗi thì chạy lại câu lệnh:

```sql
SELECT * FROM weather.cities ORDER BY id;
CHECKSUM TABLE weather.cities;
```

**PASS bước 12:**

- Có đúng **6 dòng**, id 1 → 6: Cairo, London, Tokyo, Sydney, Toronto, Berlin.
- **Không có Madrid.** Berlin còn vì được ghi trước backup; Madrid mất vì được ghi sau.
- `Checksum` bằng đúng con số đã chép ở bước 9.

Đây là bài học của restore: **mọi thứ ghi sau lúc backup đều mất**, bất kể sự cố bắt đầu thế nào. Vì vậy ở môi trường thật, backup chạy theo lịch; chạy càng dày thì khi phải restore càng mất ít.

**STOP khi** số dòng khác 6, còn Madrid, hoặc checksum lệch. Terminal SQL bị thoát về dấu nhắc bash thì xem mục [Khi gặp lỗi](#khi-gặp-lỗi).

## Bước 13: Dọn sau bài

Phần dọn có **thứ tự bắt buộc**. Làm sai thứ tự thì tài nguyên kẹt lại, hoặc ổ EBS ở lại tính tiền. Bài làm trọn hay làm dở đều dọn theo cùng thứ tự này: chặng 13.2 kiểm kê những gì đang có, các chặng sau chỉ dọn thứ mà kiểm kê cho thấy đang có.

**Bucket không bị xoá ở bước này.** Nó do Terraform quản lý; xoá bằng lệnh thì state của Terraform lệch với AWS. Bước này chỉ xoá các object backup bên trong.

**13.1. Thoát client.** Nếu đã mở terminal SQL ở bước 6, ở **terminal SQL**:

```sql
exit
```

kubectl báo pod `mysql-client` đã `deleted`. Đóng terminal SQL.

**13.2. Nạp biến và kiểm kê.** Ở **terminal kubectl**:

```bash
cd ~/platform-mysql && source ~/platform-cluster.env && source ~/platform-mysql.env
kubectl config current-context; echo "exit=$?"
echo "BUCKET=${BUCKET} BACKUP_IAM_NAME=${BACKUP_IAM_NAME}"

# Trong cluster
kubectl get ns ps --ignore-not-found; echo "exit=$?"
kubectl get crd -o name | grep 'ps\.percona\.com'
printf 'kubectl=%s grep=%s\n' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}"
helm list -n ps -a; echo "exit=$?"
kubectl -n ps get pod mysql-client --ignore-not-found; echo "exit=$?"
kubectl -n ps get pvc; echo "exit=$?"

# Trên AWS. ARN của policy tra theo tên, không dựa vào file biến
aws s3 ls "s3://${BUCKET:?}/shop/" --recursive --region "${AWS_REGION}" | wc -l
echo "s3 exit=${PIPESTATUS[0]}"
aws iam list-users \
  --query "Users[?UserName=='${BACKUP_IAM_NAME:?}'].UserName" --output text; echo "exit=$?"
POLICY_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='${BACKUP_IAM_NAME:?}'].Arn" --output text); echo "exit=$?"
echo "POLICY_ARN=${POLICY_ARN:-<chưa có policy>}"
```

**PASS 13.2** là *đọc được hiện trạng*, chưa phải đã sạch: context có chữ `aws-eks-mysql-platform-development`; `BUCKET` và `BACKUP_IAM_NAME` không rỗng; mọi dòng `exit` là `0` và dòng CRD có `kubectl=0`. Riêng dòng `s3 exit` là `0` hoặc `1`: `aws s3 ls` trả `1` khi `shop/` chưa có gì.

Đọc kết quả để biết phải làm chặng nào:

| Kiểm kê in ra | Việc phải làm |
|---|---|
| pod `mysql-client` | `kubectl -n ps delete pod mysql-client` |
| tên CRD `...ps.percona.com` (dòng CRD có `grep=0`), hoặc release `shop`, `ps-operator` trong `helm list` | chặng 13.3 |
| PVC trong `ps` | chặng 13.4 |
| số object dưới `shop/` khác `0` | phần object của 13.5 |
| tên user | phần user của 13.5 |
| `POLICY_ARN=arn:aws:iam::...` | phần policy của 13.5 |
| namespace `ps`, hoặc tên CRD | chặng 13.6 |

Thứ nào không in ra thì chưa từng được tạo, hoặc đã dọn: bỏ qua phần tương ứng. Chặng 13.7 lúc nào cũng làm.

**STOP khi** có `exit` khác 0 hoặc `kubectl` khác 0: lúc đó "không in ra" không có nghĩa là không có. `BUCKET` rỗng thì chạy lại khối đầu của bước 1 để ghi lại file biến. Các lệnh xoá bên dưới viết `${BUCKET:?}` và `${BACKUP_IAM_NAME:?}`: biến rỗng thì lệnh tự dừng thay vì chạy với tên trống.

**13.3. Gỡ restore, backup và cụm MySQL; chờ; rồi mới gỡ operator.** Làm khi 13.2 có CRD của Percona hoặc có release trong `helm list`.

Có CRD thì xoá hai object của bước 9 và 11. `--ignore-not-found` bỏ qua object chưa từng tạo:

```bash
kubectl delete -f restore.yaml -f backup.yaml --ignore-not-found; echo "exit=$?"
```

`helm list` có release `shop` thì gỡ nó:

```bash
helm uninstall shop -n ps; echo "exit=$?"
```

Có CRD thì chờ object của cụm biến mất:

```bash
kubectl -n ps get ps; echo "exit=$?"
```

**Chạy lại lệnh này cho tới khi nó in `No resources found in ps namespace.`** Thường dưới một phút: operator tắt các pod MySQL theo thứ tự rồi mới cho object của cụm biến mất. Chỉ khi đã thấy dòng đó, và `helm list` có release `ps-operator`, mới gỡ operator:

```bash
helm uninstall ps-operator -n ps; echo "exit=$?"
kubectl -n ps get pods; echo "exit=$?"
```

**PASS 13.3:** mọi dòng `exit=0`; `get ps` và `get pods` đều in `No resources found in ps namespace.` Làm trọn bài thì `restore1` và `backup1` báo `deleted`, hai release báo `uninstalled`. Pod operator còn `Terminating` vài giây thì chạy lại.

**Gỡ operator trước khi object của cụm biến mất là kẹt.** Object đó mang một finalizer mà chỉ operator gỡ được. Lỡ làm vậy thì xem mục [Khi gặp lỗi](#khi-gặp-lỗi).

**13.4. Xoá PVC, kiểm tra ổ EBS đã mất.** Không có PVC thì các lệnh dưới chỉ in `No resources found`, chạy vẫn an toàn.

```bash
kubectl -n ps get pvc
kubectl -n ps delete pvc --all; echo "exit=$?"
kubectl -n ps get pvc; echo "exit=$?"
kubectl get pv; echo "exit=$?"
aws ec2 describe-volumes --region "${AWS_REGION}" \
  --filters "Name=tag:lab-cluster,Values=${CLUSTER_NAME}" \
  --query 'Volumes[].[VolumeId, Size, State, Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value]' \
  --output text; echo "exit=$?"
```

**PASS 13.4:** làm trọn bài thì lệnh đầu còn liệt kê 3 PVC, vì `helm uninstall` không bao giờ xoá PVC của StatefulSet. Sau lệnh xoá, `get pvc` và `get pv` đều in `No resources found`. Lệnh `aws` chỉ in `exit=0`. `get pv` hay lệnh `aws` còn in dòng thì chờ nửa phút rồi chạy lại: driver xoá ổ EBS sau khi PVC mất.

**13.5. Xoá object backup, IAM user và policy.** Mỗi phần chỉ chạy khi 13.2 in ra thứ tương ứng. Giữ đúng thứ tự user trước, policy sau: policy còn gắn vào user thì không xoá được.

Có object dưới `shop/`. Lệnh chỉ xoá object trong thư mục con `shop/`, không xoá bucket:

```bash
aws s3 rm "s3://${BUCKET:?}/shop/" --recursive --only-show-errors --region "${AWS_REGION}"; echo "exit=$?"
aws s3 ls "s3://${BUCKET:?}/shop/" --recursive --region "${AWS_REGION}" | wc -l
```

Có user. Hai vòng `for` gỡ mọi policy đang gắn và xoá mọi access key mà AWS liệt kê, nên chạy được cả khi user chưa có policy hay chưa có key:

```bash
for ARN in $(aws iam list-attached-user-policies --user-name "${BACKUP_IAM_NAME:?}" \
    --query 'AttachedPolicies[].PolicyArn' --output text); do
  aws iam detach-user-policy --user-name "${BACKUP_IAM_NAME:?}" --policy-arn "${ARN}"; echo "detach exit=$?"
done
for KEY_ID in $(aws iam list-access-keys --user-name "${BACKUP_IAM_NAME:?}" \
    --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
  aws iam delete-access-key --user-name "${BACKUP_IAM_NAME:?}" --access-key-id "${KEY_ID}"; echo "delete-key exit=$?"
done
aws iam delete-user --user-name "${BACKUP_IAM_NAME:?}"; echo "delete-user exit=$?"
```

Có policy, tức `POLICY_ARN` ở 13.2 không rỗng:

```bash
aws iam delete-policy --policy-arn "${POLICY_ARN:?}"; echo "exit=$?"
```

**PASS 13.5:** mọi dòng `exit` in ra đều là `0`. Làm trọn bài thì có: một dòng `exit=0` của lệnh xoá object rồi số `0`, một `detach exit=0`, một `delete-key exit=0`, `delete-user exit=0`, và một dòng của policy. Làm dở thì ít dòng hơn: vòng `for` không có gì để gỡ thì không in dòng nào.

**13.6. Xoá namespace và 4 CRD.** Có CRD thì trước hết xác nhận trong `ps` không còn object nào của Percona và không còn release nào:

```bash
kubectl get ps,ps-backup,ps-restore -n ps; echo "exit=$?"
helm list -n ps -a; echo "exit=$?"
```

**PASS trước khi xoá namespace:** lệnh đầu in `No resources found in ps namespace.`, `helm list` chỉ in dòng tiêu đề, hai dòng `exit=0`. Còn object hay release thì quay lại 13.3.

**Đừng xoá namespace khi còn object của cụm.** Khoá trên object đó chỉ operator gỡ được. Namespace đang bị xoá thì không nhận object mới, nên lúc đó không cài lại operator vào `ps` được nữa, và namespace kẹt ở `Terminating`. Không có CRD thì bỏ khối kiểm tra này: không có loại tài nguyên thì không thể có object.

```bash
kubectl delete namespace ps --ignore-not-found; echo "exit=$?"
kubectl delete crd perconaservermysqls.ps.percona.com perconaservermysqlbackups.ps.percona.com \
  perconaservermysqlrestores.ps.percona.com perconaservermysqlclustersets.ps.percona.com \
  --ignore-not-found; echo "exit=$?"
```

**PASS 13.6:** hai dòng `exit=0`. Làm trọn bài thì namespace và 4 CRD báo `deleted`; thứ chưa từng tạo thì không in gì. Secret chứa key S3 và Secret mật khẩu MySQL mất theo namespace. Lệnh xoá namespace đứng quá vài phút thì xem mục [Khi gặp lỗi](#khi-gặp-lỗi).

**13.7. Kiểm tra cuối.**

```bash
kubectl get ns ps --ignore-not-found; echo "exit=$?"
kubectl get crd -o name | grep 'ps\.percona\.com'
printf 'kubectl=%s grep=%s\n' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}"
helm list -A; echo "exit=$?"
kubectl get pvc -A; echo "exit=$?"
kubectl get pv; echo "exit=$?"
kubectl get svc -A \
  -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
echo "exit=$?"

aws s3api list-buckets --query "Buckets[?Name=='${BUCKET}'].Name" --output text; echo "exit=$?"
aws s3 ls "s3://${BUCKET}/" --recursive --region "${AWS_REGION}" | wc -l
aws iam list-users \
  --query "Users[?UserName=='${BACKUP_IAM_NAME}'].UserName" --output text; echo "exit=$?"
aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='${BACKUP_IAM_NAME}'].Arn" --output text; echo "exit=$?"
aws ec2 describe-volumes --region "${AWS_REGION}" \
  --filters "Name=tag:lab-cluster,Values=${CLUSTER_NAME}" \
  --query 'Volumes[].VolumeId' --output text; echo "exit=$?"
```

**PASS bước 13:**

- Lệnh namespace không in gì, `exit=0`. Lệnh CRD in `kubectl=0 grep=1`.
- `helm list -A` chỉ in dòng tiêu đề. `get pvc -A` và `get pv` in `No resources found`. Lệnh `svc` chỉ in `exit=0`.
- `list-buckets` in tên bucket: bucket của Terraform **vẫn còn**, đúng như mong đợi. Lệnh `s3 ls` ngay dưới in `0`: bucket rỗng.
- Hai lệnh IAM và lệnh `describe-volumes` chỉ in `exit=0`: không còn user, policy hay ổ EBS của bài.

**STOP khi** có lệnh in `exit` khác 0 hoặc báo lỗi: lúc đó "không thấy gì" không chứng minh đã dọn xong. Còn sót thứ gì thì quay lại đúng chặng của nó ở trên.

Sau khi PASS:

- Muốn dọn file trên máy: `cd ~ && rm -rf ~/platform-mysql ~/platform-mysql.env`. Bước 1 sinh lại được cả hai.
- **Còn dùng cluster tiếp:** giữ cluster; add-on của bước 8 cứ để nguyên.
- **Hết buổi:** làm [bước 10 của runbook cluster](runbook-shared-infrastructure.md#bước-10-dọn-cuối-buổi) để xoá cluster và kiểm tra không còn sót.
- Repo Helm `percona` đã thêm ở bước 4 chỉ là một dòng cấu hình trên máy, không tốn gì. Muốn gỡ thì `helm repo remove percona`.

---

## Khi gặp lỗi

- **PVC của MySQL đứng `Pending` ở bước 5:** cluster chưa có StorageClass mặc định. `kubectl get storageclass` phải có `ebs-csi-default-sc (default)`; chưa có thì làm [bước 8 của runbook cluster](runbook-shared-infrastructure.md#bước-8-cài-add-on-mỗi-buổi). PVC tự `Bound` sau khi add-on chạy.
- **Pod MySQL hay HAProxy đứng `Pending`:** xem lý do bằng `kubectl -n ps describe pod <tên>`. `didn't match pod anti-affinity rules` nghĩa là không đủ 3 node `Ready`. `Insufficient memory` hay `Insufficient cpu` nghĩa là cluster đang chạy chồng thứ khác.
- **Client báo `ERROR 1045 ... Access denied`:** `ROOT_PWD` chưa được đặt trong terminal đang chạy client, thường vì Secret chưa có lúc đọc. Gõ `exit`, chạy lại cả khối đầu của bước 6 để đặt lại `ROOT_PWD`, rồi chạy lại lệnh `kubectl run`.
- **`kubectl run` báo `pods "mysql-client" already exists`:** pod client của lần trước còn đó, thường do đóng terminal mà chưa `exit`. Chạy `kubectl -n ps delete pod mysql-client`, rồi chạy lại lệnh `kubectl run`.
- **Terminal SQL tự thoát về dấu nhắc bash giữa bài:** phiên nối tới pod client bị ngắt. Dữ liệu nằm trong database, không nằm trong client, nên không mất gì. Chạy lại hai khối lệnh của bước 6 (đặt `ROOT_PWD`, rồi `kubectl run`), bỏ phần SQL tạo bảng, rồi làm tiếp bước đang dở.
- **Tạo access key xong nhưng Secret không tạo được, hoặc Secret sai:** phần bí mật của key không lấy lại được. Xoá key và Secret rồi làm lại từ khối "Tạo namespace" của bước 3:

  ```bash
  for KEY_ID in $(aws iam list-access-keys --user-name "${BACKUP_IAM_NAME:?}" \
      --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    aws iam delete-access-key --user-name "${BACKUP_IAM_NAME:?}" --access-key-id "${KEY_ID}"; echo "exit=$?"
  done
  kubectl -n ps delete secret s3-backup-creds --ignore-not-found
  ```

  Khi làm lại, lệnh `kubectl create namespace ps` báo `AlreadyExists` là bình thường.
- **Backup dừng ở `Failed` hay `Error`:** đọc lý do bằng `kubectl -n ps get ps-backup backup1 -o jsonpath='{.status.stateDescription}{"\n"}'`, và log của job bằng `kubectl -n ps get jobs` rồi `kubectl -n ps logs job/<tên-job>`. Hay gặp: `values-backup.yaml` mang sai tên bucket, policy ghi sai tên bucket, hoặc Secret sai. Sửa nguyên nhân; nếu phải sửa values thì chạy `helm upgrade shop percona/ps-db --version 1.2.0 -n ps -f values-backup.yaml`. Sau đó `kubectl delete -f backup.yaml` rồi `kubectl apply -f backup.yaml` để chạy lại.
- **Restore không xong:** đọc `kubectl -n ps get ps-restore restore1 -o jsonpath='{.status.stateDescription}{"\n"}'` và log của job như trên. Không xoá PVC hay pod bằng tay giữa lúc restore đang chạy.
- **Đã gỡ operator trước khi `kubectl -n ps get ps` trống, và namespace `ps` còn `Active`:** pod MySQL, HAProxy và mọi lệnh xoá PVC sẽ treo. Xem `kubectl get ns ps`: cột `STATUS` là `Active` thì cài lại operator bằng `helm install ps-operator percona/ps-operator --version 1.2.0 -n ps --wait`, chờ `kubectl -n ps get ps` in `No resources found`, rồi gỡ operator lần nữa và làm tiếp từ 13.4. `STATUS` là `Terminating` thì cách này không dùng được: xem mục ngay dưới.
- **Namespace `ps` kẹt ở `Terminating`** (lệnh `kubectl delete namespace ps` đứng mãi): thường do còn object của cụm mang finalizer, trong khi operator đã mất. **Không cài lại operator vào `ps` được:** Kubernetes không cho tạo object mới trong namespace đang bị xoá, nên `helm install ... -n ps` sẽ lỗi. Nhấn Ctrl+C ở lệnh đang đứng; việc xoá vẫn tiếp tục ở phía cluster. Xem thứ gì đang giữ namespace:

  ```bash
  kubectl get ns ps -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.message}{"\n"}{end}'
  kubectl get ps,ps-backup,ps-restore -n ps; echo "exit=$?"
  kubectl -n ps get pods; echo "exit=$?"
  ```

  - Các dòng chỉ nói còn pod hay PVC đang tắt: chờ. Pod MySQL được cho tối đa 10 phút để tắt.
  - Dòng `NamespaceFinalizersRemaining` nhắc một finalizer `percona.com/...`: cài tạm một operator ở **namespace khác**, cho nó quyền theo dõi mọi namespace, để nó gỡ khoá trong `ps`:

    ```bash
    helm install ps-rescue percona/ps-operator --version 1.2.0 -n ps-rescue --create-namespace \
      --set watchAllNamespaces=true --wait; echo "exit=$?"
    kubectl get ns ps --ignore-not-found; echo "exit=$?"
    ```

    Chạy lại dòng cuối cho tới khi nó không in namespace nào nữa. Operator tạm chỉ gỡ khoá khi còn nhiều nhất một pod MySQL, nên có thể phải chờ pod tắt xong. Rồi gỡ operator tạm:

    ```bash
    helm uninstall ps-rescue -n ps-rescue; echo "exit=$?"
    kubectl delete namespace ps-rescue; echo "exit=$?"
    kubectl get clusterrole,clusterrolebinding -o name | grep ps-rescue
    printf 'kubectl=%s grep=%s\n' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}"
    ```

    **PASS:** các dòng `exit=0`, dòng cuối in `kubectl=0 grep=1`. Làm tiếp lệnh xoá CRD của 13.6, rồi 13.7.
  - Cách cứu này dựng từ template của chart và mã nguồn operator, **chưa chạy thật**. Nếu operator tạm không cài được, hoặc sau 10 phút namespace vẫn `Terminating`: chỉ khi `kubectl -n ps get pods` không còn pod `shop-ps-db-mysql-...` nào, và finalizer còn lại đúng là `percona.com/delete-mysql-pods-in-order`, mới gỡ khoá bằng tay: `kubectl -n ps patch ps shop-ps-db --type merge -p '{"metadata":{"finalizers":[]}}'`. Khoá đó chỉ để tắt pod MySQL theo thứ tự, nên khi không còn pod thì nó hết việc. Finalizer tên khác thì STOP, không gỡ.
- **`delete-policy` hay `delete-user` báo `DeleteConflict`:** policy còn gắn vào user, hoặc user còn access key. Chạy lại lần lượt các lệnh IAM ở 13.5 theo đúng thứ tự.
- **Bước 1 không đọc được tên bucket** (`ParameterNotFound`): Terraform chưa tạo parameter, hoặc đường dẫn sai. Đường dẫn là `/<môi trường>/<dự án>/mysql-backup/bucket_name`, tên môi trường đứng trước. Xem [README của module `mysql-backup`](../modules/mysql-backup/README.md).
- **Chạy lệnh `aws ssm get-parameter` trong Git Bash thay vì WSL và bị báo tên sai:** Git Bash đổi tên bắt đầu bằng `/` thành đường dẫn Windows. Runbook này chạy trong WSL, nơi không có chuyện đó.

## Nguồn

- [Runbook bài 16](https://github.com/hieupham259/DevOps-Projects-with-Kubernetes-on-AWS/blob/master/Section%202/bai16-mysql-operator/runbook-mysql-operator.md) của repo khoá học: runbook gốc, kèm phần đối chiếu với handout S02-L07, chart 1.2.0 và mã nguồn operator v1.2.0, cùng danh sách nguồn chi tiết.
- [Runbook cluster](runbook-shared-infrastructure.md) của repo này.
- [Plan 04](../plans/04-terraform-networking-va-s3-backup.md) và [README của module `mysql-backup`](../modules/mysql-backup/README.md): bucket backup và SSM parameter chứa tên bucket.
- [Percona Operator for MySQL: tài liệu](https://docs.percona.com/percona-operator-for-mysql/ps/index.html), [release notes 1.2.0](https://docs.percona.com/percona-operator-for-mysql/ps/ReleaseNotes/Kubernetes-Operator-for-PS-RN1.2.0.html).
- Chart: [index của Helm repo Percona](https://percona.github.io/percona-helm-charts/index.yaml), [`ps-db` 1.2.0 `values.yaml`](https://github.com/percona/percona-helm-charts/blob/ps-db-1.2.0/charts/ps-db/values.yaml), [`ps-operator` 1.2.0 `values.yaml`](https://github.com/percona/percona-helm-charts/blob/ps-operator-1.2.0/charts/ps-operator/values.yaml).
- [MySQL 8.4: Group Replication](https://dev.mysql.com/doc/refman/8.4/en/group-replication.html).
- [Kubernetes: NamespaceLifecycle](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#namespacelifecycle): không tạo được object mới trong namespace đang bị xoá.
