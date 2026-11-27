using System.Security.Cryptography;
using System.Text;

using FutoBackups.Core.Strings;

namespace FutoBackups.Core.State;

public sealed class InvalidMasterKeyException() : Exception(Text.ErrorRecoveryKeyNotHexadecimal);

public static class RepositoryKeys
{
    public const int MasterKeyLength = 64;

    public static string GenerateMasterKey() => Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));

    public static bool IsValidMasterKey(string hex) => hex.Length == MasterKeyLength && hex.All(char.IsAsciiHexDigit);

    public static string? NormalizedMasterKey(string input)
    {
        var compact = new string(input.Where(character => !char.IsWhiteSpace(character) && character != '-').ToArray()).ToLowerInvariant();
        return IsValidMasterKey(compact) ? compact : null;
    }

    public static bool Matches(string input, string masterKey) => string.Equals(NormalizedMasterKey(input), masterKey, StringComparison.OrdinalIgnoreCase);

    public static int HexDigitCount(string input) => input.Count(char.IsAsciiHexDigit);

    public static string[] DisplayLines(string masterKey)
    {
        var characters = masterKey.ToUpperInvariant();
        return Enumerable.Range(0, (characters.Length + 15) / 16)
            .Select(line => string.Join(' ', Enumerable.Range(0, 4)
                .Select(group => line * 16 + group * 4)
                .Where(start => start < characters.Length)
                .Select(start => characters.Substring(start, Math.Min(4, characters.Length - start)))))
            .ToArray();
    }

    public static string Password(string masterKey, string repositoryId)
    {
        if (!IsValidMasterKey(masterKey)) throw new InvalidMasterKeyException();
        var derived = HKDF.DeriveKey(
            HashAlgorithmName.SHA256,
            Convert.FromHexString(masterKey),
            32,
            new byte[32],
            Encoding.UTF8.GetBytes($"repository-{repositoryId}"));
        return Convert.ToHexStringLower(derived);
    }
}
