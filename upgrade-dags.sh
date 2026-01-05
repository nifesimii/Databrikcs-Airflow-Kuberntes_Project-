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

IMAGE_NAME="my-dags"
IMAGE_TAG=$(date +%Y%m%d%H%M%S)
NAMESPACE="airflow"
HELM_CHART_VERSION="1.18.0"

clear
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              AIRFLOW - QUICK DAG UPGRADE                  ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if Airflow is installed
if ! kubectl get namespace ${NAMESPACE} &> /dev/null; then
    echo -e "${RED}❌ Airflow namespace not found!${NC}"
    echo -e "${YELLOW}Run ./install-airflow.sh first${NC}"
    exit 1
fi

# BUILD NEW IMAGE
echo -e "\n${YELLOW}━━━ STEP 1: Build New DAG Image ━━━${NC}"
docker build -t $IMAGE_NAME:$IMAGE_TAG -f cicd/Dockerfile . 
echo -e "${GREEN}✓ New image built: ${IMAGE_NAME}:${IMAGE_TAG}${NC}"

# LOAD IMAGE INTO KIND
echo -e "\n${YELLOW}━━━ STEP 2: Load Image into Kind ━━━${NC}"
kind load docker-image $IMAGE_NAME:$IMAGE_TAG --name kind
echo -e "${GREEN}✓ Image loaded into cluster${NC}"
# UPDATE VALUES FILE
echo -e "\n${YELLOW}━━━ STEP 3: Update Values File ━━━${NC}"



# Save image tag
echo $IMAGE_TAG > .airflow-image-tag

# UPGRADE HELM RELEASE
echo -e "\n${YELLOW}━━━ STEP 4: Upgrade Airflow Release ━━━${NC}"
helm upgrade airflow apache-airflow/airflow \
  --version ${HELM_CHART_VERSION} \
  --namespace ${NAMESPACE} \
  -f chart/values-override.yaml \
  --set migrateDatabaseJob.useHelmHooks=false \
  --set migrateDatabaseJob.enabled=false \
  --set createUserJob.useHelmHooks=false \
  --set scheduler.waitForMigrations.enabled=false \
  --set webserver.waitForMigrations.enabled=false \
  --set apiServer.waitForMigrations.enabled=false \
  --set triggerer.waitForMigrations.enabled=false \
  --set dagProcessor.waitForMigrations.enabled=false \
  --set workers.waitForMigrations.enabled=false \
  --reuse-values \
  --timeout 5m

echo -e "${GREEN}✓ Helm release upgraded${NC}"

# RESTART COMPONENTS
echo -e "\n${YELLOW}━━━ STEP 5: Restart Airflow Components ━━━${NC}"
COMPONENTS=("scheduler" "dag-processor" "triggerer")
for comp in "${COMPONENTS[@]}"; do
  echo -n "  Restarting ${comp}..."
  kubectl rollout restart deployment/airflow-${comp} -n ${NAMESPACE} 2>/dev/null || true
  echo -e " ${GREEN}✓${NC}"
done

# WAIT FOR ROLLOUT
echo -e "\n${YELLOW}━━━ STEP 6: Wait for Rollout ━━━${NC}"
for comp in "${COMPONENTS[@]}"; do
  echo -n "  ${comp}..."
  if kubectl rollout status deployment/airflow-${comp} -n ${NAMESPACE} --timeout=120s 2>/dev/null; then
    echo -e " ${GREEN}✓${NC}"
  else
    echo -e " ${YELLOW}⚠${NC}"
  fi
done

# CLEANUP FAILED PODS
echo -e "\n${YELLOW}━━━ STEP 7: Cleanup Failed Pods ━━━${NC}"
kubectl delete pod -n ${NAMESPACE} --field-selector=status.phase=Failed 2>/dev/null || true
kubectl delete pod -n ${NAMESPACE} --field-selector=status.phase=Error 2>/dev/null || true
echo -e "${GREEN}✓ Cleanup complete${NC}"

# FINAL STATUS
echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              ✅ DAGS UPGRADED SUCCESSFULLY! ✅            ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"

echo -e "\n${BLUE}📊 POD STATUS:${NC}"
kubectl get pods -n airflow

echo -e "\n${CYAN}New Image Tag: ${GREEN}${IMAGE_TAG}${NC}"

echo -e "\n${BLUE}📝 NEXT STEPS:${NC}"
echo "   1. Check DAGs: kubectl exec -n airflow deploy/airflow-scheduler -c scheduler -- airflow dags list"
echo "   2. Trigger DAG: kubectl exec -n airflow deploy/airflow-scheduler -c scheduler -- airflow dags trigger YOUR_DAG_ID"
echo "   3. View Logs:   kubectl logs -n airflow -l component=scheduler -c scheduler -f"

echo -e "\n${GREEN}🎉 Your DAGs are live! 🎉${NC}"
