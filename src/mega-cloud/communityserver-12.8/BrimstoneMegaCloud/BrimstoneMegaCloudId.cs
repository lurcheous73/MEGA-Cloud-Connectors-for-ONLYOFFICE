using System;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace ASC.Files.Thirdparty.BrimstoneMegaCloud
{
    internal static class BrimstoneMegaCloudId
    {
        private const string Prefix = "sboxbrimstonemegacc-";

        private static readonly Regex PayloadRegex =
            new Regex(@"^[A-Za-z0-9_-]+$", RegexOptions.Compiled);

        public static string Root(int providerId)
        {
            if (providerId <= 0) throw new ArgumentOutOfRangeException("providerId");
            return Prefix + providerId.ToString(CultureInfo.InvariantCulture);
        }

        public static string Encode(int providerId, string remotePath)
        {
            var root = Root(providerId);
            remotePath = NormalizeRemotePath(remotePath);

            if (remotePath == "/")
                return root;

            var bytes = Encoding.UTF8.GetBytes(remotePath);
            var payload = Convert.ToBase64String(bytes)
                .TrimEnd('=')
                .Replace('+', '-')
                .Replace('/', '_');

            return root + "-" + payload;
        }

        public static bool TryParse(object value, out int providerId, out string remotePath)
        {
            providerId = 0;
            remotePath = "/";

            if (value == null)
                return false;

            var text = Convert.ToString(value, CultureInfo.InvariantCulture);

            if (string.IsNullOrEmpty(text) ||
                !text.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase))
                return false;

            var remainder = text.Substring(Prefix.Length);
            var dash = remainder.IndexOf('-');

            var idText = dash < 0
                ? remainder
                : remainder.Substring(0, dash);

            if (!int.TryParse(idText,
                              NumberStyles.None,
                              CultureInfo.InvariantCulture,
                              out providerId) ||
                providerId <= 0)
            {
                providerId = 0;
                return false;
            }

            if (dash < 0)
            {
                remotePath = "/";
                return true;
            }

            var payload = remainder.Substring(dash + 1);

            if (string.IsNullOrEmpty(payload) ||
                !PayloadRegex.IsMatch(payload))
            {
                providerId = 0;
                return false;
            }

            try
            {
                var base64 = payload.Replace('-', '+').Replace('_', '/');

                switch (base64.Length % 4)
                {
                    case 2: base64 += "=="; break;
                    case 3: base64 += "="; break;
                    case 1:
                        providerId = 0;
                        return false;
                }

                remotePath = NormalizeRemotePath(
                    Encoding.UTF8.GetString(Convert.FromBase64String(base64)));

                return true;
            }
            catch
            {
                providerId = 0;
                remotePath = "/";
                return false;
            }
        }

        public static string NormalizeRemotePath(string value)
        {
            if (string.IsNullOrEmpty(value))
                return "/";

            var result = value.Replace('\\', '/');

            if (!result.StartsWith("/", StringComparison.Ordinal))
                result = "/" + result;

            while (result.Length > 1 &&
                   result.EndsWith("/", StringComparison.Ordinal))
                result = result.Substring(0, result.Length - 1);

            return result;
        }

        public static string ParentPath(string value)
        {
            var path = NormalizeRemotePath(value);

            if (path == "/")
                return "/";

            var slash = path.LastIndexOf('/');

            return slash <= 0
                ? "/"
                : path.Substring(0, slash);
        }

        public static string Name(string value)
        {
            var path = NormalizeRemotePath(value);

            if (path == "/")
                return string.Empty;

            var slash = path.LastIndexOf('/');
            return path.Substring(slash + 1);
        }

        public static string Combine(string parent, string name)
        {
            parent = NormalizeRemotePath(parent);

            if (string.IsNullOrEmpty(name))
                return parent;

            return parent == "/"
                ? "/" + name
                : parent + "/" + name;
        }
    }
}
