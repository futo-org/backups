using System.Text.Json;
using System.Text.RegularExpressions;

using FutoBackups.Core.Support;

namespace FutoBackups.Core.Tests.Support;

public class PathRedactorTests
{
    private static readonly PathRedactor Redactor = new(Enumerable.Repeat((byte)1, 32).ToArray());

    private static JsonElement Redacted(object value) => JsonElement.Parse(Redactor.Redact(JsonSerializer.Serialize(value)));

    [Fact]
    public void ReplacesEveryPathInAResticJsonLineAndKeepsTheRest()
    {
        var redacted = Redacted(new { message_type = "verbose_status", action = "new", item = "/photos/My Trip/IMG_0001.jpg", data_size = 3 });
        Assert.Equal("verbose_status", redacted.GetProperty("message_type").GetString());
        Assert.Equal(3, redacted.GetProperty("data_size").GetInt32());
        Assert.Matches("^<path:[0-9a-f]{12}\\.jpg>$", redacted.GetProperty("item").GetString());
    }

    [Fact]
    public void RedactsPathsInsideArraysAndNestedMessages()
    {
        var redacted = Redactor.Redact(JsonSerializer.Serialize(new
        {
            message_type = "status",
            current_files = new[] { "/photos/a.heic", "/photos/b.mov" },
            error = new { message = "open /photos/secret album/c.png: permission denied" },
        }));
        Assert.DoesNotContain("/photos", redacted);
        Assert.DoesNotContain("secret album", redacted);
        Assert.Contains(": permission denied", redacted);
    }

    [Fact]
    public void GivesTheSamePathTheSamePlaceholderWithinASession()
    {
        var first = Redacted(new { item = "/photos/a.jpg" }).GetProperty("item").GetString()!;
        Assert.Equal(first, Redacted(new { item = "/photos/a.jpg" }).GetProperty("item").GetString());
        Assert.DoesNotContain(first, new PathRedactor(Enumerable.Repeat((byte)2, 32).ToArray()).Redact(JsonSerializer.Serialize(new { item = "/photos/a.jpg" })));
    }

    [Fact]
    public void RedactsPathsInPlainTextStderrLinesButLeavesBackendUrlsAlone()
    {
        const string Retry = "Load(<data/0123abcd>, 0, 0) returned error, retrying after 1.4s: Head \"https://:***@rest.example/repo/config\": EOF";
        Assert.Equal(Retry, Redactor.Redact(Retry));
        Assert.Matches("^error: lstat <path:[0-9a-f]{12}\\.jpg>: no such file or directory$", Redactor.Redact("error: lstat /photos/My Trip/b.jpg: no such file or directory"));
    }

    [Fact]
    public void KeepsWindowsPathsOutOfTheStream()
    {
        Assert.DoesNotContain("Users", Redactor.Redact(JsonSerializer.Serialize(new { item = @"C:\Users\me\a.txt" })));
        Assert.Matches(@"^open <path:[0-9a-f]{12}\.docx>: Access is denied\.$", Redactor.Redact(@"open C:\Users\me\Tax return.docx: Access is denied."));
    }

    [Fact]
    public void RedactsTheWholePathWhenANameContainsAnApostrophe()
    {
        Assert.Matches("^error: lstat <path:[0-9a-f]{12}\\.jpg>: permission denied$", Redactor.Redact("error: lstat /photos/Alice's private album/a.jpg: permission denied"));
        Assert.DoesNotMatch("album|b\\.jpg'", Redactor.Redact("open '/photos/Alice's album/b.jpg' failed"));
    }

    [Fact]
    public void RedactsRelativeNamesInFieldsThatHoldPaths()
    {
        var redacted = Redacted(new { message_type = "verbose_status", action = "restored", item = "photos/private.jpg" });
        Assert.Equal("restored", redacted.GetProperty("action").GetString());
        Assert.Matches("^<path:[0-9a-f]{12}\\.jpg>$", redacted.GetProperty("item").GetString());
        Assert.StartsWith("<path:", Redacted(new { current_files = new[] { "a/b.mov" } }).GetProperty("current_files")[0].GetString());
    }

    [Fact]
    public void LeavesNoFragmentOfANameThatContainsADoubleQuoteOrColonSpace()
    {
        var quoted = Redacted(new { message_type = "error", error = new { message = "open /photos/private\"album/a.jpg: permission denied" }, item = "/photos/private\"album/a.jpg" });
        var colon = Redactor.Redact("lstat /photos/trip: day one/b.jpg: no such file or directory");
        Assert.Matches("^open <path:[0-9a-f]{12}\\.jpg>: permission denied$", quoted.GetProperty("error").GetProperty("message").GetString());
        Assert.Matches("^lstat <path:[0-9a-f]{12}\\.jpg>: no such file or directory$", colon);
        Assert.DoesNotMatch("album|day one|a\\.jpg|b\\.jpg", quoted.GetRawText() + colon);
    }

    [Fact]
    public void RedactsTheRestOfANameAfterANewlineInsideIt() =>
        Assert.Matches(
            "^open <path:[0-9a-f]{12}\\.jpg>: permission denied$",
            Redacted(new { message_type = "error", error = new { message = "open /photos/private\nalbum/a.jpg: permission denied" } }).GetProperty("error").GetProperty("message").GetString());

    [Fact]
    public void TelemetryLogsStripUrlCredentialsAndPathsAndNameTheClient()
    {
        var log = new Telemetry(Redactor).Log("Backup finished", new Dictionary<string, object?> { ["error"] = @"Get http://repo:secret-token@127.0.0.1:50000/config: open C:\Users\me\a.txt: denied" }, "1.0.0");
        var error = (string)log.Data["error"]!;
        Assert.DoesNotContain("secret-token", error);
        Assert.DoesNotContain("Users", error);
        Assert.Equal("windows", log.Data["client"]);
        Assert.Equal("1.0.0", log.Data["version"]);
        Assert.Equal("Backup finished", log.Summary);
    }

    [Fact]
    public void ErrorsAreSentWithTheirTypeMessageStackAndCauseLikeTheSdk()
    {
        Exception thrown;
        try
        {
            throw new InvalidOperationException(@"could not open C:\Users\me\secret.txt", new IOException("disk full"));
        }
        catch (Exception caught)
        {
            thrown = caught;
        }

        var log = new Telemetry(Redactor).Log("Unhandled error", new Dictionary<string, object?> { ["error"] = thrown }, "1.0.0");

        var error = Assert.IsType<Dictionary<string, object?>>(log.Data["error"]);
        Assert.Equal("InvalidOperationException", error["type"]);
        Assert.DoesNotContain("secret", (string)error["message"]!);
        Assert.NotNull(error["stack"]);
        var cause = Assert.IsType<Dictionary<string, object?>>(error["cause"]);
        Assert.Equal("IOException", cause["type"]);
        Assert.Equal("disk full", cause["message"]);
    }
}
