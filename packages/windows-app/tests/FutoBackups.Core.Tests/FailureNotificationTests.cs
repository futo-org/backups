namespace FutoBackups.Core.Tests;

public class FailureNotificationTests
{
    [Theory]
    [InlineData(true, true, false, false, "Post")]
    [InlineData(false, true, false, false, "Nothing")]
    [InlineData(true, false, false, false, "Nothing")]
    [InlineData(true, true, true, false, "Nothing")]
    [InlineData(true, true, false, true, "Nothing")]
    public void AScheduledFailurePostsOncePerStreak(bool scheduled, bool notifies, bool streakNotified, bool pending, string expected) =>
        Assert.Equal(expected, FailureNoticeStep.After(new BackupRunOutcome.Failed(BackupFailureReason.Other), scheduled, notifies, streakNotified, pending).GetType().Name);

    [Fact]
    public void ASuccessEndsANotifiedStreak()
    {
        Assert.IsType<FailureNoticeStep.EndStreak>(FailureNoticeStep.After(new BackupRunOutcome.Succeeded(), true, true, true, false));
        Assert.IsType<FailureNoticeStep.Nothing>(FailureNoticeStep.After(new BackupRunOutcome.Succeeded(), true, true, false, false));
        Assert.IsType<FailureNoticeStep.Nothing>(FailureNoticeStep.After(new BackupRunOutcome.Stopped(), true, true, true, false));
    }

    [Fact]
    public void SignedOutAndMissingKeyAreNamedInTheNotification()
    {
        var now = DateTimeOffset.Now;
        Assert.Contains("sign in again", FailureNotice.For(BackupFailureReason.SignedOut, "FUTO Cloud", null, now).Body);
        Assert.Contains("enter the key again", FailureNotice.For(BackupFailureReason.MissingRecoveryKey, "FUTO Cloud", null, now).Body);
        Assert.Contains("try again soon", FailureNotice.For(BackupFailureReason.Unreachable, "FUTO Cloud", now.AddMinutes(-1), now).Body);
    }

    [Theory]
    [InlineData("Your session expired. Sign in again.", BackupFailureReason.SignedOut)]
    [InlineData("Fatal: unexpected HTTP response (401): 401 Unauthorized", BackupFailureReason.SignedOut)]
    [InlineData("Could not connect to futo.cloud. Make sure that this PC is connected to the internet.", BackupFailureReason.Unreachable)]
    [InlineData("dial tcp 1.2.3.4:443: connectex: No connection could be made because the target machine actively refused it.", BackupFailureReason.Unreachable)]
    [InlineData("This PC's recovery key is missing. Enter it to keep backing up.", BackupFailureReason.MissingRecoveryKey)]
    [InlineData("Fatal: repository is locked", BackupFailureReason.Other)]
    public void FailureMessagesMapToTheirCause(string message, BackupFailureReason reason) =>
        Assert.Equal(reason, BackupFailureReasons.FromMessage(message));
}
