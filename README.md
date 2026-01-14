# BorgServer - Docker image
Debian based container image, running openssh-daemon only accessable by user named "borg" using SSH-Publickey Auth & "borgbackup" as client. Backup-Repositoriees, client's SSH-Keys & SSHd's Hostkeys will be stored in persistent storage.
For every ssh-key added, a own borg-repository will be created.

**NEW**: BorgServer now features a C# entry point with configuration file support, automatic pruning, and quota management!

**NOTE: I will assume that you know, what a ssh-key is and how to generate & use it. If not, you might want to start here: [Arch Wiki](https://wiki.archlinux.org/index.php/SSH_Keys)**

## Configuration File

BorgServer can now be configured using a JSON configuration file. If no configuration file is provided, sensible defaults are used.

### Config File Location
- Default location: `/config/borgserver.json`
- Can be overridden with `BORGSERVER_CONFIG` environment variable

### Example Configuration
See [config.example.json](./config.example.json) for a complete example.

```json
{
  "puid": 1000,
  "pgid": 1000,
  "borg_data_dir": "/backup",
  "ssh_key_dir": "/sshkeys",
  "borg_append_only": true,
  "borg_admin": "admin_client",
  "prune": {
    "enabled": true,
    "schedule": "0 2 * * *",
    "compact": true,
    "default_rules": {
      "keep_daily": 7,
      "keep_weekly": 4,
      "keep_monthly": -1,
      "keep_yearly": -1
    }
  },
  "clients": {
    "webserver": {
      "ssh_key": "ssh-rsa AAAAB3NzaC1yc2E... webserver@example.com",
      "quota": "100G",
      "prune_rules": {
        "keep_daily": 14,
        "keep_weekly": 8,
        "keep_monthly": 12,
        "keep_yearly": 5
      }
    }
  }
}
```

### Configuration Options

#### Basic Settings
- `puid` (integer, default: 1000): User ID for the borg user
- `pgid` (integer, default: 1000): Group ID for the borg group
- `borg_data_dir` (string, default: "/backup"): Directory for backup repositories
- `ssh_key_dir` (string, default: "/sshkeys"): Directory for SSH keys
- `borg_serve_args` (string, default: ""): Additional arguments for borg serve
- `borg_append_only` (boolean, default: false): Enable append-only mode
- `borg_admin` (string): Admin client name with full access to all repos

#### Prune Configuration
- `prune.enabled` (boolean, default: false): Enable automatic pruning
- `prune.schedule` (string, default: "0 2 * * *"): Cron schedule for pruning
- `prune.compact` (boolean, default: false): Run `borg compact` after pruning to free space
- `prune.default_rules`: Default prune rules for all clients
  - `keep_last`: Keep last N archives
  - `keep_hourly`: Keep N hourly archives
  - `keep_daily`: Keep N daily archives
  - `keep_weekly`: Keep N weekly archives
  - `keep_monthly`: Keep N monthly archives (-1 = keep all, default: -1)
  - `keep_yearly`: Keep N yearly archives (-1 = keep all, default: -1)

#### Client Configuration
You can configure individual clients with:
- `ssh_key`: SSH public key (alternative to file-based keys)
- `quota`: Storage quota (e.g., "100G", "1T")
- `prune_rules`: Client-specific prune rules (overrides default)

### Schema Validation
The configuration file is validated against a schema. If you use invalid property names (typos), the server will fail to start with a clear error message.

### Using Config File with Docker

```bash
docker run -td \
  -p 2222:22 \
  --volume ./borg/config:/config \
  --volume ./borg/sshkeys:/sshkeys \
  --volume ./borg/backup:/backup \
  nold360/borgserver:latest
```

## Automatic Pruning

BorgServer now supports automatic pruning of old backups:

1. **Enable pruning** in your config file
2. **Set a schedule** using cron syntax (e.g., "0 2 * * *" for daily at 2 AM)
3. **Configure prune rules** globally or per-client
4. **Optional: Enable compact** to free up disk space after pruning

Pruning works with `BORG_APPEND_ONLY` mode, allowing you to keep repositories secure while still cleaning up old backups.

## Storage Quotas

You can now set storage quotas for individual clients using the `quota` field in the client configuration. Quotas are applied automatically when repositories are detected.

```json
{
  "clients": {
    "webserver": {
      "quota": "100G"
    }
  }
}
```

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
