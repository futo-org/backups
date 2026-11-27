using FutoBackups.Core.Engine;
using FutoBackups.Core.Restic;
using FutoBackups.Core.State;
using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Tests.Engine;

public class BackupEngineTests
{
    private static readonly string Summary = """{"message_type":"summary","files_new":3,"data_added":1200,"total_files_processed":10,"total_bytes_processed":5000,"snapshot_id":"abc123"}""";

    private static Task<ResticResult> Result(int code, string stdout = "", string stderr = "") => Task.FromResult(new ResticResult(code, stdout, stderr));

    [Fact]
    public async Task ACompleteBackupPrunesReportsSizeAndRecordsTheSummary()
    {
        var fixture = new EngineFixture();
        fixture.Restic.Handler = (invocation, onLine, _) =>
        {
            switch (invocation.Arguments[0])
            {
                case "backup":
                    onLine!("""{"message_type":"status","percent_done":0.5,"total_bytes":10,"bytes_done":5}""");
                    onLine(Summary);
                    return Result(0);
                case "stats":
                    return Result(0, """{"total_size":4242}""");
                default:
                    return Result(0);
            }
        };
        var activities = new List<EngineActivity>();
        var record = await fixture.Engine.BackupAsync(EngineFixture.Config, activities.Add, cancellation: TestContext.Current.CancellationToken);
        await fixture.Engine.FlushOutboxAsync();

        Assert.Equal(BackupStatus.Complete, record.Status);
        Assert.Equal("abc123", record.SnapshotId);
        Assert.Equal(3, record.FilesNew);
        Assert.Equal(["version", "unlock", "backup", "forget", "stats"], fixture.Restic.Commands);
        Assert.IsType<EngineActivity.Preparing>(activities[0]);
        Assert.Contains(activities, activity => activity is EngineActivity.BackingUp);
        Assert.Contains(activities, activity => activity is EngineActivity.Pruning);
        Assert.Equal(["start", "size 4242", "end Complete"], fixture.Api.Calls);
        Assert.Equal(fixture.Proxy.Started, fixture.Proxy.Stopped);
    }

    [Fact]
    public async Task WithoutTelemetryConsentNoBackupMetricsAreSent()
    {
        var fixture = new EngineFixture();
        fixture.Restic.Handler = (invocation, onLine, _) =>
        {
            if (invocation.Arguments[0] == "backup")
            {
                onLine!(Summary);
            }

            return Result(0, invocation.Arguments[0] == "stats" ? """{"total_size":4242}""" : "");
        };

        await fixture.Engine.BackupAsync(EngineFixture.Config with { TelemetryConsentedAt = null }, _ => { }, cancellation: TestContext.Current.CancellationToken);
        await fixture.Engine.FlushOutboxAsync();

        Assert.Empty(fixture.Api.Calls);
        Assert.Empty(fixture.Api.Logs);
    }

    [Fact]
    public async Task AnUploadLimitChangedDuringABackupReachesTheRunningProxy()
    {
        var fixture = new EngineFixture();
        var limited = new Throttle(512 * 1024);
        fixture.Restic.Handler = async (invocation, onLine, _) =>
        {
            if (invocation.Arguments[0] == "backup")
            {
                await fixture.Engine.UpdateThrottleAsync(limited);
                onLine!(Summary);
            }

            return new ResticResult(0, string.Empty, string.Empty);
        };

        await fixture.Engine.BackupAsync(EngineFixture.Config, _ => { }, cancellation: TestContext.Current.CancellationToken);
        await fixture.Engine.UpdateThrottleAsync(Throttle.Unthrottled);

        Assert.Equal([limited], fixture.Proxy.Throttles);
    }

    [Fact]
    public async Task BackupPassesCaseInsensitiveExcludesCloudFilesAndTheHost()
    {
        var fixture = new EngineFixture();
        await fixture.Engine.BackupAsync(EngineFixture.Config with { Excludes = ["*.iso"] }, _ => { }, cancellation: TestContext.Current.CancellationToken);
        var backup = fixture.Restic.Invocations.Single(invocation => invocation.Arguments[0] == "backup").Arguments;
        Assert.Contains("--exclude-cloud-files", backup);
        Assert.Equal("*.iso", backup[backup.ToList().IndexOf("--iexclude") + 1]);
        Assert.Equal("test-pc", backup[backup.ToList().IndexOf("--host") + 1]);
        Assert.Equal("rest.connections=8", backup[backup.ToList().IndexOf("--option") + 1]);
        Assert.DoesNotContain("--use-fs-snapshot", backup);
    }

    [Fact]
    public async Task ABackupWithUnreadableFilesWarnsListsThemAndDoesNotPrune()
    {
        var fixture = new EngineFixture();
        fixture.Restic.Handler = (invocation, _, _) => invocation.Arguments[0] == "backup"
            ? Result(3, stderr: """{"message_type":"error","error":{"message":"open C:\\Users\\test\\Documents\\a.pst: The process cannot access the file because it is being used by another process."},"during":"archival","item":"C:\\Users\\test\\Documents\\a.pst"}""")
            : Result(0, """{"total_size":1}""");
        var record = await fixture.Engine.BackupAsync(EngineFixture.Config, _ => { }, cancellation: TestContext.Current.CancellationToken);
        Assert.Equal(BackupStatus.Warn, record.Status);
        var warning = Assert.Single(record.Warnings!.Items);
        Assert.Equal(@"C:\Users\test\Documents\a.pst", warning.Path);
        Assert.StartsWith("The process cannot access the file", warning.Reason);
        Assert.DoesNotContain("forget", fixture.Restic.Commands);
    }

    [Fact]
    public async Task AFailedBackupNamesTheCauseAndDoesNotPrune()
    {
        var fixture = new EngineFixture();
        fixture.Restic.Handler = (invocation, _, _) => invocation.Arguments[0] == "backup"
            ? Result(1, stderr: """{"message_type":"exit_error","code":1,"message":"Fatal: unable to open config file: unexpected HTTP response (503)"}""")
            : Result(0);
        var record = await fixture.Engine.BackupAsync(EngineFixture.Config, _ => { }, cancellation: TestContext.Current.CancellationToken);
        Assert.Equal(BackupStatus.Failed, record.Status);
        Assert.Contains("did not respond", record.Message);
        Assert.DoesNotContain("forget", fixture.Restic.Commands);
    }

    [Fact]
    public async Task CancellingABackupRecordsItAsCancelledNotFailed()
    {
        var fixture = new EngineFixture();
        using var cancellation = new CancellationTokenSource();
        fixture.Restic.Handler = async (invocation, _, token) =>
        {
            if (invocation.Arguments[0] == "backup")
            {
                await cancellation.CancelAsync();
                token.ThrowIfCancellationRequested();
            }

            return new ResticResult(0, string.Empty, string.Empty);
        };
        var record = await fixture.Engine.BackupAsync(EngineFixture.Config, _ => { }, cancellation: cancellation.Token);
        Assert.Equal(BackupStatus.Cancelled, record.Status);
    }

    [Fact]
    public async Task KeepAllNeverRunsForget()
    {
        var fixture = new EngineFixture();
        await fixture.Engine.BackupAsync(EngineFixture.Config with { Retention = SnapshotRetention.KeepAll }, _ => { }, cancellation: TestContext.Current.CancellationToken);
        Assert.DoesNotContain("forget", fixture.Restic.Commands);
    }

    [Fact]
    public async Task AWriteOnceBackupNeverRunsForgetWhateverTheRetention()
    {
        var fixture = new EngineFixture();
        var record = await fixture.Engine.BackupAsync(EngineFixture.Config with { WriteOnce = true }, _ => { }, cancellation: TestContext.Current.CancellationToken);
        Assert.DoesNotContain("forget", fixture.Restic.Commands);
        Assert.Equal(BackupStatus.Complete, record.Status);
    }

    [Fact]
    public async Task AnInvalidRetentionPolicyKeepsEverySnapshotAndSaysSo()
    {
        var fixture = new EngineFixture();
        var record = await fixture.Engine.BackupAsync(EngineFixture.Config with { Retention = new SnapshotRetention(new RetentionPolicy()) }, _ => { }, cancellation: TestContext.Current.CancellationToken);
        Assert.Equal(BackupStatus.Complete, record.Status);
        Assert.Contains("kept the old snapshots", record.Message);
    }

    [Fact]
    public async Task ACleanUpFailureKeepsTheBackupCompleteAndReportsItSeparately()
    {
        var fixture = new EngineFixture();
        fixture.Restic.Handler = (invocation, _, _) => invocation.Arguments[0] == "forget" ? Result(1, stderr: "Fatal: repository is locked") : Result(0, """{"total_size":1}""");
        var record = await fixture.Engine.BackupAsync(EngineFixture.Config, _ => { }, cancellation: TestContext.Current.CancellationToken);
        Assert.Equal(BackupStatus.Complete, record.Status);
        Assert.StartsWith("Could not delete old snapshots", record.Message);
    }

    [Fact]
    public async Task OnlyOneOperationRunsAtATime()
    {
        var fixture = new EngineFixture();
        var release = new TaskCompletionSource();
        fixture.Restic.Handler = async (invocation, _, _) =>
        {
            if (invocation.Arguments[0] == "backup")
            {
                await release.Task;
            }

            return new ResticResult(0, string.Empty, string.Empty);
        };
        var first = fixture.Engine.BackupAsync(EngineFixture.Config, _ => { }, cancellation: TestContext.Current.CancellationToken);
        while (!fixture.Engine.IsRunning) await Task.Yield();
        var busy = await Assert.ThrowsAsync<EngineException>(() => fixture.Engine.BackupAsync(EngineFixture.Config, _ => { }, cancellation: TestContext.Current.CancellationToken));
        Assert.Equal(EngineError.Busy, busy.Error);
        release.SetResult();
        await first;
        Assert.False(fixture.Engine.IsRunning);
    }

    [Fact]
    public async Task ABackupWithoutTheKeyOrSignInRefusesToStart()
    {
        var fixture = new EngineFixture();
        fixture.Secrets.Delete(SecretKey.MasterKey);
        var missing = await Assert.ThrowsAsync<EngineException>(() => fixture.Engine.BackupAsync(EngineFixture.Config, _ => { }, cancellation: TestContext.Current.CancellationToken));
        Assert.Equal(EngineError.MissingMasterKey, missing.Error);
        fixture.Secrets.Delete(SecretKey.AccessToken);
        var notLoggedIn = await Assert.ThrowsAsync<EngineException>(() => fixture.Engine.BackupAsync(EngineFixture.Config, _ => { }, cancellation: TestContext.Current.CancellationToken));
        Assert.Equal(EngineError.NotLoggedIn, notLoggedIn.Error);
        Assert.Empty(fixture.Restic.Invocations);
    }

    [Fact]
    public async Task TelemetryIsOnlySentAfterConsent()
    {
        var fixture = new EngineFixture();
        await fixture.Engine.BackupAsync(EngineFixture.Config with { TelemetryConsentedAt = null }, _ => { }, cancellation: TestContext.Current.CancellationToken);
        await fixture.Engine.FlushOutboxAsync();
        Assert.Empty(fixture.Api.Logs);
    }

    [Fact]
    public async Task VerifyingAKeyDistinguishesAWrongKeyFromAnError()
    {
        var fixture = new EngineFixture();
        fixture.Restic.Handler = (_, _, _) => Result(ResticExitCode.WrongPassword);
        Assert.False(await fixture.Engine.VerifyMasterKeyAsync(EngineFixture.MasterKey, EngineFixture.Config, "repo-1", TestContext.Current.CancellationToken));
        fixture.Restic.Handler = (_, _, _) => Result(1, stderr: "Fatal: boom");
        await Assert.ThrowsAsync<EngineException>(() => fixture.Engine.VerifyMasterKeyAsync(EngineFixture.MasterKey, EngineFixture.Config, "repo-1", TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<InvalidMasterKeyException>(() => fixture.Engine.VerifyMasterKeyAsync("nope", EngineFixture.Config, "repo-1", TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task ImportingAKeyNormalisesIt()
    {
        var fixture = new EngineFixture();
        fixture.Engine.ImportMasterKey("0011-2233 4455 6677 8899 AABB CCDD EEFF 0011 2233 4455 6677 8899 AABB CCDD EEFF");
        Assert.Equal(EngineFixture.MasterKey, fixture.Engine.StoredMasterKey());
        Assert.Throws<InvalidMasterKeyException>(() => fixture.Engine.ImportMasterKey("abc"));
        await Task.CompletedTask;
    }

    [Fact]
    public async Task OnlyWindowsBackupsAreOfferedForReconnectingThisPcsFirst()
    {
        var fixture = new EngineFixture();
        fixture.Api.Repositories.AddRange([
            new("a", "OTHER-PC", false, ConnectionType: "windows"),
            new("b", "test-pc", false, ConnectionType: "windows"),
            new("c", "MacBook", false, ConnectionType: "macos"),
        ]);
        var offered = await fixture.Engine.WindowsRepositoriesAsync(EngineFixture.Config, TestContext.Current.CancellationToken);
        Assert.Equal(["b", "a"], offered.Select(repository => repository.Id));
    }

    [Fact]
    public async Task EnsuringARepositoryCreatesAndInitialisesItOnce()
    {
        var fixture = new EngineFixture();
        var id = await fixture.Engine.EnsureRepositoryAsync(EngineFixture.Config with { RepositoryId = null }, TestContext.Current.CancellationToken);
        Assert.Equal("repo-1", id);
        Assert.Equal(["create test-pc"], fixture.Api.Calls);
        Assert.Contains("init", fixture.Restic.Commands);
        Assert.Equal("repo-1", await fixture.Engine.EnsureRepositoryAsync(EngineFixture.Config, TestContext.Current.CancellationToken));
        Assert.Single(fixture.Api.Calls);
    }

    [Fact]
    public async Task RestoringAWholeSnapshotClaimsAFreeFolderForEachRoot()
    {
        var fixture = new EngineFixture();
        var target = Directory.CreateTempSubdirectory("futo-restore-").FullName;
        Directory.CreateDirectory(Path.Combine(target, "Documents"));
        var items = RestorePlan.Items([@"C:\Users\test\Documents"], target);
        var restored = await fixture.Engine.RestoreAsync(EngineFixture.Config, "snap", items, _ => { }, cancellation: TestContext.Current.CancellationToken);
        Assert.Equal([Path.Combine(target, "Documents 2")], restored);
        var restore = fixture.Restic.Invocations.Single(invocation => invocation.Arguments[0] == "restore").Arguments;
        Assert.Equal("snap:/C/Users/test/Documents", restore[^1]);
        Assert.Equal("never", restore[restore.ToList().IndexOf("--overwrite") + 1]);
        Directory.Delete(target, true);
    }

    [Fact]
    public async Task AKeyFileLeftByACrashedKeyChangeIsRemovedBeforeTheNextBackup()
    {
        var temporary = Directory.CreateTempSubdirectory().FullName;
        var fixture = new EngineFixture(temporary);
        var leftover = Path.Combine(temporary, "futo-backups-key-" + Guid.NewGuid());
        Directory.CreateDirectory(leftover);
        await File.WriteAllTextAsync(Path.Combine(leftover, "password"), "secret", TestContext.Current.CancellationToken);

        var finished = await fixture.Engine.FinishPendingKeyRotationAsync(EngineFixture.Config, TestContext.Current.CancellationToken);

        Assert.False(finished);
        Assert.False(Directory.Exists(leftover));
    }
}
