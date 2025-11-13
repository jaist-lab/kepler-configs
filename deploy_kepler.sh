#!/bin/bash
# deploy_kepler.sh
set -e

# ArgoCD 認証情報
ARGOCD_USER="admin"
ARGOCD_PASSWORD="jaileon02"

# 引数チェック
if [ $# -eq 0 ]; then
    echo "使用方法: $0 <cluster-name>"
    echo "例: $0 development"
    echo "    $0 production"
    echo "    $0 sandbox"
    exit 1
fi

CLUSTER_NAME=$1

# クラスタ設定
case $CLUSTER_NAME in
    development)
        export KUBECONFIG=/home/jaist-lab/.kube/config-development
        ARGOCD_SERVER="172.16.100.121:32443"
        VALUES_FILE="values-development.yaml"
        ;;
    production)
        export KUBECONFIG=/home/jaist-lab/.kube/config-production
        ARGOCD_SERVER="172.16.100.101:32443"
        VALUES_FILE="values-production.yaml"
        ;;
    sandbox)
        export KUBECONFIG=/home/jaist-lab/.kube/config-sandbox
        ARGOCD_SERVER="172.16.100.131:32443"
        VALUES_FILE="values-development.yaml"
        ;;
    *)
        echo "エラー: 未知のクラスタ名: $CLUSTER_NAME"
        exit 1
        ;;
esac

echo "=== Kepler デプロイ ==="
echo "対象クラスタ: $CLUSTER_NAME"
echo "Kubeconfig: $KUBECONFIG"
echo "ArgoCD サーバー: $ARGOCD_SERVER"
echo "Values ファイル: $VALUES_FILE"
echo ""

# ArgoCD にログイン
echo "ArgoCD にログイン中..."
argocd login $ARGOCD_SERVER \
  --username $ARGOCD_USER \
  --password $ARGOCD_PASSWORD \
  --insecure

if [ $? -ne 0 ]; then
    echo "✗ ArgoCD ログイン失敗"
    exit 1
fi
echo "✓ ログイン成功"

# monitoring namespace を作成
echo "monitoring namespace を作成中..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
echo "✓ namespace 作成完了"

# 既存の Application を確認
APP_NAME="kepler"

if argocd app get $APP_NAME --server $ARGOCD_SERVER > /dev/null 2>&1; then
    echo "既存の $APP_NAME Application が存在します"
    read -p "削除して再作成しますか? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Application を削除中..."
        argocd app delete $APP_NAME --yes --server $ARGOCD_SERVER
        
        # 削除が完了するまで待機
        echo "削除完了を待機中..."
        while true; do
            if ! argocd app get $APP_NAME --server $ARGOCD_SERVER > /dev/null 2>&1; then
                break
            fi
            echo -n "."
            sleep 2
        done
        echo ""
        echo "✓ 削除完了"
        sleep 5
    else
        echo "既存の Application を使用します"
        argocd app get $APP_NAME --server $ARGOCD_SERVER
        exit 0
    fi
fi

# Application を作成
echo "$APP_NAME Application を作成中..."
argocd app create $APP_NAME \
  --server $ARGOCD_SERVER \
  --repo https://github.com/jaist-lab/kepler.git \
  --path kepler \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace monitoring \
  --sync-policy automated \
  --auto-prune \
  --self-heal \
  --sync-option CreateNamespace=true \
  --helm-set-file values=$VALUES_FILE

if [ $? -eq 0 ]; then
    echo "✓ Application 作成完了"
else
    echo "✗ Application 作成失敗"
    exit 1
fi

# 自動同期が完了するのを待つ
echo "自動同期の完了を待機中..."
sleep 10

echo ""
echo "Application 状態:"
argocd app get $APP_NAME --server $ARGOCD_SERVER

echo ""
echo "=== デプロイ完了 ==="
echo ""
echo "確認コマンド:"
echo "  export KUBECONFIG=$KUBECONFIG"
echo "  kubectl get pods -n monitoring -l app.kubernetes.io/name=kepler"
echo "  kubectl logs -n monitoring -l app.kubernetes.io/name=kepler -f"
echo "  argocd app get $APP_NAME --server $ARGOCD_SERVER"
echo ""
echo "メトリクス確認:"
echo "  kubectl port-forward -n monitoring svc/kepler-exporter 9102:9102"
echo "  curl http://localhost:9102/metrics | grep kepler"
