using System.Diagnostics;
using System.Text;

namespace BorgServer;

/// <summary>
/// Manages SSH keys and authorized_keys file
/// </summary>
public class SshKeyManager
{
    private readonly BorgServerConfig _config;

    public SshKeyManager(BorgServerConfig config)
    {
        _config = config;
    }

    /// <summary>
    /// Setup SSH host keys
    /// </summary>
    public void SetupHostKeys()
    {
        var hostKeyDir = Path.Combine(_config.SshKeyDir, "host");
        Directory.CreateDirectory(hostKeyDir);

        Console.WriteLine("########################################################");
        Console.WriteLine(" * Checking / Preparing SSH Host-Keys...");

        foreach (var keyType in new[] { "ed25519", "rsa" })
        {
            var keyPath = Path.Combine(hostKeyDir, $"ssh_host_{keyType}_key");
            if (!File.Exists(keyPath))
            {
                Console.WriteLine($"  ** Creating SSH Hostkey [{keyType}]...");
                var process = Process.Start(new ProcessStartInfo
                {
                    FileName = "ssh-keygen",
                    Arguments = $"-q -f \"{keyPath}\" -N '' -t {keyType}",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false
                });

                if (process != null)
                {
                    process.WaitForExit();
                    if (process.ExitCode != 0)
                    {
                        var error = process.StandardError.ReadToEnd();
                        throw new InvalidOperationException($"Failed to create SSH host key: {error}");
                    }
                }
            }
        }
    }

    /// <summary>
    /// Setup client keys from files and config
    /// </summary>
    public void SetupClientKeys()
    {
        Console.WriteLine("########################################################");
        Console.WriteLine(" * Starting SSH-Key import...");

        var clientKeysDir = Path.Combine(_config.SshKeyDir, "clients");
        var authorizedKeysPath = "/home/borg/.ssh/authorized_keys";

        // Delete existing authorized_keys
        if (File.Exists(authorizedKeysPath))
        {
            File.Delete(authorizedKeysPath);
        }

        // Collect all client keys (from files and config)
        var clientKeys = new Dictionary<string, string>();

        // Load keys from files
        if (Directory.Exists(clientKeysDir))
        {
            foreach (var keyFile in Directory.GetFiles(clientKeysDir))
            {
                var fileName = Path.GetFileName(keyFile);
                // Skip hidden files
                if (fileName.StartsWith("."))
                {
                    continue;
                }

                var clientName = fileName;
                var keyContent = File.ReadAllText(keyFile).Trim();
                clientKeys[clientName] = keyContent;
            }
        }

        // Load keys from config
        if (_config.Clients != null)
        {
            foreach (var client in _config.Clients)
            {
                if (!string.IsNullOrEmpty(client.Value.SshKey))
                {
                    // Config keys override file keys
                    clientKeys[client.Key] = client.Value.SshKey;
                }
            }
        }

        if (clientKeys.Count == 0)
        {
            throw new InvalidOperationException($"No SSH-Pubkey found in {clientKeysDir} or config file");
        }

        // Create authorized_keys entries
        var authorizedKeysContent = new StringBuilder();

        foreach (var clientKey in clientKeys)
        {
            var clientName = clientKey.Key;
            var keyContent = clientKey.Value;

            // Create client directory
            var clientDir = Path.Combine(_config.BorgDataDir, clientName);
            Directory.CreateDirectory(clientDir);

            Console.WriteLine($"  ** Adding client {clientName} with repo path {clientDir}");

            // Build borg command
            var borgCmd = BuildBorgCommand(clientName);

            // Add to authorized_keys
            authorizedKeysContent.AppendLine($"restrict,command=\"{borgCmd}\" {keyContent}");

            // Apply quota if specified
            if (_config.Clients != null && 
                _config.Clients.TryGetValue(clientName, out var clientConfig) && 
                !string.IsNullOrEmpty(clientConfig.Quota))
            {
                ApplyQuota(clientName, clientConfig.Quota);
            }
        }

        // Write authorized_keys file
        File.WriteAllText(authorizedKeysPath, authorizedKeysContent.ToString());

        // Set permissions
        var chmodProcess = Process.Start(new ProcessStartInfo
        {
            FileName = "chmod",
            Arguments = $"600 \"{authorizedKeysPath}\"",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        });
        chmodProcess?.WaitForExit();

        // Validate authorized_keys structure
        Console.WriteLine($" * Validating structure of generated {authorizedKeysPath}...");
        var validateProcess = Process.Start(new ProcessStartInfo
        {
            FileName = "ssh-keygen",
            Arguments = $"-lf \"{authorizedKeysPath}\"",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        });

        if (validateProcess != null)
        {
            validateProcess.WaitForExit();
            if (validateProcess.ExitCode != 0)
            {
                var error = validateProcess.StandardError.ReadToEnd();
                throw new InvalidOperationException($"Invalid authorized_keys file: {error}");
            }
        }

        // Change ownership
        var chownProcess = Process.Start(new ProcessStartInfo
        {
            FileName = "chown",
            Arguments = $"-R borg:borg {_config.BorgDataDir}",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        });
        chownProcess?.WaitForExit();

        var chownKeysProcess = Process.Start(new ProcessStartInfo
        {
            FileName = "chown",
            Arguments = $"borg:borg \"{authorizedKeysPath}\"",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false
        });
        chownKeysProcess?.WaitForExit();
    }

    /// <summary>
    /// Build borg serve command for a client
    /// </summary>
    private string BuildBorgCommand(string clientName)
    {
        var isAdmin = clientName == _config.BorgAdmin;
        var clientPath = isAdmin ? _config.BorgDataDir : $"{_config.BorgDataDir}/{clientName}";
        
        var cmd = new StringBuilder();
        cmd.Append($"cd {clientPath}; ");
        cmd.Append($"borg serve --restrict-to-path {clientPath}");
        
        if (!string.IsNullOrEmpty(_config.BorgServeArgs))
        {
            cmd.Append($" {_config.BorgServeArgs}");
        }

        // Add append-only for non-admin clients if enabled
        if (!isAdmin && _config.BorgAppendOnly)
        {
            cmd.Append(" --append-only");
        }

        if (isAdmin)
        {
            Console.WriteLine($"   ** Client '{clientName}' is BORG_ADMIN! **");
        }

        return cmd.ToString();
    }

    /// <summary>
    /// Apply quota to a client repository
    /// </summary>
    private void ApplyQuota(string clientName, string quota)
    {
        Console.WriteLine($"   ** Applying quota {quota} to client {clientName}");
        
        var clientPath = Path.Combine(_config.BorgDataDir, clientName);
        
        // Find all repositories in the client directory
        var repos = Directory.GetDirectories(clientPath)
            .Where(d => File.Exists(Path.Combine(d, "config")))
            .ToList();

        foreach (var repo in repos)
        {
            try
            {
                var process = Process.Start(new ProcessStartInfo
                {
                    FileName = "borg",
                    Arguments = $"config \"{repo}\" storage_quota {quota}",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false
                });

                if (process != null)
                {
                    process.WaitForExit();
                    if (process.ExitCode != 0)
                    {
                        var error = process.StandardError.ReadToEnd();
                        Console.WriteLine($"   ** Warning: Failed to set quota for {repo}: {error}");
                    }
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"   ** Warning: Failed to set quota for {repo}: {ex.Message}");
            }
        }
    }
}
