#!/bin/bash
set -e

echo "🔥 COMPLETE CLEANUP - Removing ALL caches and resources"
echo "========================================================"

# Step 1: Uninstall Helm release
echo ""
echo "1️⃣  Removing Helm release..."
helm uninstall airflow -n airflow 2>/dev/null || echo "   No release to uninstall"

# Step 2: Delete namespace
echo ""
echo "2️⃣  Deleting Kubernetes namespace..."
kubectl delete namespace airflow --force --grace-period=0 2>/dev/null || echo "   No namespace to delete"

# Step 3: Delete Kind cluster completely
echo ""
echo "3️⃣  Destroying Kind cluster..."
kind delete cluster --name kind 2>/dev/null || echo "   No cluster to delete"

# Step 4: Clean Helm cache
echo ""
echo "4️⃣  Cleaning Helm cache..."
rm -rf ~/.cache/helm 2>/dev/null || true
rm -rf ~/.config/helm 2>/dev/null || true
helm repo remove apache-airflow 2>/dev/null || true
echo "   ✓ Helm cache cleared"

# Step 5: Clean Docker build cache
echo ""
echo "5️⃣  Cleaning Docker build cache..."
docker builder prune -af
echo "   ✓ Docker build cache cleared"

# Step 6: Remove old images
echo ""
echo "6️⃣  Removing old Airflow images..."
docker rmi my-dags:0.0.1 2>/dev/null || echo "   No my-dags image to remove"
docker images | grep "bitnami.*postgresql" | awk '{print $3}' | xargs -r docker rmi -f 2>/dev/null || true
docker images | grep "apache/airflow" | awk '{print $3}' | xargs -r docker rmi -f 2>/dev/null || true
echo "   ✓ Old images removed"

# Step 7: Clean dangling images and volumes
echo ""
echo "7️⃣  Cleaning dangling Docker resources..."
docker system prune -af --volumes
echo "   ✓ Docker system cleaned"

# Step 8: Remove any leftover kubectl configs
echo ""
echo "8️⃣  Cleaning kubectl context..."
kubectl config delete-context kind-kind 2>/dev/null || echo "   No context to delete"
kubectl config delete-cluster kind-kind 2>/dev/null || echo "   No cluster config to delete"

# Step 9: Clean temporary files
echo ""
echo "9️⃣  Cleaning temporary files..."
rm -rf /tmp/airflow-* 2>/dev/null || true
rm -rf /tmp/helm-* 2>/dev/null || true
echo "   ✓ Temporary files cleaned"

echo ""
echo "✅ COMPLETE CLEANUP FINISHED!"
echo ""
echo "Next step: Run ./fresh-install.sh"

