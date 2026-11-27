using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace FutoBackups.YuccaApi;

public partial class YuccaApiClient
{
    private readonly Uri? apiRoot;
    private readonly string? accessToken;

    public YuccaApiClient(HttpClient httpClient, Uri apiRoot, string? accessToken = null)
        : this(httpClient)
    {
        this.apiRoot = apiRoot;
        this.accessToken = accessToken;
    }

    static partial void UpdateJsonSerializerSettings(JsonSerializerOptions settings) =>
        settings.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;

    partial void PrepareRequest(HttpClient client, HttpRequestMessage request, StringBuilder urlBuilder)
    {
        if (apiRoot is not null)
        {
            urlBuilder.Insert(0, apiRoot.AbsoluteUri.TrimEnd('/') + "/");
        }
    }

    partial void PrepareRequest(HttpClient client, HttpRequestMessage request, string url)
    {
        if (accessToken is not null)
        {
            request.Headers.TryAddWithoutValidation("Cookie", $"yucca-access-token={accessToken}");
        }
    }
}
