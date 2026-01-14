############################################################
# Dockerfile to build borgbackup server images
# Based on Debian
############################################################
ARG BASE_IMAGE=debian:bookworm-slim

# Build stage
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /source

# Copy csproj and restore dependencies
COPY ./src/*.csproj ./
RUN dotnet restore

# Copy everything else and build
COPY ./src/. ./
RUN dotnet publish -c Release -o /app/publish

# Runtime stage
FROM $BASE_IMAGE

LABEL org.opencontainers.image.source="https://github.com/Nold360/borgserver"

# Volume for SSH-Keys
VOLUME /sshkeys

# Volume for borg repositories
VOLUME /backup

# Volume for config
VOLUME /config

ENV DEBIAN_FRONTEND=noninteractive

# Install .NET Runtime and dependencies
RUN apt-get update && apt-get -y --no-install-recommends install \
		ca-certificates \
		wget \
		borgbackup openssh-server && \
		wget https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -O packages-microsoft-prod.deb && \
		dpkg -i packages-microsoft-prod.deb && \
		rm packages-microsoft-prod.deb && \
		apt-get update && \
		apt-get -y --no-install-recommends install dotnet-runtime-8.0 && \
		apt-get clean && \
		useradd -s /bin/bash -m -U borg && \
		mkdir /home/borg/.ssh && \
		chmod 700 /home/borg/.ssh && \
		chown borg:borg /home/borg/.ssh && \
		mkdir -p /run/sshd && \
		rm -f /etc/ssh/ssh_host*key* && \
		rm -rf /var/lib/apt/lists/* /var/tmp/* /tmp/*

COPY ./data/sshd_config /etc/ssh/sshd_config

# Copy built application from build stage
COPY --from=build /app/publish /app

# Default SSH-Port for clients
EXPOSE 22

ENTRYPOINT ["dotnet", "/app/BorgServer.dll"]
