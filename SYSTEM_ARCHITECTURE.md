# System Architecture Summary

## Overview
This repository contains a **production-ready Apache Airflow 3.0.2** deployment on Kubernetes, orchestrated using Helm charts. The system implements a **data pipeline** that extracts Stack Exchange data, stores it in AWS S3, and triggers Databricks workflows for data processing.

---

## System Architecture

### High-Level Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          AIRFLOW 3.0.2 PLATFORM                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────────┐      ┌──────────────────┐      ┌──────────────┐ │
│  │   API Server     │◄────►│    Scheduler     │◄────►│  Triggerer   │ │
│  │  (Port 8080)     │      │                  │      │              │ │
│  │  • Web UI        │      │  • DAG Execution │      │  • Async     │ │
│  │  • REST API      │      │  • Task Mgmt     │      │  • Sensors   │ │
│  └────────┬─────────┘      └────────┬─────────┘      └──────────────┘ │
│           │                         │                                  │
│  ┌────────▼─────────────────────────▼─────────┐                       │
│  │          DAG Processor                     │                       │
│  │  • Parses DAG files                        │                       │
│  │  • Validates DAGs                          │                       │
│  └────────┬───────────────────────────────────┘                       │
│           │                                                            │
│  ┌────────▼──────────────────────────────────────────────────────────┐ │
│  │                    Kubernetes Executor                             │ │
│  │  • Creates worker pods for task execution                          │ │
│  │  • Dynamic pod lifecycle management                                │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐ │
│  │                    PostgreSQL Database                             │ │
│  │  • Metadata store (DAGs, tasks, execution history)                │ │
│  │  • Session storage (Flask sessions)                               │ │
│  │  • State management                                               │ │
│  └───────────────────────────────────────────────────────────────────┘ │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐ │
│  │                      Git Sync                                      │ │
│  │  • Syncs DAGs from GitHub repository                              │ │
│  │  • Automatic DAG updates                                          │ │
│  └───────────────────────────────────────────────────────────────────┘ │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                    EXTERNAL SYSTEMS                                     │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────┐      ┌──────────────┐      ┌──────────────────────┐ │
│  │   AWS ECR    │      │    AWS S3    │      │    Databricks        │ │
│  │  (Registry)  │      │  (Storage)   │      │    (Processing)      │ │
│  │              │      │              │      │                      │ │
│  │ • Container  │      │ • Raw data   │      │ • Workflow jobs      │ │
│  │   images     │      │ • Posts.xml  │      │ • Data pipelines     │ │
│  │              │      │ • Users.xml  │      │ • Transformations    │ │
│  └──────────────┘      └──────────────┘      └──────────────────────┘ │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐ │
│  │                    Archive.org                                   │ │
│  │  • Source: Stack Exchange data archives                         │ │
│  │  • Format: 7z compressed files                                  │ │
│  └──────────────────────────────────────────────────────────────────┘ │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Core Components

### 1. **Airflow Components**

#### **API Server** (Replaces WebServer in Airflow 3.0)
- **Purpose**: Serves the Airflow web UI and REST API
- **Port**: 8080
- **Features**:
  - DAG visualization and monitoring
  - Task execution management
  - User authentication (admin/admin by default)
  - REST API for programmatic access

#### **Scheduler**
- **Purpose**: Core orchestration engine
- **Functionality**:
  - Parses DAGs and schedules tasks
  - Monitors task dependencies
  - Triggers task execution via Kubernetes Executor
  - Maintains execution state in PostgreSQL

#### **Triggerer**
- **Purpose**: Handles asynchronous/sensor tasks
- **Functionality**:
  - Manages deferred tasks
  - Handles event-driven workflows
  - Manages time-based sensors

#### **DAG Processor**
- **Purpose**: Parses and validates DAG files
- **Functionality**:
  - Continuously monitors DAG directory
  - Validates DAG syntax and dependencies
  - Updates DAG metadata in database

#### **Kubernetes Executor**
- **Purpose**: Executes tasks as Kubernetes pods
- **Configuration**:
  - `delete_worker_pods: false` - Retains pods for debugging
  - `delete_worker_pods_on_failure: false` - Keeps failed pods
  - Dynamic pod creation per task
  - Uses custom Docker image from ECR

### 2. **Storage Components**

#### **PostgreSQL Database**
- **Image**: `bitnamilegacy/postgresql:14.10.0`
- **Purpose**:
  - Airflow metadata storage
  - Execution history
  - DAG definitions
  - User sessions (custom session table)
- **Configuration**:
  - Password: `postgres`
  - Database: `postgres`
  - No persistence (dev environment)

#### **Persistent Volumes**
- **Logs PVC**: `airflow-logs-pvc`
  - Storage: 5Gi
  - Class: `manual`
  - Path: `/mnt/airflow-data/logs`
  - Access: ReadWriteMany

### 3. **Container Registry**

#### **AWS ECR (Elastic Container Registry)**
- **Registry**: `032517660248.dkr.ecr.us-east-1.amazonaws.com`
- **Repository**: `my-dags`
- **Purpose**: Stores custom Airflow Docker images
- **Image Build Process**:
  - Base: `apache/airflow:3.0.2-python3.11`
  - Includes: DAG files, Python dependencies
  - Tagged with timestamp: `YYYYMMDDHHMMSS`

### 4. **Git Integration**

#### **Git Sync**
- **Repository**: `https://github.com/nifesimii/Databrikcs-Airflow-Kuberntes_Project-.git`
- **Branch**: `master`
- **Path**: `dags/` subdirectory
- **Authentication**: Kubernetes secret `git-credentials`
- **Purpose**: Automatic DAG synchronization from Git

---

## Data Flow

### Pipeline Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                    DATA PIPELINE FLOW                               │
└─────────────────────────────────────────────────────────────────────┘

1. DATA EXTRACTION DAG (produce_data_assets)
   │
   ├─► Downloads: ai.meta.stackexchange.com.7z from archive.org
   │
   ├─► Extracts: Posts.xml and Users.xml files
   │
   └─► Uploads to S3:
       │
       ├─► s3://data-platform-tutorial-nifesimi/raw/Posts.xml
       └─► s3://data-platform-tutorial-nifesimi/raw/Users.xml
       │
       └─► Creates Assets:
           ├─► posts_asset = Asset("s3://data-platform-tutorial/raw/Posts.xml")
           └─► users_asset = Asset("s3://data-platform-tutorial/raw/Users.xml")


2. ASSET-BASED TRIGGERING
   │
   └─► trigger_databricks_workflow_dag is scheduled by:
       schedule = (posts_asset & users_asset)
       │
       └─► Both assets must be updated before triggering


3. DATABRICKS WORKFLOW EXECUTION
   │
   └─► DatabricksRunNowOperator triggers:
       │
       ├─► Job ID: 198061833260489
       │
       └─► Databricks workflows (from notebooks/):
           │
           ├─► bronze_posts.ipynb → bronze layer processing
           ├─► bronze_users.ipynb → bronze layer processing
           ├─► silver_posts.ipynb → silver layer processing
           ├─► gold_post_users.ipynb → gold layer aggregation
           └─► gold_most_popular_tags.ipynb → gold layer analytics
```

### Detailed Data Flow Steps

#### **Step 1: Data Extraction (`produce_data_asset` DAG)**
1. **Schedule**: `@daily` - Runs once per day
2. **Process**:
   - Downloads `ai.meta.stackexchange.com.7z` from archive.org
   - Extracts the 7z archive using `py7zr`
   - Reads `Posts.xml` and `Users.xml` files
   - Uploads both files to S3 bucket `data-platform-tutorial-nifesimi`
   - Creates/modifies assets: `posts_asset` and `users_asset`

#### **Step 2: Asset-Based Scheduling**
- Uses Airflow 3.0's **Asset-based scheduling** feature
- `trigger_databricks_workflow_dag` is triggered when:
  - Both `posts_asset` AND `users_asset` are updated
  - This ensures downstream processing only happens when data is ready

#### **Step 3: Databricks Processing**
- The Databricks workflow (`job_id: 198061833260489`) executes:
  - **Bronze Layer**: Raw XML data ingestion
  - **Silver Layer**: Cleaned and validated data
  - **Gold Layer**: Aggregated analytics (most popular tags, post-user relationships)

---

## Deployment Architecture

### Infrastructure Stack

```
┌─────────────────────────────────────────────────────────────┐
│                   DEPLOYMENT LAYER                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Kind Cluster (Local Dev)               │   │
│  │  ┌─────────────────┐  ┌─────────────────┐          │   │
│  │  │ Control Plane   │  │ Worker Node     │          │   │
│  │  │                 │  │                 │          │   │
│  │  │ • API Server    │  │ • Task Pods     │          │   │
│  │  │ • Scheduler     │  │ • Workers       │          │   │
│  │  │ • PostgreSQL    │  │                 │          │   │
│  │  └─────────────────┘  └─────────────────┘          │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Helm Chart Management                   │   │
│  │  • Chart: apache-airflow/airflow                    │   │
│  │  • Version: 1.18.0 (for Airflow 3.0.2)             │   │
│  │  • Values: chart/values-override-with-persistence.yaml│ │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Docker Image Pipeline                   │   │
│  │  1. Build: cicd/Dockerfile                          │   │
│  │  2. Push: AWS ECR                                   │   │
│  │  3. Load: kind cluster                              │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Deployment Process

#### **Installation Script Flow** (`install-airflow-2-ecr.sh`)

```
1. CLEANUP
   ├─► Uninstall existing Helm release
   ├─► Delete namespace
   └─► Recreate Kind cluster

2. IMAGE MANAGEMENT
   ├─► Authenticate with AWS ECR
   ├─► Pull latest image from ECR
   └─► Load image into Kind cluster

3. POSTGRESQL SETUP
   ├─► Pull PostgreSQL image
   └─► Load into Kind cluster

4. CONFIGURATION
   ├─► Update values file with image tag
   └─► Apply Kubernetes secrets and volumes

5. HELM INSTALLATION
   ├─► Install Airflow via Helm chart
   └─► Configure with custom values

6. DATABASE MIGRATION
   ├─► Wait for PostgreSQL readiness
   ├─► Run manual migration job
   └─► Create session table

7. POD RETENTION
   ├─► Configure Kubernetes executor settings
   └─► Disable pod deletion for debugging

8. VERIFICATION
   ├─► Wait for component readiness
   └─► Check pod status
```

### Configuration Management

#### **Helm Values Override** (`chart/values-override-with-persistence.yaml`)

```yaml
Key Configurations:
- Executor: KubernetesExecutor
- Image: ECR registry + timestamp tag
- PostgreSQL: bitnamilegacy/postgresql:14.10.0
- Logs: Persistent volume claim enabled
- DAGs: Git sync enabled from GitHub
- Pod retention: Disabled (for debugging)
- Workers: 0 replicas (tasks run as dynamic pods)
```

---

## Key Technologies & Versions

| Component | Version | Purpose |
|-----------|---------|---------|
| **Apache Airflow** | 3.0.2 | Workflow orchestration |
| **Helm Chart** | 1.18.0 | Airflow deployment |
| **Python** | 3.11 | Runtime environment |
| **PostgreSQL** | 14.10.0 | Metadata database |
| **Kubernetes** | 1.29.4 | Container orchestration |
| **Kind** | Latest | Local K8s cluster |
| **AWS ECR** | - | Container registry |
| **AWS S3** | - | Data storage |
| **Databricks** | - | Data processing |
| **Git Sync** | - | DAG synchronization |

---

## DAG Structure

### **DAG 1: `produce_data_asset`**

**Type**: Asset-producing DAG (Airflow 3.0 feature)  
**Schedule**: `@daily`  
**Function**: Data extraction and upload

**Tasks**:
1. Download Stack Exchange archive from archive.org
2. Extract XML files (Posts.xml, Users.xml)
3. Upload to S3 as raw data
4. Create/modify assets: `posts_asset`, `users_asset`

**Dependencies**:
- `requests` - HTTP downloads
- `py7zr` - Archive extraction
- `apache-airflow-providers-amazon` - S3 integration

### **DAG 2: `trigger_databricks_workflow_dag`**

**Type**: Asset-scheduled DAG  
**Schedule**: `(posts_asset & users_asset)` - Triggered when both assets update  
**Function**: Trigger downstream processing



**Tasks**:
1. `run_databricks_workflow` - Executes Databricks job ID `198061833260489`

**Dependencies**:
- `apache-airflow-providers-databricks` - Databricks integration
- Asset dependencies from `produce_data_assets.py`

---

## External Integrations

### **AWS Services**

1. **ECR (Elastic Container Registry)**
   - Stores custom Airflow Docker images
   - Registry: `032517660248.dkr.ecr.us-east-1.amazonaws.com`
   - Repository: `my-dags`

2. **S3 (Simple Storage Service)**
   - Storage for raw data files
   - Bucket: `data-platform-tutorial-nifesimi`
   - Path: `raw/Posts.xml`, `raw/Users.xml`
   - Connection: `aws_conn` (configured via Airflow connections)

### **Databricks**

- **Connection ID**: `databricks_conn`
- **Job ID**: `198061833260489`
- **Purpose**: Execute data processing workflows
- **Workflows**: 
  - Bronze layer ingestion
  - Silver layer transformation
  - Gold layer aggregation

### **GitHub**

- **Repository**: `nifesimii/Databrikcs-Airflow-Kuberntes_Project-`
- **Branch**: `master`
- **Purpose**: DAG version control and synchronization
- **Authentication**: Kubernetes secrets (base64 encoded)

---

## Data Pipeline (Medallion Architecture)

### **Bronze Layer** (Raw Data)
- **Source**: Archive.org Stack Exchange data
- **Format**: XML files
- **Storage**: S3 `raw/` directory
- **Processing**: Databricks notebooks (`bronze_posts.ipynb`, `bronze_users.ipynb`)

### **Silver Layer** (Cleaned Data)
- **Source**: Bronze layer tables
- **Processing**: Data cleaning, validation, schema enforcement
- **Notebooks**: `silver_posts.ipynb`
- **Output**: Cleaned, structured tables

### **Gold Layer** (Analytics)
- **Source**: Silver layer tables
- **Processing**: Aggregations, analytics, business metrics
- **Notebooks**: 
  - `gold_post_users.ipynb` - Post-user relationships
  - `gold_most_popular_tags.ipynb` - Tag popularity analysis
- **Output**: Business-ready analytics tables

---

## Operational Scripts

### **Installation & Deployment**
- `install-airflow-2-ecr.sh` - Complete installation with ECR integration
- `install-airflow-with-persistence.sh` - Installation with persistent volumes
- `install-airflow.sh` - Basic installation

### **Upgrade & Maintenance**
- `upgrade-dags.sh` - Quick DAG image rebuild and deployment
- `check-airflow-status.sh` - Health check script
- `complete-cleanup.sh` - Full environment cleanup

### **Debugging**
- `install-airflow-debug.sh` - Debug installation
- Diagnostic commands in `AIRFLOW_3_INSTALLATION_GUIDE.md`

---

## Security Configuration

### **Authentication**
- **Default User**: `admin` / `admin` (development only)
- **Session Storage**: PostgreSQL `session` table
- **Git Credentials**: Kubernetes secret `git-credentials`
- **AWS Credentials**: Airflow connection `aws_conn`
- **Databricks Credentials**: Airflow connection `databricks_conn`

### **Network Security**
- **Ingress**: Configured via Helm values
- **Network Policies**: Enabled in Airflow templates
- **Service Accounts**: Separate accounts per component

---

## Monitoring & Logging

### **Logging**
- **Storage**: Persistent Volume Claim (`airflow-logs-pvc`)
- **Path**: `/mnt/airflow-data/logs` (mounted to Kind cluster)
- **Access**: Via `kubectl logs` commands or Airflow UI

### **Metrics** (Optional)
- **StatsD**: Available but not configured
- **Prometheus**: Not enabled
- **Flower**: Not enabled (for Celery executor, not used here)

---

## Key Features

### **Airflow 3.0 Specific Features**
1. **Asset-Based Scheduling**: DAGs triggered by data asset updates
2. **Unified API Server**: Combined webserver + REST API
3. **Enhanced SDK**: Simplified DAG definition syntax
4. **Session Management**: Custom PostgreSQL session table

### **Kubernetes Executor Benefits**
1. **Resource Isolation**: Each task runs in its own pod
2. **Dynamic Scaling**: Pods created on-demand
3. **Pod Retention**: Failed pods retained for debugging
4. **Resource Limits**: Per-task resource allocation

### **GitOps Integration**
1. **Automatic DAG Sync**: Changes in Git automatically reflected
2. **Version Control**: Full DAG history in Git
3. **Collaboration**: Multiple developers can contribute

---

## Development Workflow

```
1. DEVELOPER MAKES CHANGES
   ├─► Edit DAG files in dags/ directory
   └─► Commit and push to GitHub

2. AUTOMATIC SYNC (if Git Sync enabled)
   └─► Git Sync sidecar updates DAGs

3. MANUAL UPGRADE (alternative)
   ├─► Run: ./upgrade-dags.sh
   ├─► Builds new Docker image
   ├─► Loads into Kind cluster
   └─► Upgrades Helm release

4. DAG DEPLOYMENT
   ├─► DAG Processor validates DAGs
   ├─► Scheduler picks up changes
   └─► Tasks execute as needed
```

---

## Production Considerations

### **Current State** (Development)
- No persistence for PostgreSQL (data lost on restart)
- No resource limits configured
- Default credentials in use
- Single-node Kind cluster
- No monitoring/metrics
- Pod retention enabled (for debugging)

### **Production Recommendations**
1. **Database**: External managed PostgreSQL with backups
2. **Image Registry**: Production ECR with proper access controls
3. **Secrets**: Kubernetes secrets for all credentials
4. **Monitoring**: Prometheus + Grafana integration
5. **Logging**: Centralized logging (CloudWatch, ELK, etc.)
6. **High Availability**: Multi-replica scheduler, API server
7. **Resource Limits**: CPU/memory limits per component
8. **Pod Cleanup**: Enable pod deletion for production
9. **DAG Versioning**: Use Git tags for DAG releases
10. **Backup**: Regular backups of PostgreSQL metadata

---

## Architecture Patterns

### **1. Medallion Architecture** (Data Lake)
- Bronze → Silver → Gold data layers
- Implemented in Databricks workflows

### **2. Event-Driven Orchestration**
- Asset-based scheduling triggers downstream DAGs
- Ensures data availability before processing

### **3. Containerized Execution**
- Kubernetes executor provides isolation
- Each task runs in dedicated container

### **4. Infrastructure as Code**
- Helm charts for declarative deployment
- Git-based configuration management

### **5. CI/CD Ready**
- Docker images built and pushed to ECR
- Automated deployment scripts
- Git-based DAG synchronization

---

## Summary

This system implements a **modern data orchestration platform** that:
- ✅ Orchestrates data extraction from external sources
- ✅ Stores raw data in cloud storage (S3)
- ✅ Triggers downstream processing (Databricks) based on data availability
- ✅ Uses Airflow 3.0's asset-based scheduling for event-driven workflows
- ✅ Leverages Kubernetes for scalable, isolated task execution
- ✅ Implements GitOps for DAG management
- ✅ Provides a complete local development environment

The architecture supports a **medallion data architecture** pattern, processing data through bronze → silver → gold layers in Databricks, all orchestrated by Airflow's intelligent scheduling system.

