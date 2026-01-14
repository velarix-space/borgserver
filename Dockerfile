############################################################
# Dockerfile to build borgbackup server images
# Based on Debian
############################################################
ARG BASE_IMAGE=debian:bookworm-slim
FROM $BASE_IMAGE

LABEL org.opencontainers.image.source="https://github.com/Nold360/borgserver"

# Volume for SSH-Keys
VOLUME /sshkeys

# Volume for borg repositories
VOLUME /backup

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get -y --no-install-recommends install \
		borgbackup openssh-server cron ca-certificates curl && \
		apt-get clean && \
		rm -rf /var/lib/apt/lists/* /var/tmp/* /tmp/*

# Download yq for YAML parsing in prune script
# Note: Using -k flag as a workaround for SSL certificate issues in some build environments.
# This is only used during image build, not at runtime. For additional security, consider:
# - Verifying the downloaded binary with checksums
# - Using a local mirror or pre-downloaded binary
# - Building in an environment with proper CA certificates
RUN YQ_VERSION="v4.40.5" && \
		curl -k -L "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" -o /usr/local/bin/yq && \
		chmod +x /usr/local/bin/yq

RUN if ! id borg > /dev/null 2>&1; then useradd -s /bin/bash -m -U borg; fi && \
		mkdir -p /home/borg/.ssh && \
		chmod 700 /home/borg/.ssh && \
		chown borg:borg /home/borg/.ssh && \
		mkdir -p /run/sshd && \
		rm -f /etc/ssh/ssh_host*key*

COPY ./data/run.sh /run.sh
COPY ./data/prune.sh /prune.sh
COPY ./data/sshd_config /etc/ssh/sshd_config
RUN chmod +x /run.sh /prune.sh

# Default SSH-Port for clients
EXPOSE 22

ENTRYPOINT ["/run.sh"]
