using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

using ASC.Core.Tenants;
using ASC.Files.Core;
using ASC.Files.Core.Security;
using ASC.Web.Files.Classes;

namespace ASC.Files.Thirdparty.MegaS4
{
    internal abstract class MegaS4DaoBase : IDisposable
    {
        protected MegaS4ProviderInfo ProviderInfo { get; private set; }
        protected MegaS4DaoSelector Selector { get; private set; }

        protected MegaS4DaoBase(MegaS4DaoSelector.MegaS4Info info, MegaS4DaoSelector selector)
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
            return Convert.ToString(Selector.ConvertId(id));
        }

        protected string MakeId(string key)
        {
            return MegaS4Id.Encode(ProviderInfo.ID, key);
        }

        protected string MakeId(MegaS4Entry entry)
        {
            return entry == null ? null : MakeId(entry.Key);
        }

        protected MegaS4FolderEntry GetS4Folder(object id)
        {
            return ProviderInfo.Storage.GetFolder(DecodeId(id));
        }

        protected MegaS4FileEntry GetS4File(object id)
        {
            return ProviderInfo.Storage.GetFile(DecodeId(id));
        }

        protected List<MegaS4Entry> GetS4Items(object parentId)
        {
            return ProviderInfo.Storage.GetItems(DecodeId(parentId));
        }

        protected Folder ToFolder(MegaS4FolderEntry entry)
        {
            if (entry == null) return null;
            var isRoot = string.IsNullOrEmpty(entry.Key);
            var modified = isRoot || entry.ModifiedUtc == DateTime.MinValue ? ProviderInfo.CreateOn : TenantUtil.DateTimeFromUtc(entry.ModifiedUtc);

            return new Folder
            {
                ID = MakeId(entry.Key),
                ParentFolderID = isRoot
                    ? (ProviderInfo.RootFolderType == FolderType.COMMON ? Global.FolderCommon : Global.FolderMy)
                    : MakeId(GetParentPrefix(entry.Key)),
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
                Title = isRoot ? ProviderInfo.CustomerTitle : Global.ReplaceInvalidCharsAndTruncate(entry.Name),
                TotalFiles = 0,
                TotalSubFolders = 0
            };
        }

        protected File ToFile(MegaS4FileEntry entry)
        {
            if (entry == null) return null;
            var modified = entry.ModifiedUtc == DateTime.MinValue ? ProviderInfo.CreateOn : TenantUtil.DateTimeFromUtc(entry.ModifiedUtc);

            return new File
            {
                ID = MakeId(entry.Key),
                Access = FileShare.None,
                ContentLength = entry.Size,
                CreateBy = ProviderInfo.Owner,
                CreateOn = modified,
                FileStatus = FileStatus.None,
                FolderID = MakeId(GetParentPrefix(entry.Key)),
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
                Version = 1
            };
        }

        protected static string GetParentPrefix(string key)
        {
            if (string.IsNullOrEmpty(key)) return string.Empty;
            key = key.TrimEnd('/');
            var slash = key.LastIndexOf('/');
            return slash < 0 ? string.Empty : key.Substring(0, slash + 1);
        }

        protected static string Leaf(string key)
        {
            if (string.IsNullOrEmpty(key)) return string.Empty;
            key = key.TrimEnd('/');
            var slash = key.LastIndexOf('/');
            return slash < 0 ? key : key.Substring(slash + 1);
        }

        protected string GetAvailableTitle(string requestedTitle, string parentPrefix, Func<string, string, bool> exists)
        {
            if (!exists(requestedTitle, parentPrefix)) return requestedTitle;
            var re = new Regex(@"( \(((?<index>[0-9])+\)(\.[^\.]*)?)$");
            var match = re.Match(requestedTitle);
            if (!match.Success)
            {
                var insert = requestedTitle.LastIndexOf(".", StringComparison.InvariantCulture);
                if (insert < 0) insert = requestedTitle.Length;
                requestedTitle = requestedTitle.Insert(insert, " (1)");
            }

            while (exists(requestedTitle, parentPrefix))
            {
                requestedTitle = re.Replace(requestedTitle, delegate(Match m)
                {
                    var index = Convert.ToInt32(m.Groups[2].Value);
                    var tail = m.Value.Substring(string.Format(" ({0})", index).Length);
                    return string.Format(" ({0}){1}", index + 1, tail);
                });
            }
            return requestedTitle;
        }

        protected static IEnumerable<MegaS4FileEntry> Files(IEnumerable<MegaS4Entry> entries)
        {
            return entries.OfType<MegaS4FileEntry>();
        }

        protected static IEnumerable<MegaS4FolderEntry> Folders(IEnumerable<MegaS4Entry> entries)
        {
            return entries.OfType<MegaS4FolderEntry>();
        }
    }
}
