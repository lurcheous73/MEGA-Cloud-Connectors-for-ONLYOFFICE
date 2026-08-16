// BRIMSTONE CUSTOM CODE: shared-secret bridge for MEGA S4.
using System;

using ASC.Core;
using ASC.Core.Common.Configuration;
using ASC.Files.Core;

namespace ASC.Files.Thirdparty.MegaS4
{
    public static class BrimstoneMegaS4Secrets
    {
        public const string Marker = "BRIMSTONE";
        public const string SharedCredentialSentinel = "BRIMSTONE:S3COMPATIBLE:IMPORT";
        public const string SharedConsumerName = "S3Compatible";

        public static bool IsSharedCredentialRequest(AuthData authData)
        {
            if (authData == null) return false;

            var loginMatch = string.Equals(authData.Login, SharedCredentialSentinel, StringComparison.Ordinal);
            var passwordMatch = string.Equals(authData.Password, SharedCredentialSentinel, StringComparison.Ordinal);

            if (loginMatch != passwordMatch)
                throw new ArgumentException("Invalid BRIMSTONE shared-credential sentinel state.");

            return loginMatch && passwordMatch;
        }

        public static AuthData ResolveForProviderSave(AuthData authData)
        {
            if (!IsSharedCredentialRequest(authData)) return authData;

            // The shared S3-Compatible credentials are portal-level administrator
            // settings. Importing them into a personal connected drive therefore
            // requires the same portal-settings permission used to manage them.
            SecurityContext.DemandPermissions(SecutiryConstants.EditPortalSettings);

            string accessKey;
            string secretKey;
            LoadSharedS3CompatibleCredentials(out accessKey, out secretKey);

            // Snapshot semantics: return real credentials to ProviderAccountDao.
            // ProviderAccountDao then validates them and stores its own encrypted
            // copy in files_thirdparty_account. The account is not permanently
            // linked to the shared backup credential set.
            return new AuthData(authData.Url, accessKey, secretKey, authData.Token);
        }

        public static void LoadSharedS3CompatibleCredentials(out string accessKey, out string secretKey)
        {
            var consumer = ConsumerFactory.GetByName(SharedConsumerName);
            if (consumer == null || string.IsNullOrEmpty(consumer.Name))
                throw new InvalidOperationException("S3Compatible AuthorizationKeys consumer is not available.");

            // "acesskey" is the spelling used by ONLYOFFICE's S3 consumer contract.
            accessKey = consumer["acesskey"];
            secretKey = consumer["secretaccesskey"];

            if (string.IsNullOrWhiteSpace(accessKey) || string.IsNullOrEmpty(secretKey))
                throw new InvalidOperationException("S3Compatible shared credentials are not configured.");

            accessKey = accessKey.Trim();
        }
    }
}
