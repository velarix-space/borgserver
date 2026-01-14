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
DEFAULT_KEEP_MONTHLY=${BORG_PRUNE_KEEP_MONTHLY:--1}
DEFAULT_KEEP_YEARLY=${BORG_PRUNE_KEEP_YEARLY:--1}

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
                    
                    # Sanitize key to prevent code injection - only allow alphanumeric and underscore
                    if [[ ! "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
                        continue
                    fi
                    
                    # Sanitize value to prevent code injection
                    value=$(printf '%s' "$value" | sed "s/['\"]//g")
                    
                    # Normalize key to lowercase for consistency
                    key_lower=$(echo "$key" | tr '[:upper:]' '[:lower:]')
                    
                    # Validate values based on key type
                    case "$key_lower" in
                        keep_daily|keep_weekly|keep_monthly|keep_yearly)
                            # Must be -1 (disabled) or a positive integer
                            if ! [[ "$value" =~ ^(-1|[0-9]+)$ ]]; then
                                log "WARNING: Invalid numeric value '$value' for $key (must be -1 or positive integer), skipping"
                                continue
                            fi
                            ;;
                        keep_within)
                            # Must match borg time format: digits followed by d, w, m, or y (case insensitive)
                            if ! [[ "$value" =~ ^[0-9]+[dwmyDWMY]$ ]]; then
                                log "WARNING: Invalid time format '$value' for $key (expected format: <number><d|w|m|y>), skipping"
                                continue
                            fi
                            ;;
                        enabled)
                            # Must be yes or no
                            if [[ "$value" != "yes" ]] && [[ "$value" != "no" ]]; then
                                log "WARNING: Invalid value '$value' for $key (must be 'yes' or 'no'), skipping"
                                continue
                            fi
                            ;;
                    esac
                    
                    if [ "$section_found" = true ] && [ "$section" == "$client_name" ]; then
                        # Client-specific config takes precedence
                        case "$key_lower" in
                            keep_daily)
                                CLIENT_KEEP_DAILY="$value"
                                ;;
                            keep_weekly)
                                CLIENT_KEEP_WEEKLY="$value"
                                ;;
                            keep_monthly)
                                CLIENT_KEEP_MONTHLY="$value"
                                ;;
                            keep_yearly)
                                CLIENT_KEEP_YEARLY="$value"
                                ;;
                            keep_within)
                                CLIENT_KEEP_WITHIN="$value"
                                ;;
                            enabled)
                                CLIENT_ENABLED="$value"
                                ;;
                        esac
                    elif [ "$section" == "default" ]; then
                        # Use default values if client-specific not set
                        case "$key_lower" in
                            keep_daily)
                                [ -z "$CLIENT_KEEP_DAILY" ] && CLIENT_KEEP_DAILY="$value"
                                ;;
                            keep_weekly)
                                [ -z "$CLIENT_KEEP_WEEKLY" ] && CLIENT_KEEP_WEEKLY="$value"
                                ;;
                            keep_monthly)
                                [ -z "$CLIENT_KEEP_MONTHLY" ] && CLIENT_KEEP_MONTHLY="$value"
                                ;;
                            keep_yearly)
                                [ -z "$CLIENT_KEEP_YEARLY" ] && CLIENT_KEEP_YEARLY="$value"
                                ;;
                            keep_within)
                                [ -z "$CLIENT_KEEP_WITHIN" ] && CLIENT_KEEP_WITHIN="$value"
                                ;;
                            enabled)
                                [ -z "$CLIENT_ENABLED" ] && CLIENT_ENABLED="$value"
                                ;;
                        esac
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
        return 2  # Return special code for disabled clients
    fi
    
    log "INFO: Starting prune for client '${client_name}' at ${repo_path}"
    
    # Build prune command
    local prune_cmd="borg prune --list --stats"
    
    # Validate and add retention options (check if numeric and greater than 0)
    # -1 means disabled, so we skip those
    if [ -n "${CLIENT_KEEP_DAILY}" ] && [[ "${CLIENT_KEEP_DAILY}" =~ ^(-1|[0-9]+)$ ]] && [ "${CLIENT_KEEP_DAILY}" -gt 0 ]; then
        prune_cmd="${prune_cmd} --keep-daily=${CLIENT_KEEP_DAILY}"
    fi
    if [ -n "${CLIENT_KEEP_WEEKLY}" ] && [[ "${CLIENT_KEEP_WEEKLY}" =~ ^(-1|[0-9]+)$ ]] && [ "${CLIENT_KEEP_WEEKLY}" -gt 0 ]; then
        prune_cmd="${prune_cmd} --keep-weekly=${CLIENT_KEEP_WEEKLY}"
    fi
    if [ -n "${CLIENT_KEEP_MONTHLY}" ] && [[ "${CLIENT_KEEP_MONTHLY}" =~ ^(-1|[0-9]+)$ ]] && [ "${CLIENT_KEEP_MONTHLY}" -gt 0 ]; then
        prune_cmd="${prune_cmd} --keep-monthly=${CLIENT_KEEP_MONTHLY}"
    fi
    if [ -n "${CLIENT_KEEP_YEARLY}" ] && [[ "${CLIENT_KEEP_YEARLY}" =~ ^(-1|[0-9]+)$ ]] && [ "${CLIENT_KEEP_YEARLY}" -gt 0 ]; then
        prune_cmd="${prune_cmd} --keep-yearly=${CLIENT_KEEP_YEARLY}"
    fi
    # Validate keep_within format: digits followed by d, w, m, or y (borg supported time units)
    if [ -n "${CLIENT_KEEP_WITHIN}" ] && [[ "${CLIENT_KEEP_WITHIN}" =~ ^[0-9]+[dwmyDWMY]$ ]]; then
        prune_cmd="${prune_cmd} --keep-within=${CLIENT_KEEP_WITHIN}"
    fi
    
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
