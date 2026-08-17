using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

using ASC.Files.Core;
using ASC.Web.Core.Files;
using ASC.Web.Studio.Core;

using File = ASC.Files.Core.File;

namespace ASC.Files.Thirdparty.BrimstoneMegaCloud
{
    internal sealed class BrimstoneMegaCloudFileDao : BrimstoneMegaCloudDaoBase, IFileDao
    {
        public BrimstoneMegaCloudFileDao(BrimstoneMegaCloudDaoSelector.BrimstoneMegaCloudInfo info,
                                         BrimstoneMegaCloudDaoSelector selector)
            : base(info, selector)
        {
        }

        public void InvalidateCache(object fileId) { }

        public File GetFile(object fileId) { return ToFile(GetCloudEntry(fileId)); }
        public File GetFile(object fileId, int fileVersion) { return GetFile(fileId); }
        public File GetFileStable(object fileId, int fileVersion = -1) { return GetFile(fileId); }
        public List<File> GetFileHistory(object fileId) { return new List<File> { GetFile(fileId) }; }

        public File GetFile(object parentId, string title)
        {
            var entry = Files(GetCloudItems(parentId))
                .FirstOrDefault(x => x.Name.Equals(title, StringComparison.InvariantCultureIgnoreCase));
            return ToFile(entry);
        }

        public List<File> GetFiles(IEnumerable<object> fileIds)
        {
            return fileIds == null
                ? new List<File>()
                : fileIds.Select(x => GetFile(x)).Where(x => x != null).ToList();
        }

        public List<File> GetFilesFiltered(IEnumerable<object> fileIds,
                                           FilterType filterType,
                                           bool subjectGroup,
                                           Guid subjectID,
                                           string searchText,
                                           bool searchInContent,
                                           string extension)
        {
            return ApplyFilters(GetFiles(fileIds), filterType, subjectID, searchText, extension).ToList();
        }

        public List<object> GetFiles(object parentId)
        {
            return Files(GetCloudItems(parentId)).Select(x => (object)MakeId(x)).ToList();
        }

        public List<File> GetFiles(object parentId,
                                   OrderBy orderBy,
                                   FilterType filterType,
                                   bool subjectGroup,
                                   Guid subjectID,
                                   string searchText,
                                   bool searchInContent,
                                   string extension,
                                   bool withSubfolders = false)
        {
            var files = Files(GetCloudItems(parentId)).Select(x => ToFile(x));
            files = ApplyFilters(files, filterType, subjectID, searchText, extension);
            return Order(files, orderBy).ToList();
        }

        public Stream GetFileStream(File file)
        {
            if (file == null)
                throw new ArgumentNullException("file");

            return ProviderInfo.Client.OpenRead(
                DecodeId(file.ID));
        }

        public Stream GetFileStream(File file, long offset)
        {
            if (file == null)
                throw new ArgumentNullException("file");

            if (offset < 0)
                throw new ArgumentOutOfRangeException("offset");

            return ProviderInfo.Client.OpenRead(
                DecodeId(file.ID),
                offset);
        }

        public Task<Stream> GetFileStreamAsync(File file)
        {
            if (file == null)
                throw new ArgumentNullException("file");

            return Task.Factory.StartNew<Stream>(
                delegate
                {
                    return GetFileStream(file);
                });
        }
        public Uri GetPreSignedUri(File file, TimeSpan expires) { throw ReadOnly(); }
        public bool IsSupportedPreSignedUri(File file) { return false; }

        public File SaveFile(File file, Stream fileStream)
        {
            if (file == null)
                throw new ArgumentNullException("file");

            if (fileStream == null)
                throw new ArgumentNullException("fileStream");

            string remotePath;

            if (file.ID != null)
            {
                // Editing is allowed. Rename is deliberately NOT part of this
                // milestone; the path identity must remain stable.
                remotePath = DecodeId(file.ID);

                var currentName = RemoteLeaf(remotePath);

                if (!string.Equals(
                        file.Title,
                        currentName,
                        StringComparison.Ordinal))
                {
                    throw new NotSupportedException(
                        "MEGA Cloud rename is not enabled in v0.004cc create/edit.");
                }
            }
            else
            {
                if (file.FolderID == null)
                    throw new ArgumentException(
                        "FolderID is required for a new MEGA Cloud file.",
                        "file");

                var parentPath =
                    DecodeId(file.FolderID);

                file.Title =
                    GetAvailableTitle(
                        file.Title,
                        parentPath,
                        IsExist);

                remotePath =
                    CombineRemotePath(
                        parentPath,
                        file.Title);
            }

            return ToFile(
                ProviderInfo.Client.Put(
                    remotePath,
                    fileStream));
        }

        public File ReplaceFileVersion(File file, Stream fileStream)
        {
            return SaveFile(file, fileStream);
        }
        public void DeleteFile(object fileId, Guid ownerId)
        {
            DeleteFile(fileId);
        }

        public void DeleteFile(object fileId)
        {
            ProviderInfo.Client.MoveToRubbish(
                DecodeId(fileId));
        }

        public bool IsExist(string title, object folderId)
        {
            var parent = DecodeId(folderId);
            return ProviderInfo.Client.ListChildren(parent)
                .Any(x => x.IsFile && x.Name.Equals(title, StringComparison.InvariantCultureIgnoreCase));
        }

        public object MoveFile(object fileId, object toFolderId)
        {
            var sourcePath =
                DecodeId(fileId);

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

        public File CopyFile(object fileId, object toFolderId)
        {
            var sourcePath =
                DecodeId(fileId);

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

            return ToFile(
                ProviderInfo.Client.Copy(
                    sourcePath,
                    destinationPath));
        }

        public object FileRename(File file, string newTitle)
        {
            if (file == null)
                throw new ArgumentNullException("file");

            var sourcePath =
                DecodeId(file.ID);

            var sourceTitle =
                RemoteLeaf(sourcePath);

            if (string.Equals(
                    sourceTitle,
                    newTitle,
                    StringComparison.Ordinal))
            {
                return MakeId(sourcePath);
            }

            var parentPath =
                ParentRemotePath(sourcePath);

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
                    sourcePath,
                    destinationPath));
        }

        public string UpdateComment(object fileId, int fileVersion, string comment) { return string.Empty; }
        public void CompleteVersion(object fileId, int fileVersion) { }
        public void ContinueVersion(object fileId, int fileVersion) { }
        public bool UseTrashForRemove(File file) { return false; }

        private File RestoreIds(File file)
        {
            if (file == null)
                return null;

            if (file.ID != null)
                file.ID = MakeId(DecodeId(file.ID));

            if (file.FolderID != null)
                file.FolderID = MakeId(DecodeId(file.FolderID));

            return file;
        }

        public ChunkedUploadSession CreateUploadSession(File file,
                                                        long contentLength)
        {
            if (file == null)
                throw new ArgumentNullException("file");

            // v0.004cc first write milestone intentionally supports normal
            // editor/new-document uploads only. True multi-request chunk
            // staging comes after create/edit acceptance.
            if (contentLength >= 0
                && SetupInfo.ChunkUploadSize <= contentLength)
            {
                throw new NotSupportedException(
                    "Large chunked MEGA Cloud uploads are not enabled yet.");
            }

            return new ChunkedUploadSession(
                RestoreIds(file),
                contentLength)
            {
                UseChunks = false
            };
        }

        public File UploadChunk(ChunkedUploadSession session,
                                Stream chunkStream,
                                long chunkLength)
        {
            if (session == null)
                throw new ArgumentNullException("session");

            if (chunkStream == null)
                throw new ArgumentNullException("chunkStream");

            if (session.UseChunks)
                throw new NotSupportedException(
                    "Large chunked MEGA Cloud uploads are not enabled yet.");

            if (session.BytesTotal == 0)
                session.BytesTotal = chunkLength;

            session.File =
                SaveFile(
                    session.File,
                    chunkStream);

            session.BytesUploaded = chunkLength;

            return session.File;
        }

        public Task UploadChunkAsync(ChunkedUploadSession session,
                                     Stream chunkStream,
                                     long chunkLength)
        {
            UploadChunk(
                session,
                chunkStream,
                chunkLength);

            return Task.FromResult(0);
        }

        public File FinalizeUploadSession(ChunkedUploadSession session)
        {
            if (session == null)
                throw new ArgumentNullException("session");

            if (session.UseChunks)
                throw new NotSupportedException(
                    "Large chunked MEGA Cloud uploads are not enabled yet.");

            return session.File;
        }

        public void AbortUploadSession(ChunkedUploadSession session)
        {
        }

        public void ReassignFiles(IEnumerable<object> fileIds, Guid newOwnerId) { }

        public List<File> GetFiles(IEnumerable<object> parentIds,
                                   FilterType filterType,
                                   bool subjectGroup,
                                   Guid subjectID,
                                   string searchText,
                                   bool searchInContent,
                                   string extension)
        {
            if (parentIds == null) return new List<File>();
            return parentIds.SelectMany(x => GetFiles(x, null, filterType, subjectGroup, subjectID,
                                                       searchText, searchInContent, extension, false)).ToList();
        }

        public IEnumerable<File> Search(string text, bool bunch = false) { return new File[0]; }

        public bool IsExistOnStorage(File file)
        {
            if (file == null || file.ID == null) return false;
            try { return GetCloudEntry(file.ID) != null; }
            catch { return false; }
        }

        public Task<bool> IsExistOnStorageAsync(File file) { return Task.FromResult(IsExistOnStorage(file)); }
        public void SaveEditHistory(File file, string changes, Stream differenceStream) { }
        public List<EditHistory> GetEditHistory(object fileId, int fileVersion = 0) { return null; }
        public Stream GetDifferenceStream(File file) { return null; }
        public bool ContainChanges(object fileId, int fileVersion) { return false; }
        public void SaveThumbnail(File file, Stream thumbnail) { }
        public Stream GetThumbnail(File file) { return null; }
        public EntryProperties GetProperties(object fileId) { return null; }
        public void SaveProperties(object fileId, EntryProperties entryProperties) { }

        private static IEnumerable<File> ApplyFilters(IEnumerable<File> files,
                                                      FilterType filterType,
                                                      Guid subjectID,
                                                      string searchText,
                                                      string extension)
        {
            if (filterType == FilterType.FoldersOnly) return new File[0];
            if (subjectID != Guid.Empty) files = files.Where(x => x.CreateBy == subjectID);

            switch (filterType)
            {
                case FilterType.DocumentsOnly: files = files.Where(x => FileUtility.GetFileTypeByFileName(x.Title) == FileType.Document); break;
                case FilterType.PresentationsOnly: files = files.Where(x => FileUtility.GetFileTypeByFileName(x.Title) == FileType.Presentation); break;
                case FilterType.SpreadsheetsOnly: files = files.Where(x => FileUtility.GetFileTypeByFileName(x.Title) == FileType.Spreadsheet); break;
                case FilterType.ImagesOnly: files = files.Where(x => FileUtility.GetFileTypeByFileName(x.Title) == FileType.Image); break;
                case FilterType.ArchiveOnly: files = files.Where(x => FileUtility.GetFileTypeByFileName(x.Title) == FileType.Archive); break;
                case FilterType.MediaOnly:
                    files = files.Where(x =>
                    {
                        var t = FileUtility.GetFileTypeByFileName(x.Title);
                        return t == FileType.Audio || t == FileType.Video;
                    });
                    break;
                case FilterType.ByExtension:
                case FilterType.ByExtensionIncludeFolders:
                    if (!string.IsNullOrEmpty(extension))
                        files = files.Where(x => FileUtility.GetFileExtension(x.Title).Equals(extension.Trim().ToLower()));
                    break;
            }

            if (!string.IsNullOrEmpty(searchText))
                files = files.Where(x => x.Title.IndexOf(searchText, StringComparison.OrdinalIgnoreCase) >= 0);
            return files;
        }

        private static IEnumerable<File> Order(IEnumerable<File> files, OrderBy orderBy)
        {
            if (orderBy == null) orderBy = new OrderBy(SortedByType.DateAndTime, false);
            switch (orderBy.SortedBy)
            {
                case SortedByType.Author: return orderBy.IsAsc ? files.OrderBy(x => x.CreateBy) : files.OrderByDescending(x => x.CreateBy);
                case SortedByType.AZ: return orderBy.IsAsc ? files.OrderBy(x => x.Title) : files.OrderByDescending(x => x.Title);
                case SortedByType.DateAndTimeCreation: return orderBy.IsAsc ? files.OrderBy(x => x.CreateOn) : files.OrderByDescending(x => x.CreateOn);
                default: return orderBy.IsAsc ? files.OrderBy(x => x.ModifiedOn) : files.OrderByDescending(x => x.ModifiedOn);
            }
        }
    }
}
