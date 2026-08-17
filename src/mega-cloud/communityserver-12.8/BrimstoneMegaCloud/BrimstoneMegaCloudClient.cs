using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace ASC.Files.Thirdparty.BrimstoneMegaCloud
{
    internal sealed class BrimstoneMegaCloudClient : IDisposable
    {
        private const int CommandTimeoutMilliseconds = 180000;
        private const int DownloadTimeoutMilliseconds = 1800000;

        private const uint Mode0700 = 448;
        private const uint Mode0600 = 384;

        // BRIMSTONE: this root belongs to the separate MEGA S4 provider.
        // It is globally unavailable through the normal MEGA Cloud provider.
        private const string ReservedS4RootName = "S4 Object storage";

        private readonly string enginePrefix;
        private readonly string stateRoot;
        private readonly string stateSlot;
        private readonly string slotRoot;
        private readonly string home;
        private readonly string socketName;

        [DllImport("libc", SetLastError = true)]
        private static extern int chmod(string pathname, uint mode);

        [DllImport("libc")]
        private static extern uint getuid();

        public BrimstoneMegaCloudClient(string stateSlot)
            : this(stateSlot,
                   Environment.GetEnvironmentVariable("BRIMSTONE_MEGA_CLOUD_ENGINE_PREFIX")
                       ?? "/opt/brimstone/mega-cloud/megacmd",
                   Environment.GetEnvironmentVariable("BRIMSTONE_MEGA_CLOUD_STATE_ROOT")
                       ?? "/var/lib/brimstone/mega-cloud/providers")
        {
        }

        internal BrimstoneMegaCloudClient(string stateSlot,
                                          string enginePrefix,
                                          string stateRoot)
        {
            if (string.IsNullOrEmpty(stateSlot))
                throw new ArgumentNullException("stateSlot");

            foreach (var c in stateSlot)
            {
                if (!(char.IsLetterOrDigit(c) || c == '_' || c == '-'))
                    throw new ArgumentException(
                        "Invalid Brimstone MEGA Cloud state slot.",
                        "stateSlot");
            }

            if (stateSlot.Length > 64)
                throw new ArgumentException(
                    "Brimstone MEGA Cloud state slot is too long.",
                    "stateSlot");

            this.stateSlot = stateSlot;
            this.enginePrefix = enginePrefix;
            this.stateRoot = stateRoot;

            slotRoot = Path.Combine(stateRoot, stateSlot);
            home = Path.Combine(slotRoot, "home");

            socketName =
                "brimstone-megacc-" + stateSlot + ".socket";

            EnsureSecureStateDirectory();
        }

        public bool HasSavedSession
        {
            get
            {
                return File.Exists(
                    Path.Combine(
                        Path.Combine(home, ".megaCmd"),
                        "session"));
            }
        }

        public List<BrimstoneMegaCloudEntry> ListChildren(string parentPath)
        {
            parentPath = BrimstoneMegaCloudId.NormalizeRemotePath(parentPath);

            // Fail closed even if somebody constructs a direct ONLYOFFICE id
            // for the reserved S4 subtree.
            DenyReservedPath(parentPath);

            var stdout = RunReadOnly(
                "ls -l --show-handles --time-format=ISO6081_WITH_TIME "
                + QuoteArgument(parentPath));

            var entries =
                BrimstoneMegaCloudLsParser.Parse(stdout);

            foreach (var entry in entries)
            {
                entry.ParentPath = parentPath;
                entry.RemotePath =
                    BrimstoneMegaCloudId.Combine(parentPath, entry.Name);
            }

            if (parentPath == "/")
            {
                var excluded = LoadExcludedRootHandles();

                entries = entries
                    .Where(x =>
                        !string.Equals(
                            (x.Name ?? string.Empty).Trim(),
                            ReservedS4RootName,
                            StringComparison.OrdinalIgnoreCase)
                        &&
                        !excluded.Contains(x.Handle))
                    .ToList();
            }

            return entries;
        }

        public BrimstoneMegaCloudEntry GetEntry(string remotePath)
        {
            remotePath =
                BrimstoneMegaCloudId.NormalizeRemotePath(remotePath);

            DenyReservedPath(remotePath);

            if (remotePath == "/")
                return null;

            var parent =
                BrimstoneMegaCloudId.ParentPath(remotePath);

            var name =
                BrimstoneMegaCloudId.Name(remotePath);

            return ListChildren(parent)
                .FirstOrDefault(x =>
                    x.Name.Equals(
                        name,
                        StringComparison.Ordinal));
        }

        public Stream OpenRead(string remotePath)
        {
            return OpenRead(remotePath, 0);
        }

        public Stream OpenRead(string remotePath, long offset)
        {
            remotePath =
                BrimstoneMegaCloudId.NormalizeRemotePath(remotePath);

            DenyReservedPath(remotePath);

            if (remotePath == "/")
                throw new ArgumentException(
                    "MEGA Cloud root cannot be opened as a file.",
                    "remotePath");

            if (offset < 0)
                throw new ArgumentOutOfRangeException("offset");

            // Resolve against the live parent listing first. This verifies that
            // the path still exists and represents a file before downloading it.
            var entry = GetEntry(remotePath);

            if (entry == null || !entry.IsFile)
                throw new FileNotFoundException(
                    "Brimstone MEGA Cloud file was not found.",
                    remotePath);

            var downloadRoot =
                Path.Combine(slotRoot, "downloads");

            Directory.CreateDirectory(downloadRoot);

            if (chmod(downloadRoot, Mode0700) != 0)
                throw new InvalidOperationException(
                    "Unable to secure Brimstone MEGA Cloud download directory.");

            var tempDirectory =
                Path.Combine(
                    downloadRoot,
                    Guid.NewGuid().ToString("N"));

            Directory.CreateDirectory(tempDirectory);

            if (chmod(tempDirectory, Mode0700) != 0)
            {
                try { Directory.Delete(tempDirectory, true); }
                catch { }

                throw new InvalidOperationException(
                    "Unable to secure Brimstone MEGA Cloud temporary download directory.");
            }

            try
            {
                RunReadOnly(
                    "get --ignore-quota-warn "
                    + QuoteArgument(remotePath)
                    + " "
                    + QuoteArgument(tempDirectory),
                    DownloadTimeoutMilliseconds);

                // A remote FILE download must create exactly one ordinary file
                // in our unique destination directory. Do not derive a local
                // filename from user-controlled remote path text.
                var files =
                    Directory.GetFiles(
                        tempDirectory,
                        "*",
                        SearchOption.TopDirectoryOnly);

                if (files.Length != 1)
                    throw new InvalidOperationException(
                        "Brimstone MEGA Cloud download produced an unexpected local result.");

                var localFile = files[0];

                if (chmod(localFile, Mode0600) != 0)
                    throw new InvalidOperationException(
                        "Unable to secure downloaded Brimstone MEGA Cloud file.");

                var stream =
                    new TemporaryDownloadFileStream(
                        localFile,
                        tempDirectory);

                if (offset > 0)
                    stream.Seek(offset, SeekOrigin.Begin);

                return stream;
            }
            catch
            {
                try
                {
                    if (Directory.Exists(tempDirectory))
                        Directory.Delete(tempDirectory, true);
                }
                catch
                {
                }

                throw;
            }
        }

        public void Dispose()
        {
        }

        private sealed class TemporaryDownloadFileStream : FileStream
        {
            private readonly string temporaryDirectory;
            private bool disposed;

            public TemporaryDownloadFileStream(string path,
                                               string temporaryDirectory)
                : base(path,
                       FileMode.Open,
                       FileAccess.Read,
                       FileShare.Read,
                       65536,
                       FileOptions.SequentialScan)
            {
                this.temporaryDirectory = temporaryDirectory;
            }

            protected override void Dispose(bool disposing)
            {
                if (disposed)
                    return;

                disposed = true;

                try
                {
                    base.Dispose(disposing);
                }
                finally
                {
                    try
                    {
                        if (!string.IsNullOrEmpty(temporaryDirectory)
                            && Directory.Exists(temporaryDirectory))
                        {
                            Directory.Delete(temporaryDirectory, true);
                        }
                    }
                    catch
                    {
                        // Cleanup failure must not invalidate a successfully
                        // delivered file stream. Stale temp cleanup can be
                        // handled separately.
                    }
                }
            }
        }

        private static void DenyReservedPath(string remotePath)
        {
            remotePath =
                BrimstoneMegaCloudId.NormalizeRemotePath(remotePath);

            var reserved = "/" + ReservedS4RootName;

            if (string.Equals(
                    remotePath,
                    reserved,
                    StringComparison.OrdinalIgnoreCase)
                ||
                remotePath.StartsWith(
                    reserved + "/",
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new UnauthorizedAccessException(
                    "The MEGA S4 namespace is not available through the normal MEGA Cloud connector.");
            }
        }

        private HashSet<string> LoadExcludedRootHandles()
        {
            var result =
                new HashSet<string>(StringComparer.Ordinal);

            var file =
                Path.Combine(slotRoot, "exclude-root-handles.txt");

            if (!File.Exists(file))
                return result;

            foreach (var raw in File.ReadAllLines(file))
            {
                var line = (raw ?? string.Empty).Trim();

                if (line.Length == 0 || line.StartsWith("#"))
                    continue;

                ValidateHandle(line);
                result.Add(line);
            }

            return result;
        }

        private void EnsureSecureStateDirectory()
        {
            Directory.CreateDirectory(slotRoot);
            Directory.CreateDirectory(home);

            if (chmod(slotRoot, Mode0700) != 0)
                throw new InvalidOperationException(
                    "Unable to secure Brimstone MEGA Cloud provider state directory.");

            if (chmod(home, Mode0700) != 0)
                throw new InvalidOperationException(
                    "Unable to secure Brimstone MEGA Cloud HOME directory.");
        }

        private void EnsureSocketDirectory()
        {
            var path =
                "/tmp/megacmd-"
                + getuid().ToString(
                    System.Globalization.CultureInfo.InvariantCulture);

            Directory.CreateDirectory(path);

            if (chmod(path, Mode0700) != 0)
                throw new InvalidOperationException(
                    "Unable to secure Brimstone MEGA Cloud MEGAcmd socket directory.");
        }

        private string RunReadOnly(string arguments)
        {
            return RunReadOnly(arguments, CommandTimeoutMilliseconds);
        }

        private string RunReadOnly(string arguments, int timeoutMilliseconds)
        {
            if (!HasSavedSession)
                throw new InvalidOperationException(
                    "Brimstone MEGA Cloud provider has no saved MEGA session.");

            EnsureSocketDirectory();

            var executable =
                Path.Combine(
                    Path.Combine(
                        Path.Combine(enginePrefix, "usr"),
                        "bin"),
                    "mega-exec");

            if (!File.Exists(executable))
                throw new FileNotFoundException(
                    "Brimstone MEGA Cloud MEGAcmd engine is not installed.",
                    executable);

            var psi = new ProcessStartInfo
            {
                FileName = executable,
                Arguments = arguments,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };

            psi.EnvironmentVariables["HOME"] = home;
            psi.EnvironmentVariables["MEGACMD_SOCKET_NAME"] = socketName;

            var libraryPath =
                Path.Combine(
                    Path.Combine(
                        Path.Combine(enginePrefix, "opt"),
                        "megacmd"),
                    "lib");

            var oldLibraryPath =
                psi.EnvironmentVariables["LD_LIBRARY_PATH"];

            psi.EnvironmentVariables["LD_LIBRARY_PATH"] =
                string.IsNullOrEmpty(oldLibraryPath)
                    ? libraryPath
                    : libraryPath + ":" + oldLibraryPath;

            using (var process = Process.Start(psi))
            {
                if (process == null)
                    throw new InvalidOperationException(
                        "Unable to start Brimstone MEGA Cloud MEGAcmd client.");

                var stdoutTask =
                    Task.Factory.StartNew(
                        delegate { return process.StandardOutput.ReadToEnd(); });

                var stderrTask =
                    Task.Factory.StartNew(
                        delegate { return process.StandardError.ReadToEnd(); });

                if (!process.WaitForExit(timeoutMilliseconds))
                {
                    try { process.Kill(); }
                    catch { }

                    throw new TimeoutException(
                        "Brimstone MEGA Cloud MEGAcmd command timed out.");
                }

                Task.WaitAll(stdoutTask, stderrTask);

                if (process.ExitCode != 0)
                {
                    var error = stderrTask.Result;

                    if (error != null && error.Length > 2048)
                        error = error.Substring(0, 2048);

                    throw new InvalidOperationException(
                        "Brimstone MEGA Cloud MEGAcmd browse failed: "
                        + error);
                }

                return stdoutTask.Result;
            }
        }

        private static string QuoteArgument(string value)
        {
            if (value == null)
                return "\"\"";

            return "\""
                + value
                    .Replace("\\", "\\\\")
                    .Replace("\"", "\\\"")
                + "\"";
        }

        private static void ValidateHandle(string handle)
        {
            if (string.IsNullOrEmpty(handle))
                return;

            foreach (var c in handle)
            {
                if (!(char.IsLetterOrDigit(c) ||
                      c == '_' ||
                      c == '-'))
                    throw new ArgumentException(
                        "Invalid MEGA node handle.",
                        "handle");
            }
        }
    }
}
