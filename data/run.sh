#!/bin/bash
# Start Script for docker-borgserver

PUID=${PUID:-1000}
PGID=${PGID:-1000}

usermod -o -u "$PUID" borg &>/dev/null
groupmod -o -g "$PGID" borg &>/dev/null

BORG_DATA_DIR=/backup
SSH_KEY_DIR=/sshkeys
BORG_CMD='cd ${BORG_DATA_DIR}/${client_name}; borg serve --restrict-to-path ${BORG_DATA_DIR}/${client_name} ${BORG_SERVE_ARGS}'
AUTHORIZED_KEYS_PATH=/home/borg/.ssh/authorized_keys

# Append only mode?
BORG_APPEND_ONLY=${BORG_APPEND_ONLY:=no}

source /etc/os-release
echo "########################################################"
echo -n " * Docker BorgServer powered by "
borg -V
echo " * Based on ${PRETTY_NAME}"
echo "########################################################"
echo " * User  id: $(id -u borg)"
echo " * Group id: $(id -g borg)"
echo "########################################################"


# Precheck if BORG_ADMIN is set
if [ "${BORG_APPEND_ONLY}" == "yes" ] && [ -z "${BORG_ADMIN}" ] && [ "${BORG_PRUNE_ENABLED}" != "yes" ] ; then
	echo "WARNING: BORG_APPEND_ONLY is active, but no BORG_ADMIN or BORG_PRUNE_ENABLED was specified!"
	echo "         This means old backups will never be removed automatically."
fi

# Precheck directories & client ssh-keys
for dir in BORG_DATA_DIR SSH_KEY_DIR ; do
	dirpath=$(eval echo '$'${dir})
	echo " * Testing Volume ${dir}: ${dirpath}"
	if [ ! -d "${dirpath}" ] ; then
		echo "ERROR: ${dirpath} is no directory!"
		exit 1
	fi

	if [ "$(find ${SSH_KEY_DIR}/clients ! -regex '.*/\..*' -a -type f | wc -l)" == "0" ] ; then
		echo "ERROR: No SSH-Pubkey file found in ${SSH_KEY_DIR}"
		exit 1
	fi
done

# Create SSH-Host-Keys on persistent storage, if not exist
mkdir -p ${SSH_KEY_DIR}/host 2>/dev/null
echo " * Checking / Preparing SSH Host-Keys..."
for keytype in ed25519 rsa ; do
	if [ ! -f "${SSH_KEY_DIR}/host/ssh_host_${keytype}_key" ] ; then
		echo "  ** Creating SSH Hostkey [${keytype}]..."
		ssh-keygen -q -f "${SSH_KEY_DIR}/host/ssh_host_${keytype}_key" -N '' -t ${keytype}
	fi
done

echo "########################################################"
echo " * Starting SSH-Key import..."

# Add every key to borg-users authorized_keys
rm ${AUTHORIZED_KEYS_PATH} &>/dev/null
for keyfile in $(find "${SSH_KEY_DIR}/clients" ! -regex '.*/\..*' -a -type f); do
    client_name=$(basename ${keyfile})
    mkdir ${BORG_DATA_DIR}/${client_name} 2>/dev/null
    echo "  ** Adding client ${client_name} with repo path ${BORG_DATA_DIR}/${client_name}"

	# If client is $BORG_ADMIN unset $client_name, so path restriction equals $BORG_DATA_DIR
	# Otherwise add --append-only, if enabled
	borg_cmd=${BORG_CMD}
	if [ "${client_name}" == "${BORG_ADMIN}" ] ; then
		echo "   ** Client '${client_name}' is BORG_ADMIN! **"
		unset client_name
	elif [ "${BORG_APPEND_ONLY}" == "yes" ] ; then
		borg_cmd="${BORG_CMD} --append-only"
	fi

  echo -n "restrict,command=\"$(eval echo -n \"${borg_cmd}\")\" " >> ${AUTHORIZED_KEYS_PATH}
  cat ${keyfile} >> ${AUTHORIZED_KEYS_PATH}
  echo >> ${AUTHORIZED_KEYS_PATH}
done
chmod 0600 "${AUTHORIZED_KEYS_PATH}"

echo " * Validating structure of generated ${AUTHORIZED_KEYS_PATH}..."
ERROR=$(ssh-keygen -lf ${AUTHORIZED_KEYS_PATH} 2>&1 >/dev/null)
if [ $? -ne 0 ]; then
    echo "ERROR: ${ERROR}"
    exit 1
fi

chown -R borg:borg ${BORG_DATA_DIR}
chown borg:borg ${AUTHORIZED_KEYS_PATH}
chmod 600 ${AUTHORIZED_KEYS_PATH}

echo "########################################################"
echo " * Setting up automatic prune..."

# Setup prune functionality
BORG_PRUNE_ENABLED=${BORG_PRUNE_ENABLED:-no}
BORG_PRUNE_SCHEDULE=${BORG_PRUNE_SCHEDULE:-"0 3 * * *"}

if [ "${BORG_PRUNE_ENABLED}" == "yes" ]; then
    echo "  ** Prune is ENABLED"
    echo "  ** Schedule: ${BORG_PRUNE_SCHEDULE}"
    
    # Create prune config if it doesn't exist
    if [ ! -f "${SSH_KEY_DIR}/prune.conf" ]; then
        echo "  ** Creating default prune configuration at ${SSH_KEY_DIR}/prune.conf"
        cp /prune.conf.example ${SSH_KEY_DIR}/prune.conf
    else
        echo "  ** Using existing prune configuration at ${SSH_KEY_DIR}/prune.conf"
    fi
    
    # Make prune script executable
    chmod +x /prune.sh
    
    # Setup cron for automatic pruning
    mkdir -p /var/log
    touch /var/log/borg-prune.log
    chown borg:borg /var/log/borg-prune.log
    
    # Create wrapper script with environment variables
    cat > /prune-env.sh << EOF
#!/bin/bash
export BORG_DATA_DIR=${BORG_DATA_DIR}
export CONFIG_DIR=${SSH_KEY_DIR}
export BORG_PRUNE_KEEP_DAILY=${BORG_PRUNE_KEEP_DAILY:-7}
export BORG_PRUNE_KEEP_WEEKLY=${BORG_PRUNE_KEEP_WEEKLY:-4}
export BORG_PRUNE_KEEP_MONTHLY=${BORG_PRUNE_KEEP_MONTHLY:-6}
export BORG_PRUNE_KEEP_YEARLY=${BORG_PRUNE_KEEP_YEARLY:-1}
exec /prune.sh
EOF
    chmod +x /prune-env.sh
    
    # Create cron job using the wrapper script
    echo "${BORG_PRUNE_SCHEDULE} root /prune-env.sh" > /etc/cron.d/borg-prune
    chmod 0644 /etc/cron.d/borg-prune
    
    echo "  ** Cron job installed for automatic pruning"
    
    # Start cron daemon
    cron
    echo "  ** Cron daemon started"
else
    echo "  ** Prune is DISABLED (set BORG_PRUNE_ENABLED=yes to enable)"
fi

echo "########################################################"
echo " * Init done! Starting SSH-Daemon..."

/usr/sbin/sshd -D -e
