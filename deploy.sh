#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Deploy Cosmos MSI Scale Test infrastructure and application to Azure.

Required Options:
    -s, --subscription-id ID        Azure subscription ID

Optional Options:
    -r, --resource-group NAME       Resource group name (default: cosmos-msi-scale-test-rg)
    -l, --location LOCATION         Azure location (default: eastus)
    -p, --prefix PREFIX             Resource name prefix (default: cosmosmsiscale)
    -n, --node-count COUNT          AKS node count (default: 3)
    -k, --k8s-only                  Deploy Kubernetes manifests only (skip ARM deployment)
    -h, --help                      Display this help message

Example:
    $0 --subscription-id "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    $0 -s "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -r my-rg -l westus2 -n 5
    $0 -s "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -k  # Deploy K8s only

EOF
    exit 1
}

# Parse command-line arguments
SUBSCRIPTION_ID=""
RESOURCE_GROUP="cosmos-msi-scale-test-rg"
LOCATION="eastus"
NAME_PREFIX="cosmosmsiscale"
NODE_COUNT=3
K8S_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--subscription-id)
            SUBSCRIPTION_ID="$2"
            shift 2
            ;;
        -r|--resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        -l|--location)
            LOCATION="$2"
            shift 2
            ;;
        -p|--prefix)
            NAME_PREFIX="$2"
            shift 2
            ;;
        -n|--node-count)
            NODE_COUNT="$2"
            shift 2
            ;;
        -k|--k8s-only)
            K8S_ONLY=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required arguments
if [ -z "$SUBSCRIPTION_ID" ]; then
    print_error "Subscription ID is required"
    usage
fi

# Check for required tools
print_info "Checking for required tools..."
REQUIRED_TOOLS=("az" "docker" "kubectl")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command_exists "$tool"; then
        print_error "$tool is not installed. Please install it and try again."
        exit 1
    fi
done

print_info "All required tools are installed."

# Set Azure subscription
print_info "Setting Azure subscription to $SUBSCRIPTION_ID..."
az account set --subscription "$SUBSCRIPTION_ID"

if [ "$K8S_ONLY" = true ]; then
    print_info "K8s-only mode: Skipping ARM deployment, retrieving existing resources..."
    
    # Get existing resource information
    print_info "Retrieving existing resources from resource group $RESOURCE_GROUP..."
    
    # Find ACR
    ACR_NAME=$(az acr list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv)
    if [ -z "$ACR_NAME" ]; then
        print_error "No ACR found in resource group $RESOURCE_GROUP"
        exit 1
    fi
    ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query "loginServer" -o tsv)
    
    # Find Cosmos DB account
    COSMOS_ACCOUNT_NAME=$(az cosmosdb list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv)
    if [ -z "$COSMOS_ACCOUNT_NAME" ]; then
        print_error "No Cosmos DB account found in resource group $RESOURCE_GROUP"
        exit 1
    fi
    COSMOS_ACCOUNT_URL="https://${COSMOS_ACCOUNT_NAME}.table.cosmos.azure.com"
    
    # Find AKS cluster
    AKS_CLUSTER_NAME=$(az aks list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv)
    if [ -z "$AKS_CLUSTER_NAME" ]; then
        print_error "No AKS cluster found in resource group $RESOURCE_GROUP"
        exit 1
    fi
    AKS_OIDC_ISSUER_URL=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" --query "oidcIssuerProfile.issuerUrl" -o tsv)
    
    # Find Managed Identity
    MANAGED_IDENTITY_NAME=$(az identity list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv)
    if [ -z "$MANAGED_IDENTITY_NAME" ]; then
        print_error "No Managed Identity found in resource group $RESOURCE_GROUP"
        exit 1
    fi
    MANAGED_IDENTITY_CLIENT_ID=$(az identity show --resource-group "$RESOURCE_GROUP" --name "$MANAGED_IDENTITY_NAME" --query "clientId" -o tsv)
    
    # Find Grafana
    GRAFANA_NAME=$(az grafana list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv)
    if [ -n "$GRAFANA_NAME" ]; then
        GRAFANA_URL=$(az grafana show --name "$GRAFANA_NAME" --resource-group "$RESOURCE_GROUP" --query "properties.endpoint" -o tsv)
    fi
    
    print_info "Retrieved existing resources:"
    print_info "ACR Name: $ACR_NAME"
    print_info "ACR Login Server: $ACR_LOGIN_SERVER"
    print_info "Cosmos Account: $COSMOS_ACCOUNT_NAME"
    print_info "AKS Cluster: $AKS_CLUSTER_NAME"
    print_info "Managed Identity: $MANAGED_IDENTITY_NAME"
    if [ -n "$GRAFANA_NAME" ]; then
        print_info "Grafana Name: $GRAFANA_NAME"
        print_info "Grafana URL: $GRAFANA_URL"
    fi
else
    # Create resource group
    print_info "Creating resource group $RESOURCE_GROUP in $LOCATION..."
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

    # Deploy infrastructure using Bicep
    print_info "Deploying Azure infrastructure..."
    DEPLOYMENT_OUTPUT=$(az deployment group create \
        --resource-group "$RESOURCE_GROUP" \
        --template-file infra/main.bicep \
        --parameters location="$LOCATION" namePrefix="$NAME_PREFIX" aksNodeCount="$NODE_COUNT" \
        --query properties.outputs \
        --output json)

    # Extract outputs
    ACR_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.acrName.value')
    ACR_LOGIN_SERVER=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.acrLoginServer.value')
    COSMOS_ACCOUNT_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.cosmosAccountName.value')
    COSMOS_ACCOUNT_URL=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.cosmosAccountUrl.value')
    AKS_CLUSTER_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.aksClusterName.value')
    MANAGED_IDENTITY_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.managedIdentityName.value')
    MANAGED_IDENTITY_CLIENT_ID=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.managedIdentityClientId.value')
    AKS_OIDC_ISSUER_URL=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.aksOidcIssuerUrl.value')
    GRAFANA_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.grafanaName.value')
    GRAFANA_URL=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.grafanaUrl.value')
    MONITOR_WORKSPACE_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.monitorWorkspaceName.value')

    print_info "Infrastructure deployed successfully!"
    print_info "ACR Name: $ACR_NAME"
    print_info "ACR Login Server: $ACR_LOGIN_SERVER"
    print_info "Cosmos Account: $COSMOS_ACCOUNT_NAME"
    print_info "AKS Cluster: $AKS_CLUSTER_NAME"
    print_info "Managed Identity: $MANAGED_IDENTITY_NAME"
    print_info "Grafana Name: $GRAFANA_NAME"
    print_info "Grafana URL: $GRAFANA_URL"

    # Build and push Docker image
    print_info "Building Docker image..."
    docker build -t cosmos-msi-scale-test:latest .

    print_info "Logging into ACR..."
    az acr login --name "$ACR_NAME"

    print_info "Tagging and pushing image to ACR..."
    docker tag cosmos-msi-scale-test:latest "$ACR_LOGIN_SERVER/cosmos-msi-scale-test:latest"
    docker push "$ACR_LOGIN_SERVER/cosmos-msi-scale-test:latest"

    print_info "Image pushed successfully!"
fi

# Get AKS credentials
print_info "Getting AKS credentials..."
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" --overwrite-existing

# Set up federated identity credential for workload identity
print_info "Setting up federated identity credential..."
az identity federated-credential create \
    --name "cosmos-msi-scale-test-federated-credential" \
    --identity-name "$MANAGED_IDENTITY_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --issuer "$AKS_OIDC_ISSUER_URL" \
    --subject "system:serviceaccount:default:cosmos-msi-sa" \
    --audience "api://AzureADTokenExchange" \
    --output none 2>/dev/null || print_warn "Federated credential may already exist"

# Deploy to Kubernetes
print_info "Deploying to Kubernetes..."
export ACR_LOGIN_SERVER
export COSMOS_ACCOUNT_URL
export MANAGED_IDENTITY_CLIENT_ID
envsubst < k8s/deployment.yaml | kubectl apply -f -

# Apply Prometheus scrape configuration
print_info "Applying Prometheus scrape configuration..."
kubectl apply -f k8s/prometheus-config.yaml

print_info "Waiting for pods to be ready..."
kubectl rollout status daemonset/cosmos-msi-scale-test --timeout=5m

print_info "Deployment completed successfully!"

# Display pod status
print_info "Pod status:"
kubectl get pods -l app=cosmos-msi-scale-test -o wide

# Display instructions for viewing metrics
if [ -n "$GRAFANA_URL" ]; then
cat << EOF

${GREEN}=== Deployment Complete ===${NC}

Azure Managed Grafana is available at:
    ${GRAFANA_URL}

The Grafana workspace is connected to Azure Monitor for Prometheus.
Metrics from the cosmos-msi-scale-test pods will automatically be scraped
and available in Grafana.

To access Grafana:
1. Navigate to: ${GRAFANA_URL}
2. Sign in with your Azure credentials
3. Create a new dashboard or explore metrics

Available metrics:
- cosmos_connection_success_total
- cosmos_auth_error_total  
- cosmos_other_error_total

To view metrics from the pods locally, you can use port-forward:

    kubectl port-forward service/cosmos-msi-scale-test-metrics 8080:8080

Then access metrics at: http://localhost:8080/metrics

To view logs from a pod:

    kubectl logs -l app=cosmos-msi-scale-test --tail=100 -f

To scale the AKS cluster:

    az aks scale --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME --node-count <desired-count>

To clean up resources:

    az group delete --name $RESOURCE_GROUP --yes --no-wait

EOF
else
cat << EOF

${GREEN}=== Deployment Complete ===${NC}

To view metrics from the pods, you can use port-forward:

    kubectl port-forward service/cosmos-msi-scale-test-metrics 8080:8080

Then access metrics at: http://localhost:8080/metrics

To view logs from a pod:

    kubectl logs -l app=cosmos-msi-scale-test --tail=100 -f

To scale the AKS cluster:

    az aks scale --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME --node-count <desired-count>

To clean up resources:

    az group delete --name $RESOURCE_GROUP --yes --no-wait

EOF
fi
