ソースリポジトリとしてGitHubを利用した、AWS CodeBuildとAmazon ECSの連携ハンズオンを作成します。シンプルなWebアプリケーションを題材にします。  
このハンズオンは、GitHubリポジトリのbuildspec や Dockerファイル から Dockerイメージを自動でビルドし、Amazon ECRにプッシュ、そして ECSのサービスをデプロイする、という一連の流れを体験することを目的としています。

AWSマネジメントコンソール、CloudShell、そしてお持ちのGitHubアカウントのみを使用するため、お使いのPCに特別な環境を構築する必要はありません。

---

## **概要**

このハンズオンでは、以下のAWSサービスとGitHubを利用して、コンテナアプリケーションの簡単なCI/CDパイプラインを構築します。

* **ソースコード管理**: GitHub  
* **ビルド・テスト**: AWS CodeBuild  
* **コンテナレジストリ**: Amazon ECR (Elastic Container Registry)  
* **コンテナ実行環境**: Amazon ECS (Elastic Container Service) on AWS Fargate

**ゴール**: GitHubリポジトリにプッシュされた変更を元に、CodeBuildがDockerイメージをビルド＆ECRへプッシュし、ECSサービスを新しいイメージで自動的に更新する仕組みを構築します。

---

## **事前準備： IAMロールの作成**

CodeBuildとECSが連携するために、それぞれに必要な権限を持つIAMロールを作成します。

### **1\. CodeBuild用IAMロールの作成**

CodeBuildがECRやECSを操作するためのロールです。

1. AWSマネジメントコンソールで **IAM** に移動します。  
2. 左側のメニューから **ロール** を選択し、**ロールを作成** をクリックします。  
3. **信頼されたエンティティタイプ** で **AWSのサービス** を選択します。  
4. **ユースケース** で **CodeBuild** を選択し、**次へ** をクリックします。  
5. 許可ポリシーの追加画面で、以下の3つのAWS管理ポリシーを検索してチェックを入れます。  
   * AmazonEC2ContainerRegistryPowerUser  
   * AmazonECS\_FullAccess (ハンズオンを簡略化するため。本番環境ではより権限を絞ってください)  
   * IAMFullAccess (CodeBuildがECSサービスに紐づくロールを操作するために一時的に必要です。本番ではより限定的なポリシーを作成してください。)  
6. **次へ** をクリックします。  
7. **ロール名** に CodeBuildECSRoleForGitHub と入力し、**ロールを作成** をクリックします。

### **2\. ECSタスク実行用IAMロールの作成**

ECSタスクがECRからコンテナイメージをプル（ダウンロード）するために必要なロールです。

1. 再度、IAMの **ロール作成** 画面に移動します。  
2. **信頼されたエンティティタイプ** で **AWSのサービス** を選択します。  
3. **ユースケース** のドロップダウンから **Elastic Container Service** を選択し、その下の **Elastic Container Service Task** を選択して **次へ** をクリックします。  
4. ポリシー AmazonECSTaskExecutionRolePolicy が選択されていることを確認し、**次へ** をクリックします。  
5. **ロール名** に ECSTaskExecutionRole と入力し、**ロールを作成** をクリックします。（既に存在する場合はこの手順をスキップして問題ありません）

---

## **ステップ1： ソースコードの準備 (GitHub)**

アプリケーションのソースコードとビルド定義ファイル（buildspec.ymlなど）をご自身のGitHubアカウントに準備します。

1. ご自身のGitHubアカウントにログインし、新しいリポジトリを作成します。  
   * **Repository name**: aws-ecs-handson  
   * **Public** を選択  
   * **Add a README file** にチェックを入れる  
   * **Create repository** をクリック  
2. 作成したリポジトリのページで、Add file \-\> Create new file をクリックし、以下の4つのファイルを作成・コミットしてください。  
   **index.html** (シンプルなWebページ)  
   HTML  
   \<\!DOCTYPE **html**\>  
   \<html\>  
   \<head\>  
     \<title\>AWS CodeBuild Hands-On with GitHub\</title\>  
     \<style\>  
       body { font-family: sans-serif; text-align: center; margin-top: 5em; background-color: \#232F3E; color: white; }  
       h1 { color: \#FF9900; }  
     \</style\>  
   \</head\>  
   \<body\>  
     \<h1\>Welcome to AWS CodeBuild & ECS\!\</h1\>  
     \<p\>Deployed from GitHub\!\</p\>  
     \<p\>Version 1.0\</p\>  
   \</body\>  
   \</html\>

   **Dockerfile** (Nginxをベースにしたコンテナの設計図)  
   Dockerfile  
   FROM nginx:alpine  
   COPY index.html /usr/share/nginx/html/

   taskdef.json (ECSタスク定義のテンプレート)  
   注意: YOUR\_AWS\_ACCOUNT\_ID の部分を、ご自身のAWSアカウントIDに書き換えてください。AWSアカウントIDは、コンソールの右上に表示されています。  
   JSON  
   {  
       "family": "my-webapp-task",  
       "containerDefinitions": \[  
           {  
               "name": "my-webapp-container",  
               "image": "\<IMAGE\_URI\_PLACEHOLDER\>",  
               "cpu": 256,  
               "memory": 512,  
               "portMappings": \[  
                   {  
                       "containerPort": 80,  
                       "hostPort": 80,  
                       "protocol": "tcp"  
                   }  
               \],  
               "essential": true  
           }  
       \],  
       "requiresCompatibilities": \[  
           "FARGATE"  
       \],  
       "networkMode": "awsvpc",  
       "cpu": "256",  
       "memory": "512",  
       "executionRoleArn": "arn:aws:iam::YOUR\_AWS\_ACCOUNT\_ID:role/ECSTaskExecutionRole"  
   }

   buildspec.yml (CodeBuildのビルド手順書)  
   注意: YOUR\_AWS\_ACCOUNT\_ID と YOUR\_AWS\_REGION (例: ap-northeast-1) の部分を、ご自身の環境に合わせて書き換えてください。  
   YAML  
   version: 0.2

   env:  
     variables:  
       AWS\_ACCOUNT\_ID: "YOUR\_AWS\_ACCOUNT\_ID"  
       AWS\_DEFAULT\_REGION: "YOUR\_AWS\_REGION"  
       IMAGE\_REPO\_NAME: "my-webapp-repo-github"  
       ECS\_CLUSTER\_NAME: "my-cluster"  
       ECS\_SERVICE\_NAME: "my-webapp-service"  
       ECS\_TASK\_DEFINITION\_NAME: "my-webapp-task"

   phases:  
     pre\_build:  
       commands:  
         \- echo Logging in to Amazon ECR...  
         \- REPOSITORY\_URI=$AWS\_ACCOUNT\_ID.dkr.ecr.$AWS\_DEFAULT\_REGION.amazonaws.com/$IMAGE\_REPO\_NAME  
         \- aws ecr get-login-password \--region $AWS\_DEFAULT\_REGION | docker login \--username AWS \--password-stdin $REPOSITORY\_URI

     build:  
       commands:  
         \- echo Build started on \`date\`  
         \- COMMIT\_HASH=$(echo $CODEBUILD\_RESOLVED\_SOURCE\_VERSION | cut \-c 1-7)  
         \- IMAGE\_TAG=${COMMIT\_HASH:=latest}  
         \- echo Building the Docker image with tag $IMAGE\_TAG...  
         \- docker build \-t $REPOSITORY\_URI:$IMAGE\_TAG .  
         \- echo Pushing the Docker image...  
         \- docker push $REPOSITORY\_URI:$IMAGE\_TAG

     post\_build:  
       commands:  
         \- echo Build completed on \`date\`  
         \- echo Creating new task definition...  
         \- IMAGE\_URI\_WITH\_TAG=$REPOSITORY\_URI:$IMAGE\_TAG  
         \# taskdef.jsonのプレースホルダーを、ビルドした実際のイメージURIに置き換える  
         \- sed \-i \-e "s|\<IMAGE\_URI\_PLACEHOLDER\>|$IMAGE\_URI\_WITH\_TAG|g" taskdef.json  
         \# 新しいタスク定義を登録し、そのリビジョンを取得  
         \- NEW\_TASK\_INFO=$(aws ecs register-task-definition \--cli-input-json file://taskdef.json)  
         \- NEW\_REVISION=$(echo $NEW\_TASK\_INFO | jq .taskDefinition.revision)  
         \- echo "New task definition revision: $NEW\_REVISION"  
         \# ECSサービスを更新して、新しいタスク定義を適用  
         \- echo "Updating ECS service..."  
         \- aws ecs update-service \--cluster $ECS\_CLUSTER\_NAME \--service $ECS\_SERVICE\_NAME \--task-definition "$ECS\_TASK\_DEFINITION\_NAME:$NEW\_REVISION" \--force-new-deployment  
         \- echo "ECS service updated successfully."

---

## **ステップ2： コンテナイメージを保管するECRリポジトリの作成**

1. AWSマネジメントコンソールで **Amazon Elastic Container Registry (ECR)** に移動します。  
2. **リポジトリ** を選択し、**リポジトリを作成** をクリックします。  
3. **可視性設定** は **プライベート** のままでOKです。  
4. **リポジトリ名** に my-webapp-repo-github と入力します。  
5. 他はデフォルト設定のまま、**リポジトリを作成** をクリックします。

---

## **ステップ3： ECSクラスターとサービスの作成**

コンテナを動かすための基盤となるECSクラスターと、アプリケーションを実際に稼働させるサービスを作成します。このステップはCodeBuildで自動化する前の、初回の手動デプロイです。

### **1\. ECSクラスターの作成**

1. AWSマネジメントコンソールで **Amazon Elastic Container Service (ECS)** に移動します。  
2. 左側のメニューから **クラスター** を選択し、**クラスターの作成** をクリックします。  
3. **クラスター名** に my-cluster と入力します。  
4. **インフラストラクチャ** は **AWS Fargate** が選択されていることを確認します。  
5. 他はデフォルトのまま **作成** をクリックします。

### **2\. タスク定義の作成（初回）**

1. 左側のメニューから **タスク定義** を選択し、**新しいタスク定義の作成** をクリックします。  
2. **タスク定義ファミリー** に my-webapp-task と入力します。  
3. **インフラストラクチャ要件** のセクションはデフォルトのままにします。  
4. **コンテナの詳細** で以下のように設定します。  
   * **名前**: my-webapp-container  
   * **イメージ URI**: public.ecr.aws/nginx/nginx:latest (これは初回デプロイ用のダミーです。後でCodeBuildが更新します)  
   * **ポートマッピング**: **ポートを追加** をクリックし、80 を入力します。  
5. **次へ** をクリックし、確認画面で **作成** をクリックします。

### **3\. ECSサービスの作成**

1. 作成した my-cluster をクリックして、クラスターの詳細画面に移動します。  
2. **サービス** タブで **作成** をクリックします。  
3. **コンピューティングオプション** は **起動タイプ** を選択し、**FARGATE** を選択します。  
4. **デプロイ設定** で以下のように設定します。  
   * **ファミリー**: my-webapp-task (先ほど作成したタスク定義)  
   * **サービス名**: my-webapp-service  
   * **必要なタスク数**: 1  
5. **ネットワーキング** セクションで、ご自身のVPCとサブネットを選択します（通常はデフォルトで選択されています）。  
6. **パブリック IP の自動割り当て** を **オンにする** に設定します。  
7. 他はデフォルト設定のまま **作成** をクリックします。

サービスの作成が完了し、タスクのステータスが **RUNNING** になるまで数分待ちます。

---

## **ステップ4： CodeBuildプロジェクトの作成**

ソースコードのビルドからECSへのデプロイまでを実行するCodeBuildプロジェクトを作成します。

1. AWSマネジメントコンソールで **AWS CodeBuild** に移動します。  
2. **ビルドプロジェクトを作成する** をクリックします。  
3. **プロジェクト名** に ecs-webapp-build-from-github と入力します。  
4. **ソース** セクションで以下のように設定します。  
   * **ソースプロバイダ**: GitHub  
   * **GitHubとの接続**: **OAuth を使用して接続** を選択し、**GitHub に接続** ボタンをクリックします。ポップアップウィンドウが表示されたら、GitHubアカウントを認証・承認してください。  
   * **リポジトリ**: **自分のGitHubアカウントのリポジトリ** を選択します。  
   * **GitHub リポジトリ**: 先ほど作成した aws-ecs-handson リポジトリを選択します。  
5. **プライマリソースのウェブフックイベント**  
   * **ビルドを再構築…** のチェックボックスを **オン** にします。これにより、GitHubへのPushをトリガーに自動でビルドが実行されます。  
   * **イベントタイプ** は **PUSH** を選択します。  
6. **環境** セクションで以下のように設定します。  
   * **環境イメージ**: マネージド型イメージ  
   * **オペレーティングシステム**: Amazon Linux 2  
   * **ランタイム**: Standard  
   * **イメージ**: 最新のものを選択します。  
   * **特権付与**: **有効にする** にチェックを入れます。(Dockerイメージのビルドに必須です)  
   * **サービスロール**: **既存のサービスロール** を選択し、事前準備で作成した CodeBuildECSRoleForGitHub を選択します。  
7. **Buildspec** セクションは、**buildspec ファイルを使用する** が選択されていることを確認します。  
8. **アーティファクト** と **ログ** はデフォルトのままにします。  
9. **ビルドプロジェクトを作成する** をクリックします。

---

## **ステップ5： ビルドの実行と自動デプロイの確認**

### **1\. 手動での初回ビルド**

1. 作成した ecs-webapp-build-from-github プロジェクトの画面で、**ビルドを開始** をクリックします。  
2. ビルドが開始され、ビルドログがリアルタイムで表示されます。pre\_build, build, post\_build の各フェーズが成功することを確認してください。  
3. ビルドが成功したら、**Amazon ECS** のコンソールに戻ります。  
4. my-cluster \-\> my-webapp-service を選択し、**デプロイ** タブを確認します。新しいデプロイが進行中であることがわかります。  
5. **タスク** タブで、新しく **RUNNING** 状態になったタスクをクリックし、ネットワークセクションにある **パブリックIP** をコピーします。※Security GroupのインバウンドでHTTP Anywhereを許可  
6. ブラウザでコピーしたIPアドレスにアクセスします。

**Deployed from GitHub\!** と書かれた、index.html の内容が表示されれば成功です！🎉

### **2\. GitHubへのPushをトリガーにした自動デプロイ**

1. ご自身のGitHubリポジトリ (aws-ecs-handson) に戻ります。  
2. index.html ファイルを開き、編集（鉛筆アイコン）します。  
3. \<p\>Version 1.0\</p\> の行を \<p\>Version 2.0 \- Auto Deployed\!\</p\> に変更し、変更をコミットします。  
4. AWSマネジメントコンソールでCodeBuildプロジェクトのページに戻り、**ビルド履歴** を確認します。GitHubへのコミットをトリガーに、新しいビルドが自動的に開始されていることがわかります。  
5. ビルドが成功するのを待ちます。  
6. ビルド完了後、先ほどアクセスしたECSタスクのパブリックIPのページをリロードします。

**Version 2.0 \- Auto Deployed\!** と表示が更新されていれば、CI/CDパイプラインの完成です！

---

## **クリーンアップ**

ハンズオンで作成したリソースは料金が発生する可能性があるため、不要になったら以下の手順で削除してください。

1. **ECSサービス**: my-webapp-service を選択し、タスクの数を 0 に更新してからサービスを削除します。  
2. **ECSクラスター**: my-cluster を削除します。  
3. **ECRリポジトリ**: my-webapp-repo-github 内のイメージを削除してから、リポジトリ自体を削除します。  
4. **CodeBuildプロジェクト**: ecs-webapp-build-from-github を削除します。  
5. **タスク定義**: my-webapp-task のすべてのリビジョンを登録解除します。  
6. **IAMロール**: CodeBuildECSRoleForGitHub と ECSTaskExecutionRole を削除します。  
7. **CloudWatch Logs**: CodeBuildとECSが作成したロググループを削除します。  
8. **GitHub**: AWSとの連携設定の解除と、作成したリポジトリの削除を行ってください。