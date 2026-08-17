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

        public BrimstoneMegaCloudEntry CreateFolder(string parentPath,
                                                         string name)
        {
            parentPath =
                BrimstoneMegaCloudId.NormalizeRemotePath(parentPath);

            ValidateNodeName(name);

            var remotePath =
                CombineRemotePath(parentPath, name);

            DenyReservedPath(remotePath);

            RunReadOnly(
                "mkdir " + QuoteArgument(remotePath));

            var created = GetEntry(remotePath);

            if (created == null || !created.IsFolder)
                throw new InvalidOperationException(
                    "Brimstone MEGA Cloud folder creation could not be verified.");

            return created;
        }

        public BrimstoneMegaCloudEntry Put(string remotePath,
                                           Stream source)
        {
            if (source == null)
                throw new ArgumentNullException("source");

            remotePath =
                BrimstoneMegaCloudId.NormalizeRemotePath(remotePath);

            DenyReservedPath(remotePath);

            if (remotePath == "/")
                throw new ArgumentException(
                    "MEGA Cloud root cannot be written as a file.",
                    "remotePath");

            var name = RemoteLeaf(remotePath);
            ValidateNodeName(name);

            var parentPath = ParentRemotePath(remotePath);
            DenyReservedPath(parentPath);

            var uploadRoot =
                Path.Combine(slotRoot, "uploads");

            Directory.CreateDirectory(uploadRoot);

            if (chmod(uploadRoot, Mode0700) != 0)
                throw new InvalidOperationException(
                    "Unable to secure Brimstone MEGA Cloud upload directory.");

            var tempDirectory =
                Path.Combine(
                    uploadRoot,
                    Guid.NewGuid().ToString("N"));

            Directory.CreateDirectory(tempDirectory);

            if (chmod(tempDirectory, Mode0700) != 0)
            {
                try { Directory.Delete(tempDirectory, true); }
                catch { }

                throw new InvalidOperationException(
                    "Unable to secure Brimstone MEGA Cloud temporary upload directory.");
            }

            try
            {
                // The local basename deliberately equals the exact MEGA basename.
                // Do not trim it: trailing spaces must survive round-trip.
                var localFile =
                    Path.Combine(tempDirectory, name);

                using (var output =
                    new FileStream(
                        localFile,
                        FileMode.CreateNew,
                        FileAccess.Write,
                        FileShare.None,
                        65536,
                        FileOptions.SequentialScan))
                {
                    source.CopyTo(output);
                    output.Flush();
                }

                if (chmod(localFile, Mode0600) != 0)
                    throw new InvalidOperationException(
                        "Unable to secure staged Brimstone MEGA Cloud upload.");

                // MEGA versioning was acceptance-tested on this account:
                // PUT of the same basename to the same parent creates a new
                // version while the live remote path remains stable.
                RunReadOnly(
                    "put "
                    + QuoteArgument(localFile)
                    + " "
                    + QuoteArgument(parentPath),
                    DownloadTimeoutMilliseconds);

                var saved = GetEntry(remotePath);

                if (saved == null || !saved.IsFile)
                    throw new InvalidOperationException(
                        "Brimstone MEGA Cloud upload could not be verified.");

                return saved;
            }
            finally
            {
                try
                {
                    if (Directory.Exists(tempDirectory))
                        Directory.Delete(tempDirectory, true);
                }
                catch
                {
                }
            }
        }

        public BrimstoneMegaCloudEntry Move(string sourcePath,
                                                string destinationPath)
        {
            sourcePath =
                BrimstoneMegaCloudId.NormalizeRemotePath(sourcePath);

            destinationPath =
                BrimstoneMegaCloudId.NormalizeRemotePath(destinationPath);

            DenyReservedPath(sourcePath);
            DenyReservedPath(destinationPath);

            if (sourcePath == "/")
                throw new InvalidOperationException(
                    "MEGA Cloud root cannot be moved or renamed.");

            if (destinationPath == "/")
                throw new InvalidOperationException(
                    "MEGA Cloud root cannot be a node destination.");

            var destinationName =
                RemoteLeaf(destinationPath);

            ValidateNodeName(destinationName);

            var source =
                GetEntry(sourcePath);

            if (source == null)
                throw new FileNotFoundException(
                    "Brimstone MEGA Cloud source node was not found.",
                    sourcePath);

            if (string.Equals(
                    sourcePath,
                    destinationPath,
                    StringComparison.Ordinal))
            {
                return source;
            }

            if (destinationPath.StartsWith(
                    sourcePath + "/",
                    StringComparison.Ordinal))
            {
                throw new InvalidOperationException(
                    "A MEGA Cloud node cannot be moved into itself.");
            }

            if (GetEntry(destinationPath) != null)
                throw new IOException(
                    "The requested MEGA Cloud destination already exists.");

            RunReadOnly(
                "mv "
                + QuoteArgument(sourcePath)
                + " "
                + QuoteArgument(destinationPath));

            var moved =
                GetEntry(destinationPath);

            if (moved == null)
                throw new InvalidOperationException(
                    "Brimstone MEGA Cloud move could not be verified.");

            return moved;
        }

        public BrimstoneMegaCloudEntry Copy(string sourcePath,
                                                string destinationPath)
        {
            sourcePath =
                BrimstoneMegaCloudId.NormalizeRemotePath(sourcePath);

            destinationPath =
                BrimstoneMegaCloudId.NormalizeRemotePath(destinationPath);

            DenyReservedPath(sourcePath);
            DenyReservedPath(destinationPath);

            if (sourcePath == "/")
                throw new InvalidOperationException(
                    "MEGA Cloud root cannot be copied.");

            if (destinationPath == "/")
                throw new InvalidOperationException(
                    "MEGA Cloud root cannot be a node destination.");

            var destinationName =
                RemoteLeaf(destinationPath);

            ValidateNodeName(destinationName);

            var source =
                GetEntry(sourcePath);

            if (source == null)
                throw new FileNotFoundException(
                    "Brimstone MEGA Cloud source node was not found.",
                    sourcePath);

            if (string.Equals(
                    sourcePath,
                    destinationPath,
                    StringComparison.Ordinal))
            {
                throw new InvalidOperationException(
                    "A MEGA Cloud node cannot be copied onto itself.");
            }

            if (destinationPath.StartsWith(
                    sourcePath + "/",
                    StringComparison.Ordinal))
            {
                throw new InvalidOperationException(
                    "A MEGA Cloud folder cannot be copied into itself.");
            }

            if (GetEntry(destinationPath) != null)
                throw new IOException(
                    "The requested MEGA Cloud destination already exists.");

            RunReadOnly(
                "cp "
                + QuoteArgument(sourcePath)
                + " "
                + QuoteArgument(destinationPath),
                DownloadTimeoutMilliseconds);

            var copied =
                GetEntry(destinationPath);

            if (copied == null)
                throw new InvalidOperationException(
                    "Brimstone MEGA Cloud copy could not be verified.");

            return copied;
        }

        public void MoveToRubbish(string sourcePath)
        {
            sourcePath =
                BrimstoneMegaCloudId.NormalizeRemotePath(sourcePath);

            DenyReservedPath(sourcePath);

            if (sourcePath == "/")
                throw new InvalidOperationException(
                    "MEGA Cloud root cannot be removed.");

            var source =
                GetEntry(sourcePath);

            if (source == null)
                throw new FileNotFoundException(
                    "Brimstone MEGA Cloud source node was not found.",
                    sourcePath);

            // Safe delete contract:
            // moving to MEGA's Rubbish Bin was acceptance-tested for both
            // files and complete folder trees, including successful restore.
            RunReadOnly(
                "mv "
                + QuoteArgument(sourcePath)
                + " //bin");

            if (GetEntry(sourcePath) != null)
                throw new InvalidOperationException(
                    "Brimstone MEGA Cloud safe delete could not be verified.");
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

        private static void ValidateNodeName(string name)
        {
            if (string.IsNullOrEmpty(name))
                throw new ArgumentException(
                    "MEGA node name is empty.",
                    "name");

            if (name.IndexOf('/') >= 0 || name.IndexOf('\0') >= 0)
                throw new ArgumentException(
                    "Invalid MEGA node name.",
                    "name");

            if (name == "." || name == "..")
                throw new ArgumentException(
                    "Invalid MEGA node name.",
                    "name");
        }

        private static string ParentRemotePath(string remotePath)
        {
            remotePath =
                BrimstoneMegaCloudId.NormalizeRemotePath(remotePath);

            var slash = remotePath.LastIndexOf('/');

            return slash <= 0
                ? "/"
                : remotePath.Substring(0, slash);
        }

        private static string RemoteLeaf(string remotePath)
        {
            remotePath =
                BrimstoneMegaCloudId.NormalizeRemotePath(remotePath);

            var slash = remotePath.LastIndexOf('/');

            return slash < 0
                ? remotePath
                : remotePath.Substring(slash + 1);
        }

        private static string CombineRemotePath(string parentPath,
                                                string name)
        {
            parentPath =
                BrimstoneMegaCloudId.NormalizeRemotePath(parentPath);

            return parentPath == "/"
                ? "/" + name
                : parentPath + "/" + name;
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
                        "Brimstone MEGA Cloud MEGAcmd command failed: "
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
