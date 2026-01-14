using System.Text.Json;
using System.Text.Json.Nodes;

namespace BorgServer;

/// <summary>
/// Handles loading and validating configuration
/// </summary>
public class ConfigLoader
{
    private static readonly string[] ValidConfigKeys = new[]
    {
        "puid", "pgid", "borg_data_dir", "ssh_key_dir", "borg_serve_args",
        "borg_append_only", "borg_admin", "prune", "clients"
    };

    private static readonly string[] ValidPruneKeys = new[]
    {
        "enabled", "schedule", "compact", "default_rules"
    };

    private static readonly string[] ValidPruneRulesKeys = new[]
    {
        "keep_last", "keep_hourly", "keep_daily", "keep_weekly", "keep_monthly", "keep_yearly"
    };

    private static readonly string[] ValidClientKeys = new[]
    {
        "ssh_key", "quota", "prune_rules"
    };

    /// <summary>
    /// Load configuration from file or use defaults
    /// </summary>
    public static BorgServerConfig LoadConfig(string? configPath = null)
    {
        configPath ??= Environment.GetEnvironmentVariable("BORGSERVER_CONFIG") ?? "/config/borgserver.json";

        if (File.Exists(configPath))
        {
            Console.WriteLine($"Loading configuration from: {configPath}");
            var json = File.ReadAllText(configPath);
            
            // Validate schema first
            ValidateSchema(json);
            
            // Deserialize
            var config = JsonSerializer.Deserialize<BorgServerConfig>(json, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true,
                AllowTrailingCommas = true,
                ReadCommentHandling = JsonCommentHandling.Skip
            });

            if (config == null)
            {
                throw new InvalidOperationException("Failed to deserialize configuration");
            }

            // Apply environment variable overrides
            ApplyEnvironmentOverrides(config);
            
            // Validate configuration
            ValidateConfig(config);
            
            return config;
        }
        else
        {
            Console.WriteLine($"No configuration file found at {configPath}, using defaults");
            var config = new BorgServerConfig();
            
            // Apply environment variable overrides
            ApplyEnvironmentOverrides(config);
            
            // Validate configuration
            ValidateConfig(config);
            
            return config;
        }
    }

    /// <summary>
    /// Validate JSON schema to catch typos
    /// </summary>
    private static void ValidateSchema(string json)
    {
        var doc = JsonNode.Parse(json);
        if (doc == null) return;

        var rootObj = doc.AsObject();
        
        // Check root level keys
        foreach (var prop in rootObj)
        {
            if (!ValidConfigKeys.Contains(prop.Key))
            {
                throw new InvalidOperationException(
                    $"Invalid configuration property '{prop.Key}'. Valid properties are: {string.Join(", ", ValidConfigKeys)}");
            }
        }

        // Check prune keys
        if (rootObj.TryGetPropertyValue("prune", out var pruneNode) && pruneNode != null)
        {
            var pruneObj = pruneNode.AsObject();
            foreach (var prop in pruneObj)
            {
                if (!ValidPruneKeys.Contains(prop.Key))
                {
                    throw new InvalidOperationException(
                        $"Invalid prune property '{prop.Key}'. Valid properties are: {string.Join(", ", ValidPruneKeys)}");
                }
            }

            // Check default_rules keys
            if (pruneObj.TryGetPropertyValue("default_rules", out var rulesNode) && rulesNode != null)
            {
                var rulesObj = rulesNode.AsObject();
                foreach (var prop in rulesObj)
                {
                    if (!ValidPruneRulesKeys.Contains(prop.Key))
                    {
                        throw new InvalidOperationException(
                            $"Invalid prune rules property '{prop.Key}'. Valid properties are: {string.Join(", ", ValidPruneRulesKeys)}");
                    }
                }
            }
        }

        // Check clients keys
        if (rootObj.TryGetPropertyValue("clients", out var clientsNode) && clientsNode != null)
        {
            var clientsObj = clientsNode.AsObject();
            foreach (var client in clientsObj)
            {
                if (client.Value != null)
                {
                    var clientObj = client.Value.AsObject();
                    foreach (var prop in clientObj)
                    {
                        if (!ValidClientKeys.Contains(prop.Key))
                        {
                            throw new InvalidOperationException(
                                $"Invalid client property '{prop.Key}' for client '{client.Key}'. Valid properties are: {string.Join(", ", ValidClientKeys)}");
                        }
                    }

                    // Check prune_rules keys
                    if (clientObj.TryGetPropertyValue("prune_rules", out var clientRulesNode) && clientRulesNode != null)
                    {
                        var clientRulesObj = clientRulesNode.AsObject();
                        foreach (var prop in clientRulesObj)
                        {
                            if (!ValidPruneRulesKeys.Contains(prop.Key))
                            {
                                throw new InvalidOperationException(
                                    $"Invalid prune rules property '{prop.Key}' for client '{client.Key}'. Valid properties are: {string.Join(", ", ValidPruneRulesKeys)}");
                            }
                        }
                    }
                }
            }
        }
    }

    /// <summary>
    /// Apply environment variable overrides
    /// </summary>
    private static void ApplyEnvironmentOverrides(BorgServerConfig config)
    {
        var puid = Environment.GetEnvironmentVariable("PUID");
        if (!string.IsNullOrEmpty(puid) && int.TryParse(puid, out var puidValue))
        {
            config.Puid = puidValue;
        }

        var pgid = Environment.GetEnvironmentVariable("PGID");
        if (!string.IsNullOrEmpty(pgid) && int.TryParse(pgid, out var pgidValue))
        {
            config.Pgid = pgidValue;
        }

        var appendOnly = Environment.GetEnvironmentVariable("BORG_APPEND_ONLY");
        if (!string.IsNullOrEmpty(appendOnly))
        {
            config.BorgAppendOnly = appendOnly.Equals("yes", StringComparison.OrdinalIgnoreCase);
        }

        var admin = Environment.GetEnvironmentVariable("BORG_ADMIN");
        if (!string.IsNullOrEmpty(admin))
        {
            config.BorgAdmin = admin;
        }

        var serveArgs = Environment.GetEnvironmentVariable("BORG_SERVE_ARGS");
        if (!string.IsNullOrEmpty(serveArgs))
        {
            config.BorgServeArgs = serveArgs;
        }
    }

    /// <summary>
    /// Validate configuration
    /// </summary>
    private static void ValidateConfig(BorgServerConfig config)
    {
        if (string.IsNullOrEmpty(config.BorgDataDir))
        {
            throw new InvalidOperationException("borg_data_dir cannot be empty");
        }

        if (string.IsNullOrEmpty(config.SshKeyDir))
        {
            throw new InvalidOperationException("ssh_key_dir cannot be empty");
        }

        if (config.Puid <= 0)
        {
            throw new InvalidOperationException("puid must be greater than 0");
        }

        if (config.Pgid <= 0)
        {
            throw new InvalidOperationException("pgid must be greater than 0");
        }

        if (config.BorgAppendOnly && string.IsNullOrEmpty(config.BorgAdmin))
        {
            Console.WriteLine("WARNING: BORG_APPEND_ONLY is active, but no BORG_ADMIN was specified!");
        }

        // Validate prune schedule if enabled
        if (config.Prune?.Enabled == true)
        {
            try
            {
                NCrontab.CrontabSchedule.Parse(config.Prune.Schedule);
            }
            catch (Exception ex)
            {
                throw new InvalidOperationException($"Invalid prune schedule '{config.Prune.Schedule}': {ex.Message}");
            }
        }
    }
}
