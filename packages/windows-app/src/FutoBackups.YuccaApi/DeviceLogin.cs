namespace FutoBackups.YuccaApi;

public sealed class DeviceLogin(YuccaApiClient client, Func<TimeSpan, CancellationToken, Task>? sleep = null)
{
    private readonly Func<TimeSpan, CancellationToken, Task> sleep = sleep ?? Task.Delay;

    public async Task<string> WaitForTokenAsync(DeviceFlowStartDto authorization, string connectionType, string connectionName, CancellationToken cancellation = default)
    {
        var interval = authorization.Interval ?? 5;
        var elapsed = 0L;
        var request = new DeviceFlowPollRequestDto { DeviceCode = authorization.DeviceCode, ConnectionType = connectionType, ConnectionName = connectionName };
        while (true)
        {
            if (elapsed >= authorization.ExpiresIn) throw new DeviceLoginException(DeviceLoginException.Expired);
            await sleep(TimeSpan.FromSeconds(interval), cancellation);
            elapsed += interval;
            var poll = await client.OidcDeviceTokenAsync(request, cancellation);
            switch (poll.Status)
            {
                case "PENDING":
                    break;
                case "SLOW_DOWN":
                    interval += 5;
                    break;
                case "SUCCESS":
                    return poll.AccessToken ?? throw new UnexpectedResponseException("SUCCESS device poll response without accessToken");
                case "FAILURE":
                    throw new DeviceLoginException(poll.Reason ?? "UNKNOWN");
                default:
                    throw new UnexpectedResponseException($"unknown device poll status: {poll.Status}");
            }
        }
    }
}
