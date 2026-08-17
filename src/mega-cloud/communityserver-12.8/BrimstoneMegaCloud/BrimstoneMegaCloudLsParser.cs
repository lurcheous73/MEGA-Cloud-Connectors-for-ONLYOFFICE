using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;

namespace ASC.Files.Thirdparty.BrimstoneMegaCloud
{
    internal static class BrimstoneMegaCloudLsParser
    {
        // BRIMSTONE CUSTOM CODE.
        // Pinned MEGAcmd 2.5.2 contract:
        // FLAGS VERS SIZE DATE HANDLE NAME
        // d---  -    -    2026-... H:XXXXXXXX Folder name with spaces
        private static readonly Regex Row = new Regex(
            @"^(?<flags>\S+)\s+(?<versions>\S+)\s+(?<size>\S+)\s+(?<date>\S+)\s+H:(?<handle>[A-Za-z0-9_-]+)\s(?<name>.*)$",
            RegexOptions.Compiled | RegexOptions.CultureInvariant);

        public static List<BrimstoneMegaCloudEntry> Parse(string output, string parentHandle)
        {
            var result = new List<BrimstoneMegaCloudEntry>();
            if (string.IsNullOrEmpty(output)) return result;

            var lines = output.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
            foreach (var raw in lines)
            {
                if (string.IsNullOrWhiteSpace(raw)) continue;
                var line = raw.TrimEnd();
                if (line.StartsWith("FLAGS ", StringComparison.Ordinal)) continue;

                var match = Row.Match(line);
                if (!match.Success) continue;

                var flags = match.Groups["flags"].Value;
                if (string.IsNullOrEmpty(flags) || (flags[0] != 'd' && flags[0] != '-')) continue;

                int versions = 0;
                var versionsText = match.Groups["versions"].Value;
                if (versionsText != "-" && !int.TryParse(versionsText, NumberStyles.None, CultureInfo.InvariantCulture, out versions))
                    throw new FormatException("Invalid MEGAcmd version count: " + versionsText);

                long size = 0;
                var sizeText = match.Groups["size"].Value;
                if (sizeText != "-" && !long.TryParse(sizeText, NumberStyles.None, CultureInfo.InvariantCulture, out size))
                    throw new FormatException("Invalid MEGAcmd size: " + sizeText);

                DateTime modifiedUtc;
                var dateText = match.Groups["date"].Value;
                if (!DateTime.TryParseExact(dateText,
                                            "yyyy-MM-dd'T'HH:mm:ss",
                                            CultureInfo.InvariantCulture,
                                            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                                            out modifiedUtc))
                    throw new FormatException("Invalid MEGAcmd ISO timestamp: " + dateText);

                result.Add(new BrimstoneMegaCloudEntry
                {
                    Handle = match.Groups["handle"].Value,
                    Name = match.Groups["name"].Value,
                    Flags = flags,
                    VersionCount = versions,
                    Size = size,
                    ModifiedUtc = modifiedUtc
                });
            }

            return result;
        }
    }
}
