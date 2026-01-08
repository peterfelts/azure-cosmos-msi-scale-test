package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"sync/atomic"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/data/aztables"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const (
	// Health status constants
	healthyStatus   int32 = 1
	unhealthyStatus int32 = 0
)

var (
	successCounter = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "cosmos_connection_success_total",
		Help: "Total number of successful Cosmos DB connections and table operations",
	})
	authErrorCounter = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "cosmos_auth_error_total",
		Help: "Total number of authentication errors when connecting to Cosmos DB",
	})
	otherErrorCounter = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "cosmos_other_error_total",
		Help: "Total number of other errors when connecting to Cosmos DB",
	})
	
	healthStatus int32 = healthyStatus
)

func init() {
	prometheus.MustRegister(successCounter)
	prometheus.MustRegister(authErrorCounter)
	prometheus.MustRegister(otherErrorCounter)
}

func main() {
	// Get configuration from environment variables
	cosmosAccountURL := os.Getenv("COSMOS_ACCOUNT_URL")
	if cosmosAccountURL == "" {
		log.Fatal("COSMOS_ACCOUNT_URL environment variable is required")
	}

	tableName := os.Getenv("TABLE_NAME")
	if tableName == "" {
		tableName = "ScaleTestTable"
	}

	metricsPort := os.Getenv("METRICS_PORT")
	if metricsPort == "" {
		metricsPort = "8080"
	}

	log.Printf("Starting Cosmos MSI Scale Test Application")
	log.Printf("Cosmos Account URL: %s", cosmosAccountURL)
	log.Printf("Table Name: %s", tableName)
	log.Printf("Metrics Port: %s", metricsPort)

	// Start metrics server
	http.Handle("/metrics", promhttp.Handler())
	http.HandleFunc("/health", healthHandler)
	http.HandleFunc("/ready", readyHandler)
	
	go func() {
		log.Printf("Starting metrics server on port %s", metricsPort)
		if err := http.ListenAndServe(":"+metricsPort, nil); err != nil {
			log.Fatalf("Failed to start metrics server: %v", err)
		}
	}()

	// Perform Cosmos DB connection and table operation
	if err := performCosmosOperation(cosmosAccountURL, tableName); err != nil {
		log.Printf("Error performing Cosmos operation: %v", err)
		atomic.StoreInt32(&healthStatus, unhealthyStatus)
	} else {
		log.Printf("Successfully performed Cosmos operation")
	}

	// Keep the application running to serve metrics
	log.Println("Application running. Press Ctrl+C to exit.")
	select {}
}

func performCosmosOperation(accountURL, tableName string) error {
	ctx := context.Background()

	// Get the client ID from environment variable
	clientID := os.Getenv("AZURE_CLIENT_ID")
	
	// Create a Managed Identity credential with explicit client ID
	log.Println("Creating Managed Identity credential...")
	var cred *azidentity.ManagedIdentityCredential
	var err error
	
	if clientID != "" {
		log.Printf("Using Managed Identity with client ID: %s", clientID)
		cred, err = azidentity.NewManagedIdentityCredential(&azidentity.ManagedIdentityCredentialOptions{
			ID: azidentity.ClientID(clientID),
		})
	} else {
		log.Println("Using default Managed Identity (no client ID specified)")
		cred, err = azidentity.NewManagedIdentityCredential(nil)
	}
	
	if err != nil {
		log.Printf("Failed to create Managed Identity credential: %v", err)
		authErrorCounter.Inc()
		return fmt.Errorf("failed to create managed identity credential: %w", err)
	}

	// Create a service client for Cosmos DB
	log.Println("Creating Cosmos DB service client...")
	serviceClient, err := aztables.NewServiceClient(accountURL, cred, nil)
	if err != nil {
		log.Printf("Failed to create service client: %v", err)
		otherErrorCounter.Inc()
		return fmt.Errorf("failed to create service client: %w", err)
	}

	// Attempt to create the table
	log.Printf("Attempting to create table: %s", tableName)
	_, err = serviceClient.CreateTable(ctx, tableName, nil)
	
	if err != nil {
		// Use Azure SDK's ResponseError for better error handling
		var respErr *azcore.ResponseError
		if errors.As(err, &respErr) {
			// Check HTTP status code for authentication/authorization errors
			if respErr.StatusCode == http.StatusUnauthorized || respErr.StatusCode == http.StatusForbidden {
				log.Printf("Authentication/Authorization error (HTTP %d): %v", respErr.StatusCode, err)
				authErrorCounter.Inc()
				return fmt.Errorf("authentication error: %w", err)
			}
			
			// Check if table already exists (conflict or specific error code)
			if respErr.StatusCode == http.StatusConflict || strings.Contains(respErr.ErrorCode, "TableAlreadyExists") {
				log.Printf("Table already exists (expected): %s", tableName)
				successCounter.Inc()
				return nil
			}
		}
		
		// Fallback: check error message for table already exists
		errStr := err.Error()
		if strings.Contains(strings.ToLower(errStr), "already exists") {
			log.Printf("Table already exists (expected): %s", tableName)
			successCounter.Inc()
			return nil
		}
		
		// Other errors
		log.Printf("Error creating table: %v", err)
		otherErrorCounter.Inc()
		return fmt.Errorf("error creating table: %w", err)
	}

	log.Printf("Successfully created table: %s", tableName)
	successCounter.Inc()
	return nil
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	if atomic.LoadInt32(&healthStatus) == healthyStatus {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("healthy"))
	} else {
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte("unhealthy"))
	}
}

func readyHandler(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ready"))
}
