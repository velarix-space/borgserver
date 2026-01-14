using System.Text.Json.Serialization;

namespace BorgServer;

/// <summary>
/// Configuration for the BorgServer
/// </summary>
public class BorgServerConfig
{
    /// <summary>
    /// User ID for the borg user (default: 1000)
    /// </summary>
    [JsonPropertyName("puid")]
    public int Puid { get; set; } = 1000;

    /// <summary>
    /// Group ID for the borg group (default: 1000)
    /// </summary>
    [JsonPropertyName("pgid")]
    public int Pgid { get; set; } = 1000;

    /// <summary>
    /// Directory where backup repositories are stored
    /// </summary>
    [JsonPropertyName("borg_data_dir")]
    public string BorgDataDir { get; set; } = "/backup";

    /// <summary>
    /// Directory where SSH keys are stored
    /// </summary>
    [JsonPropertyName("ssh_key_dir")]
    public string SshKeyDir { get; set; } = "/sshkeys";

    /// <summary>
    /// Additional arguments for borg serve command
    /// </summary>
    [JsonPropertyName("borg_serve_args")]
    public string BorgServeArgs { get; set; } = "";

    /// <summary>
    /// Enable append-only mode
    /// </summary>
    [JsonPropertyName("borg_append_only")]
    public bool BorgAppendOnly { get; set; } = false;

    /// <summary>
    /// Admin client name (has full access to all repos)
    /// </summary>
    [JsonPropertyName("borg_admin")]
    public string? BorgAdmin { get; set; }

    /// <summary>
    /// Prune configuration
    /// </summary>
    [JsonPropertyName("prune")]
    public PruneConfig? Prune { get; set; }

    /// <summary>
    /// Client configurations
    /// </summary>
    [JsonPropertyName("clients")]
    public Dictionary<string, ClientConfig>? Clients { get; set; }
}

/// <summary>
/// Prune configuration
/// </summary>
public class PruneConfig
{
    /// <summary>
    /// Enable pruning
    /// </summary>
    [JsonPropertyName("enabled")]
    public bool Enabled { get; set; } = false;

    /// <summary>
    /// Cron schedule for pruning (e.g., "0 2 * * *" for daily at 2 AM)
    /// </summary>
    [JsonPropertyName("schedule")]
    public string Schedule { get; set; } = "0 2 * * *";

    /// <summary>
    /// Enable compact after prune (frees up space)
    /// </summary>
    [JsonPropertyName("compact")]
    public bool Compact { get; set; } = false;

    /// <summary>
    /// Default prune rules (applied to all clients unless overridden)
    /// </summary>
    [JsonPropertyName("default_rules")]
    public PruneRules? DefaultRules { get; set; }
}

/// <summary>
/// Prune rules for keeping backups
/// </summary>
public class PruneRules
{
    /// <summary>
    /// Keep last N archives
    /// </summary>
    [JsonPropertyName("keep_last")]
    public int? KeepLast { get; set; }

    /// <summary>
    /// Keep N hourly archives
    /// </summary>
    [JsonPropertyName("keep_hourly")]
    public int? KeepHourly { get; set; }

    /// <summary>
    /// Keep N daily archives
    /// </summary>
    [JsonPropertyName("keep_daily")]
    public int? KeepDaily { get; set; }

    /// <summary>
    /// Keep N weekly archives
    /// </summary>
    [JsonPropertyName("keep_weekly")]
    public int? KeepWeekly { get; set; }

    /// <summary>
    /// Keep N monthly archives (-1 = keep all)
    /// </summary>
    [JsonPropertyName("keep_monthly")]
    public int? KeepMonthly { get; set; } = -1;

    /// <summary>
    /// Keep N yearly archives (-1 = keep all)
    /// </summary>
    [JsonPropertyName("keep_yearly")]
    public int? KeepYearly { get; set; } = -1;
}

/// <summary>
/// Client-specific configuration
/// </summary>
public class ClientConfig
{
    /// <summary>
    /// SSH public key for this client
    /// </summary>
    [JsonPropertyName("ssh_key")]
    public string? SshKey { get; set; }

    /// <summary>
    /// Storage quota for this client (e.g., "100G", "1T")
    /// </summary>
    [JsonPropertyName("quota")]
    public string? Quota { get; set; }

    /// <summary>
    /// Client-specific prune rules (overrides default)
    /// </summary>
    [JsonPropertyName("prune_rules")]
    public PruneRules? PruneRules { get; set; }
}
