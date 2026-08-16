// BRIMSTONE CUSTOM CODE: authenticated MEGA S4 helper endpoint.
using System;
using System.Collections.Generic;
using System.Linq;
using System.Web;

using Amazon.S3;

using ASC.Core;
using ASC.Web.Studio.Core;

namespace ASC.Files.Thirdparty.MegaS4
{
    public sealed class BrimstoneMegaS4Handler : IHttpHandler
    {
        private const string DefaultEndpoint = "https://s3.g.megas4.com";
        private const string DefaultRegion = "g";

        public bool IsReusable { get { return false; } }

        public void ProcessRequest(HttpContext context)
        {
            if (context == null) throw new ArgumentNullException("context");

            context.Response.ContentType = "application/json";
            context.Response.Cache.SetCacheability(HttpCacheability.NoCache);
            context.Response.Cache.SetNoStore();

            if (!SecurityContext.IsAuthenticated)
            {
                WriteError(context, 401, "Authentication required.");
                return;
            }

            if (!string.Equals(context.Request.HttpMethod, "POST", StringComparison.OrdinalIgnoreCase))
            {
                WriteError(context, 405, "POST required.");
                return;
            }

            try
            {
                var action = (context.Request.Form["action"] ?? string.Empty).Trim();
                if (!string.Equals(action, "list-buckets", StringComparison.Ordinal))
                    throw new ArgumentException("Unsupported BRIMSTONE MEGA S4 action.");

                var endpoint = NormalizeEndpoint(context.Request.Form["endpoint"]);
                var region = (context.Request.Form["region"] ?? DefaultRegion).Trim();
                if (region.Length == 0) region = DefaultRegion;

                string accessKey;
                string secretKey;

                var source = (context.Request.Form["source"] ?? "manual").Trim();
                if (string.Equals(source, "shared", StringComparison.Ordinal))
                {
                    SecurityContext.DemandPermissions(SecutiryConstants.EditPortalSettings);
                    BrimstoneMegaS4Secrets.LoadSharedS3CompatibleCredentials(out accessKey, out secretKey);
                }
                else if (string.Equals(source, "manual", StringComparison.Ordinal))
                {
                    accessKey = (context.Request.Form["accessKey"] ?? string.Empty).Trim();
                    secretKey = context.Request.Form["secretKey"] ?? string.Empty;
                    if (accessKey.Length == 0 || secretKey.Length == 0)
                        throw new ArgumentException("Access key and secret key are required.");
                }
                else
                {
                    throw new ArgumentException("Unknown credential source.");
                }

                var buckets = ListBuckets(accessKey, secretKey, endpoint, region);
                WriteBuckets(context, buckets);
            }
            catch (AmazonS3Exception ex)
            {
                var code = string.IsNullOrEmpty(ex.ErrorCode) ? "S3Error" : ex.ErrorCode;
                WriteError(context, 400, "MEGA S4 bucket listing failed: " + code + ".");
            }
            catch (Exception ex)
            {
                WriteError(context, 400, ex.Message);
            }
        }

        private static List<string> ListBuckets(string accessKey, string secretKey, string endpoint, string region)
        {
            var config = new AmazonS3Config
            {
                MaxErrorRetry = 2,
                ServiceURL = endpoint,
                AuthenticationRegion = region,
                ForcePathStyle = true,
                UseHttp = false
            };

            using (var client = new AmazonS3Client(accessKey, secretKey, config))
            {
                var response = client.ListBuckets();
                if (response.Buckets == null) return new List<string>();

                return response.Buckets
                    .Select(bucket => bucket.BucketName)
                    .Where(name => !string.IsNullOrWhiteSpace(name))
                    .Distinct(StringComparer.Ordinal)
                    .OrderBy(name => name, StringComparer.Ordinal)
                    .ToList();
            }
        }

        private static string NormalizeEndpoint(string value)
        {
            var endpoint = string.IsNullOrWhiteSpace(value) ? DefaultEndpoint : value.Trim().TrimEnd('/');

            // First release is deliberately MEGA-S4-only. Do not turn a privileged
            // server-side credential helper into an arbitrary URL/SSRF primitive.
            if (!string.Equals(endpoint, DefaultEndpoint, StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("Only the MEGA S4 g endpoint is permitted by this BRIMSTONE handler.");

            return DefaultEndpoint;
        }

        private static void WriteBuckets(HttpContext context, IEnumerable<string> buckets)
        {
            var values = buckets.Select(JsonString);
            context.Response.StatusCode = 200;
            context.Response.Write("{\"ok\":true,\"buckets\":[" + string.Join(",", values) + "]}");
        }

        private static void WriteError(HttpContext context, int status, string message)
        {
            context.Response.StatusCode = status;
            context.Response.TrySkipIisCustomErrors = true;
            context.Response.Write("{\"ok\":false,\"error\":" + JsonString(message) + "}");
        }

        private static string JsonString(string value)
        {
            return "\"" + HttpUtility.JavaScriptStringEncode(value ?? string.Empty) + "\"";
        }
    }
}
