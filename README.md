# Backlog Gemini Reply

Backlogで課題が起票された際に、GoogleのVertex AI (Gemini) を利用して自動で内容を解析・レビューし、コメントを投稿するWebhookアプリケーション。

このプロジェクトは、Google Cloud (Cloud Functions, API Gateway, Secret Manager, Cloud Storage) 上に、Terraformを用いてインフラを構築することを前提としています。

## アーキテクチャ

```
Backlog Webhook -> Google API Gateway -> Google Cloud Function -> Google Vertex AI (Gemini)
      ^                                       |                     |
      |                                       | (Prompt)            v
      +-------------<-- Backlog API --+       +--> GCS         (Comment)
```

1.  Backlogで課題が作成されると、設定されたWebhookが発火します。
2.  リクエストはAPI Gatewayに送信され、Basic認証が行われます。
3.  認証を通過したリクエストは、Cloud Functionに転送されます。
4.  Cloud Functionは、GCSからシステムプロンプトを読み込み、課題情報を元にVertex AI (Gemini) APIを呼び出し、レビューコメントを生成します。
5.  生成されたコメントを、Backlog APIを使って元の課題に投稿します。

## 主な使用技術

- **Application**: Python 3.12, Flask
- **Cloud**: Google Cloud
  - **Compute**: Cloud Functions (2nd gen)
  - **API**: API Gateway, Vertex AI
  - **Storage**: Cloud Storage (for prompts)
  - **Security**: Secret Manager
- **IaC**: Terraform

--- 

## クラウドへのデプロイ (Terraform)

Terraformを使用してGoogle Cloudにリソースをデプロイします。

### 前提条件

- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (gcloud CLI) がインストール・設定済みであること。
- [Terraform](https://learn.hashicorp.com/tutorials/terraform/install-cli) がインストール済みであること。
- GCPで課金が有効になっているプロジェクトがあること。

### 手順

1.  **作業ディレクトリへ移動**
    ```bash
    cd terraform
    ```

2.  **Terraform変数の設定**
    `terraform.tfvars.example`をコピーして`terraform.tfvars`ファイルを作成し、ご自身の環境に合わせて値を設定します。

    ```bash
    # Windows
    copy terraform.tfvars.example terraform.tfvars

    # macOS / Linux
    # cp terraform.tfvars.example terraform.tfvars
    ```
    
    `terraform.tfvars` を開き、以下の項目をすべて設定してください。
    - `project_id`: ご自身のGCPプロジェクトID
    - `region`: デプロイするGCPリージョン (例: `asia-northeast1`)
    - `backlog_api_key`: BacklogのAPIキー
    - `basic_auth_username`: Basic認証のユーザー名
    - `basic_auth_password`: Basic認証のパスワード
    - `backlog_space_url`: BacklogスペースのURL (例: `https://your-space.backlog.jp`)
    - `prompt_gcs_bucket_name`: プロンプトを保存するGCSバケット名。**世界中で一意な名前**にする必要があります。

3.  **Terraformの実行**
    ```bash
    # 初期化 (初回のみ)
    terraform init

    # 実行計画の確認
    terraform plan

    # 適用（デプロイ）
    terraform apply
    ```
    `apply` を確認・承認すると、リソースがGCP上に作成されます。

4.  **プロンプトの確認と適用**
    `terraform apply` を実行すると、`terraform` ディレクトリにある `system_prompt.txt` ファイルが自動的にGCSバケットにアップロードされます。
    
    プロンプトの内容を変更したい場合は、この `system_prompt.txt` ファイルを直接編集し、再度 `terraform apply` を実行するだけでGCS上のファイルが更新されます。

5.  **Backlog Webhookの設定**
    1. `terraform apply` の実行後、`outputs` としてAPI GatewayのURL (`gateway_url`) が表示されます。
    2. Backlogプロジェクトの「プロジェクト設定」>「Webhook」で「Webhookを追加」を選択します。
    3. WebhookのURLに、以下の形式でURLを設定します。
        ```
        https://<YOUR_BASIC_AUTH_USERNAME>:<YOUR_BASIC_AUTH_PASSWORD>@<API_GATEWAY_HOSTNAME>/webhook
        ```
        - `<YOUR_BASIC_AUTH_USERNAME>` と `<YOUR_BASIC_AUTH_PASSWORD>` は `terraform.tfvars` で設定したものに置き換えてください。
        - `<API_GATEWAY_HOSTNAME>` は `terraform output gateway_url` で表示されるURLのホスト名部分です。
    4. 「課題の追加」イベントのみにチェックを入れて、Webhookを登録します。

--- 

## ローカルでの開発とテスト

### 前提条件

- Python 3.12

### 手順

1.  **リポジトリのクローン**
    ```bash
    git clone https://github.com/your-username/backlog-reply.git
    cd backlog-reply
    ```

2.  **Python仮想環境の作成と有効化**
    ```bash
    # Windows
    python -m venv venv
    venv\Scripts\activate

    # macOS / Linux
    # python3 -m venv venv
    # source venv/bin/activate
    ```

3.  **依存ライブラリのインストール**
    ```bash
    pip install -r app/requirements.txt
    ```

4.  **Google Cloudの認証**
    ローカル環境からGCPリソース（Vertex AI, GCS）にアクセスするために、Application Default Credentials (ADC) を設定します。
    ```bash
    gcloud auth application-default login
    ```

5.  **環境変数の設定**
    アプリケーションは環境変数から設定を読み込みます。ローカルで実行するには、ターミナルで以下の環境変数を設定してください。

    **必須の環境変数:**
    - `GCP_PROJECT_ID`
    - `GCP_REGION`
    - `BACKLOG_SPACE_URL`
    - `BACKLOG_API_KEY`
    - `BASIC_AUTH_USERNAME`
    - `BASIC_AUTH_PASSWORD`
    - `PROMPT_GCS_BUCKET_NAME`
    - `SYSTEM_PROMPT_GCS_FILE_PATH`
    - `GEMINI_MODEL_NAME` (任意, デフォルト値あり)

    **設定例 (macOS / Linux):**
    ```bash
    export GCP_PROJECT_ID="your-gcp-project-id"
    export BACKLOG_API_KEY="your-backlog-api-key"
    ...
    ```

    **設定例 (Windows - Command Prompt):**
    ```cmd
    set GCP_PROJECT_ID="your-gcp-project-id"
    set BACKLOG_API_KEY="your-backlog-api-key"
    ...
    ```

6.  **ローカルサーバーの起動**
    ```bash
    python app/main.py
    ```
    サーバーが `http://127.0.0.1:8080` で起動します。

7.  **動作確認**
    別のターミナルから`curl`コマンドでテストします。
    ```bash
    curl -X POST -u "USER:PASS" -H "Content-Type: application/json" -d "{\"type\":1, \"content\":{\"key_id_str\":\"TEST-1\", \"summary\":\"テスト課題\", \"description\":\"これはテストです。\"}}" http://127.0.0.1:8080/webhook
    ```
    - `USER:PASS` はご自身で設定したBasic認証の情報に置き換えてください。

## ライセンス

This project is licensed under the [Apache License 2.0](LICENSE).
