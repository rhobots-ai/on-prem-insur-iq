#!/bin/bash
# Create a local Kubernetes cluster with kind for development

set -e

CLUSTER_NAME="insur-iq"
K8S_VERSION="1.28"  # Stable version

echo "🔧 Creating kind cluster: $CLUSTER_NAME"
echo ""

# Check if kind is installed
if ! command -v kind &> /dev/null; then
    echo "❌ kind is not installed"
    echo "Install with: brew install kind"
    exit 1
fi

# Check if cluster already exists
if kind get clusters | grep -q "^$CLUSTER_NAME$"; then
    echo "⚠️  Cluster '$CLUSTER_NAME' already exists"
    read -p "Delete and recreate? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kind delete cluster --name "$CLUSTER_NAME"
        echo "✓ Deleted existing cluster"
    else
        echo "Using existing cluster"
        kubectl cluster-info --context kind-$CLUSTER_NAME
        exit 0
    fi
fi

# Create cluster with port mappings for ingress
cat > /tmp/kind-config.yaml << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $CLUSTER_NAME
nodes:
- role: control-plane
  image: kindest/node:v${K8S_VERSION}.0
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
  - containerPort: 5432
    hostPort: 5432
    protocol: TCP
  - containerPort: 6379
    hostPort: 6379
    protocol: TCP
  - containerPort: 9000
    hostPort: 9000
    protocol: TCP
  - containerPort: 9001
    hostPort: 9001
    protocol: TCP
EOF

echo "Creating cluster with config:"
cat /tmp/kind-config.yaml
echo ""

kind create cluster --config /tmp/kind-config.yaml

echo ""
echo "✅ Cluster created: $CLUSTER_NAME"
echo ""
echo "Next steps:"
echo ""
echo "1. Install nginx-ingress controller:"
echo "   kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/kind/deploy.yaml"
echo ""
echo "2. Wait for ingress controller:"
echo "   kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=90s"
echo ""
echo "3. Deploy insur-iq:"
echo "   ./scripts/helm-quick-deploy.sh dev"
echo ""
echo "Useful commands:"
echo "  kubectl cluster-info --context kind-$CLUSTER_NAME"
echo "  kind delete cluster --name $CLUSTER_NAME"
echo "  kubectl get pods --all-namespaces"
