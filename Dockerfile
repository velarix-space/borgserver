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
		borgbackup openssh-server cron wget && apt-get clean && \
		wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && \
		chmod +x /usr/local/bin/yq && \
		useradd -s /bin/bash -m -U borg && \
		mkdir /home/borg/.ssh && \
		chmod 700 /home/borg/.ssh && \
		chown borg:borg /home/borg/.ssh && \
		mkdir -p /run/sshd && \
		rm -f /etc/ssh/ssh_host*key* && \
		rm -rf /var/lib/apt/lists/* /var/tmp/* /tmp/*

COPY ./data/run.sh /run.sh
COPY ./data/prune.sh /prune.sh
COPY ./data/sshd_config /etc/ssh/sshd_config
RUN chmod +x /run.sh /prune.sh

# Default SSH-Port for clients
EXPOSE 22

ENTRYPOINT ["/run.sh"]
