#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
RED='\033[0;31m'
NC='\033[0m'

AIRFLOW_VERSION="3.0.2"
HELM_CHART_VERSION="1.18.0"
IMAGE_NAME="my-dags"
IMAGE_TAG=$(date +%Y%m%d%H%M%S)
POSTGRES_IMAGE="bitnamilegacy/postgresql:14.10.0"
NAMESPACE="airflow"
POSTGRES_PASSWORD="postgres"

clear
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         AIRFLOW 3.0.2 - PRODUCTION-READY INSTALLER        ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
read -p "Press Enter to continue..."

# CLEANUP
echo -e "\n${YELLOW}━━━ STEP 1: Cleanup ━━━${NC}"
helm uninstall airflow -n ${NAMESPACE} 2>/dev/null || true
kubectl delete namespace ${NAMESPACE} 2>/dev/null || true
kind delete cluster --name kind 2>/dev/null || true
kind create cluster --name kind --image kindest/node:v1.29.4 --config k8s/clusters/kind-clusters.yaml
echo -e "${GREEN}✓ Clean environment${NC}"

# BUILD IMAGE
echo -e "\n${YELLOW}━━━ STEP 2: Build Airflow Image ━━━${NC}"
docker build -t $IMAGE_NAME:$IMAGE_TAG -f cicd/Dockerfile . 
kind load docker-image $IMAGE_NAME:$IMAGE_TAG --name kind
echo -e "${GREEN}✓ Airflow image: ${IMAGE_NAME}:${IMAGE_TAG}${NC}"

# Save image tag for upgrade script
echo $IMAGE_TAG > .airflow-image-tag
echo -e "${CYAN}  Saved image tag to .airflow-image-tag${NC}"

# UPDATE VALUES FILE
echo -e "\n${YELLOW}━━━ STEP 3: Update Airflow Image Tag ━━━${NC}"
# Only update the Airflow image tag (first occurrence under 'images:' section)
# This avoids changing the PostgreSQL tag later in the file
sed -i.bak "/images:/,/scheduler:/ s/tag: \"[^\"]*\"/tag: \"${IMAGE_TAG}\"/" chart/values-override-with-persistence.yaml

# Verify the update worked
UPDATED_TAG=$(grep -A 5 "images:" chart/values-override-with-persistence.yaml | grep "tag:" | head -1 | sed 's/.*"\(.*\)".*/\1/')
if [ "$UPDATED_TAG" = "$IMAGE_TAG" ]; then
    echo "  Airflow image tag: ${IMAGE_TAG}"
    echo -e "${GREEN}✓ Values file updated (Airflow only, PostgreSQL unchanged)${NC}"
else
    echo -e "${RED}❌ Failed to update Airflow image tag${NC}"
    exit 1
fi

# LOAD POSTGRESQL
echo -e "\n${YELLOW}━━━ STEP 4: Load PostgreSQL ━━━${NC}"
docker pull ${POSTGRES_IMAGE} 
kind load docker-image ${POSTGRES_IMAGE} --name kind
echo -e "${GREEN}✓ PostgreSQL loaded${NC}"

# SETUP HELM
echo -e "\n${YELLOW}━━━ STEP 5: Setup Helm ━━━${NC}"
helm repo add apache-airflow https://airflow.apache.org 2>/dev/null || true
helm repo update > /dev/null 2>&1
echo -e "${GREEN}✓ Helm ready${NC}"

# CREATE NAMESPACE
echo -e "\n${YELLOW}━━━ STEP 6: Create Namespace ━━━${NC}"
kubectl create namespace ${NAMESPACE}
echo -e "${GREEN}✓ Namespace created${NC}"


#Apply kubernetes secrets
kubectl apply -f k8s/secrets/git-secrets.yaml

#Apply kubernetes persistent volume
kubectl apply -f k8s/volumes/airflow-logs-pv.yaml

#Apply kubernetes persistent volume claim
kubectl apply -f k8s/volumes/airflow-logs-pvc.yaml


# INSTALL AIRFLOW
echo -e "\n${YELLOW}━━━ STEP 7: Install Airflow ━━━${NC}"
helm install airflow apache-airflow/airflow \
  --version ${HELM_CHART_VERSION} \
  --namespace ${NAMESPACE} \
  -f chart/values-override-with-persistence.yaml \
  --set migrateDatabaseJob.useHelmHooks=false \
  --set migrateDatabaseJob.enabled=false \
  --set createUserJob.useHelmHooks=false \
  --set scheduler.waitForMigrations.enabled=false \
  --set webserver.waitForMigrations.enabled=false \
  --set apiServer.waitForMigrations.enabled=false \
  --set triggerer.waitForMigrations.enabled=false \
  --set dagProcessor.waitForMigrations.enabled=false \
  --set workers.waitForMigrations.enabled=false \
  --set dags.gitSync.ref=master \
  --timeout 5m

echo -e "${GREEN}✓ Helm chart installed${NC}"

# WAIT FOR POSTGRESQL
echo -e "\n${YELLOW}━━━ STEP 8: Wait for PostgreSQL ━━━${NC}"
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=postgresql \
  -n ${NAMESPACE} \
  --timeout=300s
echo -e "${GREEN}✓ PostgreSQL ready${NC}"

# RUN MIGRATION
echo -e "\n${YELLOW}━━━ STEP 9: Run Database Migration ━━━${NC}"
kubectl delete pod -n ${NAMESPACE} airflow-migration 2>/dev/null || true
kubectl run airflow-migration \
  --namespace=${NAMESPACE} \
  --image=${IMAGE_NAME}:${IMAGE_TAG} \
  --image-pull-policy=Never \
  --restart=Never \
  --env="AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://postgres:${POSTGRES_PASSWORD}@airflow-postgresql:5432/postgres" \
  --command -- airflow db migrate

echo "  Waiting for migration..."
sleep 30

if kubectl logs -n ${NAMESPACE} airflow-migration 2>/dev/null | grep -q "Database migrating done"; then
    echo -e "${GREEN}✓ Database migration successful${NC}"
else
    echo -e "${YELLOW}⚠ Checking migration logs...${NC}"
    kubectl logs -n ${NAMESPACE} airflow-migration 2>&1 | tail -10
fi

# CREATE SESSION TABLE
echo -e "\n${YELLOW}━━━ STEP 10: Create Session Table ━━━${NC}"
kubectl exec -n ${NAMESPACE} airflow-postgresql-0 -- \
  env PGPASSWORD=${POSTGRES_PASSWORD} psql -U postgres -d postgres -c "
CREATE TABLE IF NOT EXISTS session (
    id SERIAL PRIMARY KEY,
    session_id VARCHAR(255) UNIQUE NOT NULL,
    data BYTEA,
    expiry TIMESTAMP
);
" > /dev/null 2>&1
echo -e "${GREEN}✓ Session table created${NC}"


# Force pod retention settings
echo -e "\n${YELLOW}━━━   STEP 11: Configuring Pod Retention  ━━━${NC}"
kubectl set env deployment/airflow-scheduler -n ${NAMESPACE} \
  AIRFLOW__KUBERNETES_EXECUTOR__DELETE_WORKER_PODS=False \
  AIRFLOW__KUBERNETES_EXECUTOR__DELETE_WORKER_PODS_ON_FAILURE=False

kubectl rollout status deployment/airflow-scheduler -n ${NAMESPACE}
echo -e "${GREEN}✓ Pod retention configured${NC}"

# Verify
echo -e "\n${YELLOW}━━━  STEP 12: Verifying Configuration ━━━${NC}"
sleep 5
DELETE_PODS=$(kubectl exec -n airflow deploy/airflow-scheduler -c scheduler -- \
  airflow config get-value kubernetes_executor delete_worker_pods 2>/dev/null)
echo "  delete_worker_pods: ${DELETE_PODS}"


# WAIT FOR COMPONENTS
echo -e "\n${YELLOW}━━━ STEP 13: Wait for Airflow Components ━━━${NC}"
sleep 60


COMPONENTS=("scheduler" "api-server" "triggerer" "dag-processor")
for comp in "${COMPONENTS[@]}"; do
  echo -n "  ${comp}..."
  if kubectl wait --for=condition=ready pod -l component=${comp} -n ${NAMESPACE} --timeout=180s 2>/dev/null; then
    echo -e " ${GREEN}✓${NC}"
  else
    echo -e " ${YELLOW}⚠${NC}"
  fi
done

# CLEANUP FAILED PODS
echo -e "\n${YELLOW}━━━ STEP 14: Cleanup Failed Pods ━━━${NC}"
kubectl delete pod -n ${NAMESPACE} --field-selector=status.phase=Failed 2>/dev/null || true
kubectl delete pod -n ${NAMESPACE} --field-selector=status.phase=Error 2>/dev/null || true
echo -e "${GREEN}✓ Cleanup complete${NC}"

# FINAL STATUS
echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              ✅ AIRFLOW 3.0.2 DEPLOYED! ✅                ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"

echo -e "\n${BLUE}📊 POD STATUS:${NC}"
kubectl get pods -n airflow

echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                  ACCESS AIRFLOW                            ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"

echo -e "\n${MAGENTA}1. Port Forward:${NC}"
echo -e "   ${GREEN}kubectl port-forward -n airflow svc/airflow-api-server 8080:8080${NC}"

echo -e "\n${MAGENTA}2. Browser:${NC} ${GREEN}http://localhost:8080${NC}"
echo -e "${MAGENTA}3. Login:${NC} ${GREEN}admin${NC} / ${GREEN}admin${NC}"
echo -e "\n${BLUE}📝 USEFUL COMMANDS:${NC}"
echo "   AWS Conn: kubectl exec -n airflow deploy/airflow-scheduler -c scheduler -- airflow connections add aws_conn --conn-type aws --conn-extra '{\"region_name\":\"us-east-1\"}'"
echo "   Trigger:  kubectl exec -n airflow deploy/airflow-scheduler -c scheduler -- airflow dags trigger produce_data_asset"
echo "   Logs:     kubectl logs -n airflow -l component=scheduler -c scheduler -f"

echo -e "\n${YELLOW}💡 TIP: Use ./upgrade-dags.sh to quickly rebuild and deploy DAG changes${NC}"
echo -e "\n${GREEN}🎉 Happy orchestrating! 🎉${NC}"