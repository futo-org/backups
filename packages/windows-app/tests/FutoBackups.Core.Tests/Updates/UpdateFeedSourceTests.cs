using System.Security.Cryptography;
using System.Text;

using FutoBackups.Core.Updates;

using Velopack;
using Velopack.Logging;

namespace FutoBackups.Core.Tests.Updates;

public class UpdateFeedSourceTests
{
    private const string Feed = """{"Assets":[{"PackageId":"FUTOBackups","Version":"1.26.0","Type":"Full","FileName":"FUTOBackups-1.26.0-win-x64-full.nupkg","SHA1":"a","SHA256":"b","Size":3}]}""";

    private static readonly Uri FeedRoot = new("https://github.com/futo-org/backups/releases/download/windows-feed/");

    private static readonly Uri ReleasesRoot = new("https://github.com/futo-org/backups/releases/download/");

    private static readonly ECDsa ReleaseKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);

    private static string Sign(string feed, ECDsa key) =>
        Convert.ToBase64String(key.SignData(Encoding.UTF8.GetBytes(feed), HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence));

    private static UpdateFeedSource Source(FakeHttp transport) =>
        new(transport.Client(), FeedRoot, ReleasesRoot, ReleaseKey.ExportSubjectPublicKeyInfoPem());

    [Fact]
    public async Task AFeedSignedByTheReleaseKeyListsItsReleases()
    {
        var transport = new FakeHttp().Respond(200, Feed).Respond(200, Sign(Feed, ReleaseKey) + "\n");

        var feed = await Source(transport).GetReleaseFeed(NullVelopackLogger.Instance, "FUTOBackups", "win-x64");

        Assert.Equal("1.26.0", Assert.Single(feed.Assets).Version.ToString());
        Assert.Equal(
            [new Uri(FeedRoot, "releases.win-x64.json"), new Uri(FeedRoot, "releases.win-x64.json.sig")],
            transport.Requests.Select(request => request.Url));
    }

    [Fact]
    public void AFeedSignedWithOpensslLikeTheReleaseWorkflowVerifies()
    {
        const string publicKey = """
            -----BEGIN PUBLIC KEY-----
            MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEolZljla1h/4p2PdSSrRVbWUB3iFl
            IaAHSoMlRbHurJrTQiI6DwYTXMteJKBpzJkv5lXzK8SlkNKnDhkH688HQA==
            -----END PUBLIC KEY-----
            """;
        const string signature = "MEYCIQCvliV7QEa49j9yFSo20pYCFa5vwDMOKaykNWk+tdl0fgIhAK1kUBSl7jp/6k43wkRyvigxtt25XpHkHIzHftkswm8M";

        Assert.True(UpdateFeedSource.IsSignedBy(Encoding.UTF8.GetBytes(Feed), signature, publicKey));
    }

    [Fact]
    public async Task AFeedSignedByAnyOtherKeyIsRefused()
    {
        using var otherKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var transport = new FakeHttp().Respond(200, Feed).Respond(200, Sign(Feed, otherKey));

        await Assert.ThrowsAsync<UpdateFeedException>(() => Source(transport).GetReleaseFeed(NullVelopackLogger.Instance, "FUTOBackups", "win-x64"));
    }

    [Fact]
    public async Task AFeedChangedAfterSigningIsRefused()
    {
        var transport = new FakeHttp().Respond(200, Feed.Replace("1.26.0", "9.9.9")).Respond(200, Sign(Feed, ReleaseKey));

        await Assert.ThrowsAsync<UpdateFeedException>(() => Source(transport).GetReleaseFeed(NullVelopackLogger.Instance, "FUTOBackups", "win-x64"));
    }

    [Fact]
    public async Task AMissingSignatureIsRefused()
    {
        var transport = new FakeHttp().Respond(200, Feed).Respond(404, "Not Found");

        await Assert.ThrowsAsync<UpdateFeedException>(() => Source(transport).GetReleaseFeed(NullVelopackLogger.Instance, "FUTOBackups", "win-x64"));
    }

    [Fact]
    public async Task WithoutAReleaseKeyTheFeedIsReadWithoutASignature()
    {
        var transport = new FakeHttp().Respond(200, Feed);

        var feed = await new UpdateFeedSource(transport.Client(), FeedRoot, ReleasesRoot, null).GetReleaseFeed(NullVelopackLogger.Instance, "FUTOBackups", "win-x64");

        Assert.Equal("1.26.0", Assert.Single(feed.Assets).Version.ToString());
        Assert.Equal([new Uri(FeedRoot, "releases.win-x64.json")], transport.Requests.Select(request => request.Url));
    }

    [Fact]
    public async Task APackageIsDownloadedFromTheReleaseOfItsVersion()
    {
        var transport = new FakeHttp().Respond(200, "pkg");
        var asset = VelopackAssetFeed.FromJson(Feed).Assets.Single();
        var file = Path.GetTempFileName();

        await Source(transport).DownloadReleaseEntry(NullVelopackLogger.Instance, asset, file, _ => { }, TestContext.Current.CancellationToken);

        Assert.Equal(new Uri(ReleasesRoot, "windows-v1.26.0/FUTOBackups-1.26.0-win-x64-full.nupkg"), Assert.Single(transport.Requests).Url);
        Assert.Equal("pkg", await File.ReadAllTextAsync(file, TestContext.Current.CancellationToken));
        File.Delete(file);
    }
}
