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


#### BORG_ADMIN
When *BORG_APPEND_ONLY* is active, no client is able to prune it's repo. 
Since you might want to cleanup the repos at some point, you can declare one client to be the borg "admin".

This client will have **full access to all repos of any client!** So he's able to add/prune/... what ever he wants.

To declare a client as admin, set this variable to the name of the client/sshkey you've added to the /sshkeys/clients directory.

##### Example
```
docker run --rm -e BORG_APPEND_ONLY="yes" -e BORG_ADMIN="nolds_notebook" (...) nold360/borgserver
```

To prune repos from another client, you have to add the path to the repository in the clients directory:
```
borg prune --keep-last 100 --keep-weekly 1 (...) borgserver:/clientA/clientA
```


#### BORG_PRUNE_ENABLED
When set to **"yes"**, enables scheduled automatic pruning of all repositories. This is useful when *BORG_APPEND_ONLY* is active, as it allows automatic cleanup without requiring manual intervention or BORG_ADMIN access.

Pruning rules are configured via a YAML configuration file (see BORG_PRUNE_CONFIG below).

**Note**: When pruning is enabled, the container will also run `borg compact` after each prune operation to reclaim disk space.

##### Example
```
docker run --rm -e BORG_APPEND_ONLY="yes" -e BORG_PRUNE_ENABLED="yes" \
  -v ./config:/config (...) nold360/borgserver
```


#### BORG_PRUNE_SCHEDULE
Sets the cron schedule for automatic pruning. Only takes effect when *BORG_PRUNE_ENABLED* is set to "yes".

Default: `"0 2 * * *"` (daily at 2:00 AM)

The schedule follows standard cron format: `minute hour day month weekday`

##### Examples
```
# Run pruning every 6 hours
BORG_PRUNE_SCHEDULE="0 */6 * * *"

# Run pruning weekly on Sunday at 3 AM
BORG_PRUNE_SCHEDULE="0 3 * * 0"

# Run pruning monthly on the 1st at midnight
BORG_PRUNE_SCHEDULE="0 0 1 * *"
```


#### BORG_PRUNE_CONFIG
Path to the YAML configuration file that defines pruning rules.

Default: `/config/prune-config.yml`

The configuration file must exist and be valid when *BORG_PRUNE_ENABLED* is set to "yes", otherwise the container will fail to start.

See the [Prune Configuration](#prune-configuration) section below for details on the configuration file format.


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

#### /config
This directory is used for configuration files, particularly the prune configuration file when scheduled pruning is enabled.

When *BORG_PRUNE_ENABLED* is set to "yes", you must mount this volume and provide a `prune-config.yml` file.


### Prune Configuration
When scheduled pruning is enabled (*BORG_PRUNE_ENABLED=yes*), you need to provide a YAML configuration file that defines the retention rules for your repositories.

#### Configuration File Format
The configuration file has two main sections:

1. **defaults**: Global retention rules applied to all repositories unless overridden
2. **clients**: Per-client overrides for specific repositories

##### Example Configuration
```yaml
# Global defaults (applied to all clients unless overridden)
# Use -1 for month and year to keep all archives from those periods
defaults:
  keep_hourly: 24      # Keep hourly backups for the last 24 hours
  keep_daily: 7        # Keep daily backups for the last 7 days
  keep_weekly: 4       # Keep weekly backups for the last 4 weeks
  keep_monthly: -1     # Keep all monthly backups (default)
  keep_yearly: -1      # Keep all yearly backups (default)

# Per-client prune rules (overrides defaults)
# The key must match the SSH key filename in /sshkeys/clients/
clients:
  # Custom rules for a specific client
  webserver.example.com:
    keep_hourly: 48
    keep_daily: 14
    keep_weekly: 8
    keep_monthly: 6
    keep_yearly: 2
  
  # Another client using mostly defaults, but keeping 12 months
  backup-client:
    keep_monthly: 12
```

An example configuration file is available in the repository at `data/prune-config.example.yml`.

#### Retention Rules
- **keep_hourly**: Number of hourly backups to keep
- **keep_daily**: Number of daily backups to keep
- **keep_weekly**: Number of weekly backups to keep
- **keep_monthly**: Number of monthly backups to keep (-1 to keep all)
- **keep_yearly**: Number of yearly backups to keep (-1 to keep all)

Setting a value to 0 or omitting it means that retention rule won't be applied. Setting to -1 (for monthly/yearly) keeps all archives in that category.

#### How It Works
1. The container validates the configuration file on startup
2. At the scheduled time (defined by *BORG_PRUNE_SCHEDULE*), the prune script runs
3. For each repository, it applies the retention rules (client-specific or defaults)
4. After pruning, it runs `borg compact` to reclaim disk space
5. All operations are logged to `/var/log/borg-prune.log` inside the container


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
