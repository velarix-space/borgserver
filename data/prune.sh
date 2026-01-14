#!/bin/bash
# Borg Prune Script
# Handles automatic pruning of borg repositories with per-client configuration

set -e

BORG_DATA_DIR=${BORG_DATA_DIR:-/backup}
CONFIG_DIR=${CONFIG_DIR:-/sshkeys}
LOG_FILE=${PRUNE_LOG_FILE:-/var/log/borg-prune.log}

# Default prune options from environment (used if no config file exists)
DEFAULT_KEEP_DAILY=${BORG_PRUNE_KEEP_DAILY:-7}
DEFAULT_KEEP_WEEKLY=${BORG_PRUNE_KEEP_WEEKLY:-4}
DEFAULT_KEEP_MONTHLY=${BORG_PRUNE_KEEP_MONTHLY:-6}
DEFAULT_KEEP_YEARLY=${BORG_PRUNE_KEEP_YEARLY:-1}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

# Function to read prune config for a specific client
get_client_prune_config() {
    local client_name=$1
    local config_file="${CONFIG_DIR}/prune.conf"
    
    # Check if config file exists
    if [ -f "${config_file}" ]; then
        # Try to find client-specific config in the file
        local section_found=false
        local in_section=false
        local config_values=""
        
        while IFS= read -r line || [ -n "$line" ]; do
            # Skip comments and empty lines
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue
            
            # Check for section header
            if [[ "$line" =~ ^\[(.*)\] ]]; then
                section="${BASH_REMATCH[1]}"
                if [ "$section" == "$client_name" ]; then
                    in_section=true
                    section_found=true
                elif [ "$section" == "default" ]; then
                    # Save default values but continue looking for client-specific
                    in_section=true
                else
                    in_section=false
                fi
                continue
            fi
            
            # Parse configuration values when in the right section
            if [ "$in_section" = true ]; then
                if [[ "$line" =~ ^[[:space:]]*([^=]+)[[:space:]]*=[[:space:]]*(.+)[[:space:]]*$ ]]; then
                    key="${BASH_REMATCH[1]}"
                    value="${BASH_REMATCH[2]}"
                    # Trim whitespace
                    key=$(echo "$key" | xargs)
                    value=$(echo "$value" | xargs)
                    
                    if [ "$section_found" = true ] && [ "$section" == "$client_name" ]; then
                        # Client-specific config takes precedence
                        eval "CLIENT_${key^^}='$value'"
                    elif [ "$section" == "default" ] && [ -z "$(eval echo \$CLIENT_${key^^})" ]; then
                        # Use default values if client-specific not set
                        eval "CLIENT_${key^^}='$value'"
                    fi
                fi
            fi
        done < "${config_file}"
    fi
    
    # Fall back to environment variables if no config found
    CLIENT_KEEP_DAILY=${CLIENT_KEEP_DAILY:-$DEFAULT_KEEP_DAILY}
    CLIENT_KEEP_WEEKLY=${CLIENT_KEEP_WEEKLY:-$DEFAULT_KEEP_WEEKLY}
    CLIENT_KEEP_MONTHLY=${CLIENT_KEEP_MONTHLY:-$DEFAULT_KEEP_MONTHLY}
    CLIENT_KEEP_YEARLY=${CLIENT_KEEP_YEARLY:-$DEFAULT_KEEP_YEARLY}
    CLIENT_KEEP_WITHIN=${CLIENT_KEEP_WITHIN:-}
    CLIENT_ENABLED=${CLIENT_ENABLED:-yes}
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
    unset CLIENT_KEEP_DAILY CLIENT_KEEP_WEEKLY CLIENT_KEEP_MONTHLY CLIENT_KEEP_YEARLY CLIENT_KEEP_WITHIN CLIENT_ENABLED
    get_client_prune_config "${client_name}"
    
    # Check if pruning is enabled for this client
    if [ "${CLIENT_ENABLED}" != "yes" ]; then
        log "INFO: Pruning disabled for client '${client_name}', skipping"
        return 0
    fi
    
    log "INFO: Starting prune for client '${client_name}' at ${repo_path}"
    
    # Build prune command
    local prune_cmd="borg prune --list --stats"
    
    [ -n "${CLIENT_KEEP_DAILY}" ] && [ "${CLIENT_KEEP_DAILY}" -gt 0 ] && prune_cmd="${prune_cmd} --keep-daily=${CLIENT_KEEP_DAILY}"
    [ -n "${CLIENT_KEEP_WEEKLY}" ] && [ "${CLIENT_KEEP_WEEKLY}" -gt 0 ] && prune_cmd="${prune_cmd} --keep-weekly=${CLIENT_KEEP_WEEKLY}"
    [ -n "${CLIENT_KEEP_MONTHLY}" ] && [ "${CLIENT_KEEP_MONTHLY}" -gt 0 ] && prune_cmd="${prune_cmd} --keep-monthly=${CLIENT_KEEP_MONTHLY}"
    [ -n "${CLIENT_KEEP_YEARLY}" ] && [ "${CLIENT_KEEP_YEARLY}" -gt 0 ] && prune_cmd="${prune_cmd} --keep-yearly=${CLIENT_KEEP_YEARLY}"
    [ -n "${CLIENT_KEEP_WITHIN}" ] && prune_cmd="${prune_cmd} --keep-within=${CLIENT_KEEP_WITHIN}"
    
    prune_cmd="${prune_cmd} ${repo_path}"
    
    log "INFO: Executing: ${prune_cmd}"
    
    # Execute prune command
    if su - borg -c "${prune_cmd}" >> "${LOG_FILE}" 2>&1; then
        log "SUCCESS: Prune completed for client '${client_name}'"
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
    
    # Find all client repositories
    if [ ! -d "${BORG_DATA_DIR}" ]; then
        log "ERROR: Backup directory ${BORG_DATA_DIR} not found"
        exit 1
    fi
    
    local success_count=0
    local fail_count=0
    local skip_count=0
    
    for client_dir in "${BORG_DATA_DIR}"/*; do
        if [ -d "${client_dir}" ]; then
            client_name=$(basename "${client_dir}")
            if prune_client_repo "${client_name}"; then
                ((success_count++))
            else
                if [ "${CLIENT_ENABLED}" == "no" ]; then
                    ((skip_count++))
                else
                    ((fail_count++))
                fi
            fi
        fi
    done
    
    log "Prune cycle completed: ${success_count} successful, ${fail_count} failed, ${skip_count} skipped"
    log "=========================================="
    
    # Exit with error if any prunes failed
    [ ${fail_count} -eq 0 ]
}

main "$@"
