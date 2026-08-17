using System;
using System.Web;

using ASC.Common.Web;
using ASC.Files.Core;

namespace ASC.Files.Thirdparty.MegaS4
{
    public sealed class MegaS4ProviderInfo : IProviderInfo, IDisposable
    {
        private readonly string accessKey;
        private readonly string secretKey;
        private readonly string serviceUrl;
        private readonly MegaS4Auth auth;
        private readonly FolderType rootFolderType;
        private readonly DateTime createOn;

        public int ID { get; set; }
        public Guid Owner { get; private set; }
        public string CustomerTitle { get; private set; }
        public DateTime CreateOn { get { return createOn; } }
        public object RootFolderId { get { return MegaS4Id.Root(ID); } }
        public string ProviderKey { get; private set; }
        public FolderType RootFolderType { get { return rootFolderType; } }

        internal MegaS4Storage Storage
        {
            get
            {
                if (HttpContext.Current != null)
                {
                    var key = "__MEGAS4_STORAGE_" + ID;
                    var wrapper = (StorageDisposableWrapper)DisposableHttpContext.Current[key];
                    if (wrapper == null || wrapper.Storage == null)
                    {
                        wrapper = new StorageDisposableWrapper(CreateStorage());
                        DisposableHttpContext.Current[key] = wrapper;
                    }
                    return wrapper.Storage;
                }
                return CreateStorage();
            }
        }

        internal string Bucket { get { return auth.Bucket; } }

        public MegaS4ProviderInfo(int id, string providerKey, string customerTitle, string accessKey, string secretKey,
                                  string serviceUrl, string token, Guid owner, FolderType rootFolderType, DateTime createOn)
        {
            if (string.IsNullOrEmpty(providerKey)) throw new ArgumentNullException("providerKey");
            if (string.IsNullOrEmpty(accessKey)) throw new ArgumentNullException("accessKey");
            if (string.IsNullOrEmpty(secretKey)) throw new ArgumentNullException("secretKey");

            ID = id;
            ProviderKey = providerKey;
            CustomerTitle = customerTitle;
            Owner = owner;
            this.accessKey = accessKey;
            this.secretKey = secretKey;
            this.serviceUrl = serviceUrl;
            auth = MegaS4Auth.Parse(token);
            this.rootFolderType = rootFolderType;
            this.createOn = createOn;
        }

        public bool CheckAccess()
        {
            try
            {
                using (var storage = CreateStorage())
                {
                    // The connected drive needs list permission anyway; listing
                    // one page is a better capability test than account-wide APIs.
                    storage.GetItems(string.Empty);
                    return true;
                }
            }
            catch
            {
                return false;
            }
        }

        public void InvalidateStorage()
        {
            if (HttpContext.Current == null) return;
            var key = "__MEGAS4_STORAGE_" + ID;
            var wrapper = (StorageDisposableWrapper)DisposableHttpContext.Current[key];
            if (wrapper != null)
            {
                // BRIMSTONE: DisposableHttpContext rejects null assignments.
                // Match ONLYOFFICE's stock providers: dispose the per-request
                // wrapper and let Storage recreate it if accessed again.
                wrapper.Dispose();
            }
        }

        internal void UpdateTitle(string title)
        {
            CustomerTitle = title;
        }

        private MegaS4Storage CreateStorage()
        {
            return new MegaS4Storage(new MegaS4Options(
                accessKey,
                secretKey,
                auth.Bucket,
                auth.Region,
                serviceUrl,
                auth.ForcePathStyle,
                auth.UseHttp));
        }

        public void Dispose()
        {
            InvalidateStorage();
        }

        private sealed class StorageDisposableWrapper : IDisposable
        {
            public MegaS4Storage Storage { get; private set; }

            public StorageDisposableWrapper(MegaS4Storage storage)
            {
                Storage = storage;
            }

            public void Dispose()
            {
                if (Storage != null)
                {
                    Storage.Dispose();
                    Storage = null;
                }
            }
        }
    }
}
