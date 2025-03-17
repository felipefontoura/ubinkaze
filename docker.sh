#!/bin/bash

set -euo pipefail

# --- Aesthetics ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
ICON='\xF0\x9F\x8C\x80'
NC='\033[0m'

# --- Functions ---
print_message() {
  local color=$1
  local message=$2
  echo -e "${color}${ICON} ${message}${NC}"
}

print_error() {
  print_message "${RED}" "ERROR: $1"
}

print_warning() {
  print_message "${YELLOW}" "WARNING: $1"
}

print_success() {
  print_message "${GREEN}" "SUCCESS: $1"
}

print_info() {
  print_message "${BLUE}" "INFO: $1"
}

# Function to deploy a stack
deploy_stack() {
  local stack_name=$1
  local stack_file=$2

  print_info "Deploying stack: $stack_name"
  if docker stack deploy -c "$stack_file" "$stack_name"; then
    print_success "Stack $stack_name deployed successfully"
  else
    print_error "Failed to deploy stack $stack_name"
    return 1
  fi
}

print_info "Starting Docker Swarm configuration..."

# Ensure Docker Swarm is initialized
if ! docker info | grep -q "Swarm: active"; then
  print_info "Initializing Docker Swarm..."
  if docker swarm init --advertise-addr $(hostname -I | awk '{print $1}'); then
    print_success "Docker Swarm initialized"
  else
    print_error "Failed to initialize Docker Swarm"
    exit 1
  fi
fi

# Create public network if it doesn't exist
if ! docker network ls | grep -q "network_public"; then
  print_info "Creating public network..."
  if docker network create --driver overlay --attachable network_public; then
    print_success "Public network created"
  else
    print_error "Failed to create public network"
    exit 1
  fi
fi

# Ensure the stacks directory exists
STACKS_DIR="$HOME/.local/share/ubinkaze/stacks"
if [[ ! -d "$STACKS_DIR" ]]; then
  print_info "Creating stacks directory structure..."
  mkdir -p "$STACKS_DIR/infra" "$STACKS_DIR/db" "$STACKS_DIR/app"
  print_success "Stacks directory structure created"
fi

# Decode the base64 JSON configuration
if [[ -n "$UBINKAZE_CONFIG" ]]; then
  print_info "Decoding configuration..."
  CONFIG_JSON=$(echo "$UBINKAZE_CONFIG" | base64 -d)
  if [[ $? -eq 0 ]]; then
    print_success "Configuration decoded successfully"
  else
    print_error "Failed to decode configuration"
    exit 1
  fi

  # Parse the JSON and deploy stacks accordingly.,
  # Example JSON:
  # {
  #  "nodes": [
  #    "manager": {
  #      "cpu": 2
  #      "memory": 4GB
  #    }
  #  ],
  #  "stacks": ["infra/traefik", "db/postgres", "db/redis", "app/rabbitmq"],
  #  "config": {
  #    "postgres": {
  #      "envs": {
  #        "POSTGRES_PASSWORD": "secret"
  #      }
  #    }
  #  }
  # }

  # Check if jq is installed, if not install it
  if ! command -v jq &>/dev/null; then
    print_info "Installing jq..."
    sudo apt-get update >/dev/null
    if sudo apt-get install -y jq >/dev/null; then
      print_success "jq installed"
    else
      print_error "Failed to install jq"
      exit 1
    fi
  fi

  # Check for node configuration
  NODES_CONFIG=$(echo "$CONFIG_JSON" | jq -r '.nodes // empty' 2>/dev/null)
  if [[ -n "$NODES_CONFIG" ]]; then
    print_info "Applying node configuration..."
    # Here you could add logic to configure node resources based on the JSON
    # For example, setting resource limits for Docker
  fi

  # Extract stacks array from JSON
  STACKS=$(echo "$CONFIG_JSON" | jq -r '.stacks[]' 2>/dev/null || echo "")

  if [[ -n "$STACKS" ]]; then
    print_info "Found stacks to deploy: $STACKS"

    # Deploy each stack
    for stack in $STACKS; do
      # Split the stack path if it contains a slash
      STACK_TYPE=$(echo "$stack" | cut -d'/' -f1)
      STACK_NAME=$(echo "$stack" | cut -d'/' -f2)

      # Get any specific configuration for this stack
      STACK_CONFIG=$(echo "$CONFIG_JSON" | jq -r --arg name "$STACK_NAME" '.config[$name] // empty' 2>/dev/null)

      # Create environment variables file if configuration exists
      ENV_FILE=""
      if [[ -n "$STACK_CONFIG" ]]; then
        ENV_DIR="$HOME/.local/share/ubinkaze/env"
        mkdir -p "$ENV_DIR"
        ENV_FILE="$ENV_DIR/${STACK_NAME}.env"

        # Extract environment variables from config
        echo "$STACK_CONFIG" | jq -r '.envs | to_entries[] | "\(.key)=\(.value)"' >"$ENV_FILE" 2>/dev/null

        if [[ -s "$ENV_FILE" ]]; then
          print_info "Created environment file for $STACK_NAME with custom configuration"
        else
          rm -f "$ENV_FILE"
          ENV_FILE=""
        fi
      fi

      # Determine stack file path and name for deployment
      STACK_FILE="$HOME/.local/share/ubinkaze/stacks/${STACK_TYPE}/${STACK_NAME}.yml"
      DEPLOY_NAME="${STACK_TYPE}_${STACK_NAME}"

      # Check if stack file exists
      if [[ -f "$STACK_FILE" ]]; then
        # Deploy with environment file if it exists
        if [[ -n "$ENV_FILE" ]]; then
          print_info "Deploying $stack with custom configuration"
          docker stack deploy -c "$STACK_FILE" --env-file "$ENV_FILE" "$DEPLOY_NAME" ||
            print_error "Failed to deploy stack $stack with custom configuration"
        else
          deploy_stack "$DEPLOY_NAME" "$STACK_FILE"
        fi
      else
        print_warning "Stack file not found for: $stack at $STACK_FILE"
      fi
    done
  else
    print_warning "No stacks specified in configuration or invalid JSON format"
  fi
else
  print_warning "No configuration provided"
fi

print_success "Docker stacks deployment completed"
