using FutoBackups.Core.State;

namespace FutoBackups.Core.Tests.State;

public class RepositoryKeysTests
{
    private const string TestVectorMasterKey = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
    private const string TestVectorRepositoryId = "0b6a1f6e-3c1d-4c2a-9f7e-5d4b3a2c1e0f";
    private const string TestVectorPassword = "9098804fe7a3943840f958fe8d7715cf7806b26f846e1bc977a52569fdb0bf5f";

    [Fact]
    public void PasswordMatchesTheOrchestrationApiTestVector() =>
        Assert.Equal(TestVectorPassword, RepositoryKeys.Password(TestVectorMasterKey, TestVectorRepositoryId));

    [Fact]
    public void UppercaseMasterKeyDerivesTheSamePassword() =>
        Assert.Equal(TestVectorPassword, RepositoryKeys.Password(TestVectorMasterKey.ToUpperInvariant(), TestVectorRepositoryId));

    [Fact]
    public void GeneratedKeyIsSixtyFourLowercaseHexCharacters()
    {
        var key = RepositoryKeys.GenerateMasterKey();
        Assert.Equal(64, key.Length);
        Assert.Equal(key.ToLowerInvariant(), key);
        Assert.True(RepositoryKeys.IsValidMasterKey(key));
    }

    [Fact]
    public void GeneratedKeysDiffer() =>
        Assert.Equal(3, Enumerable.Range(0, 3).Select(_ => RepositoryKeys.GenerateMasterKey()).Distinct().Count());

    [Theory]
    [InlineData("0011 2233 4455 6677 8899 AABB CCDD EEFF\n0011-2233-4455-6677-8899-aabb-ccdd-eeff")]
    [InlineData("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")]
    public void MatchesIgnoresSpacesDashesAndCase(string input) => Assert.True(RepositoryKeys.Matches(input, TestVectorMasterKey));

    [Theory]
    [InlineData("")]
    [InlineData("0011")]
    [InlineData("zz112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")]
    public void NormalisationRejectsAnythingButSixtyFourHexCharacters(string input) => Assert.Null(RepositoryKeys.NormalizedMasterKey(input));

    [Fact]
    public void PasswordRejectsAnInvalidKey() =>
        Assert.Throws<InvalidMasterKeyException>(() => RepositoryKeys.Password("abc", TestVectorRepositoryId));

    [Fact]
    public void DisplayLinesAreFourLinesOfFourGroupsInUpperCase() =>
        Assert.Equal(
            ["0011 2233 4455 6677", "8899 AABB CCDD EEFF", "0011 2233 4455 6677", "8899 AABB CCDD EEFF"],
            RepositoryKeys.DisplayLines(TestVectorMasterKey));
}
