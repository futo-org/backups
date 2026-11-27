namespace FutoBackups.YuccaApi;

public enum DiscoveryProblem
{
    NotAServer,
    Insecure,
}

public sealed class DiscoveryException(DiscoveryProblem problem, string detail) : Exception(detail)
{
    public DiscoveryProblem Problem { get; } = problem;
}

public sealed class UnexpectedResponseException(string detail) : Exception(detail);

public sealed class DeviceLoginException(string reason) : Exception(reason)
{
    public const string Expired = "EXPIRED";

    public string Reason { get; } = reason;
}
