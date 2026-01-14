#!/bin/bash
# Wrapper script for borg serve to handle automatic pruning after successful backups

# Extract client name from command line argument
CLIENT_NAME="$1"
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
    local client_dir="${BORG_DATA_DIR}/${client}"
    
    load_prune_config "${client}"
    
    # Check if pruning is enabled
    if [ "${PRUNE_ENABLED}" != "yes" ]; then
        log "Pruning disabled for ${client}"
        return 0
    fi
    
    # Find all borg repositories in the client directory
    # Use borg info to validate they are actual borg repositories
    local repos=()
    while IFS= read -r -d '' potential_repo; do
        # Check if this is a valid borg repository by trying to get info
        if borg info "${potential_repo}" &>/dev/null 2>&1; then
            repos+=("${potential_repo}")
        fi
    done < <(find "${client_dir}" -maxdepth 3 -type d -name "data" -exec dirname {} \; -print0 2>/dev/null)
    
    # Also check the client_dir itself in case it's a repo
    if [ -d "${client_dir}" ] && borg info "${client_dir}" &>/dev/null 2>&1; then
        repos+=("${client_dir}")
    fi
    
    # Also check immediate subdirectories
    if [ -d "${client_dir}" ]; then
        for subdir in "${client_dir}"/*; do
            if [ -d "${subdir}" ] && borg info "${subdir}" &>/dev/null 2>&1; then
                # Avoid duplicates
                local already_added=0
                for existing_repo in "${repos[@]}"; do
                    if [ "${existing_repo}" = "${subdir}" ]; then
                        already_added=1
                        break
                    fi
                done
                if [ ${already_added} -eq 0 ]; then
                    repos+=("${subdir}")
                fi
            fi
        done
    fi
    
    if [ ${#repos[@]} -eq 0 ]; then
        log "No borg repositories found in ${client_dir}"
        return 0
    fi
    
    # Run prune on each repository
    local overall_status=0
    for repo_path in "${repos[@]}"; do
        # Build prune command with configured retention policy
        local prune_cmd="borg prune --list --stats"
        
        [ -n "${PRUNE_KEEP_LAST}" ] && prune_cmd="${prune_cmd} --keep-last ${PRUNE_KEEP_LAST}"
        [ -n "${PRUNE_KEEP_HOURLY}" ] && prune_cmd="${prune_cmd} --keep-hourly ${PRUNE_KEEP_HOURLY}"
        [ -n "${PRUNE_KEEP_DAILY}" ] && prune_cmd="${prune_cmd} --keep-daily ${PRUNE_KEEP_DAILY}"
        [ -n "${PRUNE_KEEP_WEEKLY}" ] && prune_cmd="${prune_cmd} --keep-weekly ${PRUNE_KEEP_WEEKLY}"
        [ -n "${PRUNE_KEEP_MONTHLY}" ] && prune_cmd="${prune_cmd} --keep-monthly ${PRUNE_KEEP_MONTHLY}"
        [ -n "${PRUNE_KEEP_YEARLY}" ] && prune_cmd="${prune_cmd} --keep-yearly ${PRUNE_KEEP_YEARLY}"
        
        prune_cmd="${prune_cmd} ${repo_path}"
        
        log "Running prune for ${client} on repository ${repo_path}"
        
        # Capture both output and exit status properly
        local prune_output
        local prune_status
        prune_output=$(eval "${prune_cmd}" 2>&1)
        prune_status=$?
        
        # Log the output
        echo "${prune_output}" | while read -r line; do
            log "prune: ${line}"
        done
        
        if [ ${prune_status} -eq 0 ]; then
            log "Prune completed successfully for repository ${repo_path}"
        else
            log "Prune failed for repository ${repo_path} with status ${prune_status}"
            overall_status=${prune_status}
        fi
    done
    
    return ${overall_status}
}

# Main wrapper logic
main() {
    log "Client: ${CLIENT_NAME}"
    
    # Check if we have a client name
    if [ -z "${CLIENT_NAME}" ]; then
        log "ERROR: Client name not provided"
        exit 1
    fi
    
    # Change to the client's repository directory
    cd "${BORG_DATA_DIR}/${CLIENT_NAME}" || exit 1
    
    # Execute borg serve with restrictions
    borg serve --restrict-to-path "${BORG_DATA_DIR}/${CLIENT_NAME}" --append-only ${BORG_SERVE_ARGS}
    local serve_exit=$?
    
    log "Borg serve exited with status ${serve_exit}"
    
    # After borg serve completes successfully, run prune
    # This ensures prune runs after backups complete
    if [ ${serve_exit} -eq 0 ]; then
        log "Successful borg serve session, running prune"
        run_prune "${CLIENT_NAME}"
        # Note: We don't fail the overall operation if prune fails
        # The backup itself was successful
    fi
    
    exit ${serve_exit}
}

# Run main function
main
