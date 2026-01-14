using System.Diagnostics;
using System.Text;
using System.Text.Json;
using NCrontab;

namespace BorgServer;

/// <summary>
/// Handles scheduled pruning of borg repositories
/// </summary>
public class PruneScheduler
{
    private readonly BorgServerConfig _config;
    private CrontabSchedule? _schedule;
    private DateTime? _nextRun;
    private Timer? _timer;

    public PruneScheduler(BorgServerConfig config)
    {
        _config = config;
    }

    /// <summary>
    /// Start the prune scheduler
    /// </summary>
    public void Start()
    {
        if (_config.Prune?.Enabled != true)
        {
            Console.WriteLine("Pruning is disabled");
            return;
        }

        Console.WriteLine($"Starting prune scheduler with schedule: {_config.Prune.Schedule}");
        _schedule = CrontabSchedule.Parse(_config.Prune.Schedule);
        _nextRun = _schedule.GetNextOccurrence(DateTime.Now);
        
        Console.WriteLine($"Next prune scheduled for: {_nextRun}");

        // Check every minute if we need to run
        _timer = new Timer(CheckAndRunPrune, null, TimeSpan.Zero, TimeSpan.FromMinutes(1));
    }

    /// <summary>
    /// Stop the scheduler
    /// </summary>
    public void Stop()
    {
        _timer?.Dispose();
    }

    /// <summary>
    /// Check if it's time to run and execute prune
    /// </summary>
    private void CheckAndRunPrune(object? state)
    {
        if (_nextRun == null || DateTime.Now < _nextRun)
        {
            return;
        }

        Console.WriteLine("########################################################");
        Console.WriteLine($" * Running scheduled prune at {DateTime.Now}");
        
        try
        {
            RunPrune();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"ERROR: Prune failed: {ex.Message}");
        }

        // Schedule next run
        if (_schedule != null)
        {
            _nextRun = _schedule.GetNextOccurrence(DateTime.Now);
            Console.WriteLine($"Next prune scheduled for: {_nextRun}");
        }
    }

    /// <summary>
    /// Run prune on all client repositories
    /// </summary>
    public void RunPrune()
    {
        Console.WriteLine("Starting prune operation...");

        // Get all client directories
        var clientDirs = Directory.GetDirectories(_config.BorgDataDir);

        foreach (var clientDir in clientDirs)
        {
            var clientName = Path.GetFileName(clientDir);
            
            // Skip admin if it matches BORG_ADMIN
            if (clientName == _config.BorgAdmin)
            {
                Console.WriteLine($" * Skipping admin client: {clientName}");
                continue;
            }

            Console.WriteLine($" * Pruning repositories for client: {clientName}");

            // Get prune rules for this client
            var pruneRules = GetPruneRules(clientName);
            if (pruneRules == null)
            {
                Console.WriteLine($"   No prune rules configured for {clientName}, skipping");
                continue;
            }

            // Find all borg repositories in this client directory
            var repos = Directory.GetDirectories(clientDir)
                .Where(d => File.Exists(Path.Combine(d, "config")))
                .ToList();

            foreach (var repo in repos)
            {
                try
                {
                    PruneRepository(repo, pruneRules);
                    
                    if (_config.Prune?.Compact == true)
                    {
                        CompactRepository(repo);
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"   ** Error pruning {repo}: {ex.Message}");
                }
            }
        }

        Console.WriteLine("Prune operation completed");
    }

    /// <summary>
    /// Get prune rules for a specific client
    /// </summary>
    private PruneRules? GetPruneRules(string clientName)
    {
        // Check for client-specific rules
        if (_config.Clients != null && 
            _config.Clients.TryGetValue(clientName, out var clientConfig) &&
            clientConfig.PruneRules != null)
        {
            return clientConfig.PruneRules;
        }

        // Use default rules
        return _config.Prune?.DefaultRules;
    }

    /// <summary>
    /// Prune a specific repository
    /// </summary>
    private void PruneRepository(string repoPath, PruneRules rules)
    {
        Console.WriteLine($"   ** Pruning {repoPath}");

        var args = new StringBuilder();
        args.Append($"prune --list --stats --json \"{repoPath}\"");

        if (rules.KeepLast.HasValue && rules.KeepLast.Value >= 0)
        {
            args.Append($" --keep-last {rules.KeepLast.Value}");
        }

        if (rules.KeepHourly.HasValue && rules.KeepHourly.Value >= 0)
        {
            args.Append($" --keep-hourly {rules.KeepHourly.Value}");
        }

        if (rules.KeepDaily.HasValue && rules.KeepDaily.Value >= 0)
        {
            args.Append($" --keep-daily {rules.KeepDaily.Value}");
        }

        if (rules.KeepWeekly.HasValue && rules.KeepWeekly.Value >= 0)
        {
            args.Append($" --keep-weekly {rules.KeepWeekly.Value}");
        }

        if (rules.KeepMonthly.HasValue)
        {
            if (rules.KeepMonthly.Value == -1)
            {
                // -1 means keep all monthly archives
                args.Append(" --keep-monthly -1");
            }
            else if (rules.KeepMonthly.Value > 0)
            {
                args.Append($" --keep-monthly {rules.KeepMonthly.Value}");
            }
        }

        if (rules.KeepYearly.HasValue)
        {
            if (rules.KeepYearly.Value == -1)
            {
                // -1 means keep all yearly archives
                args.Append(" --keep-yearly -1");
            }
            else if (rules.KeepYearly.Value > 0)
            {
                args.Append($" --keep-yearly {rules.KeepYearly.Value}");
            }
        }

        var process = Process.Start(new ProcessStartInfo
        {
            FileName = "borg",
            Arguments = args.ToString(),
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        });

        if (process != null)
        {
            process.WaitForExit();
            var output = process.StandardOutput.ReadToEnd();
            var error = process.StandardError.ReadToEnd();

            if (process.ExitCode != 0)
            {
                throw new InvalidOperationException($"Prune failed: {error}");
            }

            // Try to parse JSON output
            try
            {
                using var doc = JsonDocument.Parse(output);
                var root = doc.RootElement;
                
                if (root.TryGetProperty("stats", out var stats))
                {
                    Console.WriteLine($"      Deleted data: {GetJsonValue(stats, "deleted_size")}");
                    Console.WriteLine($"      Freed space: {GetJsonValue(stats, "freed_space")}");
                }
            }
            catch
            {
                // If JSON parsing fails, just show the output
                if (!string.IsNullOrWhiteSpace(output))
                {
                    Console.WriteLine($"      {output}");
                }
            }
        }
    }

    /// <summary>
    /// Compact a repository to free up space
    /// </summary>
    private void CompactRepository(string repoPath)
    {
        Console.WriteLine($"   ** Compacting {repoPath}");

        var process = Process.Start(new ProcessStartInfo
        {
            FileName = "borg",
            Arguments = $"compact \"{repoPath}\"",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        });

        if (process != null)
        {
            process.WaitForExit();
            var error = process.StandardError.ReadToEnd();

            if (process.ExitCode != 0)
            {
                throw new InvalidOperationException($"Compact failed: {error}");
            }

            Console.WriteLine("      Compact completed");
        }
    }

    /// <summary>
    /// Helper to get JSON value as string
    /// </summary>
    private static string GetJsonValue(JsonElement element, string property)
    {
        if (element.TryGetProperty(property, out var value))
        {
            return value.ToString();
        }
        return "N/A";
    }
}
