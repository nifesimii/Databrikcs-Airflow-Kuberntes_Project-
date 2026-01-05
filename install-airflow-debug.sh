#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

AIRFLOW_VERSION="3.0.2"
HELM_CHART_VERSION="1.18.0"
IMAGE_NAME="my-dags"
IMAGE_TAG=$(date +%Y%m%d%H%M%S)
POSTGRES_IMAGE="bitnamilegacy/postgresql:14.10.0"
NAMESPACE="airflow"
POSTGRES_PASSWORD="postgres"

echo -e "${BLUE}Starting Airflow Installation with Debug Mode${NC}\n"

# CLEANUP
echo -e "${YELLOW}━━━ STEP 1: Cleanup ━━━${NC}"
helm uninstall airflow -n ${NAMESPACE} 2>/dev/null || true
kubectl delete namespace ${NAMESPACE} --timeout=60s 2>/dev/null || true
kind delete cluster --name kind 2>/dev/null || true
kind create cluster --name kind --image kindest/node:v1.29.4
echo -e "${GREEN}✓ Clean environment${NC}\n"

# BUILD IMAGE
echo -e "${YELLOW}━━━ STEP 2: Build Airflow Image ━━━${NC}"
if [ ! -f "cicd/Dockerfile" ]; then
    echo -e "${RED}✗ cicd/Dockerfile not found!${NC}"
    exit 1
fi
docker build --pull --tag $IMAGE_NAME:$IMAGE_TAG -f cicd/Dockerfile .
kind load docker-image ${IMAGE_NAME}:${IMAGE_TAG} --name kind
echo -e "${GREEN}✓ Airflow image loaded: ${IMAGE_NAME}:${IMAGE_TAG}${NC}\n"

# LOAD POSTGRESQL
echo -e "${YELLOW}━━━ STEP 3: Load PostgreSQL ━━━${NC}"
docker pull ${POSTGRES_IMAGE}
kind load docker-image ${POSTGRES_IMAGE} --name kind
echo -e "${GREEN}✓ PostgreSQL loaded${NC}\n"

# VERIFY VALUES FILE
echo -e "${YELLOW}━━━ STEP 4: Verify Values File ━━━${NC}"
if [ ! -f "chart/values-override.yaml" ]; then
    echo -e "${RED}✗ chart/values-override.yaml not found!${NC}"
    echo "Creating default values-override.yaml..."
    mkdir -p chart
    cat > chart/values-override.yaml << 'VALUES'
migrateDatabaseJob:
  enabled: false
  useHelmHooks: false

executor: "KubernetesExecutor"

images:
  airflow:
    repository: my-dags
    tag: "REPLACE_WITH_TAG"
    pullPolicy: Never

scheduler:
  replicas: 1

triggerer:
  replicas: 1

workers:
  replicas: 0

redis:
  enabled: false

postgresql:
  enabled: true
  image:
    registry: docker.io
    repository: bitnamilegacy/postgresql
    tag: "14.10.0"
    pullPolicy: Never
  auth:
    enablePostgresUser: true
    postgresPassword: postgres
  primary:
    persistence:
      enabled: false

logs:
  persistence:
    enabled: false

dags:
  persistence:
    enabled: false

config:
  core:
    load_examples: 'False'
VALUES
fi

# Update image tag in values
sed -i.bak "s|tag: \".*\"|tag: \"${IMAGE_TAG}\"|g" chart/values-override.yaml

echo -e "${CYAN}Values file contents:${NC}"
head -20 chart/values-override.yaml
echo -e "${GREEN}✓ Values file verified${NC}\n"

# SETUP HELM
echo -e "${YELLOW}━━━ STEP 5: Setup Helm ━━━${NC}"
helm repo add apache-airflow https://airflow.apache.org 2>/dev/null || true
helm repo update
echo -e "${GREEN}✓ Helm ready${NC}\n"

# CREATE NAMESPACE
echo -e "${YELLOW}━━━ STEP 6: Create Namespace ━━━${NC}"
kubectl create namespace ${NAMESPACE}
echo -e "${GREEN}✓ Namespace created${NC}\n"

# INSTALL AIRFLOW (THE CRITICAL STEP)
echo -e "${YELLOW}━━━ STEP 7: Install Airflow (WITH DEBUGGING) ━━━${NC}"
echo -e "${CYAN}This will take 1-2 minutes...${NC}"
echo -e "${CYAN}Migration is DISABLED - will run manually in Step 9${NC}\n"

# Try helm install and capture output
if helm install airflow apache-airflow/airflow \
  --version ${HELM_CHART_VERSION} \
  --namespace ${NAMESPACE} \
  -f chart/values-override.yaml \
  --timeout 5m \
  --wait=false 2>&1 | tee helm-install.log; then
    echo -e "\n${GREEN}✓ Helm install command succeeded${NC}"
else
    echo -e "\n${RED}✗ Helm install failed!${NC}"
    echo -e "${YELLOW}Checking what was created:${NC}"
    kubectl get all -n ${NAMESPACE}
    echo -e "\n${YELLOW}Recent events:${NC}"
    kubectl get events -n ${NAMESPACE} --sort-by='.lastTimestamp' | tail -20
    exit 1
fi

# WAIT FOR POSTGRESQL
echo -e "\n${YELLOW}━━━ STEP 8: Wait for PostgreSQL ━━━${NC}"
echo -e "${CYAN}Waiting up to 5 minutes...${NC}"

if kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=postgresql \
  -n ${NAMESPACE} \
  --timeout=300s 2>/dev/null; then
    echo -e "${GREEN}✓ PostgreSQL ready${NC}"
else
    echo -e "${RED}✗ PostgreSQL not ready!${NC}"
    echo -e "${YELLOW}PostgreSQL pod status:${NC}"
    kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=postgresql
    kubectl describe pod -n ${NAMESPACE} -l app.kubernetes.io/name=postgresql
    exit 1
fi

# RUN MIGRATION
echo -e "\n${YELLOW}━━━ STEP 9: Run Migration ━━━${NC}"
kubectl delete pod -n ${NAMESPACE} airflow-migration 2>/dev/null || true

echo -e "${CYAN}Starting migration pod...${NC}"
kubectl run airflow-migration \
  --namespace=${NAMESPACE} \
  --image=${IMAGE_NAME}:${IMAGE_TAG} \
  --image-pull-policy=Never \
  --restart=Never \
  --env="AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://postgres:${POSTGRES_PASSWORD}@airflow-postgresql:5432/postgres" \
  --command -- airflow db migrate

echo -e "${CYAN}Waiting for migration (30 seconds)...${NC}"
sleep 30

echo -e "${CYAN}Migration logs:${NC}"
kubectl logs -n ${NAMESPACE} airflow-migration 2>/dev/null | tail -10

if kubectl logs -n ${NAMESPACE} airflow-migration 2>/dev/null | grep -q "Database migrating done"; then
    echo -e "${GREEN}✓ Migration completed successfully${NC}"
else
    echo -e "${YELLOW}⚠ Migration may still be running, check logs:${NC}"
    echo "kubectl logs -n ${NAMESPACE} airflow-migration -f"
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

# FIX INIT CONTAINER
echo -e "\n${YELLOW}━━━ STEP 11: Fix Init Container ━━━${NC}"
echo -e "${CYAN}Upgrading Helm release (this restarts pods)...${NC}"
helm upgrade airflow apache-airflow/airflow \
  --version ${HELM_CHART_VERSION} \
  --namespace ${NAMESPACE} \
  --reuse-values \
  --set migrateDatabaseJob.enabled=true \
  --set migrateDatabaseJob.useHelmHooks=false \
  --wait \
  --timeout 10m

echo -e "${GREEN}✓ Helm upgrade complete${NC}"

# WAIT FOR PODS
echo -e "\n${YELLOW}━━━ STEP 12: Wait for Components ━━━${NC}"
sleep 30

COMPONENTS=("scheduler" "api-server" "triggerer" "dag-processor")
for comp in "${COMPONENTS[@]}"; do
  echo -e "${CYAN}Checking ${comp}...${NC}"
  if kubectl wait --for=condition=ready pod \
    -l component=${comp} \
    -n ${NAMESPACE} \
    --timeout=300s 2>/dev/null; then
    echo -e "  ${GREEN}✓ ${comp} ready${NC}"
  else
    echo -e "  ${YELLOW}⚠ ${comp} not ready yet${NC}"
  fi
done

# FINAL STATUS
echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         ✅ AIRFLOW 3.0.2 INSTALLATION COMPLETE! ✅        ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"

echo -e "\n${BLUE}📊 FINAL POD STATUS:${NC}"
kubectl get pods -n ${NAMESPACE}

echo -e "\n${BLUE}📋 SERVICES:${NC}"
kubectl get svc -n ${NAMESPACE}

echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                  HOW TO ACCESS AIRFLOW                     ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"

echo -e "\n${MAGENTA}Step 1: Port Forward (NEW terminal)${NC}"
echo -e "   ${GREEN}kubectl port-forward -n airflow svc/airflow-api-server 8080:8080${NC}"

echo -e "\n${MAGENTA}Step 2: Open Browser${NC}"
echo -e "   ${GREEN}http://localhost:8080${NC}"

echo -e "\n${MAGENTA}Step 3: Login${NC}"
echo -e "   Username: ${GREEN}admin${NC}"
echo -e "   Password: ${GREEN}admin${NC}"

echo -e "\n${BLUE}📝 USEFUL COMMANDS:${NC}"
echo "   Check pods:     kubectl get pods -n airflow"
echo "   Scheduler logs: kubectl logs -n airflow -l component=scheduler -c scheduler -f"
echo "   List DAGs:      kubectl exec -n airflow deployment/airflow-scheduler -c scheduler -- airflow dags list"

echo -e "\n${GREEN}🎉 Happy orchestrating! 🎉${NC}"

