using System;
using System.Collections.Generic;
using System.Linq;

using ASC.Core.Tenants;
using ASC.Files.Core;
using ASC.Files.Core.Security;
using ASC.Web.Files.Classes;

using File = ASC.Files.Core.File;

namespace ASC.Files.Thirdparty.BrimstoneMegaCloud
{
    internal abstract class BrimstoneMegaCloudDaoBase : IDisposable
    {
        protected BrimstoneMegaCloudProviderInfo ProviderInfo { get; private set; }
        protected BrimstoneMegaCloudDaoSelector Selector { get; private set; }

        protected BrimstoneMegaCloudDaoBase(BrimstoneMegaCloudDaoSelector.BrimstoneMegaCloudInfo info,
                                            BrimstoneMegaCloudDaoSelector selector)
        {
            if (info == null) throw new ArgumentNullException("info");
            ProviderInfo = info.ProviderInfo;
            Selector = selector;
        }

        public void Dispose()
        {
            ProviderInfo.Dispose();
        }

        protected string DecodeId(object id)
        {
            if (id == null) throw new ArgumentNullException("id");

            var text = Convert.ToString(id);
            int providerId;
            string handle;
            if (BrimstoneMegaCloudId.TryParse(text, out providerId, out handle))
            {
                if (providerId != ProviderInfo.ID)
                    throw new ArgumentException("Brimstone MEGA Cloud id belongs to another provider account.", "id");
                return handle;
            }

            // ProviderFolderDao/ProviderFileDao normally pass selector.ConvertId
            // into the provider-specific DAO, so a raw handle is valid here too.
            return text ?? string.Empty;
        }

        protected string MakeId(string remotePath)
        {
            return BrimstoneMegaCloudId.Encode(ProviderInfo.ID, remotePath);
        }

        protected string MakeId(BrimstoneMegaCloudEntry entry)
        {
            return entry == null ? null : MakeId(entry.RemotePath);
        }

        protected List<BrimstoneMegaCloudEntry> GetCloudItems(object parentId)
        {
            return ProviderInfo.Client.ListChildren(DecodeId(parentId));
        }

        protected BrimstoneMegaCloudEntry GetCloudEntry(object id)
        {
            var remotePath = DecodeId(id);

            if (BrimstoneMegaCloudId.NormalizeRemotePath(remotePath) == "/")
                return null;

            var entry = ProviderInfo.Client.GetEntry(remotePath);

            if (entry == null)
                throw new InvalidOperationException(
                    "Brimstone MEGA Cloud node was not found in its live parent listing.");

            return entry;
        }

        protected Folder ToRootFolder()
        {
            return new Folder
            {
                ID = MakeId(string.Empty),
                ParentFolderID = ProviderInfo.RootFolderType == FolderType.COMMON ? Global.FolderCommon : Global.FolderMy,
                CreateBy = ProviderInfo.Owner,
                CreateOn = ProviderInfo.CreateOn,
                FolderType = FolderType.DEFAULT,
                ModifiedBy = ProviderInfo.Owner,
                ModifiedOn = ProviderInfo.CreateOn,
                ProviderId = ProviderInfo.ID,
                ProviderKey = ProviderInfo.ProviderKey,
                RootFolderCreator = ProviderInfo.Owner,
                RootFolderId = MakeId(string.Empty),
                RootFolderType = ProviderInfo.RootFolderType,
                Shareable = false,
                Title = ProviderInfo.CustomerTitle,
                TotalFiles = 0,
                TotalSubFolders = 0
            };
        }

        protected Folder ToFolder(BrimstoneMegaCloudEntry entry)
        {
            if (entry == null || !entry.IsFolder) return null;
            var modified = TenantUtil.DateTimeFromUtc(entry.ModifiedUtc);

            return new Folder
            {
                ID = MakeId(entry.Handle),
                ParentFolderID = MakeId(entry.ParentPath),
                CreateBy = ProviderInfo.Owner,
                CreateOn = modified,
                FolderType = FolderType.DEFAULT,
                ModifiedBy = ProviderInfo.Owner,
                ModifiedOn = modified,
                ProviderId = ProviderInfo.ID,
                ProviderKey = ProviderInfo.ProviderKey,
                RootFolderCreator = ProviderInfo.Owner,
                RootFolderId = MakeId(string.Empty),
                RootFolderType = ProviderInfo.RootFolderType,
                Shareable = false,
                Title = Global.ReplaceInvalidCharsAndTruncate(entry.Name),
                TotalFiles = 0,
                TotalSubFolders = 0
            };
        }

        protected File ToFile(BrimstoneMegaCloudEntry entry)
        {
            if (entry == null || !entry.IsFile) return null;
            var modified = TenantUtil.DateTimeFromUtc(entry.ModifiedUtc);

            return new File
            {
                ID = MakeId(entry.Handle),
                Access = FileShare.None,
                ContentLength = entry.Size,
                CreateBy = ProviderInfo.Owner,
                CreateOn = modified,
                FileStatus = FileStatus.None,
                FolderID = MakeId(entry.ParentPath),
                ModifiedBy = ProviderInfo.Owner,
                ModifiedOn = modified,
                NativeAccessor = entry,
                ProviderId = ProviderInfo.ID,
                ProviderKey = ProviderInfo.ProviderKey,
                Title = Global.ReplaceInvalidCharsAndTruncate(entry.Name),
                RootFolderId = MakeId(string.Empty),
                RootFolderType = ProviderInfo.RootFolderType,
                RootFolderCreator = ProviderInfo.Owner,
                Shared = false,
                Version = entry.VersionCount > 0 ? entry.VersionCount : 1
            };
        }

        protected static IEnumerable<BrimstoneMegaCloudEntry> Folders(IEnumerable<BrimstoneMegaCloudEntry> entries)
        {
            return entries.Where(x => x.IsFolder);
        }

        protected static IEnumerable<BrimstoneMegaCloudEntry> Files(IEnumerable<BrimstoneMegaCloudEntry> entries)
        {
            return entries.Where(x => x.IsFile);
        }

        protected static NotSupportedException ReadOnly()
        {
            return new NotSupportedException("Brimstone MEGA Cloud v0.003cc is read-only.");
        }
    }
}
