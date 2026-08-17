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
        private const uint Mode0700 = 448;

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
                BrimstoneMegaCloudLsParser.Parse(stdout, string.Empty);

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

        public void Dispose()
        {
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

                if (!process.WaitForExit(CommandTimeoutMilliseconds))
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
