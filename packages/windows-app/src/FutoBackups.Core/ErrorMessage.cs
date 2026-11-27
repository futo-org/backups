using System.ComponentModel;
using System.Globalization;
using System.Net.Http;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text.RegularExpressions;

using FutoBackups.Core.Strings;
using FutoBackups.ResticWrapper;
using FutoBackups.YuccaApi;

namespace FutoBackups.Core;

public enum ConnectionFailure
{
    Unreachable,
    Unavailable,
    Offline,
    Insecure,
}

public static partial class ConnectionFailures
{
    internal const string RejectedCredentialsPhrase = "unexpected HTTP response (401)";

    private static readonly string[] UnreachableResticPhrases =
    [
        "dial tcp", "no such host", "connection refused", "network is unreachable", "i/o timeout",
        "tls handshake timeout", "connection reset by peer", "no route to host", "wsarecv", "wsasend",
        "actively refused", "connectex",
    ];

    private static readonly string[] ProxyUnreachableStatuses = ["unexpected HTTP response (502)", "unexpected HTTP response (504)"];
    private const string UnavailableStatus = "unexpected HTTP response (503)";

    public static string Message(this ConnectionFailure failure, string server) => failure switch
    {
        ConnectionFailure.Unreachable => string.Format(CultureInfo.CurrentCulture, Text.ErrorCouldNotConnect, server),
        ConnectionFailure.Unavailable => string.Format(CultureInfo.CurrentCulture, Text.ErrorServerDidNotRespond, server),
        ConnectionFailure.Offline => Text.ErrorOffline,
        _ => string.Format(CultureInfo.CurrentCulture, Text.ErrorCouldNotConnectSecurely, server),
    };

    public static ConnectionFailure? From(Exception error)
    {
        for (var current = error; current is not null; current = current.InnerException)
        {
            switch (current)
            {
                case HttpRequestException { HttpRequestError: HttpRequestError.SecureConnectionError }:
                case AuthenticationException:
                    return ConnectionFailure.Insecure;
                case SocketException { SocketErrorCode: SocketError.NetworkUnreachable or SocketError.NetworkDown or SocketError.HostUnreachable }:
                    return ConnectionFailure.Offline;
                case HttpRequestException { HttpRequestError: HttpRequestError.NameResolutionError or HttpRequestError.ConnectionError }:
                case SocketException:
                case TimeoutException:
                    return ConnectionFailure.Unreachable;
                case TaskCanceledException { InnerException: TimeoutException }:
                    return ConnectionFailure.Unreachable;
            }
        }

        return null;
    }

    public static ConnectionFailure? FromRestic(string message)
    {
        if (message.Contains(UnavailableStatus)) return ConnectionFailure.Unavailable;
        if (ProxyUnreachableStatuses.Any(message.Contains)) return ConnectionFailure.Unreachable;
        var lowered = message.ToLowerInvariant();
        return UnreachableResticPhrases.Any(lowered.Contains) ? ConnectionFailure.Unreachable : null;
    }

    public static bool IsTransient(Exception error) => From(error) is ConnectionFailure.Unreachable;

    public static bool IsProducedBy(this ConnectionFailure failure, string message)
    {
        const string Marker = "\0";
        var parts = failure.Message(Marker).Split(Marker);
        if (parts.Length != 2) return message == parts[0];
        return message.Length > parts[0].Length + parts[1].Length && message.StartsWith(parts[0], StringComparison.Ordinal) && message.EndsWith(parts[1], StringComparison.Ordinal);
    }
}

public static partial class ErrorMessage
{
    private static readonly string[] DiskFullPhrases = ["no space left on device", "not enough space on the disk"];

    private static readonly string[] AccessDeniedPhrases = ["access is denied", "permission denied"];

    [GeneratedRegex(@"unexpected HTTP response \((\d{3})\)")]
    private static partial Regex ResticHttpStatus();

    public static string SessionExpired => Strings.Text.ErrorSessionExpired;

    public static bool IsCancellation(Exception error) => error is OperationCanceledException and not TaskCanceledException { InnerException: TimeoutException };

    public static bool SignsOut(Exception error) => error switch
    {
        YuccaApiException { StatusCode: 401 } => true,
        RestoreIncompleteException incomplete => SignsOut(incomplete.Cause),
        _ => false,
    };

    public static string? Text(Exception error, string server)
    {
        if (IsCancellation(error)) return null;
        return error switch
        {
            EngineException engine => EngineText(engine.Error, engine.ResticMessage, server),
            DeviceLoginException login => DeviceLoginText(login.Reason, server),
            RestoreIncompleteException incomplete => RestoreIncompleteText(incomplete, server),
            DiscoveryException { Problem: DiscoveryProblem.Insecure } => Strings.Text.ErrorServerMustUseHttps,
            DiscoveryException => Strings.Text.ErrorNotAFutoBackupsServer,
            UnexpectedResponseException or YuccaApiException { StatusCode: >= 200 and < 300 } => Strings.Text.ErrorCouldNotReadResponse,
            YuccaApiException { StatusCode: 401 } => SessionExpired,
            YuccaApiException api => ServerStatusText(api.StatusCode),
            _ when ConnectionFailures.From(error) is { } failure => failure.Message(server),
            UnauthorizedAccessException => string.Format(CultureInfo.CurrentCulture, Strings.Text.ErrorLocalAccessDenied, error.Message),
            IOException { HResult: unchecked((int)0x80070070) or unchecked((int)0x80070027) } => Strings.Text.ErrorDiskFull,
            IOException or Win32Exception => string.Format(CultureInfo.CurrentCulture, Strings.Text.ErrorLocalProblem, error.Message),
            _ => error.Message,
        };
    }

    public static string ResticText(string message, string server)
    {
        if (ConnectionFailures.FromRestic(message) is { } failure) return failure.Message(server);
        if (message.Contains(ConnectionFailures.RejectedCredentialsPhrase)) return SessionExpired;
        var status = ResticHttpStatus().Match(message);
        if (status.Success) return ServerStatusText(int.Parse(status.Groups[1].Value, CultureInfo.InvariantCulture));

        var lowered = message.ToLowerInvariant();
        if (DiskFullPhrases.Any(lowered.Contains)) return Strings.Text.ErrorDiskFull;
        if (AccessDeniedPhrases.Any(lowered.Contains)) return string.Format(CultureInfo.CurrentCulture, Strings.Text.ErrorLocalAccessDenied, message);
        return string.Format(CultureInfo.CurrentCulture, Strings.Text.ErrorBackupToolProblem, message);
    }

    private static string ServerStatusText(int code) =>
        string.Format(CultureInfo.CurrentCulture, code >= 500 || code is 408 or 429 ? Strings.Text.ErrorServerReturnedTryLater : Strings.Text.ErrorServerReturnedTryAgain, code);

    private static string DeviceLoginText(string reason, string server) => reason switch
    {
        DeviceLoginException.Expired => Strings.Text.ErrorSignInCodeExpired,
        "ACCESS_DENIED" => Strings.Text.ErrorSignInDeclined,
        "EMAIL_NOT_ALLOWED" => Strings.Text.ErrorEmailNotAllowed,
        "WRONG_ACCOUNT" => Strings.Text.ErrorWrongAccount,
        "FEATURE_NOT_ENABLED" => Strings.Text.ErrorFeatureNotEnabled,
        "UNSUPPORTED_CONNECTION_TYPE" => string.Format(CultureInfo.CurrentCulture, Strings.Text.ErrorUnsupportedConnectionType, server),
        "UNKNOWN" => string.Format(CultureInfo.CurrentCulture, Strings.Text.ErrorSignInUnknown, server),
        _ => string.Format(CultureInfo.CurrentCulture, Strings.Text.ErrorSignInFailed, reason),
    };

    private static string EngineText(EngineError error, string? resticMessage, string server) => error switch
    {
        EngineError.NotLoggedIn => Strings.Text.ErrorNotSignedIn,
        EngineError.NoRepository => Strings.Text.ErrorNoRepository,
        EngineError.NoFolders => Strings.Text.ErrorNoFolders,
        EngineError.Busy => Strings.Text.ErrorBusy,
        EngineError.MissingMasterKey => Strings.Text.ErrorMissingKey,
        EngineError.MissingHelper => Strings.Text.ErrorMissingHelper,
        _ => ResticText(resticMessage ?? string.Empty, server),
    };

    private static string RestoreIncompleteText(RestoreIncompleteException incomplete, string server)
    {
        var parts = new List<string> { Text(incomplete.Cause, server) ?? Strings.Text.ErrorRestoreCancelled };
        if (incomplete.Restored.Count > 0)
        {
            parts.Add(incomplete.Restored.Count == 1
                ? Strings.Text.ErrorRestoredOneItem
                : string.Format(CultureInfo.CurrentCulture, Strings.Text.ErrorRestoredItems, incomplete.Restored.Count));
        }

        if (incomplete.LeftoverStaging is { } leftover)
        {
            parts.Add(string.Format(CultureInfo.CurrentCulture, Strings.Text.ErrorCouldNotRemoveTemporaryFolder, leftover));
        }

        return string.Join(". ", parts);
    }
}

public enum EngineError
{
    NotLoggedIn,
    NoRepository,
    NoFolders,
    MissingMasterKey,
    Busy,
    MissingHelper,
    Restic,
}

public sealed class EngineException(EngineError error, string? resticMessage = null, int resticCode = 0)
    : Exception(resticMessage ?? error.ToString())
{
    public EngineError Error { get; } = error;

    public string? ResticMessage { get; } = resticMessage;

    public int ResticCode { get; } = resticCode;
}

public sealed class RestoreIncompleteException(Exception cause, IReadOnlyList<string> restored, string? leftoverStaging)
    : Exception(cause.Message, cause)
{
    public Exception Cause { get; } = cause;

    public IReadOnlyList<string> Restored { get; } = restored;

    public string? LeftoverStaging { get; } = leftoverStaging;
}
