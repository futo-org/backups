using System.Text.Json;

using FutoBackups.Core.Engine;
using FutoBackups.Core.Restic;
using FutoBackups.Core.State;
using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Tests.Engine;

public class KeyRotationTests
{
    private const string RepositoryId = "repo-1";

    private static readonly string OldPassword = RepositoryKeys.Password(EngineFixture.MasterKey, RepositoryId);

    private sealed class Repository
    {
        private int nextId;

        public Dictionary<string, string> Keys { get; } = [];

        public bool FailRemove { get; set; }

        public bool RejectNewKeys { get; set; }

        public List<string> PasswordFiles { get; } = [];

        public Repository(string password) => Add(password);

        public string Add(string password)
        {
            var id = $"key-{++nextId}";
            Keys[id] = password;
            return id;
        }

        public Task<ResticResult> Run(ResticInvocation invocation)
        {
            var password = invocation.Environment["RESTIC_PASSWORD"];
            var arguments = invocation.Arguments;
            if (!Keys.ContainsValue(password)) return Result(ResticExitCode.WrongPassword);
            switch (arguments[0], arguments.Count > 1 ? arguments[1] : null)
            {
                case ("key", "list"):
                    return Result(0, JsonSerializer.Serialize(Keys.Select(key => new { id = key.Key, current = key.Value == password })));
                case ("key", "add"):
                    var file = arguments[arguments.ToList().IndexOf("--new-password-file") + 1];
                    PasswordFiles.Add(file);
                    var added = File.ReadAllText(file);
                    if (!RejectNewKeys)
                    {
                        Add(added);
                    }

                    return Result(0);
                case ("key", "remove"):
                    if (FailRemove) return Result(1, stderr: "Fatal: unable to remove key");
                    Keys.Remove(arguments[^1]);
                    return Result(0);
                default:
                    return Result(0);
            }
        }

        private static Task<ResticResult> Result(int code, string stdout = "", string stderr = "") => Task.FromResult(new ResticResult(code, stdout, stderr));
    }

    private static (EngineFixture Fixture, Repository Repository) Setup()
    {
        var fixture = new EngineFixture(Directory.CreateTempSubdirectory().FullName);
        var repository = new Repository(OldPassword);
        fixture.Restic.Handler = (invocation, _, _) => repository.Run(invocation);
        return (fixture, repository);
    }

    [Fact]
    public async Task ChangingTheKeyLeavesOnlyTheNewKeyAndStoresIt()
    {
        var (fixture, repository) = Setup();
        var newKey = RepositoryKeys.GenerateMasterKey();

        var outcome = await fixture.Engine.ChangeMasterKeyAsync(newKey, EngineFixture.Config, TestContext.Current.CancellationToken);

        Assert.Equal(KeyRotationOutcome.Complete, outcome);
        Assert.Equal([RepositoryKeys.Password(newKey, RepositoryId)], repository.Keys.Values);
        Assert.Equal(newKey, fixture.Secrets.Get(SecretKey.MasterKey));
        Assert.False(fixture.Engine.HasPendingKeyRotation);
    }

    [Fact]
    public async Task TheNewPasswordFileIsDeletedAfterTheKeyIsAdded()
    {
        var (fixture, repository) = Setup();

        await fixture.Engine.ChangeMasterKeyAsync(RepositoryKeys.GenerateMasterKey(), EngineFixture.Config, TestContext.Current.CancellationToken);

        var file = Assert.Single(repository.PasswordFiles);
        Assert.False(File.Exists(file));
        Assert.False(Directory.Exists(Path.GetDirectoryName(file)));
    }

    [Fact]
    public async Task WhenTheOldKeyCannotBeRemovedTheChangeReportsItAndTheNextBackupFinishesIt()
    {
        var (fixture, repository) = Setup();
        repository.FailRemove = true;
        var newKey = RepositoryKeys.GenerateMasterKey();

        var outcome = await fixture.Engine.ChangeMasterKeyAsync(newKey, EngineFixture.Config, TestContext.Current.CancellationToken);

        Assert.Equal(KeyRotationOutcome.OldKeyRemovalPending, outcome);
        Assert.Equal(newKey, fixture.Secrets.Get(SecretKey.MasterKey));
        Assert.Contains(OldPassword, repository.Keys.Values);
        Assert.True(fixture.Engine.HasPendingKeyRotation);

        repository.FailRemove = false;
        var finished = await fixture.Engine.FinishPendingKeyRotationAsync(EngineFixture.Config, TestContext.Current.CancellationToken);

        Assert.True(finished);
        Assert.Equal([RepositoryKeys.Password(newKey, RepositoryId)], repository.Keys.Values);
        Assert.False(fixture.Engine.HasPendingKeyRotation);
    }

    [Fact]
    public async Task ARejectedNewKeyLeavesTheCurrentKeyInPlace()
    {
        var (fixture, repository) = Setup();
        repository.RejectNewKeys = true;

        var error = await Assert.ThrowsAsync<KeyRotationException>(() => fixture.Engine.ChangeMasterKeyAsync(RepositoryKeys.GenerateMasterKey(), EngineFixture.Config, TestContext.Current.CancellationToken));

        Assert.Equal(KeyRotationError.NewKeyRejected, error.Error);
        Assert.Equal(EngineFixture.MasterKey, fixture.Secrets.Get(SecretKey.MasterKey));
        Assert.Equal([OldPassword], repository.Keys.Values);
        Assert.False(fixture.Engine.HasPendingKeyRotation);
    }

    [Fact]
    public async Task AKeyThatDoesNotOpenTheBackupIsNotReplaced()
    {
        var (fixture, repository) = Setup();
        repository.Keys.Clear();
        repository.Add(RepositoryKeys.Password(RepositoryKeys.GenerateMasterKey(), RepositoryId));

        await Assert.ThrowsAsync<EngineException>(() => fixture.Engine.ChangeMasterKeyAsync(RepositoryKeys.GenerateMasterKey(), EngineFixture.Config, TestContext.Current.CancellationToken));

        Assert.Equal(EngineFixture.MasterKey, fixture.Secrets.Get(SecretKey.MasterKey));
        Assert.False(fixture.Engine.HasPendingKeyRotation);
    }
}
