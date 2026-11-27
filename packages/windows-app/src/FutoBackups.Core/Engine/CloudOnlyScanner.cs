using FutoBackups.Core.State;

namespace FutoBackups.Core.Engine;

public interface ICloudOnlyScanner
{
    CloudOnlySkip? Scan(IReadOnlyList<string> folders, IReadOnlyList<string> excludes, CancellationToken cancellation);
}

public sealed class NoCloudOnlyScan : ICloudOnlyScanner
{
    public CloudOnlySkip? Scan(IReadOnlyList<string> folders, IReadOnlyList<string> excludes, CancellationToken cancellation) => null;
}

public sealed class PlaceholderScanner : ICloudOnlyScanner
{
    private const FileAttributes RecallOnOpen = (FileAttributes)0x40000;
    private const FileAttributes RecallOnDataAccess = (FileAttributes)0x400000;

    public static bool IsCloudOnly(FileAttributes attributes) =>
        (attributes & (RecallOnDataAccess | RecallOnOpen | FileAttributes.Offline)) != 0;

    public CloudOnlySkip? Scan(IReadOnlyList<string> folders, IReadOnlyList<string> excludes, CancellationToken cancellation)
    {
        var count = 0;
        long bytes = 0;
        var sample = new List<string>();
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = false,
            IgnoreInaccessible = true,
            AttributesToSkip = 0,
            ReturnSpecialDirectories = false,
        };
        var pending = new Stack<string>(folders.Where(Directory.Exists));
        while (pending.Count > 0)
        {
            cancellation.ThrowIfCancellationRequested();
            var directory = pending.Pop();
            if (Exclusions.IsExcluded(directory, excludes)) continue;
            IEnumerable<FileSystemInfo> entries;
            try
            {
                entries = new DirectoryInfo(directory).EnumerateFileSystemInfos("*", options);
            }
            catch (IOException)
            {
                continue;
            }
            catch (UnauthorizedAccessException)
            {
                continue;
            }

            foreach (var entry in entries)
            {
                if (entry is DirectoryInfo)
                {
                    if ((entry.Attributes & FileAttributes.ReparsePoint) == 0 || IsCloudOnlyFolder(entry.Attributes))
                    {
                        pending.Push(entry.FullName);
                    }

                    continue;
                }

                if (!IsCloudOnly(entry.Attributes) || Exclusions.IsExcluded(entry.FullName, excludes)) continue;
                count++;
                var file = (FileInfo)entry;
                bytes += file.Length;
                if (sample.Count < CloudOnlySkip.SampleLimit)
                {
                    sample.Add(entry.FullName);
                }
            }
        }

        return new CloudOnlySkip(count, bytes, sample);
    }

    private static bool IsCloudOnlyFolder(FileAttributes attributes) => (attributes & (RecallOnOpen | RecallOnDataAccess)) != 0;
}
