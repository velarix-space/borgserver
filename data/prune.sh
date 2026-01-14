#!/bin/bash
# Prune Script for docker-borgserver
# This script prunes borg repositories based on configuration

set -e

BORG_DATA_DIR=${BORG_DATA_DIR:-/backup}
PRUNE_CONFIG=${BORG_PRUNE_CONFIG:-/config/prune-config.yml}
LOG_PREFIX="[BORG-PRUNE]"
VALIDATE_ONLY=0

# Check if validation mode is requested
if [ "$1" == "--validate" ]; then
    VALIDATE_ONLY=1
fi

# Function to log messages
log() {
    echo "${LOG_PREFIX} $1"
}

# Function to log errors
error() {
    echo "${LOG_PREFIX} ERROR: $1" >&2
}

# Validate that yq is available
if ! command -v yq &> /dev/null; then
    error "yq is not installed or not in PATH"
    exit 1
fi

# Validate config file exists
if [ ! -f "${PRUNE_CONFIG}" ]; then
    error "Prune config file not found: ${PRUNE_CONFIG}"
    exit 1
fi

# Validate YAML syntax
if ! yq eval '.' "${PRUNE_CONFIG}" > /dev/null 2>&1; then
    error "Invalid YAML syntax in config file: ${PRUNE_CONFIG}"
    exit 1
fi

# Validate schema - check for required keys
defaults_check=$(yq eval '.defaults' "${PRUNE_CONFIG}")
if [ "${defaults_check}" == "null" ] || [ -z "${defaults_check}" ]; then
    error "Config file missing required 'defaults' section"
    exit 1
fi

log "Configuration validated successfully"

# If validation only mode, exit here
if [ ${VALIDATE_ONLY} -eq 1 ]; then
    log "Validation mode: Config is valid"
    exit 0
fi

# Read default retention rules
default_hourly=$(yq eval '.defaults.keep_hourly // 0' "${PRUNE_CONFIG}")
default_daily=$(yq eval '.defaults.keep_daily // 7' "${PRUNE_CONFIG}")
default_weekly=$(yq eval '.defaults.keep_weekly // 4' "${PRUNE_CONFIG}")
default_monthly=$(yq eval '.defaults.keep_monthly // -1' "${PRUNE_CONFIG}")
default_yearly=$(yq eval '.defaults.keep_yearly // -1' "${PRUNE_CONFIG}")

log "Default retention rules: hourly=${default_hourly}, daily=${default_daily}, weekly=${default_weekly}, monthly=${default_monthly}, yearly=${default_yearly}"

# Function to build prune arguments
build_prune_args() {
    local client_name=$1
    local keep_hourly keep_daily keep_weekly keep_monthly keep_yearly
    
    # Try to get client-specific rules, fallback to defaults
    keep_hourly=$(yq eval ".clients.\"${client_name}\".keep_hourly // ${default_hourly}" "${PRUNE_CONFIG}")
    keep_daily=$(yq eval ".clients.\"${client_name}\".keep_daily // ${default_daily}" "${PRUNE_CONFIG}")
    keep_weekly=$(yq eval ".clients.\"${client_name}\".keep_weekly // ${default_weekly}" "${PRUNE_CONFIG}")
    keep_monthly=$(yq eval ".clients.\"${client_name}\".keep_monthly // ${default_monthly}" "${PRUNE_CONFIG}")
    keep_yearly=$(yq eval ".clients.\"${client_name}\".keep_yearly // ${default_yearly}" "${PRUNE_CONFIG}")
    
    local args=""
    
    # Only add arguments if value is >= 0 (-1 means keep all)
    if [ "${keep_hourly}" -gt 0 ]; then
        args="${args} --keep-hourly=${keep_hourly}"
    fi
    if [ "${keep_daily}" -gt 0 ]; then
        args="${args} --keep-daily=${keep_daily}"
    fi
    if [ "${keep_weekly}" -gt 0 ]; then
        args="${args} --keep-weekly=${keep_weekly}"
    fi
    if [ "${keep_monthly}" -gt 0 ]; then
        args="${args} --keep-monthly=${keep_monthly}"
    fi
    if [ "${keep_yearly}" -gt 0 ]; then
        args="${args} --keep-yearly=${keep_yearly}"
    fi
    
    echo "${args}"
}

# Iterate through all repositories
log "Starting prune operation..."
prune_count=0
error_count=0

for repo_path in "${BORG_DATA_DIR}"/*; do
    if [ ! -d "${repo_path}" ]; then
        continue
    fi
    
    client_name=$(basename "${repo_path}")
    
    # Skip if not a borg repository
    if [ ! -d "${repo_path}/data" ] && [ ! -d "${repo_path}/config" ]; then
        log "Skipping ${client_name} - not a borg repository"
        continue
    fi
    
    log "Processing repository: ${client_name}"
    
    prune_args=$(build_prune_args "${client_name}")
    
    if [ -z "${prune_args}" ]; then
        log "No prune rules for ${client_name}, skipping"
        continue
    fi
    
    log "Prune args for ${client_name}: ${prune_args}"
    
    # Run borg prune
    if su - borg -c "borg prune ${prune_args} ${repo_path}" 2>&1 | while IFS= read -r line; do log "${line}"; done; then
        log "Prune completed for ${client_name}"
        
        # Run borg compact to free space
        log "Running compact for ${client_name}..."
        if su - borg -c "borg compact ${repo_path}" 2>&1 | while IFS= read -r line; do log "${line}"; done; then
            log "Compact completed for ${client_name}"
            ((prune_count++))
        else
            error "Compact failed for ${client_name}"
            ((error_count++))
        fi
    else
        error "Prune failed for ${client_name}"
        ((error_count++))
    fi
done

log "Prune operation completed. Processed: ${prune_count}, Errors: ${error_count}"

if [ ${error_count} -gt 0 ]; then
    exit 1
fi

exit 0
