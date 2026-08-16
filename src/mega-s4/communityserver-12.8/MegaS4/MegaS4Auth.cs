using System;
using System.Text;

namespace ASC.Files.Thirdparty.MegaS4
{
    internal sealed class MegaS4Auth
    {
        public string Bucket { get; private set; }
        public string Region { get; private set; }
        public bool ForcePathStyle { get; private set; }
        public bool UseHttp { get; private set; }

        public MegaS4Auth(string bucket, string region, bool forcePathStyle, bool useHttp)
        {
            if (string.IsNullOrWhiteSpace(bucket)) throw new ArgumentNullException("bucket");
            Bucket = bucket.Trim();
            Region = string.IsNullOrWhiteSpace(region) ? "g" : region.Trim();
            ForcePathStyle = forcePathStyle;
            UseHttp = useHttp;
        }

        public string Serialize()
        {
            var raw = string.Join("\n", new[]
            {
                "1",
                Bucket,
                Region,
                ForcePathStyle ? "1" : "0",
                UseHttp ? "1" : "0"
            });
            return Convert.ToBase64String(Encoding.UTF8.GetBytes(raw));
        }

        public static MegaS4Auth Parse(string token)
        {
            if (string.IsNullOrWhiteSpace(token)) throw new ArgumentException("MEGA S4 connection token is empty.", "token");
            string raw;
            try
            {
                raw = Encoding.UTF8.GetString(Convert.FromBase64String(token));
            }
            catch (FormatException ex)
            {
                throw new ArgumentException("MEGA S4 connection token is invalid.", "token", ex);
            }

            var parts = raw.Split(new[] { '\n' }, StringSplitOptions.None);
            if (parts.Length != 5 || parts[0] != "1") throw new ArgumentException("Unsupported MEGA S4 connection token version.", "token");
            return new MegaS4Auth(parts[1], parts[2], parts[3] == "1", parts[4] == "1");
        }
    }
}
