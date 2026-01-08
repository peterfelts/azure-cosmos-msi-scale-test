# Cosmos MSI Scale Test - Grafana Dashboard

This directory contains the Grafana dashboard configuration for visualizing Cosmos MSI scale test metrics.

## Dashboard Overview

The **Cosmos MSI Scale Test** dashboard provides comprehensive visualizations of metrics emitted by the DaemonSet pods running in your AKS cluster.

### Dashboard Panels

1. **Total Successful Connections** (Stat)
   - Aggregated count of all successful Cosmos DB operations across all pods
   - Green indicator

2. **Total Auth Errors** (Stat)
   - Aggregated count of authentication/authorization errors (HTTP 401/403)
   - Red indicator

3. **Total Other Errors** (Stat)
   - Aggregated count of other errors (credential setup, service client creation)
   - Orange indicator

4. **Aggregated Metrics Over Time** (Time Series)
   - Line graph showing all three metrics over time
   - Color-coded: Success (green), Auth Errors (red), Other Errors (orange)
   - Shows last value and mean in legend

5. **Success Rate by Pod** (Time Series)
   - 5-minute rate of successful connections per pod
   - Allows identification of pods with performance issues

6. **Auth Error Rate by Pod** (Time Series)
   - 5-minute rate of authentication errors per pod
   - Helps identify authentication problems on specific nodes

7. **Metrics by Pod** (Table)
   - Current metric values for each pod
   - Color-coded cells for easy identification of issues
   - Columns: Pod, Success, Auth Errors, Other Errors

### Features

- **Auto-refresh**: Dashboard refreshes every 30 seconds
- **Data source selector**: Choose the appropriate Prometheus data source
- **Time range selector**: Default shows last 1 hour, customizable
- **Tags**: `cosmos`, `msi`, `scale-test` for easy discovery

## Importing the Dashboard

### Automatic Import (via deployment script)

The dashboard is automatically created when you deploy using `deploy.sh`. The script will:
1. Create the Grafana workspace
2. Import the dashboard JSON
3. Display the Grafana URL

### Manual Import

If you need to manually import or update the dashboard:

1. Access your Azure Managed Grafana workspace
2. Navigate to **Dashboards** → **Import**
3. Click **Upload JSON file**
4. Select `dashboard.json` from this directory
5. Select your Prometheus data source (Azure Monitor managed service for Prometheus)
6. Click **Import**

## Customization

The dashboard is fully customizable. You can:
- Add additional panels for custom queries
- Modify existing visualizations
- Change colors, thresholds, and display options
- Export your customized dashboard and save it back to this directory

## PromQL Queries Used

The dashboard uses these PromQL queries:

- **Total aggregation**: `sum(cosmos_connection_success_total)`
- **Rate calculation**: `rate(cosmos_connection_success_total[5m])`
- **Per-pod metrics**: `cosmos_connection_success_total` (with pod label)

## Troubleshooting

### Dashboard shows "No data"

1. Verify pods are running: `kubectl get pods -n default`
2. Check metrics are being exposed: `kubectl port-forward svc/cosmos-msi-scale-test 8080:8080` then visit `http://localhost:8080/metrics`
3. Verify Prometheus is scraping: Check data collection rules in Azure Monitor

### Data source not available

1. Ensure Azure Monitor workspace is linked to your Grafana workspace
2. Check the data source configuration in Grafana settings
3. Verify the Prometheus data source name matches the dashboard variable

### Panels show errors

1. Check the PromQL queries are valid
2. Verify metric names match what your application exports
3. Ensure the time range includes data (metrics are counters that start at 0)
