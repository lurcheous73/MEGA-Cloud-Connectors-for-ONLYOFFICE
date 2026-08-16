using System;
using System.Text;

namespace ASC.Files.Thirdparty.MegaS4
{
    internal static class MegaS4Id
    {
        // ONLYOFFICE 12.8's Teamlab MappingID() only hashes a fixed set of
        // recognised third-party prefixes (including "sbox").  Using a
        // collision-safe sbox-megas4 prefix makes MEGA S4 IDs participate in
        // the native MD5 mapping path without matching SharpBox's own
        // ^sbox-\d+ selector.
        private const string Prefix = "sbox-megas4-";

        public static string Root(int linkId)
        {
            return Prefix + linkId;
        }

        public static string Encode(int linkId, string key)
        {
            if (string.IsNullOrEmpty(key)) return Root(linkId);
            var bytes = Encoding.UTF8.GetBytes(key);
            var value = Convert.ToBase64String(bytes)
                .TrimEnd('=')
                .Replace('+', '-')
                .Replace('/', '_');
            return Root(linkId) + "-" + value;
        }

        public static bool TryParse(object value, out int linkId, out string key)
        {
            linkId = 0;
            key = string.Empty;
            if (value == null) return false;

            var text = Convert.ToString(value);
            if (string.IsNullOrEmpty(text) || !text.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase)) return false;

            var remainder = text.Substring(Prefix.Length);
            var dash = remainder.IndexOf('-');
            var idText = dash < 0 ? remainder : remainder.Substring(0, dash);
            if (!int.TryParse(idText, out linkId) || linkId <= 0) return false;
            if (dash < 0) return true;

            var encoded = remainder.Substring(dash + 1).Replace('-', '+').Replace('_', '/');
            switch (encoded.Length % 4)
            {
                case 2: encoded += "=="; break;
                case 3: encoded += "="; break;
                case 0: break;
                default: return false;
            }

            try
            {
                key = Encoding.UTF8.GetString(Convert.FromBase64String(encoded));
                return true;
            }
            catch (FormatException)
            {
                linkId = 0;
                key = string.Empty;
                return false;
            }
        }
    }
}
