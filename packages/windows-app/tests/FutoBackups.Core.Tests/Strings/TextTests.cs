using System.Globalization;

using FutoBackups.Core.Strings;

namespace FutoBackups.Core.Tests.Strings;

public class TextTests
{
    [Fact]
    public void UnsupportedLanguageFallsBackToEnglish()
    {
        Text.Culture = new CultureInfo("de-DE");
        try
        {
            Assert.Equal("Settings", Text.SettingsTitle);
        }
        finally
        {
            Text.Culture = null;
        }
    }
}
