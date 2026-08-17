using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;

using ASC.Core.ChunkedUploader;
using ASC.Data.Storage.ZipOperators;
using ASC.Files.Core;
using ASC.Web.Studio.Core;

namespace ASC.Files.Thirdparty.MegaS4
{
    internal sealed class MegaS4FolderDao : MegaS4DaoBase, IFolderDao
    {
        private const long S3MaximumObjectSize = 5L * 1024L * 1024L * 1024L * 1024L;

        public MegaS4FolderDao(MegaS4DaoSelector.MegaS4Info info, MegaS4DaoSelector selector)
            : base(info, selector) { }

        public Folder GetFolder(object folderId) { return ToFolder(GetS4Folder(folderId)); }

        public Folder GetFolder(string title, object parentId)
        {
            return ToFolder(Folders(GetS4Items(parentId)).FirstOrDefault(x => x.Name.Equals(title, StringComparison.InvariantCultureIgnoreCase)));
        }

        public Folder GetRootFolder(object folderId) { return ToFolder(ProviderInfo.Storage.GetRoot()); }
        public Folder GetRootFolderByFile(object fileId) { return GetRootFolder(fileId); }
        public List<Folder> GetFolders(object parentId) { return Folders(GetS4Items(parentId)).Select(ToFolder).ToList(); }

        public List<Folder> GetFolders(object parentId, OrderBy orderBy, FilterType filterType, bool subjectGroup, Guid subjectID,
                                       string searchText, bool withSubfolders = false)
        {
            if (FileOnly(filterType)) return new List<Folder>();
            IEnumerable<Folder> folders = GetFolders(parentId);
            if (subjectID != Guid.Empty) folders = folders.Where(x => x.CreateBy == subjectID);
            if (!string.IsNullOrEmpty(searchText)) folders = folders.Where(x => x.Title.IndexOf(searchText, StringComparison.OrdinalIgnoreCase) >= 0);
            return Order(folders, orderBy).ToList();
        }

        public List<Folder> GetFolders(IEnumerable<object> folderIds, FilterType filterType = FilterType.None, bool subjectGroup = false,
                                       Guid? subjectID = null, string searchText = "", bool searchSubfolders = false, bool checkShare = true)
        {
            if (FileOnly(filterType)) return new List<Folder>();
            IEnumerable<Folder> folders = folderIds.Select(GetFolder).Where(x => x != null);
            if (subjectID.HasValue && subjectID.Value != Guid.Empty) folders = folders.Where(x => x.CreateBy == subjectID.Value);
            if (!string.IsNullOrEmpty(searchText)) folders = folders.Where(x => x.Title.IndexOf(searchText, StringComparison.OrdinalIgnoreCase) >= 0);
            return folders.ToList();
        }

        public List<Folder> GetParentFolders(object folderId)
        {
            var key = DecodeId(folderId);
            var result = new List<Folder> { GetRootFolder(folderId) };
            var parts = key.Trim('/').Split(new[] { '/' }, StringSplitOptions.RemoveEmptyEntries);
            var current = string.Empty;
            foreach (var part in parts)
            {
                current += part + "/";
                var folder = ProviderInfo.Storage.GetFolder(current);
                if (folder != null) result.Add(ToFolder(folder));
            }
            return result;
        }

        public object SaveFolder(Folder folder)
        {
            if (folder == null) throw new ArgumentNullException("folder");
            if (folder.ID != null) return RenameFolder(folder, folder.Title);
            if (folder.ParentFolderID == null) return null;

            var parent = DecodeId(folder.ParentFolderID);
            folder.Title = GetAvailableTitle(folder.Title, parent, FolderExists);
            return MakeId(ProviderInfo.Storage.CreateFolder(parent, folder.Title));
        }

        public void DeleteFolder(object folderId)
        {
            var key = DecodeId(folderId);
            if (string.IsNullOrEmpty(key)) throw new InvalidOperationException("Cannot delete the root of a connected MEGA S4 drive.");
            ProviderInfo.Storage.DeleteFolder(key);
        }

        public object MoveFolder(object folderId, object toFolderId, CancellationToken? cancellationToken)
        {
            var source = GetS4Folder(folderId);
            if (source == null) throw new InvalidOperationException("MEGA S4 source folder was not found.");
            if (string.IsNullOrEmpty(source.Key)) throw new InvalidOperationException("Cannot move the root of a connected MEGA S4 drive.");
            if (cancellationToken.HasValue) cancellationToken.Value.ThrowIfCancellationRequested();

            var destinationParent = DecodeId(toFolderId);
            var title = GetAvailableTitle(source.Name, destinationParent, FolderExists);
            var destinationKey = MegaS4Storage.NormalizeFolder(MegaS4Storage.Combine(destinationParent, title));
            var result = ProviderInfo.Storage.MoveFolder(source.Key, destinationKey);
            return MakeId(result);
        }

        public Folder CopyFolder(object folderId, object toFolderId, CancellationToken? cancellationToken)
        {
            var source = GetS4Folder(folderId);
            if (source == null) throw new InvalidOperationException("MEGA S4 source folder was not found.");
            if (string.IsNullOrEmpty(source.Key)) throw new InvalidOperationException("Cannot copy the root of a connected MEGA S4 drive.");
            if (cancellationToken.HasValue) cancellationToken.Value.ThrowIfCancellationRequested();

            var destinationParent = DecodeId(toFolderId);
            var title = GetAvailableTitle(source.Name, destinationParent, FolderExists);
            var destinationKey = MegaS4Storage.NormalizeFolder(MegaS4Storage.Combine(destinationParent, title));
            return ToFolder(ProviderInfo.Storage.CopyFolder(source.Key, destinationKey));
        }

        public IDictionary<object, string> CanMoveOrCopy(object[] folderIds, object to)
        {
            return new Dictionary<object, string>();
        }

        public object RenameFolder(Folder folder, string newTitle)
        {
            if (folder == null) throw new ArgumentNullException("folder");
            var source = GetS4Folder(folder.ID);
            if (source == null) throw new InvalidOperationException("MEGA S4 folder was not found.");

            if (string.IsNullOrEmpty(source.Key))
            {
                Selector.RenameProvider(ProviderInfo, newTitle);
                return MakeId(string.Empty);
            }

            var parent = GetParentPrefix(source.Key);
            newTitle = GetAvailableTitle(newTitle, parent, FolderExists);
            var destinationKey = MegaS4Storage.NormalizeFolder(MegaS4Storage.Combine(parent, newTitle));
            return MakeId(ProviderInfo.Storage.MoveFolder(source.Key, destinationKey));
        }

        public int GetItemsCount(object folderId) { return GetS4Items(folderId).Count; }
        public bool IsEmpty(object folderId) { return GetS4Items(folderId).Count == 0; }
        public bool UseTrashForRemove(Folder folder) { return false; }
        public bool UseRecursiveOperation(object folderId, object toRootFolderId) { return false; }
        public bool CanCalculateSubitems(object entryId) { return false; }

        public long GetMaxUploadSize(object folderId, bool chunkedUpload = false)
        {
            return chunkedUpload ? S3MaximumObjectSize : Math.Min(S3MaximumObjectSize, SetupInfo.AvailableFileSize);
        }

        public IDataWriteOperator CreateDataWriteOperator(string folderId, CommonChunkedUploadSession chunkedUploadSession,
                                                           CommonChunkedUploadSessionHolder sessionHolder)
        {
            return new ChunkZipWriteOperator(chunkedUploadSession, sessionHolder);
        }

        public void ReassignFolders(IEnumerable<object> folderIds, Guid newOwnerId) { }
        public IEnumerable<Folder> Search(string text, bool bunch = false) { return new Folder[0]; }
        public object GetFolderID(string module, string bunch, string data, bool createIfNotExists) { return null; }
        public IEnumerable<object> GetFolderIDs(string module, string bunch, IEnumerable<string> data, bool createIfNotExists) { return new object[0]; }
        public object GetFolderIDCommon(bool createIfNotExists) { return null; }
        public object GetFolderIDUser(bool createIfNotExists, Guid? userId = null) { return null; }
        public object GetFolderIDShare(bool createIfNotExists) { return null; }
        public object GetFolderIDRecent(bool createIfNotExists) { return null; }
        public object GetFolderIDFavorites(bool createIfNotExists) { return null; }
        public object GetFolderIDTemplates(bool createIfNotExists) { return null; }
        public object GetFolderIDPrivacy(bool createIfNotExists, Guid? userId = null) { return null; }
        public object GetFolderIDTrash(bool createIfNotExists, Guid? userId = null) { return null; }
        public object GetFolderIDProjects(bool createIfNotExists) { return null; }
        public string GetBunchObjectID(object folderID) { return null; }
        public Dictionary<string, string> GetBunchObjectIDs(IEnumerable<object> folderIDs) { return null; }

        private bool FolderExists(string title, string parentPrefix)
        {
            return ProviderInfo.Storage.GetItems(parentPrefix)
                .Any(x => x.IsFolder && x.Name.Equals(title, StringComparison.InvariantCultureIgnoreCase));
        }

        public bool IsExist(string title, string folderId)
        {
            int linkId;
            string decoded;
            var parent = MegaS4Id.TryParse(folderId, out linkId, out decoded) ? decoded : folderId;
            return FolderExists(title, parent);
        }

        private static bool FileOnly(FilterType filterType)
        {
            return filterType == FilterType.FilesOnly || filterType == FilterType.ByExtension ||
                   filterType == FilterType.DocumentsOnly || filterType == FilterType.ImagesOnly ||
                   filterType == FilterType.PresentationsOnly || filterType == FilterType.SpreadsheetsOnly ||
                   filterType == FilterType.ArchiveOnly || filterType == FilterType.MediaOnly;
        }

        private static IEnumerable<Folder> Order(IEnumerable<Folder> folders, OrderBy orderBy)
        {
            if (orderBy == null) orderBy = new OrderBy(SortedByType.DateAndTime, false);
            switch (orderBy.SortedBy)
            {
                case SortedByType.Author: return orderBy.IsAsc ? folders.OrderBy(x => x.CreateBy) : folders.OrderByDescending(x => x.CreateBy);
                case SortedByType.AZ: return orderBy.IsAsc ? folders.OrderBy(x => x.Title) : folders.OrderByDescending(x => x.Title);
                case SortedByType.DateAndTimeCreation: return orderBy.IsAsc ? folders.OrderBy(x => x.CreateOn) : folders.OrderByDescending(x => x.CreateOn);
                default: return orderBy.IsAsc ? folders.OrderBy(x => x.ModifiedOn) : folders.OrderByDescending(x => x.ModifiedOn);
            }
        }
    }
}
