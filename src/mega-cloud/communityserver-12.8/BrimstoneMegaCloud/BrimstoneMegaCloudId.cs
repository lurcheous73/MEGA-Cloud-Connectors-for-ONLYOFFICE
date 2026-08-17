using System;
using System.Globalization;
using System.Text.RegularExpressions;

namespace ASC.Files.Thirdparty.BrimstoneMegaCloud
{
    internal static class BrimstoneMegaCloudId
    {
        // BRIMSTONE CUSTOM MARKER.
        // Keep Cloud IDs separate from the existing MEGA S4 sboxmega-* family.
        // The sbox prefix deliberately retains ONLYOFFICE's native MappingID path.
        private const string Prefix = "sboxbrimstonemegacc-";
        private static readonly Regex HandleRegex = new Regex(@"^[A-Za-z0-9_-]+$", RegexOptions.Compiled);

        public static string Root(int providerId)
        {
            if (providerId <= 0) throw new ArgumentOutOfRangeException("providerId");
            return Prefix + providerId.ToString(CultureInfo.InvariantCulture);
        }

        public static string Encode(int providerId, string handle)
        {
            var root = Root(providerId);
            if (string.IsNullOrEmpty(handle)) return root;
            if (!HandleRegex.IsMatch(handle)) throw new ArgumentException("Invalid MEGA node handle.", "handle");
            return root + "-" + handle;
        }

        public static bool TryParse(object value, out int providerId, out string handle)
        {
            providerId = 0;
            handle = string.Empty;
            if (value == null) return false;

            var text = Convert.ToString(value, CultureInfo.InvariantCulture);
            if (string.IsNullOrEmpty(text) || !text.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase)) return false;

            var remainder = text.Substring(Prefix.Length);
            var dash = remainder.IndexOf('-');
            var idText = dash < 0 ? remainder : remainder.Substring(0, dash);
            if (!int.TryParse(idText, NumberStyles.None, CultureInfo.InvariantCulture, out providerId) || providerId <= 0)
            {
                providerId = 0;
                return false;
            }

            if (dash < 0) return true;

            handle = remainder.Substring(dash + 1);
            if (string.IsNullOrEmpty(handle) || !HandleRegex.IsMatch(handle))
            {
                providerId = 0;
                handle = string.Empty;
                return false;
            }

            return true;
        }
    }
}
