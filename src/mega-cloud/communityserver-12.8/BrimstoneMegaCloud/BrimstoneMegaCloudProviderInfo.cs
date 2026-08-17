using System;

using ASC.Files.Core;

namespace ASC.Files.Thirdparty.BrimstoneMegaCloud
{
    public sealed class BrimstoneMegaCloudProviderInfo : IProviderInfo, IDisposable
    {
        // BRIMSTONE CUSTOM CODE.
        // stateSlot is a non-secret locator for the protected MEGAcmd HOME. The
        // MEGA account password is never retained by this provider.
        private readonly string stateSlot;
        private readonly FolderType rootFolderType;
        private readonly DateTime createOn;
        private BrimstoneMegaCloudClient client;

        public int ID { get; set; }
        public Guid Owner { get; private set; }
        public string CustomerTitle { get; private set; }
        public DateTime CreateOn { get { return createOn; } }
        public object RootFolderId { get { return BrimstoneMegaCloudId.Root(ID); } }
        public string ProviderKey { get; private set; }
        public FolderType RootFolderType { get { return rootFolderType; } }

        internal string StateSlot { get { return stateSlot; } }

        internal BrimstoneMegaCloudClient Client
        {
            get
            {
                if (client == null) client = new BrimstoneMegaCloudClient(stateSlot);
                return client;
            }
        }

        public BrimstoneMegaCloudProviderInfo(int id,
                                              string providerKey,
                                              string customerTitle,
                                              string stateSlot,
                                              Guid owner,
                                              FolderType rootFolderType,
                                              DateTime createOn)
        {
            if (string.IsNullOrEmpty(providerKey)) throw new ArgumentNullException("providerKey");
            if (string.IsNullOrEmpty(stateSlot)) throw new ArgumentNullException("stateSlot");

            ID = id;
            ProviderKey = providerKey;
            CustomerTitle = customerTitle;
            Owner = owner;
            this.stateSlot = stateSlot;
            this.rootFolderType = rootFolderType;
            this.createOn = createOn;
        }

        public bool CheckAccess()
        {
            try
            {
                if (!Client.HasSavedSession) return false;
                Client.ListChildren(string.Empty);
                return true;
            }
            catch
            {
                return false;
            }
        }

        internal void UpdateTitle(string title)
        {
            CustomerTitle = title;
        }

        public void Dispose()
        {
            if (client != null)
            {
                client.Dispose();
                client = null;
            }
        }
    }
}
