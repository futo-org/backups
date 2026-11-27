using System.Text.Json;

using FutoBackups.Core.Restic;
using FutoBackups.Core.State;
using FutoBackups.Core.Strings;
using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Engine;

public sealed record PendingKeyRotation(string RepositoryId, string OldKeyId, string PreviousMasterKey, string NewMasterKey);

public enum KeyRotationError
{
    CurrentKeyNotFound,
    NewKeyRejected,
    PasswordFileFailed,
    PendingRotationUnreadable,
}

public sealed class KeyRotationException(KeyRotationError error) : Exception(error switch
{
    KeyRotationError.NewKeyRejected => Text.ErrorRotationNewKeyRejected,
    KeyRotationError.PasswordFileFailed => Text.ErrorRotationPasswordFileFailed,
    _ => Text.ErrorRotationKeyUnreadable,
})
{
    public KeyRotationError Error { get; } = error;
}

public enum KeyRotationOutcome
{
    Complete,
    OldKeyRemovalPending,
}

public sealed partial class BackupEngine
{
    internal const string PasswordDirectoryPrefix = "futo-backups-key-";

    public string TemporaryDirectory { get; init; } = Path.GetTempPath();

    public async Task<KeyRotationOutcome> ChangeMasterKeyAsync(string input, AppConfig config, CancellationToken cancellation = default)
    {
        var newMasterKey = RepositoryKeys.NormalizedMasterKey(input) ?? throw new InvalidMasterKeyException();
        var repositoryId = config.RepositoryId ?? throw new EngineException(EngineError.NoRepository);
        var token = AccessToken();
        RequireMasterKey();
        using var claim = Claim();
        var server = await ServerInfoAsync(config.ServerUrl, cancellation);
        var api = Environment.MakeApi(server.ApiRoot, token);
        RemoveStalePasswordDirectories();
        var stage = "resume";
        try
        {
            await CompletePendingKeyRotationAsync(config, token, cancellation);
            var oldMasterKey = RequireMasterKey();
            if (oldMasterKey == newMasterKey) return KeyRotationOutcome.Complete;
            stage = "list";
            string oldKeyId;
            await using (var oldSession = await StartSessionAsync(config, repositoryId, oldMasterKey, token, cancellation))
            {
                oldKeyId = await CurrentKeyIdAsync(oldSession.Context, cancellation);
                stage = "add";
                await AddKeyAsync(oldSession.Context, RepositoryKeys.Password(newMasterKey, repositoryId), cancellation);
            }

            stage = "verify";
            Exception? removalError = null;
            await using (var newSession = await StartSessionAsync(config, repositoryId, newMasterKey, token, cancellation))
            {
                await VerifyOpensAsync(newSession.Context, cancellation);
                stage = "store";
                Commit(new PendingKeyRotation(repositoryId, oldKeyId, oldMasterKey, newMasterKey));
                stage = "remove";
                try
                {
                    await RemoveKeyAsync(oldKeyId, newSession.Context, cancellation);
                    Environment.Secrets.Delete(SecretKey.PendingKeyRotation);
                }
                catch (Exception error)
                {
                    removalError = error;
                }
            }

            var data = new Dictionary<string, object?> { ["repositoryId"] = repositoryId, ["oldKeyRemoved"] = removalError is null };
            if (removalError is not null)
            {
                data["error"] = KeyRotationErrorCode(removalError);
            }

            Report(api, config, "Changed recovery key", data);
            return removalError is null ? KeyRotationOutcome.Complete : KeyRotationOutcome.OldKeyRemovalPending;
        }
        catch (Exception error)
        {
            Report(api, config, "Changed recovery key", new() { ["repositoryId"] = repositoryId, ["stage"] = stage, ["error"] = KeyRotationErrorCode(error) });
            throw;
        }
    }

    public async Task<bool> FinishPendingKeyRotationAsync(AppConfig config, CancellationToken cancellation = default)
    {
        using var claim = Claim();
        RemoveStalePasswordDirectories();
        if (LoadPendingKeyRotation() is not { } pending) return false;
        var token = AccessToken();
        var server = await ServerInfoAsync(config.ServerUrl, cancellation);
        var api = Environment.MakeApi(server.ApiRoot, token);
        try
        {
            var completed = await CompletePendingKeyRotationAsync(config, token, cancellation);
            if (!completed) return false;
        }
        catch (Exception error)
        {
            Report(api, config, "Finished recovery key change", new() { ["repositoryId"] = pending.RepositoryId, ["error"] = KeyRotationErrorCode(error) });
            throw;
        }

        Report(api, config, "Finished recovery key change", new() { ["repositoryId"] = pending.RepositoryId });
        return true;
    }

    public bool HasPendingKeyRotation => Environment.Secrets.Get(SecretKey.PendingKeyRotation) is not null;

    private async Task<bool> CompletePendingKeyRotationAsync(AppConfig config, string token, CancellationToken cancellation)
    {
        if (LoadPendingKeyRotation() is not { } pending) return false;
        var stored = Environment.Secrets.Get(SecretKey.MasterKey);
        var superseded = stored is not null && stored != pending.PreviousMasterKey && stored != pending.NewMasterKey;
        if (pending.RepositoryId != config.RepositoryId || superseded)
        {
            Environment.Secrets.Delete(SecretKey.PendingKeyRotation);
            return false;
        }

        if (stored != pending.NewMasterKey)
        {
            Environment.Secrets.Set(SecretKey.MasterKey, pending.NewMasterKey);
        }

        await using (var session = await StartSessionAsync(config, pending.RepositoryId, pending.NewMasterKey, token, cancellation))
        {
            await RemoveKeyAsync(pending.OldKeyId, session.Context, cancellation);
        }

        Environment.Secrets.Delete(SecretKey.PendingKeyRotation);
        return true;
    }

    private PendingKeyRotation? LoadPendingKeyRotation()
    {
        if (Environment.Secrets.Get(SecretKey.PendingKeyRotation) is not { } stored) return null;
        try
        {
            return JsonSerializer.Deserialize<PendingKeyRotation>(stored) ?? throw new KeyRotationException(KeyRotationError.PendingRotationUnreadable);
        }
        catch (JsonException)
        {
            throw new KeyRotationException(KeyRotationError.PendingRotationUnreadable);
        }
    }

    private void Commit(PendingKeyRotation pending)
    {
        Environment.Secrets.Set(SecretKey.PendingKeyRotation, JsonSerializer.Serialize(pending));
        try
        {
            Environment.Secrets.Set(SecretKey.MasterKey, pending.NewMasterKey);
        }
        catch
        {
            Environment.Secrets.Delete(SecretKey.PendingKeyRotation);
            throw;
        }
    }

    private async Task<string> CurrentKeyIdAsync(ResticContext context, CancellationToken cancellation)
    {
        var keys = await ListKeysAsync(context, cancellation);
        return keys.FirstOrDefault(key => key.Current)?.Id ?? throw new KeyRotationException(KeyRotationError.CurrentKeyNotFound);
    }

    private async Task<IReadOnlyList<ResticKey>> ListKeysAsync(ResticContext context, CancellationToken cancellation)
    {
        var output = await RunCheckedAsync(ResticCommand.KeyList(context), cancellation);
        return ResticOutput.ParseKeys(output.Stdout);
    }

    private async Task RemoveKeyAsync(string id, ResticContext context, CancellationToken cancellation)
    {
        var keys = await ListKeysAsync(context, cancellation);
        if (!keys.Any(key => key.Id == id)) return;
        await RunCheckedAsync(ResticCommand.KeyRemove(context, id), cancellation);
    }

    private async Task VerifyOpensAsync(ResticContext context, CancellationToken cancellation)
    {
        var result = await Restic.RunAsync(ResticCommand.CatConfig(context), null, cancellation);
        if (result.ExitCode == ResticExitCode.WrongPassword) throw new KeyRotationException(KeyRotationError.NewKeyRejected);
        RequireSuccess(result);
    }

    private async Task AddKeyAsync(ResticContext context, string password, CancellationToken cancellation)
    {
        var directory = Path.Combine(TemporaryDirectory, PasswordDirectoryPrefix + Guid.NewGuid());
        try
        {
            Directory.CreateDirectory(directory);
            var file = Path.Combine(directory, "password");
            using (var stream = new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            using (var writer = new StreamWriter(stream))
            {
                await writer.WriteAsync(password);
            }

            await RunCheckedAsync(ResticCommand.KeyAdd(context, file), cancellation);
        }
        catch (IOException)
        {
            throw new KeyRotationException(KeyRotationError.PasswordFileFailed);
        }
        finally
        {
            try
            {
                Directory.Delete(directory, true);
            }
            catch (IOException)
            {
            }
        }
    }

    private void RemoveStalePasswordDirectories()
    {
        try
        {
            foreach (var directory in Directory.EnumerateDirectories(TemporaryDirectory, PasswordDirectoryPrefix + "*"))
            {
                Directory.Delete(directory, true);
            }
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private async Task<ResticResult> RunCheckedAsync(ResticInvocation invocation, CancellationToken cancellation)
    {
        var result = await Restic.RunAsync(invocation, null, cancellation);
        RequireSuccess(result);
        return result;
    }

    private static void RequireSuccess(ResticResult result)
    {
        if (result.ExitCode != ResticExitCode.Success)
        {
            throw new EngineException(EngineError.Restic, ResticCommand.FailureMessage(result), result.ExitCode);
        }
    }

    private static string KeyRotationErrorCode(Exception error) => error switch
    {
        EngineException { Error: EngineError.Restic } engine => $"restic exit {engine.ResticCode}",
        OperationCanceledException => "cancelled",
        EngineException or KeyRotationException or InvalidMasterKeyException => error.GetType().Name + ": " + error.Message,
        _ => error.GetType().Name,
    };
}
