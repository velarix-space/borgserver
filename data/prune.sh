#!/bin/bash
# Borg Prune Script
# Handles automatic pruning of borg repositories with per-client configuration

set -e

BORG_DATA_DIR=${BORG_DATA_DIR:-/backup}
CONFIG_DIR=${CONFIG_DIR:-/sshkeys}
LOG_FILE=${PRUNE_LOG_FILE:-/var/log/borg-prune.log}
CONFIG_FILE="${CONFIG_DIR}/prune.conf"
CONFIG_CACHE="/tmp/prune-config-cache.json"
PARSER_SCRIPT="/prune_config.py"

# Default prune options from environment (used if no config file exists)
DEFAULT_KEEP_DAILY=${BORG_PRUNE_KEEP_DAILY:-7}
DEFAULT_KEEP_WEEKLY=${BORG_PRUNE_KEEP_WEEKLY:-4}
DEFAULT_KEEP_MONTHLY=${BORG_PRUNE_KEEP_MONTHLY:--1}
DEFAULT_KEEP_YEARLY=${BORG_PRUNE_KEEP_YEARLY:--1}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

# Load and cache configuration on first run
load_config_cache() {
    if [ -f "${CONFIG_FILE}" ]; then
        log "INFO: Loading configuration from ${CONFIG_FILE}"
        if ! python3 "${PARSER_SCRIPT}" cache "${CONFIG_FILE}" > "${CONFIG_CACHE}" 2>&1; then
            log "ERROR: Failed to parse configuration file"
            cat "${CONFIG_CACHE}"
            rm -f "${CONFIG_CACHE}"
            exit 1
        fi
        log "INFO: Configuration cached successfully"
    else
        log "INFO: No config file found, using environment variable defaults"
        # Create a minimal cache with just defaults
        cat > "${CONFIG_CACHE}" << EOF
{
  "default": {
    "keep_daily": ${DEFAULT_KEEP_DAILY},
    "keep_weekly": ${DEFAULT_KEEP_WEEKLY},
    "keep_monthly": ${DEFAULT_KEEP_MONTHLY},
    "keep_yearly": ${DEFAULT_KEEP_YEARLY},
    "keep_within": null,
    "enabled": true
  }
}
EOF
    fi
}

# Get configuration for a specific client from cache
get_client_prune_config() {
    local client_name=$1
    
    # Extract client config from cache, falling back to default
    local client_config=$(python3 -c "
import json, sys
with open('${CONFIG_CACHE}') as f:
    config = json.load(f)
    
client = config.get('${client_name}', {})
default = config.get('default', {})

# Merge with defaults
result = default.copy()
result.update(client)

# Export as shell variables
for key, value in result.items():
    if value is None:
        continue
    if isinstance(value, bool):
        value = 'yes' if value else 'no'
    print(f'{key.upper()}={value}')
" 2>/dev/null)
    
    if [ -z "$client_config" ]; then
        log "ERROR: Failed to get config for client '${client_name}'"
        return 1
    fi
    
    # Parse and export the config variables
    eval "$client_config"
}

# Function to prune a single client repository
prune_client_repo() {
    local client_name=$1
    local repo_path="${BORG_DATA_DIR}/${client_name}"
    
    # Check if repository exists
    if [ ! -d "${repo_path}" ]; then
        log "WARNING: Repository for client '${client_name}' not found at ${repo_path}"
        return 1
    fi
    
    # Get client-specific configuration
    unset KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY KEEP_YEARLY KEEP_WITHIN ENABLED
    get_client_prune_config "${client_name}"
    
    # Check if pruning is enabled for this client
    if [ "${ENABLED}" != "yes" ]; then
        log "INFO: Pruning disabled for client '${client_name}', skipping"
        return 2  # Return special code for disabled clients
    fi
    
    log "INFO: Starting prune for client '${client_name}' at ${repo_path}"
    
    # Build prune command
    local prune_cmd="borg prune --list --stats"
    
    # Add retention options (skip if -1 or not set)
    [ -n "${KEEP_DAILY}" ] && [ "${KEEP_DAILY}" -gt 0 ] && prune_cmd="${prune_cmd} --keep-daily=${KEEP_DAILY}"
    [ -n "${KEEP_WEEKLY}" ] && [ "${KEEP_WEEKLY}" -gt 0 ] && prune_cmd="${prune_cmd} --keep-weekly=${KEEP_WEEKLY}"
    [ -n "${KEEP_MONTHLY}" ] && [ "${KEEP_MONTHLY}" -gt 0 ] && prune_cmd="${prune_cmd} --keep-monthly=${KEEP_MONTHLY}"
    [ -n "${KEEP_YEARLY}" ] && [ "${KEEP_YEARLY}" -gt 0 ] && prune_cmd="${prune_cmd} --keep-yearly=${KEEP_YEARLY}"
    [ -n "${KEEP_WITHIN}" ] && prune_cmd="${prune_cmd} --keep-within=${KEEP_WITHIN}"
    
    prune_cmd="${prune_cmd} ${repo_path}"
    
    log "INFO: Executing: ${prune_cmd}"
    
    # Execute prune command
    if su - borg -c "${prune_cmd}" >> "${LOG_FILE}" 2>&1; then
        log "SUCCESS: Prune completed for client '${client_name}'"
        
        # Run compact to free space after prune
        log "INFO: Running compact for client '${client_name}' at ${repo_path}"
        local compact_cmd="borg compact ${repo_path}"
        if su - borg -c "${compact_cmd}" >> "${LOG_FILE}" 2>&1; then
            log "SUCCESS: Compact completed for client '${client_name}'"
        else
            log "WARNING: Compact failed for client '${client_name}'"
        fi
        return 0
    else
        log "ERROR: Prune failed for client '${client_name}'"
        return 1
    fi
}

# Main execution
main() {
    log "=========================================="
    log "Starting borg prune cycle"
    
    # Check if BORG_PRUNE_ENABLED is set to "no"
    if [ "${BORG_PRUNE_ENABLED}" == "no" ]; then
        log "INFO: Borg prune is disabled via BORG_PRUNE_ENABLED=no"
        exit 0
    fi
    
    # Load and cache configuration
    load_config_cache
    
    # Find all client repositories
    if [ ! -d "${BORG_DATA_DIR}" ]; then
        log "ERROR: Backup directory ${BORG_DATA_DIR} not found"
        exit 1
    fi
    
    local success_count=0
    local fail_count=0
    local skip_count=0
    
    # Check if there are any directories to process
    shopt -s nullglob
    local dirs=("${BORG_DATA_DIR}"/*)
    shopt -u nullglob
    
    if [ ${#dirs[@]} -eq 0 ]; then
        log "INFO: No client directories found in ${BORG_DATA_DIR}"
        log "Prune cycle completed: 0 successful, 0 failed, 0 skipped"
        log "=========================================="
        exit 0
    fi
    
    for client_dir in "${dirs[@]}"; do
        if [ -d "${client_dir}" ]; then
            client_name=$(basename "${client_dir}")
            prune_client_repo "${client_name}"
            ret=$?
            if [ $ret -eq 0 ]; then
                ((success_count++))
            elif [ $ret -eq 2 ]; then
                ((skip_count++))
            else
                ((fail_count++))
            fi
        fi
    done
    
    log "Prune cycle completed: ${success_count} successful, ${fail_count} failed, ${skip_count} skipped"
    log "=========================================="
    
    # Exit with error if any prunes failed
    [ ${fail_count} -eq 0 ]
}

main "$@"
