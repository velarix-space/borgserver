using System.Diagnostics;
using System.Runtime.InteropServices;
using BorgServer;

Console.WriteLine("########################################################");
Console.WriteLine(" * Docker BorgServer (C# Edition)");

// Display borg version
try
{
    var borgVersion = Process.Start(new ProcessStartInfo
    {
        FileName = "borg",
        Arguments = "-V",
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        UseShellExecute = false
    });

    if (borgVersion != null)
    {
        borgVersion.WaitForExit();
        var version = borgVersion.StandardOutput.ReadToEnd().Trim();
        Console.WriteLine($" * Powered by {version}");
    }
}
catch
{
    Console.WriteLine(" * Powered by borgbackup");
}

// Display OS info
try
{
    if (File.Exists("/etc/os-release"))
    {
        var osRelease = File.ReadAllLines("/etc/os-release");
        var prettyName = osRelease
            .FirstOrDefault(l => l.StartsWith("PRETTY_NAME="))
            ?.Split('=')[1]
            .Trim('"');
        if (!string.IsNullOrEmpty(prettyName))
        {
            Console.WriteLine($" * Based on {prettyName}");
        }
    }
}
catch
{
    // Ignore if we can't read OS info
}

Console.WriteLine("########################################################");

try
{
    // Load configuration
    var config = ConfigLoader.LoadConfig();

    // Set user and group IDs
    Console.WriteLine($" * Setting user ID to {config.Puid} and group ID to {config.Pgid}");
    
    var usermodProcess = Process.Start(new ProcessStartInfo
    {
        FileName = "usermod",
        Arguments = $"-o -u {config.Puid} borg",
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        UseShellExecute = false
    });
    usermodProcess?.WaitForExit();

    var groupmodProcess = Process.Start(new ProcessStartInfo
    {
        FileName = "groupmod",
        Arguments = $"-o -g {config.Pgid} borg",
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        UseShellExecute = false
    });
    groupmodProcess?.WaitForExit();

    // Display configuration
    Console.WriteLine($" * User  id: {config.Puid}");
    Console.WriteLine($" * Group id: {config.Pgid}");
    Console.WriteLine("########################################################");

    // Validate directories
    Console.WriteLine($" * Testing Volume BORG_DATA_DIR: {config.BorgDataDir}");
    if (!Directory.Exists(config.BorgDataDir))
    {
        Console.WriteLine($"ERROR: {config.BorgDataDir} is not a directory!");
        return 1;
    }

    Console.WriteLine($" * Testing Volume SSH_KEY_DIR: {config.SshKeyDir}");
    if (!Directory.Exists(config.SshKeyDir))
    {
        Console.WriteLine($"ERROR: {config.SshKeyDir} is not a directory!");
        return 1;
    }

    // Setup SSH keys
    var sshKeyManager = new SshKeyManager(config);
    sshKeyManager.SetupHostKeys();
    sshKeyManager.SetupClientKeys();

    // Start prune scheduler if enabled
    PruneScheduler? pruneScheduler = null;
    if (config.Prune?.Enabled == true)
    {
        pruneScheduler = new PruneScheduler(config);
        pruneScheduler.Start();
    }

    Console.WriteLine("########################################################");
    Console.WriteLine(" * Init done! Starting SSH-Daemon...");

    // Start SSH daemon
    var sshdProcess = Process.Start(new ProcessStartInfo
    {
        FileName = "/usr/sbin/sshd",
        Arguments = "-D -e",
        RedirectStandardOutput = false,
        RedirectStandardError = false,
        UseShellExecute = false
    });

    if (sshdProcess == null)
    {
        Console.WriteLine("ERROR: Failed to start SSH daemon");
        return 1;
    }

    // Setup signal handlers for graceful shutdown
    var cancellationTokenSource = new CancellationTokenSource();
    
    AppDomain.CurrentDomain.ProcessExit += (sender, args) =>
    {
        Console.WriteLine("Received shutdown signal, stopping...");
        pruneScheduler?.Stop();
        cancellationTokenSource.Cancel();
        
        if (!sshdProcess.HasExited)
        {
            sshdProcess.Kill(true);
        }
    };

    Console.CancelKeyPress += (sender, args) =>
    {
        args.Cancel = true;
        Console.WriteLine("Received interrupt signal, stopping...");
        pruneScheduler?.Stop();
        cancellationTokenSource.Cancel();
        
        if (!sshdProcess.HasExited)
        {
            sshdProcess.Kill(true);
        }
    };

    // Wait for SSH daemon to exit
    sshdProcess.WaitForExit();
    
    Console.WriteLine("SSH daemon stopped");
    pruneScheduler?.Stop();
    
    return sshdProcess.ExitCode;
}
catch (Exception ex)
{
    Console.WriteLine($"ERROR: {ex.Message}");
    if (ex.StackTrace != null)
    {
        Console.WriteLine(ex.StackTrace);
    }
    return 1;
}
