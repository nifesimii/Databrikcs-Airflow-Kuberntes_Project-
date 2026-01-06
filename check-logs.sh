#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         DETAILED GIT-SYNC DIAGNOSTICS                     ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"

# Get pod names
TRIGGERER_POD="airflow-triggerer-0"
DAG_POD=$(kubectl get pod -n airflow -l component=dag-processor -o jsonpath='{.items[0].metadata.name}')

echo -e "\n${YELLOW}━━━ TRIGGERER POD LOGS ━━━${NC}"
echo -e "${BLUE}Full git-sync-init logs:${NC}"
kubectl logs -n airflow $TRIGGERER_POD -c git-sync-init 2>&1 || echo "No logs yet"

echo -e "\n${YELLOW}━━━ DAG PROCESSOR POD LOGS ━━━${NC}"
echo -e "${BLUE}Full git-sync-init logs:${NC}"
kubectl logs -n airflow $DAG_POD -c git-sync-init 2>&1 || echo "No logs yet"

echo -e "\n${YELLOW}━━━ POD DESCRIPTIONS ━━━${NC}"
echo -e "${BLUE}Triggerer Events:${NC}"
kubectl describe pod -n airflow $TRIGGERER_POD | grep -A 15 "Events:"

echo -e "\n${BLUE}DAG Processor Events:${NC}"
kubectl describe pod -n airflow $DAG_POD | grep -A 15 "Events:"

echo -e "\n${YELLOW}━━━ SECRET CONFIGURATION ━━━${NC}"
if kubectl get secret git-credentials -n airflow &>/dev/null; then
    echo -e "${GREEN}✓ Secret exists${NC}"
    echo -e "${BLUE}Secret keys:${NC}"
    kubectl get secret git-credentials -n airflow -o jsonpath='{.data}' | jq 'keys' 2>/dev/null || echo "  Unable to parse"
else
    echo -e "${RED}✗ Secret 'git-credentials' not found${NC}"
fi

echo -e "\n${YELLOW}━━━ CURRENT VALUES FILE ━━━${NC}"
echo -e "${BLUE}GitSync configuration:${NC}"
grep -A 7 "gitSync:" chart/values-override.yaml 2>/dev/null || echo "  values-override.yaml not found"

echo -e "\n${YELLOW}━━━ TEST GIT CONNECTIVITY ━━━${NC}"
echo "Testing GitHub connectivity from cluster..."
kubectl run test-git -n airflow --image=alpine/git --rm -it --restart=Never --command -- \
  sh -c "git ls-remote https://github.com/nifesimii/Databrikcs-Airflow-Kuberntes_Project-.git 2>&1 | head -10" 2>&1

echo -e "\n${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              DIAGNOSIS COMPLETE                           ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
