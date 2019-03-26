# 本リポジトリについて

OpenID Connect Provider のOSS実装である、[hydra](https://github.com/ory/hydra) の検証のため、 ローカル環境のk8sにhydraをセットアップする  

## hydraの特徴

- [Certified OpenID Connect Implementations](https://openid.net/developers/certified/) になっている。 
  - kubernetes、istio との連携も可能

- 独自のユーザ管理、ユーザ認証ロジックを採用できる。
  - OpenID Connectフローの実装を任すことで、ユーザ認証のロジックを分離できる。
  - JWT発行時に任意のclaimを設定できる。

- 発行したアクセストークン、リフレッシュトークンを管理するストレージとして、MySQLとPostgreSQLを使うことができる。  

## セットアップ

### 前提

- docker for mac or minikubeなど、ローカル環境でk8s環境が構築されていること  
- [kustomize](https://github.com/kubernetes-sigs/kustomize) がインストールされていること  

### namespaceの作成

```bash
kubectl create ns hydra
```

### PostgreSQLのセットアップ

```bash
cd k8s/hydra/postgres

# persistent volume の hostPathの修正
vi base/pvc.postgres.yaml
---
  hostPath:
    # TODO modified
    path: "<need modified>" # ここを変更(ホスト側で予めディレクトリ作成しておく)
---
./build.sh
kubectl apply -f generated/hydra-postgres-local.all.yaml

# connect to postgres port 30432 from host
psql -U hydra -h localhost -p 30432
```

### nginx-ingress-controllerのセットアップ

```bash
# namespace 作成
kubectl create ns nginx-ingress
# secret 作成
cd k8s/hydra/nginx-ingress-controller
kubectl create secret tls tls-certificate --key server.key --cert server.crt -n nginx-ingress
kubectl create secret generic tls-dhparam --from-file=dhparam.pem -n nginx-ingress
# setup
./build.sh
kubectl apply -f generated/nginx-ingress-controller.local.all.yaml
```

### hydra DB マイグレーション

```bash
cd k8s/hydra/hydra/binary
export DATABASE_URL="postgres://hydra:secret@localhost:30432/hydra?sslmode=disable"
./hydra-darwin-amd64 migrate sql $DATABASE_URL
```

※ mac以外の環境の場合はhydraのバイナリをビルド(要Go1.11以上)して、それを実行する  
以下ビルド手順  

```bash
go get -d -u github.com/ory/hydra
cd $(go env GOPATH)/src/github.com/ory/hydra
HYDRA_LATEST=$(git describe --abbrev=0 --tags)
git checkout $HYDRA_LATEST
GO111MODULE=on go install \
    -ldflags "-X github.com/ory/hydra/cmd.Version=$HYDRA_LATEST -X github.com/ory/hydra/cmd.BuildTime=`TZ=UTC date -u '+%Y-%m-%dT%H:%M:%SZ'` -X github.com/ory/hydra/cmd.GitHash=`git rev-parse HEAD`" \
    github.com/ory/hydra
git checkout master
# 確認
$GOPATH/bin/hydra help
```

### hydraのセットアップ

```bash
cd k8s/hydra/hydra
./build.sh
kubectl apply -f generated/hydra.local.all.yaml
```

### API call

/etc/hosts に以下を追記する

```bash
127.0.0.1 hydra-public-api.synergy-example.com
127.0.0.1 hydra-admin-api.synergy-example.com
```

```bash
# call public api(jwks_url)
curl -k https://hydra-public-api.synergy-example.com:30443/.well-known/jwks.json
# call admin api(get oidc client list)
curl -k https://hydra-admin-api.synergy-example.com:30443/clients
```

## OpenID Connect(Authorization Code flow) を試す

### OpenID Connect client の作成

```bash
cd k8s/hydra/hydra/binary
./hydra-darwin-amd64 clients create \
    --skip-tls-verify --endpoint https://hydra-admin-api.synergy-example.com:30443 \
    --id test-client \
    --secret test-secret \
    --response-types code,id_token \
    --grant-types refresh_token,authorization_code \
    --scope openid,offline \
    --callbacks http://localhost:4446/callback
```

間違ってClient作成した場合は、以下のようにして削除  

```bash
./hydra-darwin-amd64 clients delete test-client \
    --skip-tls-verify --endpoint https://hydra-admin-api.synergy-example.com:30443
```

### ログインプロバイダの起動

exampleとして、[hydra-login-consent-node](https://github.com/ory/hydra-login-consent-node)を使う（要npm）

```bash
cd k8s/login-provider/hydra-login-consent-node
npm i
# 自己署名証明書を使っているので、NODE_TLS_REJECT_UNAUTHORIZED=0をつけて起動
NODE_TLS_REJECT_UNAUTHORIZED=0 HYDRA_ADMIN_URL=https://hydra-admin-api.synergy-example.com:30443 npm start
```

### RP起動

hydraにはテストのためのヘルパーコマンド hydra token user があり、  
このコマンドは、hydraへのリダイレクトURLを生成し、認証完了のコールバックを受け取るWebサーバを立ち上げる。  

```bash
cd k8s/hydra/hydra/binary
./hydra-darwin-amd64 token user \
    --skip-tls-verify --token-url https://hydra-public-api.synergy-example.com:30443/oauth2/token \
    --auth-url https://hydra-public-api.synergy-example.com:30443/oauth2/auth \
    --scope openid,offline \
    --client-id test-client \
    --client-secret test-secret \
    --redirect http://localhost:4446/callback
Setting up home route on http://127.0.0.1:4446/
Setting up callback listener on http://127.0.0.1:4446/callback
Press ctrl + c on Linux / Windows or cmd + c on OSX to end the process.
If your browser does not open automatically, navigate to:

	http://127.0.0.1:4446/
```

### ブラウザへのアクセス

http://localhost:4446/ にブラウザからアクセスして、以下の画面が表示される  

![RP](images/rp.png)

「Authorize」のリンクをクリックすると、  
[hydra auth url](https://www.ory.sh/docs/hydra/sdk/api#the-oauth-20-authorize-endpoint) --> hydra-login-consent-node のログイン画面(localhost:3000/login)にリダイレクトされる  

![Login](images/login.png)

ログイン成功すると、  
[hydra login accept](https://www.ory.sh/docs/hydra/sdk/api#accept-an-login-request) --> hydra-login-consent-node の同意画面(localhost:3000/consent)にリダイレクトされる   


![Consent](images/consent.png)

同意すると、各種トークンが発行されます。  

![Token](images/token.png)

jwt.ioでid_tokenをデコードしてみると、header、payloadの中身を見ることができます。  

```header
{
  "alg": "RS256",
  "kid": "public:40557f34-cddc-4f22-bf7b-3eb89bd8ff11",
  "typ": "JWT"
}
```

```payload
{
  "at_hash": "IynRuB7C5UrBH3juxLueOg",
  "aud": [
    "test-client"
  ],
  "auth_time": 1552620618,
  "exp": 1552624596,
  "groups": [
    "foo",
    "bar"
  ],
  "iat": 1552620996,
  "iss": "https://hydra-public-api.synergy-example.com:30443/",
  "jti": "3fe11e9f-3ab2-4e5b-a739-2a47fd9547bb",
  "nonce": "umlyrcshrnkcpjlkrpksellk",
  "rat": 1552620612,
  "sub": "foo@bar.com"
}
```

## mysql を使う場合

### mysql setup

```bash
cd k8s/hydra/mysql
./build.sh
kubectl apply -f secret.mysql.yaml
kubectl apply -f generated/hydra-mysql.local.all.yaml
```

### mysql migration

```bash
cd k8s/hydra/hydra/binary
export DATABASE_URL="mysql://root:password@tcp(127.0.0.1:30306)/mysql?parseTime=true"
./hydra-darwin-amd64 migrate sql $DATABASE_URL
```

### hydra configuration

```bash
cd k8s/hydra/hydra
vi base/deployment.hydra.yaml
---
  #- name: DATABASE_URL
  #  value: postgres://hydra:secret@postgres:5432/hydra?sslmode=disable
  - name: DATABASE_URL
    value: mysql://root:password@tcp(mysql:3306)/mysql?parseTime=true
---

./build.sh
kubectl apply -f generated/hydra.local.all.yaml
```

## k8s との連携

kubernetes（kube-apiserver) の認証はOpenID Connectに対応しており、[RBAC(Role Based Access Control)](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)を設定することでグループによるアクセス制御が可能  

OpenID Connectによる認証・認可に対応するために、kube-apiserver起動時にいくつかのパラメータを指定して起動する必要がある  

| パラメータ名 | 指定する内容 | 
|:-----------|:------------|
| --oidc-issuer-url       | IDトークンのiss ※ https必須      |
| --oidc-client-id     | Relying Partyのclient_id      |
| --oidc-groups-claim       | RBACのGroupとして扱うclaimのキー        |
| --oidc-ca-file       | IdPのサーバ証明書に署名したCA証明書        |

docker for mac の場合、kube-apiserver は Moby VM 上でコンテナとして動作しているので、  
[こちらの方法](https://gist.github.com/BretFisher/5e1a0c7bcca4c735e716abf62afad389)で、Docker for Mac の tty に接続して、  
`/etc/kubernetes/manifests/kube-apiserver.yaml` を直接編集した後に kubernetes を再起動する   

```yaml
(中略)
spec:
  containers:
  - command:
    - kube-apiserver
    - --authorization-mode=Node,RBAC
    (中略)
    - --oidc-issuer-url=https://hydra-public-api.synergy-example.com:30443/
    - --oidc-client-id=test-client
    - --oidc-groups-claim=groups
    - --oidc-ca-file=/path/to/cafile
(中略)
    - mountPath: /usr/share/ca-certificates
      name: usr-share-ca-certificates
      readOnly: true
    # 追記
    - mountPath: /path/to/cafile
      name: oidc-ca-certificates
      readOnly: true
  hostNetwork: true
(中略)
  - hostPath:
      path: /usr/share/ca-certificates
      type: DirectoryOrCreate
    name: usr-share-ca-certificates
  # 追記
  - hostPath:
      path: /path/to/cafile
      type: DirectoryOrCreate
    name: oidc-ca-certificates
status: {}
```

発行したIDトークンをkubernetesに登録  

```
kubectl config set-credentials synergy-admin --token=[YOUR ID TOKEN]
kubectl config set-context oidc-example --cluster=docker-desktop --user=synergy-admin
```

RoleとRoleBindingを登録 登録内容としては namespace が kube-system の pod に対する get/watch/list の操作を許可する内容となる

```
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: test-role
  namespace: kube-system
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "watch", "list"]
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: test-rolebinding
  namespace: kube-system
subjects:
- kind: Group
  name: foo # Name is case sensitive
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role #this must be Role or ClusterRole
  name: test-role # this must match the name of the Role or ClusterRole you wish to bind to
  apiGroup: rbac.authorization.k8s.io
```

実際に試してみると、namespace未指定の場合は pod の情報取得ができないが、kube-system を指定した場合は  pod の情報取得ができるようになる  

```
$ kubectl config use-context oidc-example
$ kubectl get pods
Error from server (Forbidden): pods is forbidden: User "https://hydra-public-api.synergy-example.com:30443/#foo@bar.com" cannot list resource "pods" in API group "" in the namespace "default"
$ kubectl get pod -n kube-system
NAME                                     READY   STATUS    RESTARTS   AGE
coredns-86c58d9df4-9sdb9                 1/1     Running   7          66d
coredns-86c58d9df4-f288f                 1/1     Running   7          66d
etcd-docker-desktop                      1/1     Running   25         66d
kube-apiserver-docker-desktop            1/1     Running   0          2m45s
kube-controller-manager-docker-desktop   1/1     Running   82         66d
kube-proxy-nswq7                         1/1     Running   7          66d
kube-scheduler-docker-desktop            1/1     Running   75         66d
tiller-deploy-dbb85cb99-bjrnr            1/1     Running   7          3d8h
```

## istio との連携

[istio](https://istio.io/) はマイクロサービスのサービスメッシュを実現するオープンソースプロジェクト  

OpenID Connectによる認証・認可についても、各pod で個別で行なうのは大きなコストになってしまうため、  
istio によってコードに手を入れずにユーザの権限に応じて認証・認可をできるようになる  

サンプルを実行する際の注意点が2点ある  

- 自己署名証明書のJWKsエンドポイントにアクセスできない
istio の pilot が JWKsエンドポイントにアクセスする際、自己署名証明書を使ったURLだとinvalid扱いとなり認証できない。  
hydraはhttpのissuerで起動して、IDトークンを発行すること。  

```
cd k8s/hydra/hydra/base
vi deployment.hydra.yaml

---
            # for kube-apiserver sample(kubeapi-server はhttpsでアクセスしないとJWT検証できない。httpはNG)
            #- name: OAUTH2_ISSUER_URL
            #  value: https://hydra-public-api.synergy-example.com:30443
            # for istio authentication sample (istio は自己署名証明書のサーバにhttpsアクセスしてJWT検証できない. httpは可能)
             - name: OAUTH2_ISSUER_URL
               value: http://hydra-public-api.synergy-example.com:30080
---
cd ../../
./build.sh
kubectl apply -f generated
```

- JWKsエンドポイントが 127.0.0.1 だとアクセスできない

/etc/hosts の 以下の設定により、`hydra-public-api.synergy-example.com` を 127.0.0.1 と認識してしまい、pilot からJWKsエンドポイントにアクセスできない

```bash
127.0.0.1 hydra-public-api.synergy-example.com
127.0.0.1 hydra-admin-api.synergy-example.com
```

ホストにつなぐためには、host.docker.internal のDNS名で引けるIPでないといけないため、/etc/hostsを変更する

```bash
kubectl exec -it [pod] /bin/sh

> ping host.docker.internal
PING host.docker.internal (192.168.65.2) 56(84) bytes of data.

> exit

vi /etc/hosts

---
192.168.65.2 hydra-public-api.synergy-example.com
192.168.65.2 hydra-admin-api.synergy-example.com
---
```

istio のインストールは以下の手順で実施する

```
# helm install
$ brew install kubernetes-helm

$ NAMESPACE=istio-system
$ kubectl create ns $NAMESPACE

$ helm repo add istio.io https://storage.googleapis.com/istio-prerelease/daily-build/master-latest-daily/charts

$ cd k8s/rbac-test/istio

$ kubectl apply -f install/kubernetes/helm/helm-service-account.yaml

$ helm install install/kubernetes/helm/istio-init --name istio-init --namespace $NAMESPACE
$ helm install install/kubernetes/helm/istio --name istio --namespace $NAMESPACE
# 何故か必要なCRDがインストールされずに起動できない事象があるため、個別でCRDをインストール
# https://github.com/istio/istio/issues/12535
$ kubectl apply -f install/kubernetes/helm/istio-init/files/crd-12.yaml
```

httpbinサービス登録

```
cd k8s/rbac-test/istio
kubectl apply -f httpbin/
```

アクセスできるか確認

```
curl -i http://localhost/status/200
HTTP/1.1 200 OK が返ること
```

authentication policy登録

```
cd k8s/rbac-test/istio
kubectl apply -f authentication/
```

アクセス確認

```
curl -i http://localhost/status/200
HTTP/1.1 401 Unauthorized が返ること

curl -i -H 'Authentication: Bearer <token>' http://localhost/status/200
HTTP/1.1 200 OK が返ること
```

authorization policy登録

```
cd k8s/rbac-test/istio
kubectl apply -f authorization/
```

アクセス確認

```
curl -i http://localhost/status/200
HTTP/1.1 401 Unauthorized が返ること

curl -i -H 'Authentication: Bearer <token>' http://localhost/status/200
HTTP/1.1
HTTP/1.1 200 OK が返ること
```