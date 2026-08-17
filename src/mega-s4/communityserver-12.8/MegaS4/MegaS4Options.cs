using System;

namespace ASC.Files.Thirdparty.MegaS4
{
    internal sealed class MegaS4Options
    {
        public string AccessKey { get; private set; }
        public string SecretKey { get; private set; }
        public string Bucket { get; private set; }
        public string Region { get; private set; }
        public string ServiceUrl { get; private set; }
        public bool ForcePathStyle { get; private set; }
        public bool UseHttp { get; private set; }

        public MegaS4Options(string accessKey, string secretKey, string bucket, string region, string serviceUrl, bool forcePathStyle, bool useHttp)
        {
            if (string.IsNullOrWhiteSpace(accessKey)) throw new ArgumentNullException("accessKey");
            if (string.IsNullOrWhiteSpace(secretKey)) throw new ArgumentNullException("secretKey");
            if (string.IsNullOrWhiteSpace(bucket)) throw new ArgumentNullException("bucket");

            AccessKey = accessKey.Trim();
            SecretKey = secretKey;
            Bucket = bucket.Trim();
            Region = string.IsNullOrWhiteSpace(region) ? "g" : region.Trim();
            ServiceUrl = string.IsNullOrWhiteSpace(serviceUrl) ? "https://s3.g.megas4.com" : serviceUrl.Trim().TrimEnd('/');
            ForcePathStyle = forcePathStyle;
            UseHttp = useHttp;
        }

        public static MegaS4Options MegaDefaults(string accessKey, string secretKey, string bucket)
        {
            return new MegaS4Options(accessKey, secretKey, bucket, "g", "https://s3.g.megas4.com", true, false);
        }
    }
}
