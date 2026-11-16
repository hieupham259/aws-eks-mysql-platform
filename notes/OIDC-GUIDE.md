# OIDC Guide: GitHub Actions vào AWS không cần access key dài hạn

Tài liệu này giải thích kiến thức nền của GitHub OIDC với AWS, các bước dựng từ đầu, và cách repo `aws-eks-mysql-platform` dùng nó: job nào vào được role nào, vì sao.

Đây là bản viết lại của `notes/OIDC-GUIDE.md` trong dự án mẫu [`3-tiers-app-infrastructure`](https://github.com/hieupham259/3-tiers-app-infrastructure/blob/4de50f9b3d740454eb72c6f957fe9bda0380cdee/notes/OIDC-GUIDE.md?plain=1), giữ nguyên 18 mục để so được với bản gốc. Nội dung đã đổi theo hai thứ: tài liệu chính thức tại ngày **17/11/2026**, và code thật của repo này. Các bước làm cụ thể nằm ở [plan 03](../plans/03-trien-khai-oidc-roi-cicd.md); tài liệu này giải thích, không lặp lại lệnh.

Ký hiệu dùng trong cả tài liệu:

- `<owner>`: tên tài khoản GitHub sở hữu repo. `<owner_id>`, `<repo_id>`: ID số của tài khoản và của repo.
- `<account-id>`: account AWS, 12 chữ số.
- **`<tiền tố>`** là `repo:<owner>@<owner_id>/aws-eks-mysql-platform@<repo_id>`. Đây là giá trị của biến repo `OIDC_SUBJECT_PREFIX`.

## Mục lục

- [Khác bản gốc ở đâu](#khác-bản-gốc-ở-đâu)
- [1. Vấn đề cũ: access key dài hạn](#1-vấn-đề-cũ-access-key-dài-hạn)
- [2. Kiến thức nền: OIDC là gì](#2-kiến-thức-nền-oidc-là-gì)
- [3. Kiến thức nền: cấu trúc JWT](#3-kiến-thức-nền-cấu-trúc-jwt)
- [4. Kiến thức nền: GitHub Actions là một OIDC issuer](#4-kiến-thức-nền-github-actions-là-một-oidc-issuer)
- [5. Các claim trong JWT, và dạng mới của `sub`](#5-các-claim-trong-jwt-và-dạng-mới-của-sub)
- [6. AWS kiểm tra JWT thế nào](#6-aws-kiểm-tra-jwt-thế-nào)
- [7. Đường đi của token](#7-đường-đi-của-token)
- [8. Các bước dựng GitHub OIDC với AWS](#8-các-bước-dựng-github-oidc-với-aws)
- [9. `bootstrap/01-trust-anchor.yaml` của repo này tạo gì](#9-bootstrap01-trust-anchoryaml-của-repo-này-tạo-gì)
- [10. Năm lớp quyết định một job vào đâu](#10-năm-lớp-quyết-định-một-job-vào-đâu)
- [11. Tóm tắt: chỗ nào trỏ tới đâu](#11-tóm-tắt-chỗ-nào-trỏ-tới-đâu)
- [12. Các tầng bảo vệ](#12-các-tầng-bảo-vệ)
- [13. Ví dụ từ đầu tới cuối: merge vào `development`](#13-ví-dụ-từ-đầu-tới-cuối-merge-vào-development)
- [14. Các kiểu tấn công và vì sao bị chặn](#14-các-kiểu-tấn-công-và-vì-sao-bị-chặn)
- [15. So sánh trước và sau OIDC](#15-so-sánh-trước-và-sau-oidc)
- [16. Hỏi đáp](#16-hỏi-đáp)
- [17. Chi tiết từng pha: từ lúc job chạy tới từng lời gọi API](#17-chi-tiết-từng-pha-từ-lúc-job-chạy-tới-từng-lời-gọi-api)
- [18. Tham khảo](#18-tham-khảo)

## Khác bản gốc ở đâu

| Chủ đề | Bản gốc viết | Bản này |
|---|---|---|
| Dạng `sub` | `repo:<org>/<repo>:...` | `repo:<owner>@<owner_id>/<repo>@<repo_id>:...`, áp dụng cho repo tạo sau 15/07/2026 (mục 5) |
| Cách biết `sub` | suy từ tên repo và tên nhánh | cần thêm hai ID, lấy từ API của GitHub (mục 8, bước 0) |
| Thumbprint của provider | bắt buộc khai trong CloudFormation | tuỳ chọn; template của repo này không khai (mục 6) |
| Lỗi khi `sub` không khớp | `IDPRejectedClaim` hoặc `AccessDenied` | `AccessDenied`, câu `Not authorized to perform sts:AssumeRoleWithWebIdentity`. `IDPRejectedClaim` là lỗi khác (mục 6) |
| Condition key của GitHub | có `repository_owner`, `iss` | danh sách theo tài liệu IAM hiện hành, có thêm `repository_id`, `repository_owner_id` (mục 17, pha F) |
| Điều kiện của role apply | theo nhánh, `ref:refs/heads/<nhánh>` | theo Environment: `:environment:development` và `:environment:production` (mục 10) |
| Số account | hai account, development và production | như bản gốc: hai môi trường, account chọn theo nhánh qua `DEV_ACCOUNT_ID` và `PROD_ACCOUNT_ID`. Hai biến cùng giá trị thì hai môi trường chung một account |
| Region | `ap-southeast-1` | `us-east-1` |
| Tên role | `gha-bootstrap`, `gha-infra-plan`, `gha-infra-apply` | có tiền tố tên repo: `aws-eks-mysql-platform-gha-bootstrap`, `-gha-plan`, `-gha-apply` |
| Phiên bản action | `configure-aws-credentials@v4` | `@v6`; `actions/checkout@v7` |
| Ví dụ phân quyền ở pha H | policy giả định | policy thật của role plan và role apply trong repo này |

---

## 1. Vấn đề cũ: access key dài hạn

Cách cũ để GitHub Actions gọi AWS:

```text
1. Tạo một IAM user
2. Tạo Access Key và Secret Key cho user đó (không có hạn dùng)
3. Lưu vào GitHub Secrets: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
4. Workflow đọc secret rồi gọi AWS
```

Vấn đề:

- Key không bao giờ hết hạn. Lộ một lần là lộ cho tới khi có người nhớ ra và đổi.
- Key nằm trong GitHub Secrets. Ai chiếm được quyền admin repo thì dùng được key.
- Đổi key là việc làm tay, phải đồng bộ ở nhiều chỗ.
- CloudTrail chỉ ghi tên IAM user, không biết workflow nào, nhánh nào, lần chạy nào.
- Trái với khuyến nghị của AWS: dùng credentials tạm thời.

## 2. Kiến thức nền: OIDC là gì

OpenID Connect là một lớp xác thực trên OAuth 2.0. Một bên phát hành danh tính (identity provider, IdP) cấp **ID token** theo chuẩn JWT, trong đó ghi token này đại diện cho ai. Bên thứ ba như AWS có thể tin một IdP, rồi dựa vào token để cấp quyền tạm thời, không cần mật khẩu hay key dài hạn.

Các thành phần:

- **Issuer URL:** địa chỉ công khai của IdP, ví dụ `https://token.actions.githubusercontent.com`. Phải là HTTPS, không có cổng, không có query string; có thể có đường dẫn.
- **Discovery endpoint:** `<issuer>/.well-known/openid-configuration`, trả về JSON mô tả IdP, gồm `issuer`, `jwks_uri`, các thuật toán ký.
- **JWKS endpoint:** nơi công bố public key để kiểm tra chữ ký của JWT. AWS nhận tối đa 100 key RSA và 100 key EC.
- **Thuật toán ký được AWS chấp nhận:** `RS256`, `RS384`, `RS512`, `ES256`, `ES384`, `ES512`.
- **Audience (`aud`):** token này gửi cho ai. Khi đăng ký IdP với AWS, `aud` trong token phải trùng một audience đã khai cho provider. Với GitHub và AWS, giá trị quen dùng là `sts.amazonaws.com`.

GitHub Actions là một IdP đầy đủ. Mỗi job có thể xin một JWT ngắn hạn do GitHub ký, đưa cho AWS để đổi lấy credentials tạm thời.

## 3. Kiến thức nền: cấu trúc JWT

Một JWT có dạng `xxxxx.yyyyy.zzzzz`, ba phần mã hoá base64url:

1. **Header:** thuật toán ký và `kid`, cho biết key nào trong JWKS đã ký.
2. **Payload:** một JSON chứa các *claim* (mục 5).
3. **Signature:** chữ ký của hai phần trên bằng private key của IdP.

JWT tự chứng minh được mình: AWS không phải hỏi lại GitHub mỗi lần, chỉ cần public key của GitHub. Bù lại, token có hạn dùng ngắn, ghi ở claim `exp`. Token của GitHub Actions chỉ sống vài phút, đủ để job đổi lấy credentials một lần.

Phần payload chỉ được mã hoá, không được giữ kín: ai cầm token cũng đọc được nội dung. Thứ phải giữ kín là cả token, vì ai cầm nó đều đổi được credentials trong lúc token còn hạn.

## 4. Kiến thức nền: GitHub Actions là một OIDC issuer

- **Issuer URL** của github.com: `https://token.actions.githubusercontent.com`. AWS so URL này có phân biệt hoa thường, nên phải viết toàn chữ thường, không có dấu `/` cuối.
- **Discovery:** `https://token.actions.githubusercontent.com/.well-known/openid-configuration`.
- **Key được xoay định kỳ.** Đó là lý do AWS tải public key qua JWKS chứ không lưu cứng.
- **Audience mặc định:** nếu job không yêu cầu gì, GitHub đặt `aud` là địa chỉ của chủ repo, kiểu `https://github.com/<owner>`. Action `aws-actions/configure-aws-credentials` tự xin `aud` là `sts.amazonaws.com`, nên trust policy phía AWS phải so với đúng giá trị đó.
- **Quyền bắt buộc** trong workflow:

  ```yaml
  permissions:
    id-token: write   # cho phép job xin OIDC token
    contents: read    # cho actions/checkout
  ```

  `id-token: write` không cho job ghi gì cả. Nó chỉ là quyền xin token. Thiếu nó thì job không có nơi nào để xin, và bước đăng nhập AWS hỏng vì không tìm được credentials.
- **Pull request từ fork** không được cấp `id-token: write`. Job vẫn chạy, nhưng không xin được token, nên không vào được role nào.

## 5. Các claim trong JWT, và dạng mới của `sub`

Payload của token mà job `apply` của repo này nhận được, khi chạy trong Environment `development`. Hai con số ID là số minh hoạ:

```json
{
  "jti": "<uuid>",
  "iss": "https://token.actions.githubusercontent.com",
  "aud": "sts.amazonaws.com",
  "sub": "repo:<owner>@1234567/aws-eks-mysql-platform@7654321:environment:development",

  "iat": 1794900000,
  "nbf": 1794899700,
  "exp": 1794900300,

  "repository": "<owner>/aws-eks-mysql-platform",
  "repository_id": "7654321",
  "repository_owner": "<owner>",
  "repository_owner_id": "1234567",
  "repository_visibility": "public",

  "actor": "<owner>",
  "actor_id": "1234567",

  "ref": "refs/heads/development",
  "ref_type": "branch",
  "head_ref": "",
  "base_ref": "",
  "sha": "<commit sha>",

  "workflow": "Terraform Apply",
  "workflow_ref": "<owner>/aws-eks-mysql-platform/.github/workflows/terraform-apply.yaml@refs/heads/development",
  "workflow_sha": "<commit sha>",
  "job_workflow_ref": "<owner>/aws-eks-mysql-platform/.github/workflows/terraform-apply.yaml@refs/heads/development",
  "job_workflow_sha": "<commit sha>",

  "run_id": "1234567890",
  "run_number": "42",
  "run_attempt": "1",
  "check_run_id": "9876543210",

  "event_name": "push",
  "environment": "development",
  "runner_environment": "github-hosted"
}
```

Claim AWS dùng:

| Claim | Ý nghĩa | AWS dùng để |
|---|---|---|
| `iss` | ai phát hành token | tìm OIDC provider có URL trùng trong account |
| `aud` | token gửi cho ai | so với danh sách audience của provider, và với điều kiện trong trust policy |
| `sub` | job này là ai | so với điều kiện trong trust policy |
| `exp`, `iat`, `nbf` | khoảng thời gian token có hiệu lực | từ chối token hết hạn |

### `sub` đổi theo ngữ cảnh chạy

| Job chạy thế nào | `sub` |
|---|---|
| Job khai `environment: X` | `<tiền tố>:environment:X` |
| Sự kiện `pull_request`, job không khai environment | `<tiền tố>:pull_request` |
| Chạy trên một nhánh, job không khai environment | `<tiền tố>:ref:refs/heads/<nhánh>` |
| Chạy trên một tag, job không khai environment | `<tiền tố>:ref:refs/tags/<tag>` |

Job đã khai `environment` thì `sub` theo environment, không còn mang tên nhánh hay `pull_request`. Đây là chi tiết dễ làm hỏng trust policy nhất: viết điều kiện theo nhánh cho một job có khai environment thì không bao giờ khớp.

### Dạng mới của phần tiền tố

Từ ngày 15/07/2026, GitHub gắn ID số vào sau tên chủ repo và tên repo:

```text
dạng cũ:  repo:<owner>/<repo>:ref:refs/heads/main
dạng mới: repo:<owner>@<owner_id>/<repo>@<repo_id>:ref:refs/heads/main
```

- **Repo nào dùng dạng mới:** repo tạo sau 15/07/2026; repo được đổi tên hoặc chuyển chủ sau ngày đó; repo cũ đã chủ động bật. Repo tạo trước ngày đó và chưa bật thì giữ dạng cũ. GitHub Enterprise Server không áp dụng.
- **Vì sao GitHub đổi:** tên có thể được dùng lại. Nếu một tài khoản hoặc một repo bị xoá rồi người khác lấy đúng tên đó, token của họ sẽ mang `sub` giống hệt, và trust policy cũ vẫn mở cửa. ID thì không bao giờ được cấp lại.
- **Dấu `@`** được chọn làm dấu ngăn vì không thể xuất hiện trong tên tài khoản hay tên repo.
- **Hệ quả:** trust policy viết theo dạng cũ không khớp token dạng mới. AWS chỉ báo `Not authorized to perform sts:AssumeRoleWithWebIdentity`, không nói khác ở đâu.

Repo `aws-eks-mysql-platform` được tạo sau mốc này, nên mọi `sub` trong tài liệu dùng dạng mới.

**Điều đã kiểm và điều còn giả định:** tài liệu của GitHub cho ví dụ dạng mới với ngữ cảnh nhánh. Với `environment` và `pull_request`, tài liệu không cho ví dụ; repo này giả định chúng dùng cùng tiền tố. Lần kiểm thật là khi workflow Bootstrap và workflow OIDC test vào được role (plan 03, bước 5 và bước 8).

### Ba cách biết tiền tố của một repo

1. Lấy ID của repo và ID của chủ repo từ API công khai `https://api.github.com/repos/<owner>/<repo>`, rồi ghép theo dạng ở trên. Plan 03 dùng cách này ở bước 2, vì nó chỉ cần một lệnh.
2. Gọi REST API `GET /repos/{owner}/{repo}/actions/oidc/customization/sub`, đọc trường `sub_claim_prefix`. Cần token có quyền với repo.
3. Mở sự kiện `AssumeRoleWithWebIdentity` trong CloudTrail để xem `sub` mà một job đã trình. Đây là cách duy nhất trong ba cách cho thấy chuỗi thật mà AWS nhận được, kể cả phần đuôi.

### Ghi chú thêm

- Dấu `:` nằm trong một giá trị, ví dụ tên environment `Production:V1`, được đổi thành `%3A` trong `sub`.
- `sub` có thể tuỳ biến qua REST API `PUT /repos/{owner}/{repo}/actions/oidc/customization/sub`, với các trường `use_default`, `include_claim_keys`, `use_immutable_subject`. Dù tuỳ biến thế nào, ID của chủ repo và của repo vẫn nằm trong đoạn `repo`. Repo này dùng dạng mặc định, không tuỳ biến.

## 6. AWS kiểm tra JWT thế nào

### Thumbprint không còn là thứ phải lo

Trước đây, khi tạo OIDC provider phải khai thumbprint của chứng chỉ TLS. AWS đã đổi cách làm:

> *"AWS secures communication with OIDC identity providers (IdPs) using our library of trusted root certificate authorities (CAs) to verify the JSON Web Key Set (JWKS) endpoint's TLS certificate. If your OIDC IdP relies on a certificate that is not signed by one of these trusted CAs, only then we secure communication using the thumbprints set in the IdP's configuration."*

Hệ quả:

- Chứng chỉ của `token.actions.githubusercontent.com` do một CA công khai ký, nên AWS dùng thư viện CA của mình. Thumbprint chỉ là đường dự phòng.
- Với `AWS::IAM::OIDCProvider` trong CloudFormation, `ThumbprintList` là thuộc tính tuỳ chọn. Bỏ trống thì IAM tự lấy thumbprint của CA trung gian. Template `bootstrap/01-trust-anchor.yaml` của repo này không khai nó.

### IAM kiểm tra trust policy ngay lúc tạo role

GitHub là một IdP dùng chung cho mọi khách hàng của AWS: ai cũng có cùng issuer URL. Vì vậy IAM bắt buộc trust policy của role tin provider GitHub phải có điều kiện trên `sub` (hoặc trên `job_workflow_ref`), và giá trị không được chỉ là ký tự đại diện. Thiếu thì lệnh tạo hoặc sửa role bị từ chối với lỗi `MalformedPolicyDocument`.

### Một lời gọi `AssumeRoleWithWebIdentity` được xét thế nào

1. Đọc JWT từ tham số `WebIdentityToken`.
2. Lấy `iss`, tìm OIDC provider có URL trùng trong account. Không có thì trả `InvalidIdentityToken`.
3. Tải JWKS, kiểm chứng chỉ TLS của endpoint bằng thư viện CA.
4. Kiểm chữ ký của JWT bằng public key ứng với `kid`. Sai thì `InvalidIdentityToken`.
5. Kiểm thời hạn. Hết hạn thì `ExpiredToken`.
6. Kiểm `aud` có nằm trong danh sách audience của provider không. Không khớp thì `InvalidIdentityToken`.
7. Xét trust policy của role được xin:
   - `Principal.Federated` phải là ARN của provider trong account;
   - `Action` phải là `sts:AssumeRoleWithWebIdentity`;
   - mọi điều kiện trong `Condition` phải đúng với các claim của token.

   Không đạt thì trả `AccessDenied`, câu `Not authorized to perform sts:AssumeRoleWithWebIdentity`.
8. Đạt hết thì trả credentials tạm thời: access key ID, secret access key, session token và thời điểm hết hạn. Mặc định một giờ; có thể xin từ 900 giây tới trần `MaxSessionDuration` của role, tối đa 12 giờ.

Các mã lỗi của API, theo tài liệu STS:

| Mã lỗi | Nghĩa |
|---|---|
| `InvalidIdentityToken` | AWS không kiểm được token: sai chữ ký, sai audience, không có provider khớp |
| `ExpiredToken` | token đã hết hạn hoặc không hợp lệ |
| `IDPRejectedClaim` | chính IdP báo xác thực thất bại; cũng có thể là claim đã hết hạn hoặc bị thu hồi |
| `IDPCommunicationError` | AWS không liên lạc được với IdP, thường là tạm thời |
| `AccessDenied` | token hợp lệ, nhưng trust policy của role không cho vào |

Lỗi gặp nhiều nhất khi mới dựng là dòng cuối: token thật, role thật, chỉ có `sub` không nằm trong điều kiện.

## 7. Đường đi của token

```text
+-----------------+                 +------------------+                 +----------------+
|  GitHub Actions |                 |     AWS STS      |                 |   AWS account  |
|    một job      |                 |   (IAM, OIDC)    |                 |   tài nguyên   |
+--------+--------+                 +--------+---------+                 +--------+-------+
         |                                   |                                    |
         | 1. id-token: write -> xin JWT     |                                    |
         |    từ issuer của GitHub.          |                                    |
         |    sub = <tiền tố>:environment:   |                                    |
         |          development              |                                    |
         |    aud = sts.amazonaws.com        |                                    |
         |                                   |                                    |
         | 2. AssumeRoleWithWebIdentity      |                                    |
         |    (RoleArn = ...-gha-apply,      |                                    |
         |     WebIdentityToken = JWT)       |                                    |
         | --------------------------------> |                                    |
         |                                   | 3. Tìm provider theo iss,          |
         |                                   |    tải JWKS, kiểm TLS              |
         |                                   |                                    |
         |                                   | 4. Kiểm chữ ký, hạn dùng, aud      |
         |                                   |                                    |
         |                                   | 5. Xét trust policy:               |
         |                                   |    aud khớp? sub khớp?             |
         |                                   |                                    |
         | 6. Nhận credentials tạm           |                                    |
         |    (hết hạn sau khoảng 1 giờ)     |                                    |
         | <-------------------------------- |                                    |
         |                                   |                                    |
         | 7. Dùng credentials gọi AWS API   |                                    |
         | --------------------------------------------------------------------> |
         |    (terraform apply ...)                                               |
         |                                   |                                    |
         | 8. Job xong, credentials tự       |                                    |
         |    hết hạn                        |                                    |
```

| Thứ | Sống bao lâu | Nằm ở đâu |
|---|---|---|
| JWT của GitHub | vài phút | bộ nhớ của máy chạy job |
| Credentials tạm của AWS | 900 giây tới 12 giờ, mặc định 1 giờ | biến môi trường `AWS_*` của job |
| Secret dài hạn | không có | không tồn tại |

## 8. Các bước dựng GitHub OIDC với AWS

AWS Security Blog mô tả năm bước: tạo OIDC provider, tạo role với trust policy thu hẹp theo repo và ngữ cảnh, gán quyền tối thiểu, viết workflow, rồi kiểm tra qua CloudTrail. Repo này thêm một bước 0 ở trước và một bước siết ở sau.

### Điều kiện trước

- Một danh tính AWS có quyền tạo provider và role, dùng một lần cho bước làm tay.
- Repo GitHub đã tồn tại. Dạng mới của `sub` chứa ID của repo, nên không viết trước trust policy được khi chưa có repo.

### Bước 0: lấy hai ID của repo

Dạng mới của `sub` cần ID của chủ repo và ID của repo. Lấy cả hai bằng một lệnh gọi API công khai của GitHub, rồi ghép thành `<tiền tố>`, là giá trị của biến `OIDC_SUBJECT_PREFIX`. Cách làm từng bước: [plan 03, bước 2](../plans/03-trien-khai-oidc-roi-cicd.md#bước-2-lấy-hai-id-của-repo).

Tiền tố ghép kiểu này dựa trên tài liệu của GitHub, chưa phải chuỗi đọc từ token thật. Nó được kiểm lần đầu khi workflow Bootstrap vào được role.

### Bước 1: OIDC provider trong AWS

Một account chỉ có được một provider cho mỗi URL. Mọi role và mọi dự án trong account dùng chung provider của GitHub. Provider không dùng chéo account: role và provider mà nó tin phải ở cùng account.

Kiểm tra account đã có chưa:

```bash
aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?ends_with(Arn, ':oidc-provider/token.actions.githubusercontent.com')].Arn" \
  --output text
```

Chưa có thì tạo, bằng một trong ba cách:

- **Console:** IAM → Identity providers → Add provider → OpenID Connect; Provider URL `https://token.actions.githubusercontent.com`, Audience `sts.amazonaws.com`.
- **CLI:**

  ```bash
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com
  ```

  Bản AWS CLI cũ có thể báo thiếu `--thumbprint-list`. Khi đó cập nhật CLI, hoặc dùng cách CloudFormation bên dưới.

- **CloudFormation**, cách của repo này, trong `bootstrap/01-trust-anchor.yaml`:

  ```yaml
  GitHubOidcProvider:
    Type: AWS::IAM::OIDCProvider
    Condition: ShouldCreateOidcProvider
    DeletionPolicy: Retain
    UpdateReplacePolicy: Retain
    Properties:
      Url: https://token.actions.githubusercontent.com
      ClientIdList:
        - sts.amazonaws.com
  ```

  `Condition` cho phép bỏ qua việc tạo khi account đã có provider. `Retain` giữ provider lại khi xoá stack, vì dự án khác có thể đang tin nó.

Terraform cũng có resource cho provider, nhưng repo này không dùng: provider phải có trước thì Terraform trong CI mới đăng nhập được.

ARN của provider: `arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com`.

### Bước 2: role và trust policy

Trust policy của role apply trong repo này, sau khi CloudFormation thay tham số:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": [
            "repo:<owner>@<owner_id>/aws-eks-mysql-platform@<repo_id>:environment:development",
            "repo:<owner>@<owner_id>/aws-eks-mysql-platform@<repo_id>:environment:production"
          ]
        }
      }
    }
  ]
}
```

`StringEquals` và `StringLike`:

- `StringEquals` so chính xác từng ký tự. Dùng khi biết rõ ngữ cảnh. Repo này dùng `StringEquals` ở cả ba role.
- Muốn cho nhiều ngữ cảnh thì liệt kê nhiều giá trị dưới cùng một key; khớp một giá trị là đủ. Role apply ở trên liệt kê hai Environment. Role plan liệt kê hai giá trị: pull request và nhánh `main`.
- `StringLike` cho phép ký tự đại diện `*`. Một dấu `*` khớp cả dấu `:`, nên `repo:<owner>/<repo>:*` mở cửa cho mọi nhánh, mọi pull request và mọi environment của repo. Đây là trạng thái hiện tại của role apply ở dự án mẫu.

Quyền của role (permissions policy) là chuyện riêng, tách khỏi trust policy: trust policy trả lời "ai được thành role này", permissions policy trả lời "thành rồi thì được làm gì". Repo này gán `ReadOnlyAccess` cộng một policy nhỏ cho role plan, và `AdministratorAccess` cho role apply và role bootstrap. Hai role admin được bù bằng điều kiện `sub` chặt và Environment có người duyệt.

`MaxSessionDuration` là trần thời lượng phiên mà job được xin. Cả ba role để 3600 giây.

### Bước 3: workflow

Dạng tối thiểu, rút từ các workflow của repo này:

```yaml
permissions:
  id-token: write
  contents: read

jobs:
  apply:
    runs-on: ubuntu-latest
    environment: ${{ github.ref == 'refs/heads/production' && 'production' || 'development' }}
    env:
      ACCOUNT_ID: ${{ github.ref == 'refs/heads/production' && vars.PROD_ACCOUNT_ID || vars.DEV_ACCOUNT_ID }}
    steps:
      - uses: actions/checkout@v7

      - uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: arn:aws:iam::${{ env.ACCOUNT_ID }}:role/aws-eks-mysql-platform-gha-apply
          aws-region: us-east-1

      - name: Verify caller identity
        run: aws sts get-caller-identity --query Arn --output text
```

Bước đăng nhập chỉ cần hai dòng: vào role nào, ở region nào. Hai biểu thức phía trên chọn Environment và account theo nhánh: nhánh `production` ra `production`, mọi nhánh khác ra `development`. Dự án mẫu viết đúng như vậy.

Các input khác của `aws-actions/configure-aws-credentials`, để biết khi cần. Repo này không dùng input nào trong số đó:

| Input | Dùng để |
|---|---|
| `audience` | `aud` xin từ GitHub; mặc định `sts.amazonaws.com` |
| `role-session-name` | tên phiên, hiện trong CloudTrail; mặc định `GitHubActions` |
| `role-duration-seconds` | thời lượng phiên; mặc định một giờ, không vượt `MaxSessionDuration` |
| `mask-aws-account-id` | che account ID trong log |
| `disable-retry` | không thử lại khi vào role hỏng; dùng cho các lần chờ bị từ chối |

Repo này không đặt `role-session-name`, nên mọi phiên mang tên mặc định `GitHubActions`. Nếu tự đặt, tên phiên phải dài 2 tới 64 ký tự, chỉ gồm chữ, số và các ký tự `_+=,.@-`.

### Bước 4: xác nhận đường thông

Repo này có một workflow chỉ để thử đăng nhập, `oidc-test.yaml`. Nó chạy khi có push vào `development` hoặc `production`: in tên nhánh, vào role apply, rồi gọi `aws sts get-caller-identity`. Trong log của job:

- bước `aws-actions/configure-aws-credentials` xanh;
- bước **Verify caller identity** in `arn:aws:sts::<account-id>:assumed-role/aws-eks-mysql-platform-gha-apply/GitHubActions`.

Cách chạy: [plan 03, phần 2](../plans/03-trien-khai-oidc-roi-cicd.md#phần-2-thử-bằng-một-pull-request).

### Bước 5: xem lại trên CloudTrail

**CloudTrail → Event history**, lọc **Event name** là `AssumeRoleWithWebIdentity`. Trong chi tiết một sự kiện:

- `userIdentity.identityProvider` là `token.actions.githubusercontent.com`;
- `userIdentity.userName` là `sub` mà job đã trình;
- `requestParameters.roleArn` là role được xin;
- `requestParameters.roleSessionName` là tên phiên;
- token đã được che, không nằm trong log.

Mọi lời gọi API sau đó mang `userIdentity.arn` dạng `arn:aws:sts::<account-id>:assumed-role/<tên role>/<tên phiên>`. AWS khuyên không đưa thông tin cá nhân vào `sub`, vì nó được ghi vào CloudTrail; `sub` của GitHub chỉ chứa tên và ID của repo.

### Bước 6: siết lại

Việc repo này đã làm:

1. `sub` được so chính xác, từng ngữ cảnh một, không có ký tự đại diện.
2. Role ghi (apply, bootstrap) chỉ nhận job chạy trong Environment có luật nhánh và có người duyệt.
3. Tách role theo việc: plan chỉ đọc, apply được ghi, bootstrap chỉ cho phần nền.
4. Role plan đọc được state nhưng không ghi được state.

Việc còn có thể làm, khi cần chặt hơn:

- đặt `role-session-name` theo ID lần chạy, để từ CloudTrail lần ngược được về đúng lần chạy trên GitHub;
- thêm điều kiện trên `token.actions.githubusercontent.com:repository_id` và `:repository_owner_id`. Hai key này so thẳng với ID, không phụ thuộc cách GitHub ghép chuỗi `sub`;
- thêm điều kiện trên `:job_workflow_ref`, để chỉ đúng một file workflow vào được role;
- thay `AdministratorAccess` của role apply bằng quyền vừa đủ cho những gì Terraform quản lý;
- cảnh báo khi có `AssumeRoleWithWebIdentity` bị từ chối trên role ghi.

## 9. `bootstrap/01-trust-anchor.yaml` của repo này tạo gì

File này là bước làm tay duy nhất trên AWS. Nó làm hai việc trong account đang đăng nhập.

**Tham số:**

| Tham số | Ý nghĩa |
|---|---|
| `ProjectName` | tên dự án, trùng tên repo; làm tiền tố cho tên role |
| `OidcSubjectPrefix` | `<tiền tố>`, đọc từ token thật |
| `CreateOidcProvider` | `true` nếu account chưa có provider của GitHub, `false` nếu đã có |

**Việc 1: provider.** Tạo `AWS::IAM::OIDCProvider` khi `CreateOidcProvider` là `true`; ngược lại không tạo, và role trỏ tới provider có sẵn bằng ARN.

**Việc 2: role bootstrap.**

```yaml
GhaBootstrapRole:
  Type: AWS::IAM::Role
  Properties:
    RoleName: !Sub '${ProjectName}-gha-bootstrap'
    MaxSessionDuration: 3600
    ManagedPolicyArns:
      - !Sub 'arn:${AWS::Partition}:iam::aws:policy/AdministratorAccess'
    AssumeRolePolicyDocument:
      Version: '2012-10-17'
      Statement:
        - Effect: Allow
          Principal:
            Federated: <ARN của provider>
          Action: sts:AssumeRoleWithWebIdentity
          Condition:
            StringEquals:
              'token.actions.githubusercontent.com:aud': sts.amazonaws.com
              'token.actions.githubusercontent.com:sub': !Sub '${OidcSubjectPrefix}:environment:bootstrap'
```

Trust policy nói: chỉ job của đúng repo này, chạy trong GitHub Environment tên `bootstrap`, mới vào được. Environment đó chỉ nhận nhánh `main` và phải có người duyệt. Vì role tin mọi job mang `sub` này, Environment phải có luật **trước** khi role được tạo.

Sau khi stack xong, account có: một provider (mới tạo hoặc có sẵn), và một role `aws-eks-mysql-platform-gha-bootstrap` mang quyền admin. Không có bucket, không có role nào khác. Phần còn lại do workflow `bootstrap.yaml` tạo, bằng chính role này.

Khác bản gốc: provider được giữ lại khi xoá stack, còn role thì xoá theo stack. Một role admin không nên sống sót sau khi dự án đã dọn.

## 10. Năm lớp quyết định một job vào đâu

### Lớp 1: account AWS

Role nằm trong account nào thì job vào account đó. Account ID nằm trong ARN của role, và workflow đặt nó vào biến môi trường `ACCOUNT_ID`, chọn theo nhánh như dự án mẫu: nhánh `production` thì lấy biến repo `PROD_ACCOUNT_ID`, còn lại lấy `DEV_ACCOUNT_ID`. Hai biến mang cùng một giá trị thì hai môi trường nằm chung một account, như dự án mẫu đang chạy.

```text
Account <account-id>
+-- OIDC provider token.actions.githubusercontent.com   (dùng chung cho mọi dự án trong account)
+-- role aws-eks-mysql-platform-gha-bootstrap
+-- role aws-eks-mysql-platform-gha-plan
+-- role aws-eks-mysql-platform-gha-apply
+-- bucket aws-eks-mysql-platform-tfstate-<account-id>
```

### Lớp 2: GitHub Environment

| Environment | Nhánh được dùng | Người duyệt | Job nào khai |
|---|---|---|---|
| `bootstrap` | `main` | có | job của `bootstrap.yaml` |
| `development` | `development` | có | job `apply` của `terraform-apply.yaml`, job `destroy` của `terraform-destroy.yaml`, và job `test` của `oidc-test.yaml`, khi chúng chạy cho `development` |
| `production` | `production` | có | ba job trên, khi chúng chạy cho `production` |

Environment làm hai việc cùng lúc: chặn job cho tới khi có người duyệt, và đổi `sub` của job thành `<tiền tố>:environment:<tên>`.

### Lớp 3: role ARN trong bước đăng nhập

```yaml
role-to-assume: arn:aws:iam::${{ env.ACCOUNT_ID }}:role/aws-eks-mysql-platform-gha-apply
```

Tên role được ghi thẳng. Job `plan` và job `drift` xin role `-gha-plan`; job `apply`, `destroy` và `test` xin role `-gha-apply`. Hai môi trường dùng chung tên role; khác account thì mỗi account có bộ role riêng mang cùng tên.

### Lớp 4: trust policy của từng role

| Role | Quyền | `sub` được nhận |
|---|---|---|
| `aws-eks-mysql-platform-gha-bootstrap` | `AdministratorAccess` | `<tiền tố>:environment:bootstrap` |
| `aws-eks-mysql-platform-gha-plan` | `ReadOnlyAccess`, đọc state, ghi lock file | `<tiền tố>:pull_request`, `<tiền tố>:ref:refs/heads/main` |
| `aws-eks-mysql-platform-gha-apply` | `AdministratorAccess` | `<tiền tố>:environment:development`, `<tiền tố>:environment:production` |

Lớp 3 là thứ job xin. Lớp 4 là thứ AWS cho. Job xin sai thì lớp 4 từ chối.

### Lớp 5: backend của Terraform

```hcl
# envs/development/backend.tf
terraform {
  backend "s3" {
    bucket       = "aws-eks-mysql-platform-tfstate-<account-id>"
    key          = "aws-eks-mysql-platform/development/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    kms_key_id   = "alias/aws-eks-mysql-platform-tfstate"
    use_lockfile = true
  }
}
```

Tên bucket được ghi trong file, có account ID ở đuôi, như ở dự án mẫu. `envs/production/backend.tf` giống hệt, chỉ khác `key`. Hai môi trường chung account thì chung một bucket, mỗi môi trường một key.

## 11. Tóm tắt: chỗ nào trỏ tới đâu

| File | Chỗ | Quyết định điều gì |
|---|---|---|
| `bootstrap/01-trust-anchor.yaml` | cả file | account nào có role bootstrap: account đang đăng nhập lúc deploy |
| `bootstrap/01-trust-anchor.yaml` | tham số `OidcSubjectPrefix` | repo nào vào được role bootstrap |
| `bootstrap/03-github-oidc-roles.yaml` | danh sách `sub` của `GhaPlanRole` | ngữ cảnh nào vào được role chỉ đọc |
| `bootstrap/03-github-oidc-roles.yaml` | danh sách `sub` của `GhaApplyRole` | Environment nào vào được role ghi |
| Biến repo `DEV_ACCOUNT_ID`, `PROD_ACCOUNT_ID` | Settings của GitHub | account mà workflow nhắm tới, chọn theo nhánh |
| Biến repo `OIDC_SUBJECT_PREFIX` | Settings của GitHub | giá trị workflow Bootstrap truyền vào template 03 |
| `.github/workflows/bootstrap.yaml` | `environment: bootstrap` | job phải qua cửa duyệt, và `sub` mang đuôi `:environment:bootstrap` |
| `.github/workflows/terraform-plan.yaml` | hai biểu thức trên `github.base_ref` | thư mục env và account được plan: `production` khi nhánh đích là `production`, còn lại là `development` |
| `.github/workflows/terraform-apply.yaml` | ba biểu thức trên `github.ref` | Environment, thư mục env và account theo nhánh vừa nhận push |
| `.github/workflows/terraform-apply.yaml` | `on.push.branches` | chỉ push vào `development` và `production` mới chạy |
| `.github/workflows/terraform-drift.yaml` | `matrix.include` | mỗi môi trường một job, với nhánh và account của nó |
| `.github/workflows/terraform-destroy.yaml` | ô chọn `environment` | Environment, thư mục env và account bị xoá |
| `envs/<môi trường>/backend.tf` | `bucket`, `key` | state nằm ở bucket nào, và ở đâu trong bucket |
| Settings → Environments | luật nhánh, người duyệt | nhánh nào dùng được Environment nào, ai duyệt |

## 12. Các tầng bảo vệ

Một job muốn ghi vào AWS bằng role apply phải qua các tầng sau.

```text
+------------------------------------------------------------------+
| Tầng 1: BẢO VỆ NHÁNH (GitHub)                                    |
|   Nhánh môi trường chỉ nhận code qua pull request,               |
|   không force push, không xoá nhánh.                             |
+------------------------------------------------------------------+
                               v
+------------------------------------------------------------------+
| Tầng 2: ENVIRONMENT (GitHub)                                     |
|   Mỗi Environment chỉ nhận nhánh cùng tên,                       |
|   và phải có người duyệt.                                        |
+------------------------------------------------------------------+
                               v
+------------------------------------------------------------------+
| Tầng 3: LOGIC CỦA WORKFLOW (GitHub)                              |
|   Tên Environment và thư mục env suy từ tên nhánh.               |
|   Workflow apply chỉ chạy khi push vào nhánh môi trường.         |
+------------------------------------------------------------------+
                               v
+------------------------------------------------------------------+
| Tầng 4: TRUST POLICY (AWS)                                       |
|   Role apply chỉ nhận sub của hai Environment đã liệt kê.        |
|   Job không chạy trong một Environment đó thì AWS từ chối,       |
|   dù workflow viết gì.                                           |
+------------------------------------------------------------------+
                               v
+------------------------------------------------------------------+
| Tầng 5: QUYỀN CỦA ROLE VÀ CỦA TÀI NGUYÊN (AWS)                   |
|   Role plan không ghi được state. Bucket state từ chối           |
|   kết nối không TLS và upload không mã hoá KMS.                  |
+------------------------------------------------------------------+
```

Ba tầng đầu do GitHub giữ, hai tầng sau do AWS giữ. Ý nghĩa của tầng 4: kể cả khi ai đó viết được một workflow tuỳ ý trên một nhánh lạ, AWS vẫn không đưa role ghi cho job đó. Ở dự án mẫu, tầng này hiện để ngỏ vì trust policy dùng `:*`.

Tầng 2 và tầng 4 phải khớp nhau. Trust policy tin `:environment:development` và `:environment:production`, nên cả hai Environment phải có luật nhánh và người duyệt. Một Environment không có luật thì tầng 4 cũng không còn nghĩa.

## 13. Ví dụ từ đầu tới cuối: merge vào `development`

**Bước 1: pull request.** Feature branch mở pull request vào `development`. Workflow `terraform-plan.yaml` chạy bằng role plan, với `sub` là `<tiền tố>:pull_request`, và ghi plan vào pull request.

**Bước 2: merge.** Merge tạo một lần push vào `development`. Vì có đổi `envs/**` hoặc `modules/**`, `terraform-apply.yaml` chạy.

**Bước 3: job `apply` gặp Environment.** Sau job `sync-check`, workflow chỉ còn một job, như ở dự án mẫu:

```yaml
environment: ${{ github.ref == 'refs/heads/production' && 'production' || 'development' }}   # development
```

GitHub kiểm luật của Environment `development`: nhánh `development` được phép, và cần người duyệt. Job dừng ở trạng thái chờ, chưa chạy bước nào.

**Bước 4: duyệt.** Lần chạy này chưa có plan nào để xem. Người duyệt đọc plan trong comment của pull request ở bước 1, rồi bấm **Approve and deploy**.

**Bước 5: xin token.** Job xin JWT:

```text
iss: https://token.actions.githubusercontent.com
aud: sts.amazonaws.com
sub: <tiền tố>:environment:development
```

**Bước 6: gọi STS.**

```yaml
role-to-assume: arn:aws:iam::<account-id>:role/aws-eks-mysql-platform-gha-apply
```

**Bước 7: AWS xét trust policy.** `aud` khớp, `sub` khớp một trong hai giá trị được liệt kê. STS trả credentials tạm thời, hạn một giờ.

**Bước 8: Terraform chạy.** `terraform init` đọc tên bucket và key trong `envs/development/backend.tf`, mở state, giữ khoá bằng lock file. Rồi `plan` ghi ra một file plan, và `apply` chạy đúng file đó.

**Bước 9: job kết thúc.** Máy chạy job bị huỷ, biến môi trường mất theo. Credentials hết hạn sau tối đa một giờ. Mục Deployments của repo thêm một dòng `development`.

Merge vào `production` đi đúng các bước trên, với Environment `production`, thư mục `envs/production` và biến `PROD_ACCOUNT_ID`.

## 14. Các kiểu tấn công và vì sao bị chặn

Mỗi mục ghi tầng nào chặn. Đây là phân tích theo thiết kế: repo không có workflow nào chạy thử các trường hợp này.

### 1. Workflow trên nhánh lạ tự xin role apply

```yaml
# trên nhánh feat/x, không khai environment
- uses: aws-actions/configure-aws-credentials@v6
  with:
    role-to-assume: arn:aws:iam::<account-id>:role/aws-eks-mysql-platform-gha-apply
```

`sub` của job là `<tiền tố>:ref:refs/heads/feat/x`. Role apply chỉ nhận `<tiền tố>:environment:development` và `<tiền tố>:environment:production`. AWS từ chối. Chạy từ `main` cũng bị từ chối, vì `sub` vẫn là dạng nhánh. Tầng 4.

### 2. Workflow trên nhánh lạ khai `environment: development` để có `sub` đúng

GitHub xét luật của Environment trước khi job chạy bước nào: nhánh `feat/x` không được dùng `development`. Job bị dừng ngay, không có token nào được cấp. Tầng 2.

### 3. Khai một Environment chưa tồn tại

Workflow gọi tên một Environment chưa có, ví dụ `staging`, thì GitHub tự tạo nó, không có luật nào. Job chạy được, và `sub` là `<tiền tố>:environment:staging`. Trust policy không liệt kê giá trị đó, nên AWS từ chối. Tầng 4.

Bài học cho người sửa template: chỉ thêm một Environment vào trust policy sau khi nó đã có luật nhánh và người duyệt.

### 4. Workflow ở repo khác

Repo khác, kể cả cùng chủ, có tên repo và ID repo khác, nên tiền tố khác. Không khớp. Tầng 4.

### 5. Tên bị dùng lại

Một tài khoản hoặc repo bị xoá, người khác tạo lại đúng tên đó. Với dạng `sub` cũ, token của họ khớp trust policy cũ. Với dạng mới, ID khác nên không khớp. Đây là lý do GitHub đổi dạng `sub`. Tầng 4.

### 6. Nhánh có tên gần giống

Nhánh `main-evil` cho `sub` là `...:ref:refs/heads/main-evil`. Role plan so chính xác với `...:ref:refs/heads/main`. Không khớp. Điều này chỉ đúng vì dùng `StringEquals`; một mẫu `StringLike` kiểu `...:ref:refs/heads/main*` sẽ khớp. Tầng 4.

### 7. Pull request từ fork

Job của pull request từ fork không được cấp `id-token: write`, nên không xin được token. Không có gì để đưa cho AWS. Ngoài ra, repo đặt chế độ phải duyệt mới chạy workflow của người đóng góp bên ngoài.

### 8. Dùng lại hoặc lấy trộm token

Token sống vài phút, và chỉ đổi được đúng role mà `sub` của nó được phép. Credentials sau đó sống tối đa một giờ. So với một access key không có hạn, khoảng thời gian và phạm vi thiệt hại nhỏ hơn nhiều.

### Thứ không bị chặn, theo thiết kế

Một pull request trong chính repo có thể sửa workflow plan và chạy nó với role plan. Role này chỉ đọc, nhưng đọc được state và mọi thứ `ReadOnlyAccess` cho phép. Thứ giới hạn ở đây là quyền push lên repo, không phải IAM. Ghi ở mục giới hạn của plan 03.

## 15. So sánh trước và sau OIDC

| Tiêu chí | Access key | OIDC |
|---|---|---|
| Thời hạn của credentials | không có hạn | 900 giây tới 12 giờ, mặc định 1 giờ |
| Lưu ở đâu | GitHub Secrets | không lưu; chỉ nằm trong bộ nhớ của job |
| Đổi key | làm tay | mỗi lần chạy một bộ mới |
| Truy vết theo lần chạy | khó | CloudTrail có `sub` và tên phiên |
| Thiệt hại khi lộ | kéo dài tới khi phát hiện | tối đa một phiên |
| Việc phải dựng | IAM user, key, secret | provider, role, trust policy |
| Dùng từ repo khác | cùng key dùng được ở mọi nơi | bị điều kiện `sub` chặn |
| Khuyến nghị của AWS | không nên | nên |

## 16. Hỏi đáp

> **Đâu là chỗ làm job trỏ tới đúng account và đúng môi trường?**

Năm chỗ, ở mục 10: account nơi deploy trust anchor; biến `DEV_ACCOUNT_ID` hoặc `PROD_ACCOUNT_ID`, chọn theo nhánh; tên Environment suy từ tên nhánh; trust policy của từng role; và tên bucket cùng key của state trong `backend.tf`.

> **`bootstrap/01-trust-anchor.yaml` tạo chính xác những gì?**

Hai thứ: OIDC provider của GitHub, nếu account chưa có, và role `aws-eks-mysql-platform-gha-bootstrap`. Không tạo bucket, không tạo role plan hay apply. Xem mục 9.

> **Vì sao trust policy chép từ hướng dẫn cũ không chạy với repo này?**

Vì hướng dẫn cũ viết `sub` theo dạng `repo:<owner>/<repo>:...`, còn repo tạo sau 15/07/2026 phát `repo:<owner>@<owner_id>/<repo>@<repo_id>:...`. Hai chuỗi không bằng nhau, và AWS so từng ký tự. Xem mục 5.

> **Job khai `environment` thì `sub` có còn tên nhánh không?**

Không. `sub` chỉ còn `<tiền tố>:environment:<tên>`. Việc "chỉ nhánh `development` mới deploy được lên `development`" do luật nhánh của Environment giữ, không do `sub`.

> **Tóm tắt trong một câu?**

GitHub cấp cho mỗi job một JWT ghi job đó là ai; AWS kiểm chữ ký của GitHub, so `aud` và `sub` với trust policy của role, rồi trả credentials sống một giờ; không có access key dài hạn ở đâu cả.

## 17. Chi tiết từng pha: từ lúc job chạy tới từng lời gọi API

Mục này đi chậm qua mọi bước, và đào sâu hai chỗ các mục trước chỉ lướt qua: GitHub cấp token cho job thế nào (pha C, D), và AWS quyết định từng lời gọi API ra sao (pha H).

Pha A tới G trả lời "ai được thành role". Pha H trả lời "thành role rồi thì được làm gì".

### Pha A: những thứ phải có sẵn trong AWS

1. OIDC provider với URL `https://token.actions.githubusercontent.com` và audience `sts.amazonaws.com`.
2. Role, với hai policy độc lập:
   - **trust policy:** ai được thành role này;
   - **permissions policy:** role này được làm gì.

Trong repo này, provider và role bootstrap đến từ `bootstrap/01-trust-anchor.yaml` (deploy tay). Role plan và role apply đến từ `bootstrap/03-github-oidc-roles.yaml` (workflow Bootstrap deploy).

### Pha B: GitHub khởi chạy job

GitHub nhận một sự kiện (`push`, `pull_request`, `workflow_dispatch`, `schedule`), đối chiếu với khối `on:` của workflow, tạo một lần chạy và giao job cho một máy.

1. GitHub đọc `permissions:`. Có `id-token: write` thì job được cấp một địa chỉ và một mã để xin OIDC token; không có thì không.
2. Nếu job khai `environment`, GitHub xét luật của Environment trước: nhánh có được phép không, đã có người duyệt chưa. Job chỉ chạy khi mọi luật đạt.

Tới đây job chưa có credentials AWS nào.

### Pha C: job xin JWT

Action đăng nhập gọi hàm `getIDToken` của bộ công cụ Actions. Hàm này gọi một endpoint nội bộ của GitHub Actions, kèm audience muốn xin, và nhận về JWT.

JWT gồm header (thuật toán, `kid`), payload (các claim ở mục 5) và chữ ký của GitHub.

### Pha D: gọi `sts:AssumeRoleWithWebIdentity`

Action gửi tới endpoint STS của region đã cấu hình, ở đây là `us-east-1`:

```text
Action=AssumeRoleWithWebIdentity
RoleArn=arn:aws:iam::<account-id>:role/aws-eks-mysql-platform-gha-apply
RoleSessionName=GitHubActions
WebIdentityToken=<JWT của pha C>
DurationSeconds=3600
```

Lời gọi này không cần credentials AWS nào để ký. Danh tính của người gọi nằm trọn trong token.

### Pha E: AWS kiểm token

Theo thứ tự ở mục 6: tìm provider theo `iss`, tải JWKS, kiểm chữ ký, kiểm hạn dùng, kiểm `aud` có trong danh sách audience của provider.

Pha E trả lời: token này có đúng do GitHub ký không, còn hạn không, có gửi cho AWS không.

### Pha F: AWS xét trust policy của role

AWS đọc trust policy của role được xin, và hỏi:

1. Có câu lệnh `Allow` nào mà `Principal.Federated` là ARN của provider, và `Action` là `sts:AssumeRoleWithWebIdentity` không?
2. Mọi điều kiện của câu lệnh đó có đúng với các claim không?

Condition key dùng được với GitHub, theo tài liệu IAM. Tất cả mang tiền tố `token.actions.githubusercontent.com:`.

| Condition key | Claim tương ứng | Ghi chú |
|---|---|---|
| `sub` | `sub` | IAM bắt buộc phải có điều kiện trên key này, hoặc trên `job_workflow_ref` |
| `aud` | `aud` | |
| `repository` | `repository` | tên, có thể bị dùng lại |
| `repository_id` | `repository_id` | ID, không đổi khi đổi tên repo |
| `repository_owner_id` | `repository_owner_id` | ID của chủ repo |
| `actor` | `actor` | tài khoản khởi chạy |
| `actor_id` | `actor_id` | |
| `environment` | `environment` | |
| `ref` | `ref` | |
| `workflow` | `workflow` | tên workflow |
| `job_workflow_ref` | `job_workflow_ref` | đường dẫn file workflow kèm ref |
| `enterprise_id` | | chỉ có với GitHub Enterprise |

Trừ `sub` và `aud`, các key này chỉ dùng được trong trust policy, không dùng được trong permissions policy.

Không câu lệnh nào đạt thì trả `AccessDenied`.

Trust policy không quan tâm role được làm gì. Nó chỉ trả lời ai được thành role.

### Pha G: STS trả credentials tạm thời

```json
{
  "Credentials": {
    "AccessKeyId": "ASIA...",
    "SecretAccessKey": "...",
    "SessionToken": "...",
    "Expiration": "2026-11-17T10:42:00Z"
  },
  "AssumedRoleUser": {
    "AssumedRoleId": "AROAEXAMPLEID:GitHubActions",
    "Arn": "arn:aws:sts::<account-id>:assumed-role/aws-eks-mysql-platform-gha-apply/GitHubActions"
  },
  "SubjectFromWebIdentityToken": "repo:<owner>@<owner_id>/aws-eks-mysql-platform@<repo_id>:environment:development",
  "Audience": "sts.amazonaws.com",
  "Provider": "arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com"
}
```

Action đặt các biến môi trường `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_REGION` và `AWS_DEFAULT_REGION` cho các bước sau.

Access key ID bắt đầu bằng `ASIA` là dấu hiệu của credentials tạm thời; key dài hạn của IAM user bắt đầu bằng `AKIA`.

### Pha H: mỗi lời gọi API sau đó được xét quyền

Từ đây, mỗi lời gọi (`ssm:GetParameter`, `s3:PutObject`, mọi thứ `terraform` gọi) đi qua hai bước.

**H.1. Xác thực.** SDK ký lời gọi bằng access key và secret key, kèm session token. AWS kiểm chữ ký.

**H.2. Phân quyền.** AWS xét mọi policy liên quan, theo luật:

1. Có một `Deny` tường minh ở bất kỳ policy nào thì từ chối. `Deny` thắng mọi `Allow`.
2. Nếu account thuộc AWS Organizations, policy của tổ chức (SCP, RCP) phải cho phép.
3. Phải có một `Allow`: từ policy gắn vào role, hoặc, trong cùng account, từ policy gắn vào tài nguyên có nêu tên role.
4. Nếu role có permissions boundary, hoặc phiên có session policy, chúng cũng phải cho phép.
5. Không có `Allow` nào thì từ chối ngầm.

Thông báo lỗi của AWS nói rõ hỏng ở tầng nào, nên khi gỡ lỗi hãy đọc nguyên câu.

**H.3. Năm ví dụ thật của repo này.**

Policy liên quan: role plan có `ReadOnlyAccess` và policy `tfstate-read-and-lock`; role apply có `AdministratorAccess`; bucket state có bucket policy với hai câu lệnh `Deny`.

*Lời gọi 1: role plan đọc SSM parameter thử CI/CD.* `ssm:GetParameter`. `ReadOnlyAccess` cho phép. Không có `Deny` nào. **Được.**

*Lời gọi 2: role plan ghi đè file state.* `s3:PutObject` lên `.../development/terraform.tfstate`. `ReadOnlyAccess` không có quyền ghi. Policy `tfstate-read-and-lock` chỉ cho `s3:GetObject` trên file state. Không có `Allow` nào. **Từ chối ngầm:**

```text
User: arn:aws:sts::<account-id>:assumed-role/aws-eks-mysql-platform-gha-plan/GitHubActions
is not authorized to perform: s3:PutObject on resource: "arn:aws:s3:::aws-eks-mysql-platform-tfstate-<account-id>/aws-eks-mysql-platform/development/terraform.tfstate"
because no identity-based policy allows the s3:PutObject action
```

Đây là chủ ý: một pull request không sửa được state.

*Lời gọi 3: role plan ghi lock file.* `s3:PutObject` lên `.../terraform.tfstate.tflock`. Câu lệnh `TakeAndReleaseStateLock` cho phép. Bucket policy có hai `Deny`: một cho kết nối không TLS, một cho upload không kèm mã hoá KMS. Terraform gọi qua TLS và gửi kèm yêu cầu mã hoá KMS, nên không `Deny` nào khớp. S3 cần thêm `kms:GenerateDataKey` trên key của state; câu lệnh `UseStateKey` cho phép. **Được.**

*Lời gọi 4: role apply sửa SSM parameter.* `ssm:PutParameter`. `AdministratorAccess` cho phép. **Được.**

*Lời gọi 5: role apply upload vào bucket state mà không yêu cầu mã hoá KMS.* `AdministratorAccess` cho phép, nhưng câu lệnh `DenyUnencryptedUploads` của bucket policy khớp. **Từ chối**, với câu kết `with an explicit deny in a resource-based policy`. Quyền admin không thắng được một `Deny` tường minh.

### Pha I: job kết thúc

1. Bước cuối chạy xong, máy chạy job bị huỷ, biến môi trường `AWS_*` mất theo.
2. Credentials còn hiệu lực phía AWS tới `Expiration`, nhưng không còn ai giữ chúng. Muốn cắt sớm, dùng chức năng thu hồi phiên của role trong IAM.
3. CloudTrail giữ sự kiện `AssumeRoleWithWebIdentity`, kèm `sub` của job, và mọi lời gọi sau đó dưới tên role.

### Pha J: sơ đồ tổng hợp

```text
+---------------------+   kích hoạt   +----------------------+
|  Sự kiện GitHub     | ------------> | Một job              |
|  (push development) |               | permissions:         |
+---------------------+               |   id-token: write    |
                                      +----------+-----------+
                                                 |
                  Pha B: xét luật Environment    |
                  (nhánh được phép, người duyệt) |
                                                 v
+----------------------+               +----------------------+
| Issuer của GitHub    |<-- xin aud ---| configure-aws-       |
| token.actions...     |--- JWT ------>| credentials@v6       |
+----------------------+               +----------+-----------+
                                                  |
                              AssumeRoleWithWebIdentity
                                                  v
+----------------------------------------------------------------+
|                           AWS STS                              |
|  Pha E: kiểm token (iss, chữ ký, hạn dùng, aud)                |
|  Pha F: xét trust policy                                       |
|     Principal.Federated là provider của GitHub?                |
|     Action là sts:AssumeRoleWithWebIdentity?                   |
|     Condition (aud, sub) đúng với claim?                       |
+----------------------------------------------------------------+
                                                  |
                         credentials tạm (1 giờ, access key ASIA...)
                                                  v
+----------------------+                +----------------------+
| Các bước của job     |-- lời gọi ---->| Dịch vụ AWS          |
| (terraform apply)    |   đã ký        | (SSM, S3, EC2, ...)  |
|                      |<-- kết quả ----+                      |
+----------------------+                +----------+-----------+
                                                   |
                                        Pha H: xét quyền
                                          1. Deny tường minh
                                          2. Policy của tổ chức
                                          3. Allow từ role hoặc tài nguyên
                                          4. Boundary, session policy
                                                   v
                                            Cho phép / Từ chối
```

### Pha K: lỗi nào hỏng ở đâu

| Hỏng ở | Thấy gì | Sửa ở đâu |
|---|---|---|
| Workflow thiếu `id-token: write` | bước đăng nhập hỏng, báo không tải được credentials | thêm khối `permissions:` |
| Account chưa có provider của GitHub | `InvalidIdentityToken`, câu báo không tìm thấy OpenID Connect provider | tạo provider, hoặc deploy trust anchor với `CreateOidcProvider=true` |
| `aud` không nằm trong audience của provider | `InvalidIdentityToken` | thêm audience vào provider, hoặc sửa input `audience` |
| `sub` không nằm trong trust policy | `Not authorized to perform sts:AssumeRoleWithWebIdentity` | so `sub` thật trong CloudTrail với điều kiện của role; xem ba dòng dưới |
| Trust policy theo dạng cũ, repo phát dạng mới | như trên; `sub` thật có `@<số>`, điều kiện thì không | sửa biến `OIDC_SUBJECT_PREFIX`, deploy lại trust anchor và stack role |
| Job chạy sai nhánh | như trên; đuôi `sub` là nhánh không có trong danh sách | chạy từ đúng nhánh |
| Job thiếu hoặc thừa `environment` | như trên; đuôi `sub` là `:ref:...` trong khi role chờ `:environment:...`, hoặc ngược lại | sửa khai báo `environment` của job |
| Nhánh không được dùng Environment | job đỏ ngay, chưa chạy bước nào, báo luật bảo vệ của Environment | chạy từ đúng nhánh, hoặc sửa luật nhánh |
| Token hết hạn | `ExpiredToken` | chạy lại job |
| Role không có `Allow` cho hành động | `AccessDenied ... because no identity-based policy allows ...` | thêm quyền vào role, nếu đó là chủ ý |
| Có `Deny` tường minh | `AccessDenied ... with an explicit deny in ...` | đọc phần cuối câu để biết policy nào |

Bốn dòng giữa bảng cho cùng một câu lỗi từ AWS. Thứ phân biệt chúng là `sub` thật của job, xem được ở cột `Username` của sự kiện `AssumeRoleWithWebIdentity` trong CloudTrail.

## 18. Tham khảo

- GitHub Docs, [OpenID Connect reference](https://docs.github.com/en/actions/reference/security/oidc): danh sách claim, các dạng `sub`, dạng có ID, tuỳ biến `sub`.
- GitHub Changelog 23/04/2026, [Immutable subject claims for GitHub Actions OIDC tokens](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/).
- GitHub Docs, [REST API endpoints for GitHub Actions OIDC](https://docs.github.com/en/rest/actions/oidc): đọc và đặt cách ghép `sub`.
- GitHub Docs, [Configuring OpenID Connect in Amazon Web Services](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services).
- AWS IAM, [Create an OpenID Connect (OIDC) identity provider](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html): yêu cầu với URL, JWKS, thumbprint.
- AWS IAM, [Create a role for OpenID Connect federation](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-idp_oidc.html): trust policy cho GitHub.
- AWS IAM, [Identity-provider controls for shared OIDC providers](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_oidc_secure-by-default.html): điều kiện bắt buộc trên `sub`.
- AWS IAM, [Available keys for AWS OIDC federation](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_iam-condition-keys.html): condition key của GitHub.
- AWS STS, [AssumeRoleWithWebIdentity](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRoleWithWebIdentity.html): tham số, kết quả, mã lỗi.
- AWS CloudFormation, [AWS::IAM::OIDCProvider](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-iam-oidcprovider.html).
- AWS Security Blog, [Use IAM roles to connect GitHub Actions to actions in AWS](https://aws.amazon.com/blogs/security/use-iam-roles-to-connect-github-actions-to-actions-in-aws/).
- [`aws-actions/configure-aws-credentials`](https://github.com/aws-actions/configure-aws-credentials): README của action.
