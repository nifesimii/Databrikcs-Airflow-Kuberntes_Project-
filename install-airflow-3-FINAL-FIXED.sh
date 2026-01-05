#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

AIRFLOW_VERSION="3.0.2"
HELM_CHART_VERSION="1.18.0"
IMAGE_NAME="my-dags"
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
kind create cluster --name kind --image kindest/node:v1.29.4
echo -e "${GREEN}✓ Clean environment${NC}"

# BUILD IMAGE
echo -e "\n${YELLOW}━━━ STEP 2: Build Airflow Image ━━━${NC}"
mkdir -p dags
cat > dags/example.py << 'DAG'
from datetime import datetime
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator

def process_data(**context):
    import random
    data = [random.randint(1, 100) for _ in range(10)]
    print(f"Data: {data}, Sum: {sum(data)}")
    return sum(data)

default_args = {'owner': 'airflow', 'start_date': datetime(2024, 1, 1)}

with DAG('example_pipeline', default_args=default_args, schedule='@daily', catchup=False, tags=['example']) as dag:
    start = BashOperator(task_id='start', bash_command='echo "Starting pipeline..."')
    process = PythonOperator(task_id='process', python_callable=process_data)
    end = BashOperator(task_id='end', bash_command='echo "Pipeline complete!"')
    start >> process >> end

with DAG('hello', default_args=default_args, schedule='@hourly', catchup=False, tags=['simple']) as dag2:
    BashOperator(task_id='hello', bash_command='echo "Hello Airflow 3.0.2!"')
DAG

cat > Dockerfile << 'DOCKER'
FROM apache/airflow:3.0.2-python3.11
COPY dags/ ${AIRFLOW_HOME}/dags/
USER airflow
DOCKER

docker build -t ${IMAGE_NAME}:${AIRFLOW_VERSION} . > /dev/null 2>&1
kind load docker-image ${IMAGE_NAME}:${AIRFLOW_VERSION} --name kind
echo -e "${GREEN}✓ Airflow image loaded${NC}"

# LOAD POSTGRESQL
echo -e "\n${YELLOW}━━━ STEP 3: Load PostgreSQL ━━━${NC}"
docker pull ${POSTGRES_IMAGE} > /dev/null 2>&1
kind load docker-image ${POSTGRES_IMAGE} --name kind
echo -e "${GREEN}✓ PostgreSQL loaded${NC}"

# CREATE VALUES-OVERRIDE.YAML
echo -e "\n${YELLOW}━━━ STEP 4: Create values-override.yaml ━━━${NC}"
cat > values-override.yaml << 'VALUES'
# ============================================================================
# Airflow 3.0.2 - Schema-Compliant Configuration for Helm Chart 1.18.0
# ============================================================================

executor: "KubernetesExecutor"

images:
  airflow:
    repository: my-dags
    tag: "3.0.2"
    pullPolicy: Never

# Scheduler
scheduler:
  replicas: 1

# Triggerer
triggerer:
  replicas: 1

# Workers (set to 0 for KubernetesExecutor)
workers:
  replicas: 0

# Redis (not needed)
redis:
  enabled: false

# PostgreSQL
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

# Storage
logs:
  persistence:
    enabled: false

dags:
  persistence:
    enabled: false

# Airflow config
config:
  core:
    load_examples: 'False'
  webserver:
    expose_config: 'True'
VALUES

echo -e "${GREEN}✓ values-override.yaml created${NC}"

# SETUP HELM
echo -e "\n${YELLOW}━━━ STEP 5: Setup Helm ━━━${NC}"
helm repo add apache-airflow https://airflow.apache.org 2>/dev/null || true
helm repo update > /dev/null 2>&1
echo -e "${GREEN}✓ Helm ready${NC}"

# CREATE NAMESPACE
echo -e "\n${YELLOW}━━━ STEP 6: Create Namespace ━━━${NC}"
kubectl create namespace ${NAMESPACE}
echo -e "${GREEN}✓ Namespace created${NC}"

# INSTALL AIRFLOW
echo -e "\n${YELLOW}━━━ STEP 7: Install Airflow ━━━${NC}"
helm install airflow apache-airflow/airflow \
  --version ${HELM_CHART_VERSION} \
  --namespace ${NAMESPACE} \
  -f values-override.yaml \
  --timeout 3m

echo -e "${GREEN}✓ Helm installed${NC}"

# WAIT FOR POSTGRESQL
echo -e "\n${YELLOW}━━━ STEP 8: Wait for PostgreSQL ━━━${NC}"
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=postgresql \
  -n ${NAMESPACE} \
  --timeout=300s
echo -e "${GREEN}✓ PostgreSQL ready${NC}"

# RUN MIGRATION
echo -e "\n${YELLOW}━━━ STEP 9: Run Migration ━━━${NC}"
kubectl delete pod -n ${NAMESPACE} airflow-migration 2>/dev/null || true
kubectl run airflow-migration \
  --namespace=${NAMESPACE} \
  --image=${IMAGE_NAME}:${AIRFLOW_VERSION} \
  --image-pull-policy=Never \
  --restart=Never \
  --env="AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://postgres:${POSTGRES_PASSWORD}@airflow-postgresql:5432/postgres" \
  --command -- airflow db migrate > /dev/null 2>&1

sleep 30
kubectl logs -n ${NAMESPACE} airflow-migration 2>/dev/null | tail -3
echo -e "${GREEN}✓ Migration complete${NC}"

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
helm upgrade airflow apache-airflow/airflow \
  --version ${HELM_CHART_VERSION} \
  --namespace ${NAMESPACE} \
  --reuse-values \
  --set migrateDatabaseJob.enabled=true \
  --set migrateDatabaseJob.useHelmHooks=false \
  --wait \
  --timeout 10m > /dev/null 2>&1
echo -e "${GREEN}✓ Init fix applied${NC}"

# WAIT FOR PODS
echo -e "\n${YELLOW}━━━ STEP 12: Wait for Components ━━━${NC}"
sleep 30

COMPONENTS=("scheduler" "api-server" "triggerer" "dag-processor")
for comp in "${COMPONENTS[@]}"; do
  if kubectl wait --for=condition=ready pod -l component=${comp} -n ${NAMESPACE} --timeout=300s 2>/dev/null; then
    echo "  ✓ ${comp}"
  fi
done

# SUCCESS
echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         ✅ AIRFLOW 3.0.2 INSTALLATION COMPLETE! ✅        ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"

echo -e "\n${BLUE}📊 POD STATUS:${NC}"
kubectl get pods -n ${NAMESPACE}

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
echo "   Trigger DAG:    kubectl exec -n airflow deployment/airflow-scheduler -c scheduler -- airflow dags trigger example_pipeline"

echo -e "\n${BLUE}📂 FILES CREATED:${NC}"
echo "   • values-override.yaml  (Helm configuration)"
echo "   • Dockerfile            (Airflow image)"
echo "   • dags/example.py       (Example DAGs)"

echo -e "\n${GREEN}🎉 Happy orchestrating! 🎉${NC}"

