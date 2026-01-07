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
    -h, --help                      Display this help message

Example:
    $0 --subscription-id "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    $0 -s "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -r my-rg -l westus2 -n 5

EOF
    exit 1
}

# Parse command-line arguments
SUBSCRIPTION_ID=""
RESOURCE_GROUP="cosmos-msi-scale-test-rg"
LOCATION="eastus"
NAME_PREFIX="cosmosmsiscale"
NODE_COUNT=3

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

print_info "Infrastructure deployed successfully!"
print_info "ACR Name: $ACR_NAME"
print_info "ACR Login Server: $ACR_LOGIN_SERVER"
print_info "Cosmos Account: $COSMOS_ACCOUNT_NAME"
print_info "AKS Cluster: $AKS_CLUSTER_NAME"
print_info "Managed Identity: $MANAGED_IDENTITY_NAME"

# Build and push Docker image
print_info "Building Docker image..."
docker build -t cosmos-msi-scale-test:latest .

print_info "Logging into ACR..."
az acr login --name "$ACR_NAME"

print_info "Tagging and pushing image to ACR..."
docker tag cosmos-msi-scale-test:latest "$ACR_LOGIN_SERVER/cosmos-msi-scale-test:latest"
docker push "$ACR_LOGIN_SERVER/cosmos-msi-scale-test:latest"

print_info "Image pushed successfully!"

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
envsubst < k8s/deployment.yaml | kubectl apply -f -

print_info "Waiting for pods to be ready..."
kubectl rollout status daemonset/cosmos-msi-scale-test --timeout=5m

print_info "Deployment completed successfully!"

# Display pod status
print_info "Pod status:"
kubectl get pods -l app=cosmos-msi-scale-test -o wide

# Display instructions for viewing metrics
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
