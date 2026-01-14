using System.Text.Json;
using BorgServer;
using Xunit;

namespace BorgServer.Tests;

public class ConfigLoaderTests
{
    [Fact]
    public void LoadConfig_WithNoFile_UsesDefaults()
    {
        // Arrange
        var nonExistentPath = "/tmp/nonexistent-config.json";

        // Act
        var config = ConfigLoader.LoadConfig(nonExistentPath);

        // Assert
        Assert.NotNull(config);
        Assert.Equal(1000, config.Puid);
        Assert.Equal(1000, config.Pgid);
        Assert.Equal("/backup", config.BorgDataDir);
        Assert.Equal("/sshkeys", config.SshKeyDir);
        Assert.False(config.BorgAppendOnly);
    }

    [Fact]
    public void LoadConfig_WithValidJson_LoadsCorrectly()
    {
        // Arrange
        var tempFile = Path.GetTempFileName();
        var json = @"{
            ""puid"": 2000,
            ""pgid"": 2000,
            ""borg_data_dir"": ""/custom/backup"",
            ""ssh_key_dir"": ""/custom/sshkeys"",
            ""borg_append_only"": true,
            ""borg_admin"": ""admin""
        }";
        File.WriteAllText(tempFile, json);

        try
        {
            // Act
            var config = ConfigLoader.LoadConfig(tempFile);

            // Assert
            Assert.Equal(2000, config.Puid);
            Assert.Equal(2000, config.Pgid);
            Assert.Equal("/custom/backup", config.BorgDataDir);
            Assert.Equal("/custom/sshkeys", config.SshKeyDir);
            Assert.True(config.BorgAppendOnly);
            Assert.Equal("admin", config.BorgAdmin);
        }
        finally
        {
            File.Delete(tempFile);
        }
    }

    [Fact]
    public void LoadConfig_WithInvalidProperty_ThrowsException()
    {
        // Arrange
        var tempFile = Path.GetTempFileName();
        var json = @"{
            ""puid"": 1000,
            ""invalid_property"": ""value""
        }";
        File.WriteAllText(tempFile, json);

        try
        {
            // Act & Assert
            var exception = Assert.Throws<InvalidOperationException>(() => 
                ConfigLoader.LoadConfig(tempFile));
            Assert.Contains("Invalid configuration property", exception.Message);
        }
        finally
        {
            File.Delete(tempFile);
        }
    }

    [Fact]
    public void LoadConfig_WithPruneConfig_LoadsCorrectly()
    {
        // Arrange
        var tempFile = Path.GetTempFileName();
        var json = @"{
            ""prune"": {
                ""enabled"": true,
                ""schedule"": ""0 3 * * *"",
                ""compact"": true,
                ""default_rules"": {
                    ""keep_daily"": 7,
                    ""keep_weekly"": 4,
                    ""keep_monthly"": -1,
                    ""keep_yearly"": -1
                }
            }
        }";
        File.WriteAllText(tempFile, json);

        try
        {
            // Act
            var config = ConfigLoader.LoadConfig(tempFile);

            // Assert
            Assert.NotNull(config.Prune);
            Assert.True(config.Prune.Enabled);
            Assert.Equal("0 3 * * *", config.Prune.Schedule);
            Assert.True(config.Prune.Compact);
            Assert.NotNull(config.Prune.DefaultRules);
            Assert.Equal(7, config.Prune.DefaultRules.KeepDaily);
            Assert.Equal(4, config.Prune.DefaultRules.KeepWeekly);
            Assert.Equal(-1, config.Prune.DefaultRules.KeepMonthly);
            Assert.Equal(-1, config.Prune.DefaultRules.KeepYearly);
        }
        finally
        {
            File.Delete(tempFile);
        }
    }

    [Fact]
    public void LoadConfig_WithInvalidPruneProperty_ThrowsException()
    {
        // Arrange
        var tempFile = Path.GetTempFileName();
        var json = @"{
            ""prune"": {
                ""enabled"": true,
                ""invalid_prune_prop"": ""value""
            }
        }";
        File.WriteAllText(tempFile, json);

        try
        {
            // Act & Assert
            var exception = Assert.Throws<InvalidOperationException>(() => 
                ConfigLoader.LoadConfig(tempFile));
            Assert.Contains("Invalid prune property", exception.Message);
        }
        finally
        {
            File.Delete(tempFile);
        }
    }

    [Fact]
    public void LoadConfig_WithClients_LoadsCorrectly()
    {
        // Arrange
        var tempFile = Path.GetTempFileName();
        var json = @"{
            ""clients"": {
                ""client1"": {
                    ""ssh_key"": ""ssh-rsa AAAA..."",
                    ""quota"": ""100G"",
                    ""prune_rules"": {
                        ""keep_daily"": 14
                    }
                },
                ""client2"": {
                    ""ssh_key"": ""ssh-rsa BBBB...""
                }
            }
        }";
        File.WriteAllText(tempFile, json);

        try
        {
            // Act
            var config = ConfigLoader.LoadConfig(tempFile);

            // Assert
            Assert.NotNull(config.Clients);
            Assert.Equal(2, config.Clients.Count);
            Assert.True(config.Clients.ContainsKey("client1"));
            Assert.NotNull(config.Clients["client1"]);
            Assert.Equal("ssh-rsa AAAA...", config.Clients["client1"].SshKey);
            Assert.Equal("100G", config.Clients["client1"].Quota);
            Assert.NotNull(config.Clients["client1"].PruneRules);
            Assert.Equal(14, config.Clients["client1"].PruneRules.KeepDaily);
        }
        finally
        {
            File.Delete(tempFile);
        }
    }

    [Fact]
    public void LoadConfig_WithInvalidClientProperty_ThrowsException()
    {
        // Arrange
        var tempFile = Path.GetTempFileName();
        var json = @"{
            ""clients"": {
                ""client1"": {
                    ""ssh_key"": ""ssh-rsa AAAA..."",
                    ""invalid_client_prop"": ""value""
                }
            }
        }";
        File.WriteAllText(tempFile, json);

        try
        {
            // Act & Assert
            var exception = Assert.Throws<InvalidOperationException>(() => 
                ConfigLoader.LoadConfig(tempFile));
            Assert.Contains("Invalid client property", exception.Message);
        }
        finally
        {
            File.Delete(tempFile);
        }
    }

    [Fact]
    public void LoadConfig_WithInvalidCronSchedule_ThrowsException()
    {
        // Arrange
        var tempFile = Path.GetTempFileName();
        var json = @"{
            ""prune"": {
                ""enabled"": true,
                ""schedule"": ""invalid cron""
            }
        }";
        File.WriteAllText(tempFile, json);

        try
        {
            // Act & Assert
            var exception = Assert.Throws<InvalidOperationException>(() => 
                ConfigLoader.LoadConfig(tempFile));
            Assert.Contains("Invalid prune schedule", exception.Message);
        }
        finally
        {
            File.Delete(tempFile);
        }
    }

    [Fact]
    public void LoadConfig_WithZeroPuid_ThrowsException()
    {
        // Arrange
        var tempFile = Path.GetTempFileName();
        var json = @"{""puid"": 0}";
        File.WriteAllText(tempFile, json);

        try
        {
            // Act & Assert
            var exception = Assert.Throws<InvalidOperationException>(() => 
                ConfigLoader.LoadConfig(tempFile));
            Assert.Contains("puid must be greater than 0", exception.Message);
        }
        finally
        {
            File.Delete(tempFile);
        }
    }
}
