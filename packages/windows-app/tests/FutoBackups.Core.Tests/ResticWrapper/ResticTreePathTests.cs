using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Tests.ResticWrapper;

public class ResticTreePathTests
{
    [Theory]
    [InlineData(@"C:\Users\Sam\Documents", "/C/Users/Sam/Documents")]
    [InlineData(@"D:\", "/D")]
    [InlineData(@"C:\Users\Sam\[Draft] notes", "/C/Users/Sam/[Draft] notes")]
    [InlineData(@"\\nas\photos\2025", @"/\\nas\photos/2025")]
    [InlineData(@"\\nas\photos", @"/\\nas\photos")]
    [InlineData(@"\\?\C:\Users\Sam\Documents", @"/\\?\C:/Users/Sam/Documents")]
    public void TreePathsRoundTripToTheWindowsPathTheyCameFrom(string local, string tree)
    {
        Assert.Equal(tree, ResticTreePath.FromLocal(local));
        Assert.Equal(local.TrimEnd('\\'), ResticTreePath.ToLocal(tree).TrimEnd('\\'));
    }

    [Theory]
    [InlineData("/C/Users/Sam", "/C/Users")]
    [InlineData("/C", "/")]
    [InlineData("/", null)]
    [InlineData("relative", null)]
    public void TheParentOfATreePathIsTheFolderAboveIt(string path, string? parent) =>
        Assert.Equal(parent, ResticTreePath.Parent(path));
}
