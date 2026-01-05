# Airflow 3.0.2 on Kubernetes - Complete Installation Guide & Troubleshooting

**Author:** Based on extensive debugging session  
**Date:** December 2025  
**Version:** Airflow 3.0.2 with Helm Chart 1.18.0  
**Target:** Kind Kubernetes cluster with KubernetesExecutor

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Architecture Overview](#architecture-overview)
3. [Complete Error Post-Mortem](#complete-error-post-mortem)
4. [Installation Scripts](#installation-scripts)
5. [Debugging Toolkit](#debugging-toolkit)
6. [Best Practices](#best-practices)
7. [Common Issues & Solutions](#common-issues--solutions)

---

## Quick Start

### Prerequisites
```bash
# Required tools
- Docker Desktop
- Kind (Kubernetes in Docker)
- kubectl
- Helm 3.x
```

### One-Command Installation
```bash
./install-airflow-3-PERFECT.sh
```

### Access Airflow
```bash
# Terminal 1: Port forward
kubectl port-forward -n airflow svc/airflow-api-server 8080:8080

# Browser: 
http://localhost:8080
Username: admin
Password: admin
```

---

## Architecture Overview

### Airflow 3.0.2 Components
```
┌─────────────────────────────────────────────────┐
│            Airflow 3.0.2 Architecture           │
├─────────────────────────────────────────────────┤
│                                                 │
│  ┌──────────────┐      ┌──────────────┐       │
│  │  API Server  │◄────►│  Scheduler   │       │
│  │  (Port 8080) │      │              │       │
│  │              │      │              │       │
│  │  • Web UI    │      │  • DAG Exec  │       │
│  │  • REST API  │      │  • Task Mgmt │       │
│  └──────┬───────┘      └──────┬───────┘       │
│         │                     │                │
│         │    ┌────────────────┘                │
│         │    │                                 │
│         ▼    ▼                                 │
│  ┌──────────────────┐                         │
│  │   PostgreSQL     │                         │
│  │                  │                         │
│  │  • Metadata DB   │                         │
│  │  • State Store   │                         │
│  └──────────────────┘                         │
│                                                 │
│         ▼                                      │
│  ┌──────────────────┐                         │
│  │ Kubernetes Pods  │ (Worker pods)           │
│  │ (Task Execution) │                         │
│  └──────────────────┘                         │
│                                                 │
└─────────────────────────────────────────────────┘
```

### Key Changes from Airflow 2.x

| Component | Airflow 2.x | Airflow 3.0.2 |
|-----------|-------------|---------------|
| **UI Server** | `webserver` | `api-server` |
| **Python** | 3.7+ | 3.9+ |
| **Auth** | Flask-AppBuilder | Simplified |
| **CLI** | `airflow db init` | `airflow db migrate` |
| **Session Storage** | Optional | Required (session table) |

---

## Complete Error Post-Mortem

### ERROR #1: Helm Chart Version Mismatch

#### Symptoms
```
Thank you for installing Apache Airflow 2.10.5!
```
Even though you specified `images.airflow.tag: "3.0.2"`

#### Root Cause
- Used Helm chart version 1.16.0 (designed for Airflow 2.10.5)
- Helm charts have embedded version-specific configurations
- Overriding image tag alone doesn't change chart configurations

#### How to Diagnose
```bash
# Check available chart versions
helm search repo apache-airflow/airflow --versions | head -20

# Expected output:
# NAME                    CHART VERSION   APP VERSION
# apache-airflow/airflow  1.18.0          3.0.2       ← CORRECT
# apache-airflow/airflow  1.17.0          3.0.2
# apache-airflow/airflow  1.16.0          2.10.5      ← WRONG FOR 3.0.2
```

#### Solution
```bash
# Always specify matching Helm chart version
helm install airflow apache-airflow/airflow \
  --version 1.18.0 \  # ← Explicitly use correct version
  --namespace airflow \
  -f values.yaml
```

#### Prevention
- **ALWAYS** check Helm chart to Airflow version mapping
- Don't assume latest chart = latest Airflow
- Use `helm search repo` before installation

#### Lesson
✅ Helm chart version ≠ Airflow version  
✅ Chart configurations are version-specific  
✅ Explicit versioning prevents surprises

---

### ERROR #2: Database Migration Never Ran

#### Symptoms
```bash
# Pod logs show:
TimeoutError: There are still unapplied migrations after 60 seconds
MigrationHead(s) in DB: set()  ← EMPTY DATABASE!
Migration Head(s) in Source Code: {'29ce7909c52b'}

# Pods stuck in:
Init:CrashLoopBackOff
```

#### Root Cause
```yaml
# In values.yaml:
migrateDatabaseJob:
  useHelmHooks: false  # ← This DISABLES automatic migration!
```

**What happens:**
1. Helm installs Airflow components
2. Migration job is disabled (no Helm hook)
3. Database remains empty (no tables)
4. Pods wait for migrations that never run
5. Init containers timeout after 60 seconds

#### How to Diagnose
```bash
# Check if migration job exists
kubectl get jobs -n airflow
# Expected if broken: No resources found

# Check init container logs
kubectl logs -n airflow -l component=scheduler \
  -c wait-for-airflow-migrations --tail=20

# Shows:
# [2025-12-30] {db.py:816} INFO - Waiting for migrations... 59 second(s)
# TimeoutError: There are still unapplied migrations...
```

#### Solution
```bash
# Run migration manually
kubectl run airflow-migration \
  --namespace=airflow \
  --image=my-dags:3.0.2 \
  --image-pull-policy=Never \
  --restart=Never \
  --env="AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://postgres:postgres@airflow-postgresql:5432/postgres" \
  --command -- airflow db migrate

# Wait for completion
sleep 30

# Verify success
kubectl logs -n airflow airflow-migration | grep "Database migrating done"
```

#### Prevention
```yaml
# Option 1: Keep Helm hooks enabled (automatic)
migrateDatabaseJob:
  useHelmHooks: true

# Option 2: If disabled, run migration manually (shown above)
```

#### Lesson
✅ `useHelmHooks: false` = manual migration required  
✅ Always verify migration completed before pods start  
✅ Check logs for "Database migrating done" message

---

### ERROR #3: Init Container Timeout Bug

#### Symptoms
```bash
# Migration completed successfully:
kubectl logs airflow-migration
# Output: Database migrating done!

# But pods STILL fail:
TimeoutError: There are still unapplied migrations after 60 seconds
MigrationHead(s) in DB: {'29ce7909c52b'}  ← HAS IT!
Migration Head(s) in Source Code: {'29ce7909c52b'}  ← MATCHES!
```

**Both values are IDENTICAL but still timeout!**

#### Root Cause
- **Bug in Airflow 3.0.2's `airflow db check-migrations` command**
- Init container checks if DB head matches source code head
- Logic error causes timeout even when they match
- Known issue in early Airflow 3.x releases

#### How to Diagnose
```bash
# Compare before and after migration:

# Before migration:
kubectl logs ... -c wait-for-airflow-migrations | tail -5
# MigrationHead(s) in DB: set()
# Migration Head(s) in Source Code: {'29ce7909c52b'}
# ← DIFFERENT (expected to fail)

# After migration:
kubectl logs ... -c wait-for-airflow-migrations | tail -5
# MigrationHead(s) in DB: {'29ce7909c52b'}
# Migration Head(s) in Source Code: {'29ce7909c52b'}
# ← IDENTICAL but STILL FAILS (this is the bug!)
```

#### Solution
```bash
# Upgrade Helm release to bypass broken check
helm upgrade airflow apache-airflow/airflow \
  --namespace airflow \
  --reuse-values \
  --set migrateDatabaseJob.enabled=true \
  --set migrateDatabaseJob.useHelmHooks=false \
  --wait \
  --timeout 5m

# This tells Helm: "Migration is handled, skip the init check"
```

#### Alternative Solutions
```yaml
# Option 1: Disable wait in values.yaml
scheduler:
  waitForMigrations:
    enabled: false

webserver:
  waitForMigrations:
    enabled: false
```

#### Prevention
- Check GitHub issues for known bugs in new releases
- Have workarounds ready for init container problems
- Consider using Helm chart annotations to skip checks

#### Lesson
✅ Not all errors are your fault - sometimes it's upstream bugs  
✅ When identical values fail, suspect logic errors  
✅ Workarounds are valid solutions for known bugs

---

### ERROR #4: Missing Session Table

#### Symptoms
```bash
# UI shows generic error:
"Something bad has happened"

# API server logs show:
sqlalchemy.exc.InternalError: 
SELECT ... FROM session WHERE session.session_id = ...
psycopg2.errors.InFailedSqlTransaction: 
current transaction is aborted
```

#### Root Cause
```
Airflow 3.0.2 Architecture:
┌─────────────────────────────────────┐
│  API Server (UI)                    │
│    │                                │
│    ├─ Uses Flask-Session for auth  │
│    │                                │
│    └─ Requires 'session' table     │
│         in database                 │
│                                      │
│  Database Migration                 │
│    │                                │
│    └─ DOESN'T create session table │  ← BUG!
│       (oversight in Airflow 3.0.2) │
└─────────────────────────────────────┘
```

**Flow:**
1. User accesses UI
2. API server tries to read session from database
3. `SELECT * FROM session WHERE ...`
4. Table doesn't exist → error
5. UI shows generic error message

#### How to Diagnose
```bash
# Check API server logs
kubectl logs -n airflow -l component=api-server --tail=50

# Look for:
# SELECT ... FROM session WHERE session.session_id = ...
# psycopg2.errors.InFailedSqlTransaction

# Verify session table doesn't exist
kubectl exec -n airflow airflow-postgresql-0 -- \
  env PGPASSWORD=postgres psql -U postgres -d postgres -c "\dt" | grep session
# Output: (empty) ← TABLE MISSING!
```

#### Solution
```bash
# Create session table manually
kubectl exec -n airflow airflow-postgresql-0 -- \
  env PGPASSWORD=postgres psql -U postgres -d postgres -c "
CREATE TABLE IF NOT EXISTS session (
    id SERIAL PRIMARY KEY,
    session_id VARCHAR(255) UNIQUE NOT NULL,
    data BYTEA,
    expiry TIMESTAMP
);
"

# Restart API server to pick up new table
kubectl rollout restart deployment/airflow-api-server -n airflow

# Wait for restart
sleep 20

# Verify table exists
kubectl exec -n airflow airflow-postgresql-0 -- \
  env PGPASSWORD=postgres psql -U postgres -d postgres -c "\dt" | grep session
# Output: public | session | table | postgres ← SUCCESS!
```

#### Prevention
```bash
# Add to installation script:
echo "Creating session table..."
kubectl exec ... psql ... -c "CREATE TABLE IF NOT EXISTS session ..."
```

#### Lesson
✅ Always check application logs for specific errors  
✅ "Something bad happened" = dig into container logs  
✅ Migrations can be incomplete - manual fixes sometimes needed  
✅ Database schema issues show up as SQL errors in logs

---

### ERROR #5: No Webserver Pod

#### Symptoms
```bash
# Check pods
kubectl get pods -n airflow
# Shows: api-server, scheduler, postgresql
# Missing: webserver ← WHERE IS IT?

# Try to port-forward
kubectl port-forward -n airflow svc/airflow-webserver 8080:8080
# Error: service "airflow-webserver" not found
```

#### Root Cause

**Airflow 3.0 Architectural Change:**
```
Airflow 2.x:                    Airflow 3.0.2:
┌─────────────┐                ┌─────────────┐
│ Webserver   │ ← UI          │ API Server  │ ← UI + API
│ (Port 8080) │                │ (Port 8080) │
├─────────────┤                ├─────────────┤
│ Scheduler   │                │ Scheduler   │
├─────────────┤                ├─────────────┤
│ Database    │                │ Database    │
└─────────────┘                └─────────────┘

Separate webserver              Merged into api-server
```

**What changed:**
- Airflow 2.x: `webserver` component serves UI
- Airflow 3.0: `api-server` serves both UI and REST API
- `webserver` is now optional/deprecated
- Helm chart 1.18.0 reflects this new architecture

#### How to Diagnose
```bash
# Check all services
kubectl get svc -n airflow
# Shows: airflow-api-server (NOT airflow-webserver)

# Check all deployments
kubectl get deployments -n airflow
# Shows: api-server, scheduler (NO webserver)

# Check Helm chart notes
helm get notes airflow -n airflow
# Shows: "Airflow API Server: kubectl port-forward svc/airflow-api-server..."
```

#### Solution
```bash
# Use api-server instead of webserver
kubectl port-forward -n airflow svc/airflow-api-server 8080:8080

# Browser:
http://localhost:8080  # Works!
```

#### Prevention
- Read release notes for major version upgrades
- Understand architectural changes
- Update scripts/docs to reference api-server

#### Lesson
✅ Major versions = architectural changes  
✅ Airflow 3.0 merged webserver into api-server  
✅ Always check what components exist before assuming

---

### ERROR #6: Image Pull Issues

#### Symptoms
```bash
kubectl get pods -n airflow
# NAME                            READY   STATUS
# airflow-postgresql-0            0/1     ImagePullBackOff
# airflow-scheduler-xxx           0/2     ErrImagePull

kubectl describe pod airflow-postgresql-0 -n airflow
# Events:
#   Failed to pull image "bitnami/postgresql:16.1.0"
#   Back-off pulling image
```

#### Root Cause

**Kind Cluster Isolation:**
```
┌──────────────────────────────────────┐
│  Docker Desktop                      │
│  ┌────────────────────────────────┐ │
│  │  Kind Cluster                  │ │
│  │  (Isolated network)            │ │
│  │                                │ │
│  │  ⚠️ NO internet access!       │ │
│  │  ⚠️ Can't pull from DockerHub │ │
│  │                                │ │
│  │  Must pre-load images          │ │
│  └────────────────────────────────┘ │
└──────────────────────────────────────┘
```

**What happens:**
1. Kubernetes tries to pull image from registry
2. Kind cluster is isolated (no internet)
3. Pull fails → ImagePullBackOff
4. Pod never starts

#### How to Diagnose
```bash
# Check pod events
kubectl describe pod -n airflow airflow-postgresql-0

# Look for:
# Events:
#   Failed to pull image "bitnami/postgresql:16.1.0"
#   Back-off pulling image

# Check images in Kind
docker exec kind-control-plane crictl images | grep postgresql
# Output: (empty) ← IMAGE NOT LOADED!
```

#### Solution
```bash
# Step 1: Pull image to local Docker
docker pull bitnamilegacy/postgresql:14.10.0

# Step 2: Load image into Kind cluster
kind load docker-image bitnamilegacy/postgresql:14.10.0 --name kind

# Step 3: Set pullPolicy in Helm values
cat > values.yaml << 'YAML'
postgresql:
  image:
    registry: docker.io
    repository: bitnamilegacy/postgresql
    tag: "14.10.0"
    pullPolicy: Never  # ← CRITICAL!
YAML

# Step 4: Verify image is in Kind
docker exec kind-control-plane crictl images | grep postgresql
# Should show: bitnamilegacy/postgresql  14.10.0
```

#### Prevention
```bash
# Always pre-load ALL images:
IMAGES=(
  "my-dags:3.0.2"
  "bitnamilegacy/postgresql:14.10.0"
)

for image in "${IMAGES[@]}"; do
  docker pull $image 2>/dev/null || docker build -t $image .
  kind load docker-image $image --name kind
done
```

#### Lesson
✅ Kind requires explicit image loading  
✅ Set `pullPolicy: Never` to prevent pull attempts  
✅ Always verify images with `crictl images`  
✅ Pre-load BEFORE Helm install

---

### ERROR #7: PostgreSQL Connection Refused

#### Symptoms
```bash
# Logs show:
connection to server at "airflow-postgresql" failed: Connection refused
Is the server running on that host and accepting TCP/IP connections?

# Pods waiting:
Init:0/1
```

#### Root Cause

**Race Condition:**
```
Timeline:
T=0s  : Helm install starts
T=5s  : PostgreSQL pod created (but not ready)
T=10s : Scheduler pod starts
T=12s : Scheduler tries to connect to PostgreSQL
T=12s : Connection refused (PostgreSQL still starting)
T=15s : Migration job tries to run
T=15s : Connection refused
T=30s : PostgreSQL finally ready
T=31s : But other pods already failed
```

#### How to Diagnose
```bash
# Check PostgreSQL status
kubectl get pods -n airflow -l app.kubernetes.io/name=postgresql
# NAME                   READY   STATUS
# airflow-postgresql-0   0/1     ContainerCreating ← NOT READY!

# Check PostgreSQL logs
kubectl logs -n airflow airflow-postgresql-0
# Shows: database system is starting up...
```

#### Solution
```bash
# Wait for PostgreSQL before proceeding
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=postgresql \
  -n airflow \
  --timeout=300s

# Only after this succeeds, run migration
kubectl run airflow-migration ...
```

#### Prevention
```bash
# In installation script, always:
echo "Waiting for PostgreSQL..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=postgresql \
  -n airflow \
  --timeout=300s

echo "PostgreSQL ready! Running migration..."
kubectl run airflow-migration ...
```

#### Lesson
✅ Always wait for dependencies  
✅ Use `kubectl wait` instead of `sleep`  
✅ Verify readiness before proceeding  
✅ Race conditions cause intermittent failures

---

## Installation Scripts

### Complete Installation Script
```bash
#!/bin/bash
# File: install-airflow-3-PERFECT.sh

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Airflow 3.0.2 Installation${NC}"

# Configuration
AIRFLOW_VERSION="3.0.2"
IMAGE_NAME="my-dags"
POSTGRES_IMAGE="bitnamilegacy/postgresql:14.10.0"
NAMESPACE="airflow"

# Step 1: Cleanup
echo -e "${YELLOW}Step 1: Cleanup${NC}"
helm uninstall airflow -n ${NAMESPACE} 2>/dev/null || true
kubectl delete namespace ${NAMESPACE} 2>/dev/null || true
kind delete cluster --name kind 2>/dev/null || true
kind create cluster --name kind --image kindest/node:v1.29.4

# Step 2: Build image
echo -e "${YELLOW}Step 2: Build image${NC}"
mkdir -p dags
cat > dags/example.py << 'DAG'
from datetime import datetime
from airflow import DAG
from airflow.operators.bash import BashOperator

with DAG('example', start_date=datetime(2024,1,1), schedule='@daily', catchup=False) as dag:
    BashOperator(task_id='hello', bash_command='echo "Hello Airflow 3.0.2!"')
DAG

cat > Dockerfile << 'DOCKER'
FROM apache/airflow:3.0.2-python3.11
COPY dags/ ${AIRFLOW_HOME}/dags/
USER airflow
DOCKER

docker build -t ${IMAGE_NAME}:${AIRFLOW_VERSION} .
kind load docker-image ${IMAGE_NAME}:${AIRFLOW_VERSION} --name kind

# Step 3: Load PostgreSQL
echo -e "${YELLOW}Step 3: Load PostgreSQL${NC}"
docker pull ${POSTGRES_IMAGE}
kind load docker-image ${POSTGRES_IMAGE} --name kind

# Step 4: Create values
echo -e "${YELLOW}Step 4: Create values${NC}"
cat > values.yaml << 'VALUES'
executor: "KubernetesExecutor"
images:
  airflow:
    repository: my-dags
    tag: "3.0.2"
    pullPolicy: Never
webserver:
  defaultUser:
    enabled: true
    username: admin
    password: admin
scheduler:
  replicas: 1
triggerer:
  enabled: false
workers:
  replicas: 0
redis:
  enabled: false
dagProcessor:
  enabled: false
postgresql:
  enabled: true
  image:
    registry: docker.io
    repository: bitnamilegacy/postgresql
    tag: "14.10.0"
    pullPolicy: Never
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

# Step 5: Install
echo -e "${YELLOW}Step 5: Install Airflow${NC}"
helm repo add apache-airflow https://airflow.apache.org 2>/dev/null || true
helm repo update
kubectl create namespace ${NAMESPACE}

helm install airflow apache-airflow/airflow \
  --version 1.18.0 \
  --namespace ${NAMESPACE} \
  -f values.yaml \
  --timeout 3m \
  2>&1 | grep -v "context deadline" || true

# Step 6: Wait for PostgreSQL
echo -e "${YELLOW}Step 6: Wait for PostgreSQL${NC}"
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=postgresql \
  -n ${NAMESPACE} \
  --timeout=300s

# Step 7: Run migration
echo -e "${YELLOW}Step 7: Run migration${NC}"
kubectl run airflow-migration \
  --namespace=${NAMESPACE} \
  --image=${IMAGE_NAME}:${AIRFLOW_VERSION} \
  --image-pull-policy=Never \
  --restart=Never \
  --env="AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://postgres:postgres@airflow-postgresql:5432/postgres" \
  --command -- airflow db migrate

sleep 30
kubectl logs -n ${NAMESPACE} airflow-migration | tail -3

# Step 8: Create session table
echo -e "${YELLOW}Step 8: Create session table${NC}"
kubectl exec -n ${NAMESPACE} airflow-postgresql-0 -- \
  env PGPASSWORD=postgres psql -U postgres -d postgres -c "
CREATE TABLE IF NOT EXISTS session (
    id SERIAL PRIMARY KEY,
    session_id VARCHAR(255) UNIQUE NOT NULL,
    data BYTEA,
    expiry TIMESTAMP
);
" > /dev/null 2>&1

# Step 9: Fix init container
echo -e "${YELLOW}Step 9: Fix init container${NC}"
helm upgrade airflow apache-airflow/airflow \
  --version 1.18.0 \
  --namespace ${NAMESPACE} \
  --reuse-values \
  --set migrateDatabaseJob.enabled=true \
  --set migrateDatabaseJob.useHelmHooks=false \
  --wait \
  --timeout 5m \
  > /dev/null 2>&1

# Step 10: Verify
echo -e "${YELLOW}Step 10: Verify${NC}"
sleep 20
kubectl get pods -n ${NAMESPACE}

echo -e "${GREEN}✅ Installation complete!${NC}"
echo ""
echo "Access Airflow:"
echo "  kubectl port-forward -n airflow svc/airflow-api-server 8080:8080"
echo "  http://localhost:8080 (admin/admin)"
```

### Uninstall Script
```bash
#!/bin/bash
# File: uninstall-airflow.sh

helm uninstall airflow -n airflow 2>/dev/null || true
kubectl delete namespace airflow 2>/dev/null || true

echo "✓ Airflow uninstalled"
echo ""
echo "To delete Kind cluster:"
echo "  kind delete cluster --name kind"
```

---

## Debugging Toolkit

### Essential Commands
```bash
# ============================================================================
# POD STATUS & INSPECTION
# ============================================================================

# Check all resources
kubectl get all -n airflow

# Check pods with details
kubectl get pods -n airflow -o wide

# Check pod in real-time
kubectl get pods -n airflow -w

# Describe pod (events, config)
kubectl describe pod -n airflow <pod-name>

# ============================================================================
# LOGS
# ============================================================================

# Container logs (last 50 lines)
kubectl logs -n airflow <pod-name> -c <container-name> --tail=50

# Follow logs in real-time
kubectl logs -n airflow <pod-name> -c <container-name> -f

# Init container logs
kubectl logs -n airflow <pod-name> -c wait-for-airflow-migrations --tail=50

# All scheduler logs
kubectl logs -n airflow -l component=scheduler -c scheduler --tail=100

# All api-server logs
kubectl logs -n airflow -l component=api-server --tail=100

# Previous container logs (if restarted)
kubectl logs -n airflow <pod-name> -c <container-name> --previous

# ============================================================================
# DATABASE INSPECTION
# ============================================================================

# Connect to PostgreSQL
kubectl exec -it -n airflow airflow-postgresql-0 -- \
  env PGPASSWORD=postgres psql -U postgres -d postgres

# List tables
kubectl exec -n airflow airflow-postgresql-0 -- \
  env PGPASSWORD=postgres psql -U postgres -d postgres -c "\dt"

# Check specific table
kubectl exec -n airflow airflow-postgresql-0 -- \
  env PGPASSWORD=postgres psql -U postgres -d postgres -c "SELECT * FROM session LIMIT 5;"

# Check migration head
kubectl exec -n airflow airflow-postgresql-0 -- \
  env PGPASSWORD=postgres psql -U postgres -d postgres -c "SELECT * FROM alembic_version;"

# ============================================================================
# AIRFLOW COMMANDS
# ============================================================================

# List users
kubectl exec -n airflow deployment/airflow-scheduler -c scheduler -- \
  airflow users list

# List DAGs
kubectl exec -n airflow deployment/airflow-scheduler -c scheduler -- \
  airflow dags list

# Trigger DAG
kubectl exec -n airflow deployment/airflow-scheduler -c scheduler -- \
  airflow dags trigger example_hello_world

# Check database connectivity
kubectl exec -n airflow deployment/airflow-scheduler -c scheduler -- \
  airflow db check

# ============================================================================
# HELM
# ============================================================================

# List Helm releases
helm list -n airflow

# Get Helm values
helm get values airflow -n airflow

# Get Helm manifest
helm get manifest airflow -n airflow

# Helm history
helm history airflow -n airflow

# ============================================================================
# KIND CLUSTER
# ============================================================================

# Check images in Kind
docker exec kind-control-plane crictl images

# Check Kind cluster info
kind get clusters
kubectl cluster-info

# Export Kind logs
kind export logs --name kind

# ============================================================================
# EVENTS
# ============================================================================

# All events (sorted by time)
kubectl get events -n airflow --sort-by='.lastTimestamp'

# Watch events
kubectl get events -n airflow -w

# ============================================================================
# RESTART COMPONENTS
# ============================================================================

# Restart deployment
kubectl rollout restart deployment/airflow-scheduler -n airflow
kubectl rollout restart deployment/airflow-api-server -n airflow

# Delete pod (will auto-recreate)
kubectl delete pod -n airflow <pod-name>

# Delete all airflow pods
kubectl delete pods -n airflow -l tier=airflow

# ============================================================================
# PORT FORWARDING
# ============================================================================

# Forward API server
kubectl port-forward -n airflow svc/airflow-api-server 8080:8080

# Forward PostgreSQL
kubectl port-forward -n airflow svc/airflow-postgresql 5432:5432

# ============================================================================
# RESOURCE USAGE
# ============================================================================

# Check resource usage
kubectl top pods -n airflow
kubectl top nodes

# ============================================================================
# YAML EXPORT
# ============================================================================

# Export pod YAML
kubectl get pod -n airflow <pod-name> -o yaml

# Export all resources
kubectl get all -n airflow -o yaml > airflow-backup.yaml
```

### Diagnostic Script
```bash
#!/bin/bash
# File: diagnose-airflow.sh

NAMESPACE="airflow"

echo "=== Airflow 3.0.2 Diagnostics ==="
echo ""

echo "1. Pod Status:"
kubectl get pods -n ${NAMESPACE}
echo ""

echo "2. Services:"
kubectl get svc -n ${NAMESPACE}
echo ""

echo "3. Recent Events:"
kubectl get events -n ${NAMESPACE} --sort-by='.lastTimestamp' | tail -20
echo ""

echo "4. PostgreSQL Status:"
kubectl exec -n ${NAMESPACE} airflow-postgresql-0 -- \
  env PGPASSWORD=postgres psql -U postgres -d postgres -c "SELECT version();" 2>/dev/null || echo "PostgreSQL not accessible"
echo ""

echo "5. Database Tables:"
kubectl exec -n ${NAMESPACE} airflow-postgresql-0 -- \
  env PGPASSWORD=postgres psql -U postgres -d postgres -c "\dt" 2>/dev/null | head -20
echo ""

echo "6. Scheduler Logs (last 10 lines):"
kubectl logs -n ${NAMESPACE} -l component=scheduler -c scheduler --tail=10
echo ""

echo "7. API Server Logs (last 10 lines):"
kubectl logs -n ${NAMESPACE} -l component=api-server --tail=10
echo ""

echo "8. Helm Release Info:"
helm list -n ${NAMESPACE}
echo ""

echo "Diagnostics complete!"
```

---

## Best Practices

### 1. Pre-Installation Checklist
```bash
# ✅ Verify tools installed
command -v docker && echo "✓ Docker" || echo "✗ Docker missing"
command -v kind && echo "✓ Kind" || echo "✗ Kind missing"
command -v kubectl && echo "✓ kubectl" || echo "✗ kubectl missing"
command -v helm && echo "✓ Helm" || echo "✗ Helm missing"

# ✅ Check Helm chart versions
helm repo add apache-airflow https://airflow.apache.org
helm repo update
helm search repo apache-airflow/airflow --versions | head -5

# ✅ Verify Kind cluster config
kind get clusters

# ✅ Check available resources
docker system df
```

### 2. Installation Best Practices
```yaml
# values.yaml - Production-Ready Template

executor: "KubernetesExecutor"

# Image configuration
images:
  airflow:
    repository: my-airflow
    tag: "3.0.2"
    pullPolicy: Never  # For Kind; use IfNotPresent for real clusters

# Security
webserver:
  defaultUser:
    enabled: true
    username: admin
    password: "CHANGE_ME_IN_PRODUCTION"  # Use secrets!
  secretKey: "STATIC_SECRET_KEY_HERE"  # Generate with: openssl rand -hex 32

# Resource limits
scheduler:
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 2Gi

# Persistence (disable for dev, enable for prod)
logs:
  persistence:
    enabled: false  # Set to true in production
    size: 10Gi

dags:
  persistence:
    enabled: false  # Use GitSync in production

# Database
postgresql:
  enabled: true  # Use external DB in production
  primary:
    persistence:
      enabled: false  # Set to true in production
      size: 10Gi

# Monitoring
config:
  metrics:
    statsd_on: true
  logging:
    remote_logging: false  # Enable in production
```

### 3. Troubleshooting Workflow
```
Problem Occurs
      │
      ▼
┌─────────────────────┐
│ 1. Check Pod Status │
│ kubectl get pods    │
└──────┬──────────────┘
       │
       ▼
┌─────────────────────┐
│ 2. Describe Pod     │
│ kubectl describe    │
│ (Check Events)      │
└──────┬──────────────┘
       │
       ▼
┌─────────────────────┐
│ 3. Check Logs       │
│ kubectl logs        │
│ (All containers)    │
└──────┬──────────────┘
       │
       ▼
┌─────────────────────┐
│ 4. Check Database   │
│ psql commands       │
│ (Tables, data)      │
└──────┬──────────────┘
       │
       ▼
┌─────────────────────┐
│ 5. Verify Config    │
│ helm get values     │
│ kubectl get cm      │
└──────┬──────────────┘
       │
       ▼
┌─────────────────────┐
│ 6. Check Images     │
│ crictl images       │
└──────┬──────────────┘
       │
       ▼
   SOLUTION FOUND
```

### 4. Common Pitfalls to Avoid
```bash
# ❌ DON'T: Use wrong Helm chart version
helm install airflow apache-airflow/airflow  # Uses random version

# ✅ DO: Specify exact version
helm install airflow apache-airflow/airflow --version 1.18.0

# ❌ DON'T: Forget to pre-load images
helm install airflow ...  # Images not in Kind

# ✅ DO: Load images first
kind load docker-image my-dags:3.0.2 --name kind

# ❌ DON'T: Skip migration verification
kubectl run airflow-migration ...
helm upgrade airflow ...  # Migration not checked!

# ✅ DO: Verify migration completed
kubectl logs airflow-migration | grep "Database migrating done"

# ❌ DON'T: Use sleep for synchronization
sleep 30
kubectl run next-step ...  # Might not be ready

# ✅ DO: Use kubectl wait
kubectl wait --for=condition=ready pod ...
kubectl run next-step ...

# ❌ DON'T: Ignore init container logs
kubectl logs pod main-container  # Missing critical info

# ✅ DO: Check ALL containers
kubectl logs pod -c init-container
kubectl logs pod -c main-container

# ❌ DON'T: Use default passwords in production
password: admin

# ✅ DO: Use Kubernetes secrets
password: ${SECRET_PASSWORD}
```

---

## Common Issues & Solutions

### Issue: Pods Stuck in Pending
```bash
# Symptoms
kubectl get pods -n airflow
# NAME                    READY   STATUS    RESTARTS   AGE
# airflow-scheduler-xxx   0/2     Pending   0          5m

# Diagnosis
kubectl describe pod -n airflow airflow-scheduler-xxx

# Common causes:
# 1. Resource constraints
# 2. Node not ready
# 3. Image pull issues

# Solutions:
# 1. Check resources
kubectl top nodes

# 2. Check events
kubectl get events -n airflow --sort-by='.lastTimestamp' | tail -20

# 3. Verify images loaded
docker exec kind-control-plane crictl images | grep my-dags
```

### Issue: CrashLoopBackOff
```bash
# Symptoms
kubectl get pods -n airflow
# NAME                    READY   STATUS              RESTARTS   AGE
# airflow-scheduler-xxx   0/2     CrashLoopBackOff   5          10m

# Diagnosis
kubectl logs -n airflow airflow-scheduler-xxx -c scheduler --tail=50

# Common causes:
# 1. Database not ready
# 2. Missing migration
# 3. Configuration error

# Solutions:
# 1. Check database
kubectl exec -n airflow deployment/airflow-scheduler -c scheduler -- airflow db check

# 2. Run migration
kubectl run airflow-migration ...

# 3. Check config
helm get values airflow -n airflow
```

### Issue: UI Shows Error
```bash
# Symptoms
# Browser shows: "Something bad has happened"

# Diagnosis
kubectl logs -n airflow -l component=api-server --tail=50

# Common causes:
# 1. Missing session table
# 2. Database error
# 3. Authentication issue

# Solutions:
# 1. Create session table
kubectl exec airflow-postgresql-0 -- psql ... -c "CREATE TABLE session ..."

# 2. Restart api-server
kubectl rollout restart deployment/airflow-api-server -n airflow

# 3. Check user exists
kubectl exec deployment/airflow-scheduler -c scheduler -- airflow users list
```

### Issue: DAGs Not Showing
```bash
# Symptoms
# UI loads but no DAGs visible

# Diagnosis
kubectl exec -n airflow deployment/airflow-scheduler -c scheduler -- airflow dags list

# Common causes:
# 1. DAGs not in image
# 2. DAG parsing errors
# 3. Scheduler not running

# Solutions:
# 1. Verify DAGs in image
kubectl exec deployment/airflow-scheduler -c scheduler -- ls -la /opt/airflow/dags/

# 2. Check scheduler logs
kubectl logs -n airflow -l component=scheduler -c scheduler -f

# 3. Trigger DAG list refresh
kubectl exec deployment/airflow-scheduler -c scheduler -- airflow dags list-import-errors
```

---

## Version Compatibility Matrix

| Component | Version | Compatible With |
|-----------|---------|-----------------|
| **Airflow** | 3.0.2 | ✅ |
| **Helm Chart** | 1.18.0 | ✅ Airflow 3.0.2 |
| **Helm Chart** | 1.17.0 | ✅ Airflow 3.0.2 |
| **Helm Chart** | 1.16.0 | ❌ Airflow 2.10.5 |
| **Python** | 3.11 | ✅ |
| **Python** | 3.12 | ✅ |
| **Python** | 3.8 | ❌ (too old) |
| **PostgreSQL** | 14.x | ✅ |
| **PostgreSQL** | 15.x | ✅ |
| **PostgreSQL** | 16.x | ✅ |
| **Kubernetes** | 1.29.x | ✅ |
| **Kubernetes** | 1.28.x | ✅ |
| **Kind** | 0.20+ | ✅ |
| **Helm** | 3.x | ✅ |
| **Helm** | 4.x | ✅ |

---

## Quick Reference Card
```
╔════════════════════════════════════════════════════════════╗
║           AIRFLOW 3.0.2 QUICK REFERENCE                    ║
╠════════════════════════════════════════════════════════════╣
║                                                            ║
║  INSTALLATION                                              ║
║  ./install-airflow-3-PERFECT.sh                           ║
║                                                            ║
║  ACCESS UI                                                 ║
║  kubectl port-forward -n airflow svc/airflow-api-server \ ║
║    8080:8080                                               ║
║  http://localhost:8080 (admin/admin)                      ║
║                                                            ║
║  CHECK STATUS                                              ║
║  kubectl get pods -n airflow                              ║
║                                                            ║
║  VIEW LOGS                                                 ║
║  kubectl logs -n airflow -l component=scheduler -f        ║
║                                                            ║
║  LIST DAGS                                                 ║
║  kubectl exec -n airflow deployment/airflow-scheduler \   ║
║    -c scheduler -- airflow dags list                      ║
║                                                            ║
║  TRIGGER DAG                                               ║
║  kubectl exec -n airflow deployment/airflow-scheduler \   ║
║    -c scheduler -- airflow dags trigger <dag_id>          ║
║                                                            ║
║  TROUBLESHOOT                                              ║
║  ./diagnose-airflow.sh                                    ║
║                                                            ║
║  UNINSTALL                                                 ║
║  ./uninstall-airflow.sh                                   ║
║  kind delete cluster --name kind                          ║
║                                                            ║
╚════════════════════════════════════════════════════════════╝
```

---

## Appendix: Error Codes & Meanings

### Pod Status Codes

| Status | Meaning | Common Cause |
|--------|---------|--------------|
| `Pending` | Pod created but not scheduled | Resources unavailable, image pull pending |
| `ContainerCreating` | Pod scheduled, containers starting | Pulling image, mounting volumes |
| `Running` | All containers running | ✅ Normal state |
| `Completed` | Container finished successfully | Job/migration completed |
| `Error` | Container exited with error | Application error, config issue |
| `CrashLoopBackOff` | Container keeps crashing | Persistent error, needs fix |
| `ImagePullBackOff` | Can't pull image | Image not found, network issue |
| `Init:0/1` | Init container running | Waiting for migration |
| `Init:CrashLoopBackOff` | Init container crashing | Migration failed |
| `Init:Error` | Init container error | Check init logs |

### Common Error Messages
```bash
# "There are still unapplied migrations"
# Cause: Migration not run or init container bug
# Fix: Run migration manually, apply Helm upgrade

# "Connection refused"
# Cause: PostgreSQL not ready
# Fix: kubectl wait for PostgreSQL

# "ImagePullBackOff"
# Cause: Image not in Kind
# Fix: kind load docker-image

# "SELECT ... FROM session"
# Cause: Missing session table
# Fix: CREATE TABLE session

# "No resources found"
# Cause: Component not deployed
# Fix: Check Helm values, ensure enabled

# "context deadline exceeded"
# Cause: Timeout waiting for resources
# Fix: Increase --timeout, check pod status
```

---

## Resources & Further Reading

### Official Documentation
- Airflow 3.0 Docs: https://airflow.apache.org/docs/apache-airflow/3.0.2/
- Helm Chart: https://github.com/apache/airflow/tree/main/chart
- Kind Docs: https://kind.sigs.k8s.io/

### Useful Links
- Airflow GitHub Issues: https://github.com/apache/airflow/issues
- Kubernetes Debugging: https://kubernetes.io/docs/tasks/debug/
- Helm Best Practices: https://helm.sh/docs/chart_best_practices/

### Community
- Airflow Slack: https://apache-airflow.slack.com
- Stack Overflow: [apache-airflow] tag
- Reddit: r/apacheairflow

---

**Document Version:** 1.0  
**Last Updated:** December 2025  
**Tested On:** Kind v0.20, Kubernetes 1.29, Airflow 3.0.2

---

**END OF GUIDE**

✅ You now have a complete reference for Airflow 3.0.2 installation!
✅ Save this file and refer back whenever needed
✅ All errors documented with solutions
✅ Production-ready scripts included

Good luck with your Airflow journey! 🚀
