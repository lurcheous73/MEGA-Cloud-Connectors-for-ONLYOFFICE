using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;

using ASC.Core.ChunkedUploader;
using ASC.Data.Storage.ZipOperators;
using ASC.Files.Core;
using ASC.Web.Studio.Core;

namespace ASC.Files.Thirdparty.BrimstoneMegaCloud
{
    internal sealed class BrimstoneMegaCloudFolderDao : BrimstoneMegaCloudDaoBase, IFolderDao
    {
        public BrimstoneMegaCloudFolderDao(BrimstoneMegaCloudDaoSelector.BrimstoneMegaCloudInfo info,
                                           BrimstoneMegaCloudDaoSelector selector)
            : base(info, selector)
        {
        }

        public Folder GetFolder(object folderId)
        {
            var remotePath = DecodeId(folderId);
            return BrimstoneMegaCloudId.NormalizeRemotePath(remotePath) == "/"
                ? ToRootFolder()
                : ToFolder(GetCloudEntry(remotePath));
        }

        public Folder GetFolder(string title, object parentId)
        {
            var entry = Folders(GetCloudItems(parentId))
                .FirstOrDefault(x => x.Name.Equals(title, StringComparison.InvariantCultureIgnoreCase));
            return ToFolder(entry);
        }

        public Folder GetRootFolder(object folderId)
        {
            return ToRootFolder();
        }

        public Folder GetRootFolderByFile(object fileId)
        {
            return ToRootFolder();
        }

        public List<Folder> GetFolders(object parentId)
        {
            return Folders(GetCloudItems(parentId)).Select(ToFolder).ToList();
        }

        public List<Folder> GetFolders(object parentId,
                                       OrderBy orderBy,
                                       FilterType filterType,
                                       bool subjectGroup,
                                       Guid subjectID,
                                       string searchText,
                                       bool withSubfolders = false)
        {
            if (FileOnly(filterType)) return new List<Folder>();

            IEnumerable<Folder> folders = GetFolders(parentId);
            if (subjectID != Guid.Empty) folders = folders.Where(x => x.CreateBy == subjectID);
            if (!string.IsNullOrEmpty(searchText))
                folders = folders.Where(x => x.Title.IndexOf(searchText, StringComparison.OrdinalIgnoreCase) >= 0);
            return Order(folders, orderBy).ToList();
        }

        public List<Folder> GetFolders(IEnumerable<object> folderIds,
                                       FilterType filterType = FilterType.None,
                                       bool subjectGroup = false,
                                       Guid? subjectID = null,
                                       string searchText = "",
                                       bool searchSubfolders = false,
                                       bool checkShare = true)
        {
            if (FileOnly(filterType)) return new List<Folder>();
            IEnumerable<Folder> folders = folderIds == null
                ? new Folder[0]
                : folderIds.Select(GetFolder).Where(x => x != null);

            if (subjectID.HasValue && subjectID.Value != Guid.Empty)
                folders = folders.Where(x => x.CreateBy == subjectID.Value);
            if (!string.IsNullOrEmpty(searchText))
                folders = folders.Where(x => x.Title.IndexOf(searchText, StringComparison.OrdinalIgnoreCase) >= 0);
            return folders.ToList();
        }

        public List<Folder> GetParentFolders(object folderId)
        {
            var remotePath =
                BrimstoneMegaCloudId.NormalizeRemotePath(DecodeId(folderId));

            var result = new List<Folder> { ToRootFolder() };

            if (remotePath == "/")
                return result;

            var current = "/";

            foreach (var part in remotePath
                .Trim('/')
                .Split(new[] { '/' }, StringSplitOptions.RemoveEmptyEntries))
            {
                current = BrimstoneMegaCloudId.Combine(current, part);

                var entry = ProviderInfo.Client.GetEntry(current);

                if (entry == null || !entry.IsFolder)
                    throw new InvalidOperationException(
                        "Brimstone MEGA Cloud breadcrumb node was not found in the live MEGA namespace.");

                result.Add(ToFolder(entry));
            }

            return result;
        }

        public object SaveFolder(Folder folder)
        {
            if (folder == null)
                throw new ArgumentNullException("folder");

            // Existing folder IDs mean rename in ONLYOFFICE. Keep that disabled
            // for this milestone; only creation is enabled.
            if (folder.ID != null)
                throw new NotSupportedException(
                    "MEGA Cloud folder rename is not enabled in v0.004cc create/edit.");

            if (folder.ParentFolderID == null)
                throw new ArgumentException(
                    "ParentFolderID is required for a new MEGA Cloud folder.",
                    "folder");

            var parentPath =
                DecodeId(folder.ParentFolderID);

            folder.Title =
                GetAvailableTitle(
                    folder.Title,
                    parentPath,
                    FolderExists);

            return MakeId(
                ProviderInfo.Client.CreateFolder(
                    parentPath,
                    folder.Title));
        }
        public void DeleteFolder(object folderId)
        {
            ProviderInfo.Client.MoveToRubbish(
                DecodeId(folderId));
        }

        public object MoveFolder(object folderId,
                                 object toFolderId,
                                 CancellationToken? cancellationToken)
        {
            if (cancellationToken.HasValue)
                cancellationToken.Value.ThrowIfCancellationRequested();

            var sourcePath =
                DecodeId(folderId);

            var destinationParent =
                DecodeId(toFolderId);

            var destinationTitle =
                GetAvailableTitle(
                    RemoteLeaf(sourcePath),
                    destinationParent,
                    NodeExists);

            var destinationPath =
                CombineRemotePath(
                    destinationParent,
                    destinationTitle);

            return MakeId(
                ProviderInfo.Client.Move(
                    sourcePath,
                    destinationPath));
        }

        public Folder CopyFolder(object folderId,
                                 object toFolderId,
                                 CancellationToken? cancellationToken)
        {
            if (cancellationToken.HasValue)
                cancellationToken.Value.ThrowIfCancellationRequested();

            var sourcePath =
                DecodeId(folderId);

            var destinationParent =
                DecodeId(toFolderId);

            var destinationTitle =
                GetAvailableTitle(
                    RemoteLeaf(sourcePath),
                    destinationParent,
                    NodeExists);

            var destinationPath =
                CombineRemotePath(
                    destinationParent,
                    destinationTitle);

            return ToFolder(
                ProviderInfo.Client.Copy(
                    sourcePath,
                    destinationPath));
        }

        public IDictionary<object, string> CanMoveOrCopy(object[] folderIds, object to)
        {
            var result =
                new Dictionary<object, string>();

            if (folderIds == null)
                return result;

            foreach (var id in folderIds)
            {
                try
                {
                    var remotePath =
                        BrimstoneMegaCloudId.NormalizeRemotePath(
                            DecodeId(id));

                    if (remotePath == "/")
                    {
                        result[id] =
                            "The MEGA Cloud provider root cannot be moved or copied.";
                    }
                }
                catch (Exception error)
                {
                    result[id] = error.Message;
                }
            }

            return result;
        }

        public object RenameFolder(Folder folder, string newTitle)
        {
            if (folder == null)
                throw new ArgumentNullException("folder");

            var remotePath =
                BrimstoneMegaCloudId.NormalizeRemotePath(
                    DecodeId(folder.ID));

            if (remotePath == "/")
            {
                Selector.RenameProvider(
                    ProviderInfo,
                    newTitle);

                return MakeId(string.Empty);
            }

            var currentTitle =
                RemoteLeaf(remotePath);

            if (string.Equals(
                    currentTitle,
                    newTitle,
                    StringComparison.Ordinal))
            {
                return MakeId(remotePath);
            }

            var parentPath =
                ParentRemotePath(remotePath);

            var destinationTitle =
                GetAvailableTitle(
                    newTitle,
                    parentPath,
                    NodeExists);

            var destinationPath =
                CombineRemotePath(
                    parentPath,
                    destinationTitle);

            return MakeId(
                ProviderInfo.Client.Move(
                    remotePath,
                    destinationPath));
        }

        public int GetItemsCount(object folderId) { return GetCloudItems(folderId).Count; }
        public bool IsEmpty(object folderId) { return GetCloudItems(folderId).Count == 0; }
        public bool UseTrashForRemove(Folder folder) { return false; }
        public bool UseRecursiveOperation(object folderId, object toRootFolderId) { return false; }
        public bool CanCalculateSubitems(object entryId) { return false; }
        public long GetMaxUploadSize(object folderId, bool chunkedUpload = false)
        {
            return SetupInfo.AvailableFileSize;
        }

        public IDataWriteOperator CreateDataWriteOperator(string folderId,
                                                           CommonChunkedUploadSession chunkedUploadSession,
                                                           CommonChunkedUploadSessionHolder sessionHolder)
        {
            throw ReadOnly();
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

        private bool FolderExists(string title,
                                  string parentPath)
        {
            return ProviderInfo.Client.ListChildren(parentPath)
                .Any(x =>
                    x.IsFolder
                    && x.Name.Equals(
                        title,
                        StringComparison.InvariantCultureIgnoreCase));
        }

        public bool IsExist(string title, string folderId)
        {
            int providerId;
            string handle;
            var parent = BrimstoneMegaCloudId.TryParse(folderId, out providerId, out handle) ? handle : folderId;
            return ProviderInfo.Client.ListChildren(parent)
                .Any(x => x.IsFolder && x.Name.Equals(title, StringComparison.InvariantCultureIgnoreCase));
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
