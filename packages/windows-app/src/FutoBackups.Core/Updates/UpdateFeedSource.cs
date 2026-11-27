using System.Net;
using System.Security.Cryptography;
using System.Text;

using Velopack;
using Velopack.Logging;
using Velopack.Sources;

namespace FutoBackups.Core.Updates;

public sealed class UpdateFeedException(string message) : Exception(message);

public sealed class UpdateFeedSource(HttpClient http, Uri feedRoot, Uri releasesRoot, string? publicKeyPem) : IUpdateSource
{
    public static bool IsSignedBy(byte[] feed, string base64Signature, string publicKeyPem)
    {
        using var key = ECDsa.Create();
        try
        {
            key.ImportFromPem(publicKeyPem);
            return key.VerifyData(feed, Convert.FromBase64String(base64Signature), HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
        }
        catch (Exception error) when (error is ArgumentException or FormatException or CryptographicException)
        {
            return false;
        }
    }

    public async Task<VelopackAssetFeed> GetReleaseFeed(IVelopackLogger logger, string? appId, string channel, Guid? stagingId = null, VelopackAsset? latestLocalRelease = null)
    {
        var name = $"releases.{channel}.json";
        var feed = await DownloadAsync(new Uri(feedRoot, name), CancellationToken.None);
        if (publicKeyPem is not null)
        {
            var signature = await DownloadAsync(new Uri(feedRoot, name + ".sig"), CancellationToken.None);
            if (!IsSignedBy(feed, Encoding.ASCII.GetString(signature).Trim(), publicKeyPem))
            {
                throw new UpdateFeedException($"{name} is not signed by the FUTO Backups release key");
            }
        }

        return VelopackAssetFeed.FromJson(Encoding.UTF8.GetString(feed));
    }

    public async Task DownloadReleaseEntry(IVelopackLogger logger, VelopackAsset releaseEntry, string localFile, Action<int> progress, CancellationToken cancelToken = default)
    {
        var url = new Uri(releasesRoot, $"windows-v{releaseEntry.Version}/{Uri.EscapeDataString(releaseEntry.FileName)}");
        var package = await DownloadAsync(url, cancelToken);
        await File.WriteAllBytesAsync(localFile, package, cancelToken);
        progress(100);
    }

    private async Task<byte[]> DownloadAsync(Uri url, CancellationToken cancellation)
    {
        using var response = await http.GetAsync(url, cancellation);
        if (response.StatusCode != HttpStatusCode.OK)
        {
            throw new UpdateFeedException($"{url} returned HTTP {(int)response.StatusCode}");
        }

        return await response.Content.ReadAsByteArrayAsync(cancellation);
    }
}
