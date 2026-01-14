# Migration Guide: Bash to C# BorgServer

This guide helps you migrate from the bash-based BorgServer to the new C# version with config file support.

## What Changed?

### Before (Bash)
- Entry point: `/run.sh`
- Configuration: Environment variables only
- SSH keys: Files in `/sshkeys/clients/`
- No automatic pruning
- No quota management

### After (C#)
- Entry point: C# application
- Configuration: Config file + environment variables (env vars override config)
- SSH keys: Files in `/sshkeys/clients/` OR config file
- Automatic pruning with cron scheduling
- Quota management per client

## Migration Paths

### Option 1: Keep Using Environment Variables (No Changes Needed)

The new version is **100% backward compatible**. If you're using environment variables, nothing changes:

```bash
docker run -td \
  -p 2222:22 \
  --volume ./borg/sshkeys:/sshkeys \
  --volume ./borg/backup:/backup \
  -e BORG_APPEND_ONLY="yes" \
  -e BORG_ADMIN="admin_client" \
  nold360/borgserver:latest
```

This works exactly as before. SSH keys are read from `/sshkeys/clients/` as usual.

### Option 2: Migrate to Config File

Create a config file for more features:

1. **Create config directory:**
   ```bash
   mkdir -p ./borg/config
   ```

2. **Create `borgserver.json`:**
   ```json
   {
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
     }
   }
   ```

3. **Update docker-compose.yml:**
   ```yaml
   version: '3'
   services:
     borgserver:
       image: nold360/borgserver:latest
       volumes:
         - ./borg/backup:/backup
         - ./borg/sshkeys:/sshkeys
         - ./borg/config:/config  # Add this line
       ports:
         - "2222:22"
       restart: unless-stopped
   ```

4. **Start container:**
   ```bash
   docker-compose up -d
   ```

### Option 3: Move SSH Keys to Config

If you want to manage SSH keys in the config file:

```json
{
  "clients": {
    "webserver": {
      "ssh_key": "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC... webserver@example.com",
      "quota": "100G",
      "prune_rules": {
        "keep_daily": 14,
        "keep_weekly": 8,
        "keep_monthly": 12,
        "keep_yearly": 5
      }
    },
    "laptop": {
      "ssh_key": "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQD... laptop@example.com",
      "quota": "50G"
    }
  }
}
```

**Note:** Config keys override file-based keys for the same client name.

## New Features

### Automatic Pruning

Enable scheduled pruning to clean up old backups:

```json
{
  "prune": {
    "enabled": true,
    "schedule": "0 2 * * *",  // Daily at 2 AM
    "compact": true,           // Free disk space after prune
    "default_rules": {
      "keep_daily": 7,
      "keep_weekly": 4,
      "keep_monthly": -1,     // -1 = keep all
      "keep_yearly": -1       // -1 = keep all
    }
  }
}
```

### Storage Quotas

Set storage limits for clients:

```json
{
  "clients": {
    "webserver": {
      "quota": "100G"
    }
  }
}
```

Quotas are applied to existing repositories automatically.

### Per-Client Prune Rules

Override default prune rules per client:

```json
{
  "clients": {
    "important_server": {
      "prune_rules": {
        "keep_daily": 30,
        "keep_weekly": 12,
        "keep_monthly": 24,
        "keep_yearly": 10
      }
    }
  }
}
```

## Configuration Reference

### All Configuration Options

```json
{
  "puid": 1000,
  "pgid": 1000,
  "borg_data_dir": "/backup",
  "ssh_key_dir": "/sshkeys",
  "borg_serve_args": "",
  "borg_append_only": false,
  "borg_admin": "admin_client",
  "prune": {
    "enabled": false,
    "schedule": "0 2 * * *",
    "compact": false,
    "default_rules": {
      "keep_last": 5,
      "keep_hourly": 24,
      "keep_daily": 7,
      "keep_weekly": 4,
      "keep_monthly": -1,
      "keep_yearly": -1
    }
  },
  "clients": {
    "client_name": {
      "ssh_key": "ssh-rsa AAAA...",
      "quota": "100G",
      "prune_rules": {
        "keep_daily": 14
      }
    }
  }
}
```

### Environment Variable Overrides

These environment variables override config file settings:

- `PUID`: User ID for borg user
- `PGID`: Group ID for borg group
- `BORG_APPEND_ONLY`: Enable append-only mode ("yes" or "no")
- `BORG_ADMIN`: Admin client name
- `BORG_SERVE_ARGS`: Additional borg serve arguments
- `BORGSERVER_CONFIG`: Path to config file (default: `/config/borgserver.json`)

## Troubleshooting

### Config Validation Errors

The new version validates your config file. If you have a typo in a property name, it will fail with a clear error:

```
ERROR: Invalid configuration property 'borg_append_onlu'. 
Valid properties are: puid, pgid, borg_data_dir, ssh_key_dir, borg_serve_args, borg_append_only, borg_admin, prune, clients
```

### Checking Logs

View logs to see what's happening:

```bash
docker logs borgserver
```

You should see output like:

```
########################################################
 * Docker BorgServer (C# Edition)
 * Powered by borg 1.2.4
 * Based on Debian GNU/Linux 12 (bookworm)
########################################################
Loading configuration from: /config/borgserver.json
 * Setting user ID to 1000 and group ID to 1000
 * User  id: 1000
 * Group id: 1000
########################################################
 * Checking / Preparing SSH Host-Keys...
########################################################
 * Starting SSH-Key import...
  ** Adding client webserver with repo path /backup/webserver
   ** Applying quota 100G to client webserver
########################################################
 * Init done! Starting SSH-Daemon...
```

### Rollback

If you need to rollback to the bash version, use an older tag:

```bash
docker pull nold360/borgserver:bookworm
```

Or specify the old version in docker-compose.yml:

```yaml
services:
  borgserver:
    image: nold360/borgserver:bookworm  # Use old version
```

## Benefits of Migrating

1. **Automatic Cleanup**: Schedule prune operations to keep backups under control
2. **Quota Management**: Prevent clients from using too much space
3. **Centralized Config**: Manage all settings in one place
4. **Type Safety**: Schema validation catches configuration errors early
5. **Better Logging**: Structured output with clear error messages
6. **JSON Parsing**: Cleaner borg output parsing with --json flag

## Support

If you encounter issues, please open an issue on GitHub:
https://github.com/Nold360/borgserver/issues
