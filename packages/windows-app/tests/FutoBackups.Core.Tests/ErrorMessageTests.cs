using System.ComponentModel;

using FutoBackups.YuccaApi;

namespace FutoBackups.Core.Tests;

public class ErrorMessageTests
{
    private const string Server = "futo.cloud";

    [Theory]
    [InlineData("Fatal: unable to open config file: unexpected HTTP response (500): 500 Internal Server Error", "The server returned an error (HTTP 500). Try again later.")]
    [InlineData("Fatal: unexpected HTTP response (429): 429 Too Many Requests", "The server returned an error (HTTP 429). Try again later.")]
    [InlineData("Fatal: unexpected HTTP response (404): 404 Not Found", "The server returned an error (HTTP 404). Try again, or contact FUTO support if it keeps happening.")]
    [InlineData("Fatal: open repository: write C:\\cache\\x: There is not enough space on the disk.", "This PC's disk is full. Free up some space, then try again.")]
    public void ResticErrorsBecomePlainMessages(string restic, string expected)
    {
        Assert.Equal(expected, ErrorMessage.ResticText(restic, Server));
    }

    [Fact]
    public void ResticRejectingTheTokenReadsAsAnExpiredSession()
    {
        Assert.Equal(ErrorMessage.SessionExpired, ErrorMessage.ResticText("Fatal: unexpected HTTP response (401): 401 Unauthorized", Server));
    }

    [Fact]
    public void ResticNetworkFailuresReadAsCouldNotConnect()
    {
        Assert.Equal(ConnectionFailure.Unreachable.Message(Server), ErrorMessage.ResticText("Fatal: dial tcp 127.0.0.1:443: connectex: No connection could be made", Server));
    }

    [Fact]
    public void AnUnrecognisedResticErrorKeepsItsDetailAfterThePlainMessage()
    {
        var text = ErrorMessage.ResticText("Fatal: wrong password or no key found", Server);

        Assert.StartsWith("FUTO Backups ran into a problem.", text);
        Assert.EndsWith("Details: Fatal: wrong password or no key found", text);
    }

    [Fact]
    public void LocalFileErrorsSayWhatToDoAndKeepTheDetail()
    {
        Assert.Equal("This PC's disk is full. Free up some space, then try again.", ErrorMessage.Text(new IOException("disk full", unchecked((int)0x80070070)), Server));
        Assert.EndsWith("Details: Access to the path is denied.", ErrorMessage.Text(new UnauthorizedAccessException("Access to the path is denied."), Server));
        Assert.StartsWith("FUTO Backups could not use a file or folder on this PC.", ErrorMessage.Text(new Win32Exception(2), Server));
    }

    private static YuccaApiException ApiError(int status) => new("error", status, null, new Dictionary<string, IEnumerable<string>>(), null);

    [Fact]
    public void ApiErrorsSayWhatHappenedOnTheServer()
    {
        Assert.Equal(ErrorMessage.SessionExpired, ErrorMessage.Text(ApiError(401), Server));
        Assert.Equal("The server returned an error (HTTP 503). Try again later.", ErrorMessage.Text(ApiError(503), Server));
        Assert.Equal("The server returned an error (HTTP 404). Try again, or contact FUTO support if it keeps happening.", ErrorMessage.Text(ApiError(404), Server));
        Assert.Equal("FUTO Backups could not read the response from the server. Try again later.", ErrorMessage.Text(ApiError(200), Server));
        Assert.True(ErrorMessage.SignsOut(ApiError(401)));
        Assert.False(ErrorMessage.SignsOut(ApiError(500)));
    }

    [Fact]
    public void DiscoveryProblemsSayWhatIsWrongWithTheAddress()
    {
        Assert.Equal("The server address must use HTTPS.", ErrorMessage.Text(new DiscoveryException(DiscoveryProblem.Insecure, "detail"), Server));
        Assert.Equal("The server address is not a FUTO Backups server. Make sure that the address is correct.", ErrorMessage.Text(new DiscoveryException(DiscoveryProblem.NotAServer, "detail"), Server));
        Assert.Equal("FUTO Backups could not read the response from the server. Try again later.", ErrorMessage.Text(new UnexpectedResponseException("detail"), Server));
    }

    [Theory]
    [InlineData("EXPIRED", "expired")]
    [InlineData("ACCESS_DENIED", "declined")]
    [InlineData("EMAIL_NOT_ALLOWED", "cannot use")]
    [InlineData("WRONG_ACCOUNT", "different account")]
    [InlineData("FEATURE_NOT_ENABLED", "not enabled")]
    [InlineData("UNSUPPORTED_CONNECTION_TYPE", "does not support")]
    [InlineData("UNKNOWN", "could not finish")]
    [InlineData("SOMETHING_NEW", "Sign-in failed")]
    public void EverySignInFailureHasItsOwnMessageWithANextStep(string reason, string expected)
    {
        var text = ErrorMessage.Text(new DeviceLoginException(reason), Server);

        Assert.Contains(expected, text, StringComparison.Ordinal);
        Assert.Matches("(?i)(try again|contact FUTO support)", text);
    }
}
