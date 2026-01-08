# Azure Cosmos DB MSI Scale Test

## Purpose
This project performs scale testing of Azure Managed Service Identity (MSI) based authentication to an Azure Cosmos DB account. The application runs as a DaemonSet on an Azure Kubernetes Service (AKS) cluster, with one pod per node, allowing you to test authentication at scale.

## Architecture

### Components
1. **Go Application**: Authenticates to Cosmos DB using Managed Identity and performs table operations
2. **Azure Container Registry (ACR)**: Stores the containerized application
3. **Azure Cosmos DB**: Table API account for testing
4. **Azure Kubernetes Service (AKS)**: Runs the application with Azure Overlay Networking
5. **Managed Identity**: Provides authentication for pods to access Cosmos DB
6. **Prometheus Metrics**: Exposes success/failure metrics for monitoring
7. **Azure Monitor Workspace**: Collects Prometheus metrics from AKS
8. **Azure Managed Grafana**: Provides visualization and dashboards for metrics

### Metrics
The application exposes the following Prometheus metrics:
- `cosmos_connection_success_total`: Count of successful Cosmos DB operations
- `cosmos_auth_error_total`: Count of authentication/authorization errors
- `cosmos_other_error_total`: Count of other errors

These metrics are automatically scraped by Azure Monitor for Prometheus and can be visualized in Azure Managed Grafana.

## Prerequisites

### Required Tools
- Go 1.23 or newer
- Docker
- Azure CLI (`az`)
- kubectl
- jq (for JSON parsing in deployment script)

### Azure Subscription
You need an active Azure subscription with permissions to:
- Create resource groups
- Deploy Azure Container Registry
- Deploy Azure Cosmos DB accounts
- Deploy AKS clusters
- Create and manage managed identities
- Assign RBAC roles

## Getting Started

### 1. Build the Application Locally (Optional)

```bash
# Install dependencies
go mod download

# Build the binary
go build -o cosmos-msi-scale-test main.go

# Run locally (requires environment variables)
export COSMOS_ACCOUNT_URL="https://your-cosmos-account.table.cosmos.azure.com"
export TABLE_NAME="ScaleTestTable"
export METRICS_PORT="8080"
./cosmos-msi-scale-test
```

### 2. Deploy to Azure

The `deploy.sh` script automates the entire deployment process:

```bash
# Basic deployment
./deploy.sh --subscription-id "your-subscription-id"

# Custom deployment with options
./deploy.sh \
  --subscription-id "your-subscription-id" \
  --resource-group "my-rg" \
  --location "westus2" \
  --prefix "mytest" \
  --node-count 5

# Deploy only Kubernetes manifests (skip ARM deployment)
./deploy.sh \
  --subscription-id "your-subscription-id" \
  --resource-group "my-rg" \
  --k8s-only
```

#### Deployment Script Options
- `-s, --subscription-id`: Azure subscription ID (required)
- `-r, --resource-group`: Resource group name (default: cosmos-msi-scale-test-rg)
- `-l, --location`: Azure location (default: eastus)
- `-p, --prefix`: Resource name prefix (default: cosmosmsiscale)
- `-n, --node-count`: Initial AKS node count (default: 3)
- `-k, --k8s-only`: Deploy Kubernetes manifests only, skip ARM deployment (default: false)
- `-h, --help`: Display help message

#### Kubernetes-Only Deployment Mode

Use the `--k8s-only` flag when you want to update or redeploy the Kubernetes manifests without recreating Azure infrastructure:

**Use cases:**
- Updating application configuration (environment variables, resource limits, etc.)
- Redeploying after modifying the Kubernetes manifests
- Testing different DaemonSet configurations
- Updating the application after a new Docker image has been pushed manually

**What it does:**
- Retrieves information from existing Azure resources (ACR, Cosmos DB, AKS, Managed Identity)
- Skips ARM/Bicep deployment
- Skips Docker build and push
- Gets AKS credentials and deploys/updates Kubernetes manifests
- Sets up federated identity credential (if not already exists)

**Important:** The resource group must already exist with all required resources deployed.

### What the Deployment Script Does

**Full Deployment Mode (default):**
1. **Validates Prerequisites**: Checks for required tools (az, docker, kubectl)
2. **Creates Resource Group**: Sets up Azure resource group
3. **Deploys Infrastructure**: Uses Bicep to provision:
   - Azure Container Registry
   - Azure Cosmos DB account with Table API
   - AKS cluster with Azure Overlay Networking and Workload Identity
   - User-assigned Managed Identity
   - RBAC role assignments
4. **Builds and Pushes Container**: Builds Docker image and pushes to ACR
5. **Configures Workload Identity**: Sets up federated identity credential
6. **Deploys to Kubernetes**: Applies DaemonSet configuration
7. **Verifies Deployment**: Checks pod status

**Kubernetes-Only Mode (`--k8s-only`):**
1. **Validates Prerequisites**: Checks for required tools
2. **Retrieves Resources**: Gets information from existing Azure resources
3. **Configures Workload Identity**: Sets up federated identity credential (if needed)
4. **Deploys to Kubernetes**: Applies DaemonSet configuration
5. **Verifies Deployment**: Checks pod status

## Viewing Metrics

### Azure Managed Grafana (Recommended)

After deployment, metrics are automatically collected by Azure Monitor for Prometheus and available in Azure Managed Grafana.

**Access Grafana:**
1. The deployment script outputs the Grafana URL
2. Navigate to the URL in your browser
3. Sign in with your Azure credentials
4. You'll have access to the Grafana workspace

**Create a Dashboard:**
1. In Grafana, click "+" and select "Dashboard"
2. Add a new panel
3. Select "Prometheus" as the data source
4. Use PromQL queries to visualize metrics:
   ```promql
   # Total successful connections
   cosmos_connection_success_total
   
   # Rate of successful connections per second
   rate(cosmos_connection_success_total[5m])
   
   # Authentication errors
   cosmos_auth_error_total
   
   # Error rate
   rate(cosmos_auth_error_total[5m])
   ```

**Viewing All Metrics:**
- In Grafana, go to "Explore"
- Select the Prometheus data source
- Use the metrics browser to discover available metrics
- Metrics from all pods are automatically aggregated

### Local Port Forward (Alternative)

For quick local access to raw metrics:

```bash
kubectl port-forward service/cosmos-msi-scale-test-metrics 8080:8080
```

Then access metrics at: http://localhost:8080/metrics

### View Logs
```bash
# View logs from all pods
kubectl logs -l app=cosmos-msi-scale-test --tail=100 -f

# View logs from specific pod
kubectl logs <pod-name>
```

### Check Pod Status
```bash
kubectl get pods -l app=cosmos-msi-scale-test -o wide
```

## Scaling the Cluster

To test at different scales, adjust the AKS node count:

```bash
# Scale to 10 nodes
az aks scale \
  --resource-group cosmos-msi-scale-test-rg \
  --name cosmosmsiscale-aks \
  --node-count 10

# Wait for new pods to be scheduled
kubectl rollout status daemonset/cosmos-msi-scale-test
```

Since the application runs as a DaemonSet, scaling the cluster will automatically adjust the number of test pods (one per node).

## Understanding the Results

### Successful Operation
When a pod successfully authenticates and creates/verifies the table:
- `cosmos_connection_success_total` counter increments
- Pod logs show: "Successfully performed Cosmos operation"

### Authentication Error
When MSI authentication fails:
- `cosmos_auth_error_total` counter increments
- Pod logs show the authentication error details

### Other Errors
For any other errors (network, configuration, etc.):
- `cosmos_other_error_total` counter increments
- Pod logs show the error details

## Troubleshooting

### Pods Not Starting
```bash
# Check pod status
kubectl describe pod -l app=cosmos-msi-scale-test

# Check events
kubectl get events --sort-by='.lastTimestamp'
```

### Authentication Failures
1. Verify workload identity is enabled:
   ```bash
   az aks show --resource-group <rg> --name <aks-name> --query "oidcIssuerProfile"
   ```

2. Check federated credential:
   ```bash
   az identity federated-credential list \
     --identity-name <identity-name> \
     --resource-group <rg>
   ```

3. Verify RBAC assignment on Cosmos DB:
   ```bash
   az role assignment list --scope <cosmos-account-id>
   ```

### Image Pull Errors
```bash
# Verify ACR access
az aks check-acr \
  --resource-group <rg> \
  --name <aks-name> \
  --acr <acr-name>
```

## Cleanup

To delete all resources:

```bash
az group delete --name cosmos-msi-scale-test-rg --yes --no-wait
```

## Architecture Details

### Networking
- **Azure Overlay Networking**: Provides efficient pod networking without consuming VNet IP addresses
- **Pod CIDR**: 10.244.0.0/16
- **Service CIDR**: 10.0.0.0/16

### Security
- **Workload Identity**: Uses Azure AD Workload Identity for pod authentication
- **No Admin Credentials**: ACR admin user is disabled, using RBAC instead
- **Managed Identity**: User-assigned identity with minimal required permissions

### High Availability
- **DaemonSet**: Ensures one pod per node
- **Liveness/Readiness Probes**: Kubernetes health checks
- **Resource Limits**: Prevents resource exhaustion

## Development

### Project Structure
```
.
├── main.go              # Application source code
├── go.mod               # Go module definition
├── go.sum               # Go dependencies
├── Dockerfile           # Container image definition
├── deploy.sh            # Deployment automation script
├── infra/
│   └── main.bicep      # Azure infrastructure definition
├── k8s/
│   └── deployment.yaml  # Kubernetes manifests
└── README.md           # This file
```

### Building Locally
```bash
# Build for local testing
go build -o cosmos-msi-scale-test main.go

# Build Docker image
docker build -t cosmos-msi-scale-test:latest .
```

### Running Tests
```bash
# Run Go tests (if any exist)
go test ./...
```

## Contributing

When making changes:
1. Test locally before deploying
2. Update documentation as needed
3. Follow Go best practices
4. Ensure Docker image builds successfully

## License

This project is provided as-is for testing purposes.
