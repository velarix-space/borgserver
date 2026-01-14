#!/bin/bash
# Wrapper script for borg prune cron job
# This script sets up the environment and calls the main prune script

# Export environment variables for the prune script
export BORG_DATA_DIR=${BORG_DATA_DIR:-/backup}
export CONFIG_DIR=${CONFIG_DIR:-/sshkeys}
export BORG_PRUNE_KEEP_DAILY=${BORG_PRUNE_KEEP_DAILY:-7}
export BORG_PRUNE_KEEP_WEEKLY=${BORG_PRUNE_KEEP_WEEKLY:-4}
export BORG_PRUNE_KEEP_MONTHLY=${BORG_PRUNE_KEEP_MONTHLY:-6}
export BORG_PRUNE_KEEP_YEARLY=${BORG_PRUNE_KEEP_YEARLY:-1}

# Execute the main prune script
exec /prune.sh
