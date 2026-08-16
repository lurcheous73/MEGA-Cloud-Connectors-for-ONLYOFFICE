using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

using ASC.Files.Core;
using ASC.Web.Core.Files;
using ASC.Web.Studio.Core;

using File = ASC.Files.Core.File;

namespace ASC.Files.Thirdparty.MegaS4
{
    internal sealed class MegaS4FileDao : MegaS4DaoBase, IFileDao
    {
        public MegaS4FileDao(MegaS4DaoSelector.MegaS4Info info, MegaS4DaoSelector selector)
            : base(info, selector) { }

        public void InvalidateCache(object fileId) { }

        public File GetFile(object fileId) { return ToFile(GetS4File(fileId)); }
        public File GetFile(object fileId, int fileVersion) { return GetFile(fileId); }
        public File GetFileStable(object fileId, int fileVersion = -1) { return GetFile(fileId); }
        public List<File> GetFileHistory(object fileId) { return new List<File> { GetFile(fileId) }; }

        public File GetFile(object parentId, string title)
        {
            var entry = Files(GetS4Items(parentId)).FirstOrDefault(x => x.Name.Equals(title, StringComparison.InvariantCultureIgnoreCase));
            return ToFile(entry);
        }

        public List<File> GetFiles(IEnumerable<object> fileIds)
        {
            return fileIds == null ? new List<File>() : fileIds.Select(GetFile).Where(x => x != null).ToList();
        }

        public List<File> GetFilesFiltered(IEnumerable<object> fileIds, FilterType filterType, bool subjectGroup, Guid subjectID,
                                           string searchText, bool searchInContent, string extension)
        {
            return ApplyFilters(GetFiles(fileIds), filterType, subjectID, searchText, extension).ToList();
        }

        public List<object> GetFiles(object parentId)
        {
            return Files(GetS4Items(parentId)).Select(x => (object)MakeId(x)).ToList();
        }

        public List<File> GetFiles(object parentId, OrderBy orderBy, FilterType filterType, bool subjectGroup, Guid subjectID,
                                   string searchText, bool searchInContent, string extension, bool withSubfolders = false)
        {
            var files = Files(GetS4Items(parentId)).Select(ToFile);
            files = ApplyFilters(files, filterType, subjectID, searchText, extension);
            return Order(files, orderBy).ToList();
        }

        public Stream GetFileStream(File file) { return GetFileStream(file, 0); }

        public Stream GetFileStream(File file, long offset)
        {
            if (file == null) throw new ArgumentNullException("file");
            var key = DecodeId(file.ID);
            return ProviderInfo.Storage.Download(key, offset);
        }

        public Task<Stream> GetFileStreamAsync(File file) { return Task.FromResult(GetFileStream(file)); }
        public Uri GetPreSignedUri(File file, TimeSpan expires) { throw new NotSupportedException(); }
        public bool IsSupportedPreSignedUri(File file) { return false; }

        public File SaveFile(File file, Stream fileStream)
        {
            if (file == null) throw new ArgumentNullException("file");
            if (fileStream == null) throw new ArgumentNullException("fileStream");

            MegaS4FileEntry saved;
            if (file.ID != null)
            {
                var key = DecodeId(file.ID);
                var existing = ProviderInfo.Storage.GetFile(key);
                if (existing == null) throw new FileNotFoundException("MEGA S4 object not found.", key);

                if (!existing.Name.Equals(file.Title, StringComparison.Ordinal))
                {
                    var parent = GetParentPrefix(key);
                    file.Title = GetAvailableTitle(file.Title, parent, IsExist);
                    key = ProviderInfo.Storage.MoveFile(key, MegaS4Storage.Combine(parent, file.Title)).Key;
                }
                saved = ProviderInfo.Storage.Put(key, fileStream);
            }
            else
            {
                if (file.FolderID == null) throw new ArgumentException("FolderID is required for a new MEGA S4 file.", "file");
                var parent = DecodeId(file.FolderID);
                file.Title = GetAvailableTitle(file.Title, parent, IsExist);
                saved = ProviderInfo.Storage.PutFile(parent, file.Title, fileStream);
            }

            return ToFile(saved);
        }

        public File ReplaceFileVersion(File file, Stream fileStream) { return SaveFile(file, fileStream); }
        public void DeleteFile(object fileId, Guid ownerId) { DeleteFile(fileId); }
        public void DeleteFile(object fileId) { ProviderInfo.Storage.DeleteFile(DecodeId(fileId)); }

        public bool IsExist(string title, object folderId)
        {
            return IsExist(title, DecodeId(folderId));
        }

        private bool IsExist(string title, string parentPrefix)
        {
            return ProviderInfo.Storage.GetItems(parentPrefix)
                .Any(x => !x.IsFolder && x.Name.Equals(title, StringComparison.InvariantCultureIgnoreCase));
        }

        public object MoveFile(object fileId, object toFolderId)
        {
            var source = GetS4File(fileId);
            if (source == null) throw new FileNotFoundException();
            var parent = DecodeId(toFolderId);
            var title = GetAvailableTitle(source.Name, parent, IsExist);
            return MakeId(ProviderInfo.Storage.MoveFile(source.Key, MegaS4Storage.Combine(parent, title)));
        }

        public File CopyFile(object fileId, object toFolderId)
        {
            var source = GetS4File(fileId);
            if (source == null) throw new FileNotFoundException();
            var parent = DecodeId(toFolderId);
            var title = GetAvailableTitle(source.Name, parent, IsExist);
            return ToFile(ProviderInfo.Storage.CopyFile(source.Key, MegaS4Storage.Combine(parent, title)));
        }

        public object FileRename(File file, string newTitle)
        {
            if (file == null) throw new ArgumentNullException("file");
            var source = GetS4File(file.ID);
            if (source == null) throw new FileNotFoundException();
            var parent = GetParentPrefix(source.Key);
            newTitle = GetAvailableTitle(newTitle, parent, IsExist);
            return MakeId(ProviderInfo.Storage.MoveFile(source.Key, MegaS4Storage.Combine(parent, newTitle)));
        }

        public string UpdateComment(object fileId, int fileVersion, string comment) { return string.Empty; }
        public void CompleteVersion(object fileId, int fileVersion) { }
        public void ContinueVersion(object fileId, int fileVersion) { }
        public bool UseTrashForRemove(File file) { return false; }

        public ChunkedUploadSession CreateUploadSession(File file, long contentLength)
        {
            if (file == null) throw new ArgumentNullException("file");
            if (SetupInfo.ChunkUploadSize > contentLength && contentLength >= 0)
                return new ChunkedUploadSession(file, contentLength) { UseChunks = false };

            string key;
            if (file.ID != null)
            {
                key = DecodeId(file.ID);
            }
            else
            {
                var parent = DecodeId(file.FolderID);
                file.Title = GetAvailableTitle(file.Title, parent, IsExist);
                key = MegaS4Storage.Combine(parent, file.Title);
            }

            var session = new ChunkedUploadSession(file, contentLength);
            session.Items["MegaS4Key"] = key;
            session.Items["MegaS4UploadId"] = ProviderInfo.Storage.BeginMultipart(key);
            session.Items["MegaS4PartNumber"] = 1;
            session.Items["MegaS4ETags"] = new Dictionary<int, string>();
            return session;
        }

        public File UploadChunk(ChunkedUploadSession session, Stream chunkStream, long chunkLength)
        {
            if (!session.UseChunks)
            {
                if (session.BytesTotal == 0) session.BytesTotal = chunkLength;
                session.File = SaveFile(session.File, chunkStream);
                session.BytesUploaded = chunkLength;
                return session.File;
            }

            var key = session.GetItemOrDefault<string>("MegaS4Key");
            var uploadId = session.GetItemOrDefault<string>("MegaS4UploadId");
            var partNumber = session.GetItemOrDefault<int>("MegaS4PartNumber");
            if (partNumber <= 0) partNumber = 1;
            var etags = session.GetItemOrDefault<Dictionary<int, string>>("MegaS4ETags") ?? new Dictionary<int, string>();

            etags[partNumber] = ProviderInfo.Storage.UploadPart(key, uploadId, partNumber, chunkLength, chunkStream);
            session.Items["MegaS4ETags"] = etags;
            session.Items["MegaS4PartNumber"] = partNumber + 1;
            session.BytesUploaded += chunkLength;

            if (session.LastChunk || (session.BytesTotal >= 0 && session.BytesUploaded == session.BytesTotal))
                session.File = FinalizeUploadSession(session);

            return session.File;
        }

        public Task UploadChunkAsync(ChunkedUploadSession session, Stream chunkStream, long chunkLength)
        {
            UploadChunk(session, chunkStream, chunkLength);
            return Task.FromResult(0);
        }

        public File FinalizeUploadSession(ChunkedUploadSession session)
        {
            if (!session.UseChunks) return session.File;
            var key = session.GetItemOrDefault<string>("MegaS4Key");
            var uploadId = session.GetItemOrDefault<string>("MegaS4UploadId");
            var etags = session.GetItemOrDefault<Dictionary<int, string>>("MegaS4ETags") ?? new Dictionary<int, string>();
            if (etags.Count == 0) throw new InvalidOperationException("Cannot complete an empty MEGA S4 multipart upload.");
            return ToFile(ProviderInfo.Storage.CompleteMultipart(key, uploadId, etags));
        }

        public void AbortUploadSession(ChunkedUploadSession session)
        {
            if (session == null || !session.UseChunks) return;
            var key = session.GetItemOrDefault<string>("MegaS4Key");
            var uploadId = session.GetItemOrDefault<string>("MegaS4UploadId");
            if (!string.IsNullOrEmpty(key) && !string.IsNullOrEmpty(uploadId)) ProviderInfo.Storage.AbortMultipart(key, uploadId);
        }

        public void ReassignFiles(IEnumerable<object> fileIds, Guid newOwnerId) { }
        public List<File> GetFiles(IEnumerable<object> parentIds, FilterType filterType, bool subjectGroup, Guid subjectID, string searchText, bool searchInContent, string extension) { return new List<File>(); }
        public IEnumerable<File> Search(string text, bool bunch = false) { return new File[0]; }
        public bool IsExistOnStorage(File file) { return file != null && ProviderInfo.Storage.GetFile(DecodeId(file.ID)) != null; }
        public Task<bool> IsExistOnStorageAsync(File file) { return Task.FromResult(IsExistOnStorage(file)); }
        public void SaveEditHistory(File file, string changes, Stream differenceStream) { }
        public List<EditHistory> GetEditHistory(object fileId, int fileVersion = 0) { return null; }
        public Stream GetDifferenceStream(File file) { return null; }
        public bool ContainChanges(object fileId, int fileVersion) { return false; }
        public void SaveThumbnail(File file, Stream thumbnail) { }
        public Stream GetThumbnail(File file) { return null; }
        public EntryProperties GetProperties(object fileId) { return null; }
        public void SaveProperties(object fileId, EntryProperties entryProperties) { }

        private static IEnumerable<File> ApplyFilters(IEnumerable<File> files, FilterType filterType, Guid subjectID, string searchText, string extension)
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
                case FilterType.MediaOnly: files = files.Where(x => { var t = FileUtility.GetFileTypeByFileName(x.Title); return t == FileType.Audio || t == FileType.Video; }); break;
                case FilterType.ByExtension:
                case FilterType.ByExtensionIncludeFolders:
                    if (!string.IsNullOrEmpty(extension)) files = files.Where(x => FileUtility.GetFileExtension(x.Title).Equals(extension.Trim().ToLower()));
                    break;
            }

            if (!string.IsNullOrEmpty(searchText)) files = files.Where(x => x.Title.IndexOf(searchText, StringComparison.OrdinalIgnoreCase) >= 0);
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
