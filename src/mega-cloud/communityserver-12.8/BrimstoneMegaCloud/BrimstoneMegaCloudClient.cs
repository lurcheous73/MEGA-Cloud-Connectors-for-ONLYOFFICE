using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace ASC.Files.Thirdparty.BrimstoneMegaCloud
{
    internal sealed class BrimstoneMegaCloudClient : IDisposable
    {
        // BRIMSTONE CUSTOM CODE.
        // v0.002cc is deliberately saved-session/read-only. No password, session
        // token or other secret is ever placed in a process argument.
        private const int CommandTimeoutMilliseconds = 180000;
        private const uint Mode0700 = 448;

        private static readonly ConcurrentDictionary<string, BrimstoneMegaCloudEntry> EntryCache =
            new ConcurrentDictionary<string, BrimstoneMegaCloudEntry>(StringComparer.Ordinal);

        private readonly string enginePrefix;
        private readonly string stateRoot;
        private readonly string stateSlot;
        private readonly string home;
        private readonly string socketName;

        [DllImport("libc", SetLastError = true)]
        private static extern int chmod(string pathname, uint mode);

        public BrimstoneMegaCloudClient(string stateSlot)
            : this(stateSlot,
                   Environment.GetEnvironmentVariable("BRIMSTONE_MEGA_CLOUD_ENGINE_PREFIX") ?? "/opt/brimstone/mega-cloud/megacmd",
                   Environment.GetEnvironmentVariable("BRIMSTONE_MEGA_CLOUD_STATE_ROOT") ?? "/var/lib/brimstone/mega-cloud/providers")
        {
        }

        internal BrimstoneMegaCloudClient(string stateSlot, string enginePrefix, string stateRoot)
        {
            if (string.IsNullOrEmpty(stateSlot)) throw new ArgumentNullException("stateSlot");
            if (string.IsNullOrEmpty(enginePrefix)) throw new ArgumentNullException("enginePrefix");
            if (string.IsNullOrEmpty(stateRoot)) throw new ArgumentNullException("stateRoot");

            foreach (var c in stateSlot)
            {
                if (!(char.IsLetterOrDigit(c) || c == '_' || c == '-'))
                    throw new ArgumentException("Invalid Brimstone MEGA Cloud state slot.", "stateSlot");
            }

            if (stateSlot.Length > 64) throw new ArgumentException("Brimstone MEGA Cloud state slot is too long.", "stateSlot");

            this.stateSlot = stateSlot;
            this.enginePrefix = enginePrefix;
            this.stateRoot = stateRoot;
            home = Path.Combine(Path.Combine(stateRoot, stateSlot), "home");
            socketName = "brimstone-megacc-" + stateSlot + ".socket";

            EnsureSecureStateDirectory();
        }

        public bool HasSavedSession
        {
            get { return File.Exists(Path.Combine(Path.Combine(home, ".megaCmd"), "session")); }
        }

        public List<BrimstoneMegaCloudEntry> ListChildren(string parentHandle)
        {
            parentHandle = parentHandle ?? string.Empty;
            ValidateHandle(parentHandle);

            var remote = string.IsNullOrEmpty(parentHandle) ? "/" : "H:" + parentHandle;
            var stdout = RunReadOnly("ls -l --show-handles --time-format=ISO6081_WITH_TIME " + remote);
            var entries = BrimstoneMegaCloudLsParser.Parse(stdout, parentHandle);

            foreach (var entry in entries)
                EntryCache[CacheKey(entry.Handle)] = entry;

            return entries;
        }

        public BrimstoneMegaCloudEntry GetCachedEntry(string handle)
        {
            if (string.IsNullOrEmpty(handle)) return null;
            ValidateHandle(handle);

            BrimstoneMegaCloudEntry entry;
            return EntryCache.TryGetValue(CacheKey(handle), out entry) ? entry : null;
        }

        public void Dispose()
        {
        }

        private string CacheKey(string handle)
        {
            return stateSlot + "\n" + handle;
        }

        private void EnsureSecureStateDirectory()
        {
            var slotRoot = Path.Combine(stateRoot, stateSlot);
            Directory.CreateDirectory(slotRoot);
            Directory.CreateDirectory(home);

            // Target runtime is Linux. Failure to tighten either directory is a
            // security failure because MEGAcmd's saved session lives below HOME.
            if (chmod(slotRoot, Mode0700) != 0)
                throw new InvalidOperationException("Unable to secure Brimstone MEGA Cloud provider state directory.");
            if (chmod(home, Mode0700) != 0)
                throw new InvalidOperationException("Unable to secure Brimstone MEGA Cloud HOME directory.");
        }

        private string RunReadOnly(string arguments)
        {
            if (!HasSavedSession)
                throw new InvalidOperationException("Brimstone MEGA Cloud provider has no saved MEGA session.");

            var executable = Path.Combine(Path.Combine(Path.Combine(enginePrefix, "usr"), "bin"), "mega-exec");
            if (!File.Exists(executable))
                throw new FileNotFoundException("Brimstone MEGA Cloud MEGAcmd engine is not installed.", executable);

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

            var libraryPath = Path.Combine(Path.Combine(Path.Combine(enginePrefix, "opt"), "megacmd"), "lib");
            var oldLibraryPath = psi.EnvironmentVariables["LD_LIBRARY_PATH"];
            psi.EnvironmentVariables["LD_LIBRARY_PATH"] = string.IsNullOrEmpty(oldLibraryPath)
                ? libraryPath
                : libraryPath + ":" + oldLibraryPath;

            using (var process = Process.Start(psi))
            {
                if (process == null) throw new InvalidOperationException("Unable to start Brimstone MEGA Cloud MEGAcmd client.");

                var stdoutTask = Task.Factory.StartNew(delegate { return process.StandardOutput.ReadToEnd(); });
                var stderrTask = Task.Factory.StartNew(delegate { return process.StandardError.ReadToEnd(); });

                if (!process.WaitForExit(CommandTimeoutMilliseconds))
                {
                    try { process.Kill(); }
                    catch { }
                    throw new TimeoutException("Brimstone MEGA Cloud MEGAcmd command timed out.");
                }

                Task.WaitAll(stdoutTask, stderrTask);
                if (process.ExitCode != 0)
                {
                    var error = stderrTask.Result;
                    if (error != null && error.Length > 2048) error = error.Substring(0, 2048);
                    throw new InvalidOperationException("Brimstone MEGA Cloud MEGAcmd browse failed: " + error);
                }

                return stdoutTask.Result;
            }
        }

        private static void ValidateHandle(string handle)
        {
            if (string.IsNullOrEmpty(handle)) return;
            foreach (var c in handle)
            {
                if (!(char.IsLetterOrDigit(c) || c == '_' || c == '-'))
                    throw new ArgumentException("Invalid MEGA node handle.", "handle");
            }
        }
    }
}
