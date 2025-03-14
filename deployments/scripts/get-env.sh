#!/bin/bash

# Chain config example:
# chain:
#   name: "Network Name"
#   chain_id: chain_id
#   contracts:
#     factory: "0x0000000000000000000000000000000000000000"
#  deployment:
#    owner: "0x0000000000000000000000000000000000000000"
#    deployer: "0x0000000000000000000000000000000000000000"
#    deploy_curve: false
#    deploy_mock: false
#    salts:
#      factory: "0x0000000000000000000000000000000000000000"
# rpc:
#   rpc_url: "https://eth-sepolia.g.alchemy.com/v2/demo"
#   explorer_api_key: "demo"

set -e

CHAIN=$1
ENV=$2
OUTPUT_FILE=$3

if [ -z "$CHAIN" ] || [ -z "$ENV" ]; then
    echo "Usage: ./get-env.sh <chain> <environment> [output_file]"
    echo "Example: ./get-env.sh eth prod .env.generated"
    exit 1
fi

ENV_CONFIG_PATH="deployments/chains/${CHAIN}/${ENV}.yaml"

if [ ! -f "$ENV_CONFIG_PATH" ]; then
    echo "Environment configuration file not found: $ENV_CONFIG_PATH"
    exit 1
fi

# Function to convert YAML path to environment variable name
yaml_path_to_env_var() {
    local path=$1
    # Replace dots with underscores and convert to uppercase
    echo "$path" | tr '.' '_' | tr '[:lower:]' '[:upper:]'
}

# Function to extract values from YAML and convert to environment variables
extract_env_vars() {
    local prefix=$1
    local yaml_file=$2
    
    # Get all leaf nodes (keys with values) from the YAML
    local keys=$(yq eval 'paths | select(. != null) | join(".")' "$yaml_file")
    
    for key in $keys; do
        # Skip arrays and objects
        if yq eval ".$key | type" "$yaml_file" | grep -q -E "array|object"; then
            continue
        fi
        
        # Get the value
        local value=$(yq eval ".$key" "$yaml_file")
        
        # Skip if value is null or empty
        if [ "$value" = "null" ] || [ -z "$value" ]; then
            continue
        fi
        
        # Convert YAML path to environment variable name
        local env_var=$(yaml_path_to_env_var "$prefix$key")
        
        # Output the environment variable
        echo "$env_var=$value"
    done
}

# Extract environment variables from contracts section
extract_contracts_env_vars() {
    local yaml_file=$1
    
    # Check if contracts section exists
    if ! yq eval '.chain.contracts' "$yaml_file" | grep -q -v "null"; then
        return
    fi
    
    # Get all contract addresses
    local contracts=$(yq eval '.chain.contracts | keys | .[]' "$yaml_file")
    
    for contract in $contracts; do
        # Get the value
        local value=$(yq eval ".chain.contracts.$contract" "$yaml_file")
        
        # Skip if value is null or empty
        if [ "$value" = "null" ] || [ -z "$value" ]; then
            continue
        fi
        
        # Convert to uppercase
        local env_var=$(echo "$contract" | tr '[:lower:]' '[:upper:]')
        
        # Output the environment variable
        echo "$env_var=$value"
    done
}

# Extract environment variables from deployment.salts section
extract_salts_env_vars() {
    local yaml_file=$1
    
    # Check if deployment.salts section exists
    if ! yq eval '.deployment.salts' "$yaml_file" | grep -q -v "null"; then
        return
    fi
    
    # Get all salts
    local salts=$(yq eval '.deployment.salts | keys | .[]' "$yaml_file")
    
    for salt in $salts; do
        # Get the value
        local value=$(yq eval ".deployment.salts.$salt" "$yaml_file")
        
        # Skip if value is null or empty
        if [ "$value" = "null" ] || [ -z "$value" ]; then
            continue
        fi
        
        # Convert to uppercase salt name
        local env_var="SALT_$(echo "$salt" | tr '[:lower:]' '[:upper:]')"
        
        # Output the environment variable
        echo "$env_var=$value"
    done
}

# Extract RPC configuration
extract_rpc_env_vars() {
    local yaml_file=$1
    
    # Check if rpc section exists
    if ! yq eval '.rpc' "$yaml_file" | grep -q -v "null"; then
        return
    fi
    
    # Get all RPC settings
    local rpc_keys=$(yq eval '.rpc | keys | .[]' "$yaml_file")
    
    for key in $rpc_keys; do
        # Get the value
        local value=$(yq eval ".rpc.$key" "$yaml_file")
        
        # Skip if value is null or empty
        if [ "$value" = "null" ] || [ -z "$value" ]; then
            continue
        fi
        
        # Convert to uppercase
        local env_var=$(echo "$key" | tr '[:lower:]' '[:upper:]')
        
        # Output the environment variable
        echo "$env_var=$value"
    done
}

# Generate environment variables
(
    echo "# Generated from ${CHAIN}/${ENV} configuration"
    echo "# $(date)"
    echo ""
    
    # Chain info - check if fields exist before trying to access them
    if yq eval '.chain.chain_id' "$ENV_CONFIG_PATH" | grep -q -v "null"; then
        echo "CHAIN_ID=$(yq eval '.chain.chain_id' "$ENV_CONFIG_PATH")"
    fi
    
    if yq eval '.chain.name' "$ENV_CONFIG_PATH" | grep -q -v "null"; then
        echo "CHAIN_NAME=\"$(yq eval '.chain.name' "$ENV_CONFIG_PATH")\""
    fi
    
    echo ""
    
    # Deployment settings if they exist
    if yq eval '.deployment' "$ENV_CONFIG_PATH" | grep -q -v "null"; then
        echo "# Deployment settings"
        [ "$(yq eval '.deployment.owner' "$ENV_CONFIG_PATH")" != "null" ] && echo "OWNER=$(yq eval '.deployment.owner' "$ENV_CONFIG_PATH")"
        [ "$(yq eval '.deployment.deployer' "$ENV_CONFIG_PATH")" != "null" ] && echo "DEPLOYER=$(yq eval '.deployment.deployer' "$ENV_CONFIG_PATH")"
        [ "$(yq eval '.deployment.multisig' "$ENV_CONFIG_PATH")" != "null" ] && echo "MULTISIG=$(yq eval '.deployment.multisig' "$ENV_CONFIG_PATH")"
        [ "$(yq eval '.deployment.deploy_curve' "$ENV_CONFIG_PATH")" != "null" ] && echo "DEPLOY_CURVE=$(yq eval '.deployment.deploy_curve' "$ENV_CONFIG_PATH")"
        [ "$(yq eval '.deployment.deploy_mock' "$ENV_CONFIG_PATH")" != "null" ] && echo "DEPLOY_MOCK=$(yq eval '.deployment.deploy_mock' "$ENV_CONFIG_PATH")"
        echo ""
    fi
    
    # Contract addresses
    echo "# Contract addresses"
    extract_contracts_env_vars "$ENV_CONFIG_PATH"
    echo ""
    
    # Salts for deterministic deployment
    if yq eval '.deployment.salts' "$ENV_CONFIG_PATH" | grep -q -v "null"; then
        echo "# Salts for deterministic deployment"
        extract_salts_env_vars "$ENV_CONFIG_PATH"
        echo ""
    fi
    
    # RPC configuration
    if yq eval '.rpc' "$ENV_CONFIG_PATH" | grep -q -v "null"; then
        echo "# RPC configuration"
        extract_rpc_env_vars "$ENV_CONFIG_PATH"
    fi
) > "${OUTPUT_FILE:-.env.${CHAIN}.${ENV}}"

echo "Environment variables generated in ${OUTPUT_FILE:-.env.${CHAIN}.${ENV}}"