#!/bin/bash
# Wrapper script for borg serve to handle automatic pruning after successful backups

# Extract client name from environment (set by run.sh via authorized_keys)
CLIENT_NAME="${BORG_CLIENT_NAME}"
BORG_DATA_DIR="${BORG_DATA_DIR:-/backup}"
PRUNE_CONFIG_DIR="/sshkeys/clients/.prune"

# Log function for debugging
log() {
    echo "[borg-wrapper] $*" >&2
}

# Function to load prune configuration for a client
load_prune_config() {
    local client="$1"
    local config_file="${PRUNE_CONFIG_DIR}/${client}.conf"
    
    # Start with defaults from environment variables
    PRUNE_ENABLED="${BORG_PRUNE_ENABLED:-yes}"
    PRUNE_KEEP_LAST="${BORG_PRUNE_KEEP_LAST:-}"
    PRUNE_KEEP_HOURLY="${BORG_PRUNE_KEEP_HOURLY:-}"
    PRUNE_KEEP_DAILY="${BORG_PRUNE_KEEP_DAILY:-7}"
    PRUNE_KEEP_WEEKLY="${BORG_PRUNE_KEEP_WEEKLY:-4}"
    PRUNE_KEEP_MONTHLY="${BORG_PRUNE_KEEP_MONTHLY:-6}"
    PRUNE_KEEP_YEARLY="${BORG_PRUNE_KEEP_YEARLY:-}"
    
    # Override with client-specific config if it exists
    if [ -f "${config_file}" ]; then
        log "Loading prune config for ${client} from ${config_file}"
        # Source the config file in a safe way
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^#.*$ ]] && continue
            [[ -z "$key" ]] && continue
            # Remove leading/trailing whitespace
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            case "$key" in
                PRUNE_ENABLED) PRUNE_ENABLED="$value" ;;
                PRUNE_KEEP_LAST) PRUNE_KEEP_LAST="$value" ;;
                PRUNE_KEEP_HOURLY) PRUNE_KEEP_HOURLY="$value" ;;
                PRUNE_KEEP_DAILY) PRUNE_KEEP_DAILY="$value" ;;
                PRUNE_KEEP_WEEKLY) PRUNE_KEEP_WEEKLY="$value" ;;
                PRUNE_KEEP_MONTHLY) PRUNE_KEEP_MONTHLY="$value" ;;
                PRUNE_KEEP_YEARLY) PRUNE_KEEP_YEARLY="$value" ;;
            esac
        done < "${config_file}"
    fi
}

# Function to run prune after successful backup
run_prune() {
    local client="$1"
    local repo_path="${BORG_DATA_DIR}/${client}"
    
    load_prune_config "${client}"
    
    # Check if pruning is enabled
    if [ "${PRUNE_ENABLED}" != "yes" ]; then
        log "Pruning disabled for ${client}"
        return 0
    fi
    
    # Build prune command with configured retention policy
    local prune_cmd="borg prune --list --stats"
    
    [ -n "${PRUNE_KEEP_LAST}" ] && prune_cmd="${prune_cmd} --keep-last ${PRUNE_KEEP_LAST}"
    [ -n "${PRUNE_KEEP_HOURLY}" ] && prune_cmd="${prune_cmd} --keep-hourly ${PRUNE_KEEP_HOURLY}"
    [ -n "${PRUNE_KEEP_DAILY}" ] && prune_cmd="${prune_cmd} --keep-daily ${PRUNE_KEEP_DAILY}"
    [ -n "${PRUNE_KEEP_WEEKLY}" ] && prune_cmd="${prune_cmd} --keep-weekly ${PRUNE_KEEP_WEEKLY}"
    [ -n "${PRUNE_KEEP_MONTHLY}" ] && prune_cmd="${prune_cmd} --keep-monthly ${PRUNE_KEEP_MONTHLY}"
    [ -n "${PRUNE_KEEP_YEARLY}" ] && prune_cmd="${prune_cmd} --keep-yearly ${PRUNE_KEEP_YEARLY}"
    
    prune_cmd="${prune_cmd} ${repo_path}"
    
    log "Running prune for ${client}: ${prune_cmd}"
    
    # Run prune as borg user with full access to the repository
    cd "${repo_path}" || return 1
    eval "${prune_cmd}" 2>&1 | while read -r line; do
        log "prune: ${line}"
    done
    
    local prune_status=${PIPESTATUS[0]}
    if [ ${prune_status} -eq 0 ]; then
        log "Prune completed successfully for ${client}"
    else
        log "Prune failed for ${client} with status ${prune_status}"
    fi
    
    return ${prune_status}
}

# Main wrapper logic
main() {
    log "Client: ${CLIENT_NAME}"
    
    # Check if we have a client name
    if [ -z "${CLIENT_NAME}" ]; then
        log "ERROR: BORG_CLIENT_NAME not set"
        exit 1
    fi
    
    # Execute the borg serve command that was passed to us
    # The command includes all necessary restrictions and is constructed by run.sh
    eval "${BORG_SERVE_CMD}"
    local serve_exit=$?
    
    log "Borg serve exited with status ${serve_exit}"
    
    # After borg serve completes successfully, run prune
    # This ensures prune runs after backups complete
    if [ ${serve_exit} -eq 0 ] && [ "${BORG_APPEND_ONLY}" = "yes" ]; then
        log "Successful borg serve session, running prune"
        run_prune "${CLIENT_NAME}"
        # Note: We don't fail the overall operation if prune fails
        # The backup itself was successful
    fi
    
    exit ${serve_exit}
}

# Run main function
main
