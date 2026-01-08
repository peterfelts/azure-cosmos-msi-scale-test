## Purpose
The goal of this project is to perform scale testing of Azure MSI-based authentication to an Azure Cosmos DB account.

## Quick Start

To deploy the complete solution to Azure:

```bash
./deploy.sh --subscription-id "your-subscription-id"
```

For detailed instructions, see [DEPLOYMENT.md](DEPLOYMENT.md).

## Architecture

- **Go Application**: Authenticates to Cosmos DB using Managed Identity and performs table operations
- **Azure Container Registry**: Stores the containerized application
- **Azure Cosmos DB**: Table API account for testing
- **AKS Cluster**: Runs the application with Azure Overlay Networking
- **Managed Identity**: Provides secure authentication
- **Prometheus Metrics**: Exposes success/failure metrics

## Requirements
- Go 1.23 or newer
- Docker
- Azure CLI (`az`)
- kubectl
- jq
- Active Azure subscription

## Key Features

- **MSI Authentication**: Uses Azure Managed Identity for secure, credential-less authentication
- **Scale Testing**: DaemonSet deployment ensures one pod per node for testing at scale
- **Metrics Collection**: Prometheus metrics track authentication success/failures
- **Automated Deployment**: Single command deploys all infrastructure and application
- **Production-Ready**: Includes health checks, resource limits, and proper error handling

## Metrics & Visualization

The application exposes these Prometheus metrics at `/metrics`:
- `cosmos_connection_success_total`: Successful Cosmos DB operations
- `cosmos_auth_error_total`: Authentication/authorization errors
- `cosmos_other_error_total`: Other errors

**Grafana Dashboard**: A pre-built dashboard (`grafana/dashboard.json`) is included with visualizations for:
- Aggregated success/auth-error/other-error counts
- Time series graphs of metrics over time
- Per-pod breakdowns for troubleshooting
- Rate calculations for performance monitoring

The dashboard is automatically imported to Azure Managed Grafana during deployment.

## Usage

### Deploy
```bash
./deploy.sh --subscription-id "your-subscription-id" \
  --resource-group "my-rg" \
  --location "westus2" \
  --node-count 5
```

### View Metrics
```bash
kubectl port-forward service/cosmos-msi-scale-test-metrics 8080:8080
# Access http://localhost:8080/metrics
```

### Scale
```bash
az aks scale --resource-group my-rg --name my-aks --node-count 10
```

### Cleanup
```bash
az group delete --name my-rg --yes
```

## Documentation

- [DEPLOYMENT.md](DEPLOYMENT.md) - Complete deployment guide
- [infra/main.bicep](infra/main.bicep) - Infrastructure as Code
- [k8s/deployment.yaml](k8s/deployment.yaml) - Kubernetes manifests

## Success Criteria
A wholistic view of how many pods received authentication errors when connecting with Cosmos can be viewed through the Prometheus metrics endpoint.

