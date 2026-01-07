## Purpose
The goal of this project is to perform scale testing of Azure MSI-based authentication to an Azure Cosmos DB account.

## Requirements
Go 1.23 or newer
Azure AzTables SDK for Go using MSI authentication to authenticate to Cosmos
AKS cluster using Azure CNI Overlay Networking
One pod per node
AKS cluster can be scaled to any number of nodes
Each pod uses MSI auth to connect to an Azure Cosmos DB account 
After establishing a connection to the Cosmos account, the Go application will perform a table-creation operation. Cosmos will return an error if the table already exists. If the error is related to not being authorized, an error metric will be published. If table creation succeeds (or fails because the table already exists) a success metric will be published.
Metrics will be aggregated and can be viewed to get wholistic view of how many pods succeeded in connecting to Cosmos and did or did not receive an authentication error.
The NewManagedIdentityCredential API will be used to create a token credential to be used with the NewServiceClient to create a Cosmos service client, in the Go application
Create a CLI command that can be used to deploy all resources to an Azure subscription (subscription ID will be provided as an argument to the CLI).
When tearing down the cluster, delete nodes in batches of 1K at a time.

## Success Criteria
A wholistic view of how many pods received authentication errors when connecting with Cosmos can be viewed
