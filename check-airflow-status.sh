#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NAMESPACE="airflow"

echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}   AIRFLOW 3.0.2 STATUS CHECK${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

# Check namespace exists
if ! kubectl get namespace ${NAMESPACE} &> /dev/null; then
    echo -e "${RED}✗ Namespace '${NAMESPACE}' not found${NC}"
    echo "Run: ./install-airflow-3-FINAL-PERFECT.sh"
    exit 1
fi

# Component status
echo -e "${YELLOW}Component Status:${NC}"
COMPONENTS=("scheduler" "api-server" "triggerer" "dag-processor" "statsd")

for comp in "${COMPONENTS[@]}"; do
    STATUS=$(kubectl get pods -n ${NAMESPACE} -l component=${comp} -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    READY=$(kubectl get pods -n ${NAMESPACE} -l component=${comp} -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
    
    if [ "$STATUS" = "Running" ] && [ "$READY" = "true" ]; then
        echo -e "  ${GREEN}✓${NC} ${comp}"
    elif [ "$STATUS" = "Running" ]; then
        echo -e "  ${YELLOW}⚠${NC} ${comp} (not ready)"
    else
        echo -e "  ${RED}✗${NC} ${comp} (${STATUS})"
    fi
done

# Database status
DB_STATUS=$(kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [ "$DB_STATUS" = "Running" ]; then
    echo -e "  ${GREEN}✓${NC} postgresql"
else
    echo -e "  ${RED}✗${NC} postgresql (${DB_STATUS})"
fi

echo ""
echo -e "${YELLOW}All Pods:${NC}"
kubectl get pods -n ${NAMESPACE}

echo ""
echo -e "${YELLOW}Services:${NC}"
kubectl get svc -n ${NAMESPACE}

echo ""
echo -e "${YELLOW}Access Airflow:${NC}"
echo "  kubectl port-forward -n airflow svc/airflow-api-server 8080:8080"
echo "  Then open: http://localhost:8080"

