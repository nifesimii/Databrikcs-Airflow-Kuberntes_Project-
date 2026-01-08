# Data Orchestration Platform: Airflow 3.0.2 on Kubernetes

> **Project Review**: A well-architected data orchestration platform demonstrating modern data engineering practices with Apache Airflow 3.0.2, Kubernetes, and event-driven workflows.

---

## 🎯 Executive Summary

This project implements a **production-grade data orchestration platform** that orchestrates end-to-end data pipelines from external sources (Stack Exchange archives) through cloud storage (AWS S3) to data processing (Databricks). The architecture leverages Airflow 3.0's cutting-edge **asset-based scheduling** features, demonstrating a mature understanding of modern data engineering patterns.

**Key Strengths:**
- ✅ **Modern Tech Stack**: Airflow 3.0.2 with Kubernetes Executor shows awareness of latest platform capabilities
- ✅ **Event-Driven Architecture**: Asset-based scheduling ensures data availability before downstream processing
- ✅ **Medallion Architecture**: Properly implements Bronze → Silver → Gold data layers
- ✅ **Infrastructure as Code**: Helm charts and automated deployment scripts
- ✅ **GitOps Integration**: Automatic DAG synchronization from GitHub
- ✅ **Comprehensive Documentation**: Extensive troubleshooting guide shows production experience

**Areas for Enhancement:**
- ⚠️ **Production Hardening**: Database persistence, resource limits, and monitoring need attention
- ⚠️ **Security**: Default credentials and secret management require production-grade implementation
- ⚠️ **Observability**: Metrics and centralized logging should be added for production use
- ⚠️ **Testing**: Unit tests and integration tests for DAGs would strengthen reliability

---

## 🏗️ Architecture Overview

### System Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                    DATA ORCHESTRATION PLATFORM                    │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐         ┌──────────────┐                      │
│  │ API Server   │◄───────►│  Scheduler   │                      │
│  │ (Airflow 3.0)│         │              │                      │
│  └──────┬───────┘         └──────┬───────┘                      │
│         │                        │                               │
│         ▼                        ▼                               │
│  ┌──────────────────────────────────────────────┐               │
│  │       Kubernetes Executor                     │               │
│  │  • Dynamic pod creation per task              │               │
│  │  • Isolated execution environments            │               │
│  └──────────────────────────────────────────────┘               │
│                                                                  │
│  ┌──────────────────────────────────────────────┐               │
│  │       PostgreSQL Database                     │               │
│  │  • Metadata & execution history               │               │
│  └──────────────────────────────────────────────┘               │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Data Pipeline Flow

```
1. DATA EXTRACTION (produce_data_asset DAG)
   Archive.org → Extract XML → Upload to S3 → Create Assets
   
2. ASSET-BASED TRIGGERING (Airflow 3.0 Feature)
   Both assets updated → trigger_databricks_workflow_dag scheduled
   
3. DATABRICKS PROCESSING
   Workflow executes → Bronze → Silver → Gold transformations
   ![Databricks-Workflows](diagrams/Databricks-Workflow.png)




```

For detailed architecture documentation, see [SYSTEM_ARCHITECTURE.md](SYSTEM_ARCHITECTURE.md).

---

## 🚀 Quick Start

### Prerequisites

```bash
# Required tools
- Docker Desktop (running)
- Kind (Kubernetes in Docker)
- kubectl (v1.29+)
- Helm 3.x
- AWS CLI (configured with ECR access)
```

### Installation

#### Option 1: ECR-Based Installation (Recommended)

```bash
# Clone repository
git clone https://github.com/nifesimii/Databrikcs-Airflow-Kuberntes_Project-.git
cd Databrikcs-Airflow-Kuberntes_Project

# Ensure AWS credentials are configured
aws configure

# Run installation script
chmod +x install-airflow-2-ecr.sh
./install-airflow-2-ecr.sh
```

#### Option 2: Local Build Installation

```bash
# Build and deploy locally
chmod +x install-airflow.sh
./install-airflow.sh
```

### Access Airflow UI

```bash
# Port forward API server
kubectl port-forward -n airflow svc/airflow-api-server 8080:8080

# Access in browser
# URL: http://localhost:8080
# Username: admin
# Password: admin
```

---

## 📋 Project Structure

```
.
├── cicd/
│   └── Dockerfile              # Custom Airflow image with DAGs
├── chart/
│   └── values-override-with-persistence.yaml  # Helm configuration
├── config/
│   └── airflow_local_settings.py  # Airflow 3.0 compatibility config
├── dags/
│   ├── produce_data_assets.py          # Data extraction DAG
│   └── trigger_databricks_workflow_dag.py  # Downstream processing
├── k8s/
│   ├── clusters/               # Kind cluster configuration
│   ├── secrets/                # Kubernetes secrets
│   └── volumes/                # Persistent volume definitions
├── notebooks/                  # Databricks notebooks (bronze/silver/gold)
├── install-airflow-2-ecr.sh   # Main installation script
├── upgrade-dags.sh            # Quick DAG upgrade script
├── check-airflow-status.sh    # Health check utility
└── SYSTEM_ARCHITECTURE.md     # Detailed architecture documentation
```

---

## 🔄 Data Pipeline

### DAG 1: `produce_data_asset`

**Purpose**: Extract and load raw data from Stack Exchange archives

**Schedule**: `@daily`

**Process**:
1. Downloads `ai.meta.stackexchange.com.7z` from archive.org
2. Extracts `Posts.xml` and `Users.xml` files
3. Uploads to S3: `s3://data-platform-tutorial-nifesimi/raw/`
4. Creates/modifies Airflow assets: `posts_asset`, `users_asset`

**Technologies**:
- `requests` - HTTP client
- `py7zr` - Archive extraction
- `apache-airflow-providers-amazon` - S3 integration

### DAG 2: `trigger_databricks_workflow_dag`

**Purpose**: Trigger downstream data processing workflows

**Schedule**: Asset-based `(posts_asset & users_asset)` - Triggered when both assets are updated

**Process**:
1. Waits for both `posts_asset` and `users_asset` to be updated
2. Triggers Databricks job (ID: `198061833260489`)
3. Executes medallion architecture transformations:
   - **Bronze**: Raw XML ingestion
   - **Silver**: Cleaned and validated data
   - **Gold**: Analytics and aggregations

**Technologies**:
- `apache-airflow-providers-databricks` - Databricks integration
- Airflow 3.0 Asset-based scheduling

---

## 🎓 Architecture Highlights

### What I Like (Senior Engineer Perspective)

#### 1. **Modern Airflow 3.0 Adoption**
Using Airflow 3.0.2's **asset-based scheduling** is a sophisticated choice. This feature enables true event-driven workflows where DAGs are triggered by data availability, not just time. This demonstrates understanding of modern data engineering patterns beyond simple cron-based scheduling.

**Code Example:**
```python
# Asset-based scheduling - only runs when data is ready
schedule = (posts_asset & users_asset)
```

#### 2. **Kubernetes Executor Implementation**
The Kubernetes Executor provides excellent isolation and scalability. Each task runs in its own pod, allowing for:
- Resource isolation per task
- Dynamic scaling based on workload
- Easier debugging (pods retained for inspection)

#### 3. **Medallion Architecture**
Proper implementation of the medallion (bronze/silver/gold) architecture pattern shows architectural maturity. This pattern is widely recognized as a best practice for data lakehouse implementations.

#### 4. **Infrastructure as Code**
Using Helm charts for deployment with versioned configuration files demonstrates DevOps best practices. The automated installation scripts show operational maturity.

#### 5. **Comprehensive Documentation**
The `AIRFLOW_3_INSTALLATION_GUIDE.md` and `SYSTEM_ARCHITECTURE.md` show production experience. Troubleshooting guides and error post-mortems are invaluable for operations teams.

### Areas for Improvement

#### 1. **Production Hardening** ⚠️

**Current State (Development)**:
```yaml
postgresql:
  primary:
    persistence:
      enabled: false  # ❌ Data lost on restart
```

**Recommendation**:
```yaml
postgresql:
  primary:
    persistence:
      enabled: true
      size: 20Gi
      storageClassName: standard-ssd
```

#### 2. **Resource Management** ⚠️

**Missing**: Resource requests/limits for components

**Recommendation**:
```yaml
scheduler:
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 2000m
      memory: 4Gi
```

#### 3. **Security** ⚠️

**Current**: Default credentials (`admin/admin`)

**Recommendation**:
- Use Kubernetes secrets for all credentials
- Implement OIDC/RBAC for production
- Rotate secrets regularly
- Use AWS Secrets Manager for external credentials

#### 4. **Observability** ⚠️

**Missing**: Metrics and centralized logging

**Recommendation**:
```yaml
# Enable StatsD metrics
config:
  metrics:
    statsd_on: true
    statsd_host: prometheus-statsd-exporter
    statsd_port: 9125

# Add Prometheus serviceMonitor
# Implement centralized logging (CloudWatch/ELK)
```

#### 5. **Testing** ⚠️

**Recommendation**: Add DAG validation tests

```python
# tests/test_dags.py
from airflow.models import DagBag

def test_dags_load():
    dag_bag = DagBag()
    assert len(dag_bag.import_errors) == 0, "No Import Failures"

def test_dag_structure():
    dag_bag = DagBag()
    for dag_id, dag in dag_bag.dags.items():
        assert len(dag.tasks) > 0, f"{dag_id} has no tasks"
```

---

## 🛠️ Development Workflow

### Making DAG Changes

#### Method 1: Git Sync (Automatic)
```bash
# 1. Edit DAG files
vim dags/produce_data_assets.py

# 2. Commit and push
git add dags/
git commit -m "Update data extraction logic"
git push origin master

# 3. Git Sync automatically updates DAGs in Airflow
# (No manual intervention needed)
```

#### Method 2: Manual Upgrade (Fast Iteration)
```bash
# Quick rebuild and deploy
./upgrade-dags.sh

# This script:
# 1. Builds new Docker image
# 2. Loads into Kind cluster
# 3. Upgrades Helm release
# 4. Restarts Airflow components
```

### Building Custom Docker Images

```bash
# Build image
docker build -t my-dags:latest -f cicd/Dockerfile .

# Tag for ECR
docker tag my-dags:latest \
  032517660248.dkr.ecr.us-east-1.amazonaws.com/my-dags:latest

# Push to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  032517660248.dkr.ecr.us-east-1.amazonaws.com

docker push 032517660248.dkr.ecr.us-east-1.amazonaws.com/my-dags:latest
```

---

## 🔍 Monitoring & Operations

### Health Checks

```bash
# Check Airflow status
./check-airflow-status.sh

# View pod status
kubectl get pods -n airflow

# View logs
kubectl logs -n airflow -l component=scheduler -c scheduler -f
```

### Common Operations

#### Trigger a DAG
```bash
kubectl exec -n airflow deploy/airflow-scheduler -c scheduler -- \
  airflow dags trigger produce_data_asset
```

#### List DAGs
```bash
kubectl exec -n airflow deploy/airflow-scheduler -c scheduler -- \
  airflow dags list
```

#### View Task Logs
```bash
# Via kubectl
kubectl logs -n airflow <task-pod-name> -c base

# Via Airflow UI
# Navigate to DAG → Task → Logs
```

#### Add AWS Connection
```bash
kubectl exec -n airflow deploy/airflow-scheduler -c scheduler -- \
  airflow connections add aws_conn \
    --conn-type aws \
    --conn-extra '{"region_name":"us-east-1"}'
```

---

## 🧪 Testing & Validation

### DAG Validation

```bash
# Validate DAG syntax
kubectl exec -n airflow deploy/airflow-scheduler -c scheduler -- \
  airflow dags list-import-errors

# Check DAG structure
kubectl exec -n airflow deploy/airflow-scheduler -c scheduler -- \
  airflow dags show produce_data_asset
```

### Integration Testing

```python
# Example: Test asset creation
from airflow.models import DagRun
from airflow.utils.state import DagRunType

def test_produce_data_asset():
    dag = dag_bag.get_dag('produce_data_asset')
    dagrun = dag.create_dagrun(
        run_type=DagRunType.MANUAL,
        execution_date=datetime.now()
    )
    # Validate asset creation
    assert dagrun.state == 'running'
```

---

## 📚 Documentation

- **[SYSTEM_ARCHITECTURE.md](SYSTEM_ARCHITECTURE.md)** - Comprehensive architecture documentation
- **[AIRFLOW_3_INSTALLATION_GUIDE.md](AIRFLOW_3_INSTALLATION_GUIDE.md)** - Detailed installation and troubleshooting guide

---

## 🔐 Security Considerations

### Current Security Posture (Development)

- ⚠️ Default credentials in use
- ⚠️ Secrets stored as base64-encoded Kubernetes secrets
- ⚠️ No network policies enforced
- ⚠️ Pod retention enabled (for debugging)

### Production Security Checklist

- [ ] Replace default admin credentials
- [ ] Use AWS Secrets Manager for sensitive data
- [ ] Implement RBAC with OIDC integration
- [ ] Enable network policies
- [ ] Use least-privilege service accounts
- [ ] Enable pod security policies
- [ ] Encrypt secrets at rest
- [ ] Enable audit logging
- [ ] Regular security scanning of images

---

## 🚢 Production Readiness

### Current State: **Development/Staging Ready**

This platform is well-architected for development and staging environments. For production deployment, consider:

### Production Deployment Checklist

#### Infrastructure
- [ ] Use managed PostgreSQL (RDS/Aurora) with automated backups
- [ ] Deploy on production Kubernetes cluster (EKS/GKE/AKS)
- [ ] Enable high availability (multi-replica scheduler, API server)
- [ ] Configure resource quotas and limits
- [ ] Set up autoscaling policies

#### Monitoring & Observability
- [ ] Integrate Prometheus + Grafana for metrics
- [ ] Centralized logging (CloudWatch Logs, ELK, Splunk)
- [ ] Set up alerting (PagerDuty, Slack, email)
- [ ] Configure APM tracing (Datadog, New Relic)

#### CI/CD
- [ ] Automated testing pipeline
- [ ] Image scanning and vulnerability checks
- [ ] Automated deployment via GitOps (ArgoCD, Flux)
- [ ] Rollback procedures

#### Disaster Recovery
- [ ] Database backup and restore procedures
- [ ] DAG versioning and rollback capability
- [ ] Cross-region failover plan
- [ ] Recovery time objective (RTO) < 4 hours
- [ ] Recovery point objective (RPO) < 1 hour

---

## 🐛 Troubleshooting

### Common Issues

#### Pods Stuck in Init:CrashLoopBackOff
```bash
# Check init container logs
kubectl logs -n airflow <pod-name> -c wait-for-airflow-migrations

# Verify database migration completed
kubectl exec -n airflow airflow-postgresql-0 -- \
  env PGPASSWORD=postgres psql -U postgres -d postgres \
  -c "SELECT * FROM alembic_version;"
```

#### DAGs Not Appearing
```bash
# Check DAG processor logs
kubectl logs -n airflow -l component=dag-processor

# Verify DAGs in image
kubectl exec -n airflow deploy/airflow-scheduler -c scheduler -- \
  ls -la /opt/airflow/dags/

# Check import errors
kubectl exec -n airflow deploy/airflow-scheduler -c scheduler -- \
  airflow dags list-import-errors
```

#### Image Pull Errors
```bash
# Verify image in cluster
docker exec kind-control-plane crictl images | grep my-dags

# Reload image
kind load docker-image my-dags:latest --name kind
```

For detailed troubleshooting, see [AIRFLOW_3_INSTALLATION_GUIDE.md](AIRFLOW_3_INSTALLATION_GUIDE.md).

---

## 🤝 Contributing

### Development Guidelines

1. **DAG Development**:
   - Follow Airflow best practices
   - Use asset-based scheduling where appropriate
   - Include error handling and retries
   - Add docstrings and comments

2. **Code Style**:
   - Follow PEP 8 for Python code
   - Use meaningful variable names
   - Add type hints where possible

3. **Testing**:
   - Validate DAGs before committing
   - Test locally before pushing
   - Document any breaking changes

4. **Documentation**:
   - Update README for new features
   - Add comments to complex logic
   - Document DAG dependencies

---

## 📊 Technology Stack

| Component | Version | Purpose |
|-----------|---------|---------|
| Apache Airflow | 3.0.2 | Workflow orchestration |
| Helm Chart | 1.18.0 | Airflow deployment |
| Python | 3.11 | Runtime environment |
| PostgreSQL | 14.10.0 | Metadata database |
| Kubernetes | 1.29.4 | Container orchestration |
| Kind | Latest | Local K8s cluster |
| AWS ECR | - | Container registry |
| AWS S3 | - | Data storage |
| Databricks | - | Data processing |

---

## 📝 License

[Specify your license here]

---

## 🙏 Acknowledgments

This project demonstrates modern data engineering practices with:
- Apache Airflow community for excellent orchestration platform
- Kubernetes community for container orchestration
- Databricks for data processing capabilities

---

## 📧 Contact

For questions or contributions, please open an issue or contact the maintainers.

---

## 📌 Final Notes (Senior Engineer Review)

### Overall Assessment: **Strong Foundation with Room for Production Enhancement**

This is a **well-designed project** that demonstrates:
- ✅ Strong understanding of modern data engineering patterns
- ✅ Good architectural decisions (asset-based scheduling, Kubernetes executor)
- ✅ Operational awareness (comprehensive documentation, automation)
- ✅ Production-minded approach (GitOps, IaC, versioning)

**Recommendation**: This platform is **ready for staging deployment** with minor enhancements. For production, prioritize:
1. Database persistence and backups
2. Monitoring and alerting
3. Security hardening
4. Resource management
5. Testing framework

**Key Differentiator**: The use of Airflow 3.0's asset-based scheduling shows forward-thinking and understanding of event-driven data engineering, which is a significant advantage over traditional time-based scheduling.

**Next Steps**:
1. Implement production checklist items
2. Add comprehensive test coverage
3. Set up CI/CD pipeline
4. Deploy to staging environment
5. Conduct load testing
6. Prepare production runbook

Well done on building a solid, modern data orchestration platform! 🚀

