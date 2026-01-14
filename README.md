# BorgServer - Docker image
Debian based container image, running openssh-daemon only accessable by user named "borg" using SSH-Publickey Auth & "borgbackup" as client. Backup-Repositoriees, client's SSH-Keys & SSHd's Hostkeys will be stored in persistent storage.
For every ssh-key added, a own borg-repository will be created.

**NOTE: I will assume that you know, what a ssh-key is and how to generate & use it. If not, you might want to start here: [Arch Wiki](https://wiki.archlinux.org/index.php/SSH_Keys)**

## Quick Example
Here is a quick example how to configure & run this image:

### Create persistent sshkey storage
```
 $ mkdir -p borg/sshkeys/clients
```

Make sure that the permissions are right on the sshkey folder:
```
 $ chown 1000:1000 borg/sshkeys
```

### (Generate &) Copy every client's ssh publickey into persistent storage
*Remember*: Filename = Borg-repository name!
```
 $ cp ~/.ssh/my_machine.pub borg/sshkeys/clients/my_machine
```

The OpenSSH-Deamon will expose on port 22/tcp - so you will most likely want to redirect it to a different port. Like in this example:
```
docker run -td \
	-p 2222:22  \
	--volume ./borg/sshkeys:/sshkeys \
	--volume ./borg/backup:/backup \
	nold360/borgserver:latest
```


## Borgserver Configuration
 * Place Borg-Clients SSH-PublicKeys in persistent storage
 * Client backup-directories will be named by the filename found in /sshkeys/clients/

### Environment Variables
#### BORG_SERVE_ARGS
Use this variable if you want to set special options for the "borg serve"-command, which is used internally.

See the the documentation for all available arguments: [borgbackup.readthedocs.io](https://borgbackup.readthedocs.io/en/stable/usage.html#borg-serve)

##### Example
```
docker run --rm -e BORG_SERVE_ARGS="--progress --debug" (...) nold360/borgserver
```

#### BORG_APPEND_ONLY
If you want your client to be only able to append & not prune anything from their repo, set this variable to **"yes"**.

**NEW**: When `BORG_APPEND_ONLY` is enabled, automatic pruning is now supported! After each successful backup session, the server will automatically run `borg prune` with configurable retention policies. This allows you to keep `BORG_APPEND_ONLY` enabled for security while still managing repository size.


#### Automatic Prune Configuration
When `BORG_APPEND_ONLY` is enabled, the server automatically runs `borg prune` after successful backup sessions. You can configure the retention policy using environment variables for global defaults, or per-client configuration files for client-specific rules.

##### Global Default Prune Settings (Environment Variables)
These environment variables set the default prune retention policy for all clients:

- **BORG_PRUNE_ENABLED** - Enable/disable automatic pruning (default: `yes`)
- **BORG_PRUNE_KEEP_LAST** - Number of most recent archives to keep
- **BORG_PRUNE_KEEP_HOURLY** - Number of hourly archives to keep
- **BORG_PRUNE_KEEP_DAILY** - Number of daily archives to keep (default: `7`)
- **BORG_PRUNE_KEEP_WEEKLY** - Number of weekly archives to keep (default: `4`)
- **BORG_PRUNE_KEEP_MONTHLY** - Number of monthly archives to keep (default: `6`)
- **BORG_PRUNE_KEEP_YEARLY** - Number of yearly archives to keep

##### Example with Global Prune Settings
```
docker run --rm \
  -e BORG_APPEND_ONLY="yes" \
  -e BORG_PRUNE_KEEP_DAILY="14" \
  -e BORG_PRUNE_KEEP_WEEKLY="8" \
  -e BORG_PRUNE_KEEP_MONTHLY="12" \
  (...) nold360/borgserver
```

##### Per-Client Prune Configuration
You can override the global defaults for specific clients by creating configuration files in `/sshkeys/clients/.prune/`. Each client can have their own prune policy.

Create a file named `/sshkeys/clients/.prune/<client_name>.conf` with the following format:

```
# Prune configuration for client_name
PRUNE_ENABLED=yes
PRUNE_KEEP_DAILY=30
PRUNE_KEEP_WEEKLY=8
PRUNE_KEEP_MONTHLY=12
PRUNE_KEEP_YEARLY=2
```

Example for different clients:
```bash
# High-frequency backups with longer retention
echo "PRUNE_KEEP_DAILY=30" > /sshkeys/clients/.prune/production_server.conf
echo "PRUNE_KEEP_WEEKLY=12" >> /sshkeys/clients/.prune/production_server.conf

# Low-frequency backups with shorter retention  
echo "PRUNE_KEEP_DAILY=7" > /sshkeys/clients/.prune/test_machine.conf
echo "PRUNE_KEEP_WEEKLY=4" >> /sshkeys/clients/.prune/test_machine.conf

# Disable automatic pruning for a specific client
echo "PRUNE_ENABLED=no" > /sshkeys/clients/.prune/archive_server.conf
```


#### BORG_ADMIN
When *BORG_APPEND_ONLY* is active, clients cannot manually prune their repos, but automatic server-side pruning runs after successful backups (see above). 

If you need manual control or want to prune other clients' repos, you can declare one client to be the borg "admin".

This client will have **full access to all repos of any client!** So he's able to add/prune/... whatever he wants.

To declare a client as admin, set this variable to the name of the client/sshkey you've added to the /sshkeys/clients directory.

##### Example
```
docker run --rm -e BORG_APPEND_ONLY="yes" -e BORG_ADMIN="nolds_notebook" (...) nold360/borgserver
```

To prune repos from another client, you have to add the path to the repository in the clients directory:
```
borg prune --keep-last 100 --keep-weekly 1 (...) borgserver:/clientA/clientA
```


#### PUID
Used to set the user id of the `borg` user inside the container. This can be useful when the container has to access resources on the host with a specific user id.


#### PGID
Used to set the group id of the `borg` group inside the container. This can be useful when the container has to access resources on the host with a specific group id.


### Persistent Storages & Client Configuration
We will need two persistent storage directories for our borgserver to be usefull.

#### /sshkeys
This directory has two subdirectories:

##### /sshkeys/clients/
Here we will put all SSH public keys from our borg clients, we want to backup. Every key must be it's own file, containing only one line, with the key. The name of the file will become the name of the borg repository, we need for our client to connect.

That means every client get's it's own repository. So you might want to use the hostname of the client as the name of the sshkey file.

Hidden files & files inside of hidden directories will be ignored!

```
e.g. /sshkeys/clients/webserver.mydomain.com
```

Than your client would have to initiat the borg repository like this:
```
webserver.mydomain.com ~$ borg init ssh://borg@borgserver-container/backup/webserver.mydomain.com/my_first_repo
```

**!IMPORTANT!**: The container wouldn't start the SSH-Deamon until there is at least one ssh-keyfile in this directory!

##### /sshkeys/host/
This directory will be automaticly created on first start. Also run.sh will copy the SSH-Hostkeys here, so your clients can verify it's borgservers ssh-hostkey.

#### /backup
In this directory will borg write all the client data to. It's best to start with an empty directory.


## Example Setup
### docker-compose.yml
Here is a quick example, how to run borgserver using docker-compose: [docker-compose.yml](https://github.com/Nold360/docker-borgserver/blob/master/docker-compose.yml)

### ~/.ssh/config for clients
With this configuration (on your borg client) you can easily connect to your borgserver.
```
Host backup
	Hostname my.docker.host
	Port 2222
	User borg
```

Now initiate a borg-repository like this:
```
 $ borg init backup:my_first_borg_repo
```

And create your first backup!
```
 $ borg create backup:my_first_borg_repo::documents-2017-11-01 /home/user/MyImportentDocs
```

## Docker Releases

All images are freshly built and published to both Docker Hub and GitHub Container Registry with the following tags:
  - Stable - [borg version](https://packages.debian.org/trixie/borgbackup): `trixie`, `latest`
  - Old Stable - [borg version](https://packages.debian.org/stable/borgbackup): `bookworm`
  - Unstable - [borg version](https://packages.debian.org/sid/borgbackup): `unstable`

### Docker Hub
- `nold360/borgserver`

### GitHub Container Registry
- `ghcr.io/nold360/borgserver`

All images are built every week and include the latest security updates and bug fixes. The same tags are pushed to both Docker Hub and GitHub Container Registry.
