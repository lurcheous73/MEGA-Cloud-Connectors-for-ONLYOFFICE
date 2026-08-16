using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

using Amazon.S3;
using Amazon.S3.Model;

namespace ASC.Files.Thirdparty.MegaS4
{
    /// <summary>
    /// Direct MEGA S4 client used by the ONLYOFFICE connected-storage DAO.
    /// No filesystem, WebDAV or sync layer is involved.
    /// </summary>
    internal sealed class MegaS4Storage : IDisposable
    {
        private const long MultipartCopyPartSize = 500L * 1024L * 1024L;
        private readonly MegaS4Options options;
        private readonly IAmazonS3 client;

        public MegaS4Storage(MegaS4Options options)
        {
            if (options == null) throw new ArgumentNullException("options");
            this.options = options;

            // Match the custom-endpoint pattern used by ONLYOFFICE 12.8's own
            // S3Storage: ServiceURL + ForcePathStyle for S3-compatible services.
            var config = new AmazonS3Config
            {
                MaxErrorRetry = 3,
                ServiceURL = options.ServiceUrl,
                ForcePathStyle = options.ForcePathStyle,
                UseHttp = options.UseHttp
            };

            client = new AmazonS3Client(options.AccessKey, options.SecretKey, config);
        }

        public void Dispose()
        {
            client.Dispose();
        }

        public void CheckAccess()
        {
            // HeadBucket avoids requiring account-wide ListBuckets permission.
            client.GetACL(new GetACLRequest { BucketName = options.Bucket });
        }

        public MegaS4FolderEntry GetRoot()
        {
            return new MegaS4FolderEntry
            {
                Key = string.Empty,
                Name = string.Empty,
                ModifiedUtc = DateTime.MinValue
            };
        }

        public MegaS4FolderEntry GetFolder(string prefix)
        {
            prefix = NormalizeFolder(prefix);
            if (prefix.Length == 0) return GetRoot();

            var response = client.ListObjectsV2(new ListObjectsV2Request
            {
                BucketName = options.Bucket,
                Prefix = prefix,
                MaxKeys = 1
            });

            if (response.S3Objects == null || response.S3Objects.Count == 0) return null;
            return FolderFromPrefix(prefix, response.S3Objects[0].LastModified.GetValueOrDefault());
        }

        public MegaS4FileEntry GetFile(string key)
        {
            key = NormalizeFileKey(key);
            if (key.Length == 0) return null;

            try
            {
                var response = client.GetObjectMetadata(new GetObjectMetadataRequest
                {
                    BucketName = options.Bucket,
                    Key = key
                });

                return new MegaS4FileEntry
                {
                    Key = key,
                    Name = LeafName(key),
                    Size = response.ContentLength,
                    ETag = response.ETag,
                    ModifiedUtc = response.LastModified.GetValueOrDefault()
                };
            }
            catch (AmazonS3Exception ex)
            {
                if (IsNotFound(ex)) return null;
                throw;
            }
        }

        public List<MegaS4Entry> GetItems(string prefix)
        {
            prefix = NormalizeFolder(prefix);
            var result = new List<MegaS4Entry>();
            var folders = new HashSet<string>(StringComparer.Ordinal);
            string token = null;

            do
            {
                var response = client.ListObjectsV2(new ListObjectsV2Request
                {
                    BucketName = options.Bucket,
                    Prefix = prefix,
                    Delimiter = "/",
                    ContinuationToken = token,
                    MaxKeys = 1000
                });

                if (response.CommonPrefixes != null)
                {
                    foreach (var commonPrefix in response.CommonPrefixes)
                    {
                        var folderKey = NormalizeFolder(commonPrefix);
                        if (folderKey == prefix || !folders.Add(folderKey)) continue;
                        result.Add(FolderFromPrefix(folderKey, DateTime.MinValue));
                    }
                }

                if (response.S3Objects != null)
                {
                    foreach (var obj in response.S3Objects)
                    {
                        if (string.Equals(obj.Key, prefix, StringComparison.Ordinal)) continue; // marker for current folder
                        if (obj.Key.EndsWith("/", StringComparison.Ordinal))
                        {
                            var folderKey = NormalizeFolder(obj.Key);
                            if (folders.Add(folderKey)) result.Add(FolderFromPrefix(folderKey, obj.LastModified.GetValueOrDefault()));
                            continue;
                        }

                        result.Add(new MegaS4FileEntry
                        {
                            Key = obj.Key,
                            Name = LeafName(obj.Key),
                            Size = obj.Size.GetValueOrDefault(),
                            ETag = obj.ETag,
                            ModifiedUtc = obj.LastModified.GetValueOrDefault()
                        });
                    }
                }

                token = response.IsTruncated.GetValueOrDefault() ? response.NextContinuationToken : null;
            }
            while (!string.IsNullOrEmpty(token));

            return result;
        }

        public Stream Download(string key, long offset)
        {
            key = NormalizeFileKey(key);
            var request = new GetObjectRequest
            {
                BucketName = options.Bucket,
                Key = key
            };
            if (offset > 0) request.ByteRange = new ByteRange(offset);

            return new ResponseStreamWrapper(client.GetObject(request));
        }

        public MegaS4FolderEntry CreateFolder(string parentPrefix, string title)
        {
            var key = NormalizeFolder(Combine(parentPrefix, title));
            using (var empty = new MemoryStream(new byte[0], false))
            {
                Put(key, empty);
            }
            return GetFolder(key) ?? FolderFromPrefix(key, DateTime.UtcNow);
        }

        public MegaS4FileEntry PutFile(string parentPrefix, string title, Stream stream)
        {
            return Put(Combine(parentPrefix, title), stream);
        }

        public MegaS4FileEntry Put(string key, Stream stream)
        {
            if (stream == null) throw new ArgumentNullException("stream");
            key = key.EndsWith("/", StringComparison.Ordinal) ? NormalizeFolder(key) : NormalizeFileKey(key);

            var request = new PutObjectRequest
            {
                BucketName = options.Bucket,
                Key = key,
                InputStream = stream,
                AutoCloseStream = false,
                UseChunkEncoding = false,
                DisableDefaultChecksumValidation = true
            };

            client.PutObject(request);
            return key.EndsWith("/", StringComparison.Ordinal) ? null : GetFile(key);
        }

        public void DeleteFile(string key)
        {
            key = NormalizeFileKey(key);
            client.DeleteObject(new DeleteObjectRequest { BucketName = options.Bucket, Key = key });
        }

        public void DeleteFolder(string prefix)
        {
            var objects = ListRecursive(NormalizeFolder(prefix));
            DeleteKeys(objects.Select(x => x.Key));
        }

        public MegaS4FileEntry CopyFile(string sourceKey, string destinationKey)
        {
            sourceKey = NormalizeFileKey(sourceKey);
            destinationKey = NormalizeFileKey(destinationKey);
            CopyObjectVerified(sourceKey, destinationKey);
            return GetFile(destinationKey);
        }

        public MegaS4FileEntry MoveFile(string sourceKey, string destinationKey)
        {
            var destination = CopyFile(sourceKey, destinationKey);
            DeleteFile(sourceKey);
            return destination;
        }

        public MegaS4FolderEntry CopyFolder(string sourcePrefix, string destinationPrefix)
        {
            sourcePrefix = NormalizeFolder(sourcePrefix);
            destinationPrefix = NormalizeFolder(destinationPrefix);
            if (destinationPrefix.StartsWith(sourcePrefix, StringComparison.Ordinal))
                throw new InvalidOperationException("Cannot copy an S4 folder into itself.");

            var sourceObjects = ListRecursive(sourcePrefix);
            var created = new List<string>();
            try
            {
                // Preserve an empty source folder too.
                if (sourceObjects.Count == 0)
                {
                    using (var empty = new MemoryStream(new byte[0], false)) Put(destinationPrefix, empty);
                    created.Add(destinationPrefix);
                }
                else
                {
                    foreach (var source in sourceObjects)
                    {
                        var suffix = source.Key.Substring(sourcePrefix.Length);
                        var destinationKey = destinationPrefix + suffix;
                        CopyObjectVerified(source.Key, destinationKey);
                        created.Add(destinationKey);
                    }
                }
            }
            catch
            {
                DeleteKeys(created);
                throw;
            }

            return GetFolder(destinationPrefix) ?? FolderFromPrefix(destinationPrefix, DateTime.UtcNow);
        }

        public MegaS4FolderEntry MoveFolder(string sourcePrefix, string destinationPrefix)
        {
            var destination = CopyFolder(sourcePrefix, destinationPrefix);
            DeleteFolder(sourcePrefix);
            return destination;
        }

        public string BeginMultipart(string key)
        {
            key = NormalizeFileKey(key);
            return client.InitiateMultipartUpload(new InitiateMultipartUploadRequest
            {
                BucketName = options.Bucket,
                Key = key
            }).UploadId;
        }

        public string UploadPart(string key, string uploadId, int partNumber, long partSize, Stream stream)
        {
            key = NormalizeFileKey(key);
            var response = client.UploadPart(new UploadPartRequest
            {
                BucketName = options.Bucket,
                Key = key,
                UploadId = uploadId,
                PartNumber = partNumber,
                PartSize = partSize,
                InputStream = stream,
                DisableDefaultChecksumValidation = true
            });
            return response.ETag;
        }

        public MegaS4FileEntry CompleteMultipart(string key, string uploadId, IDictionary<int, string> etags)
        {
            key = NormalizeFileKey(key);
            var request = new CompleteMultipartUploadRequest
            {
                BucketName = options.Bucket,
                Key = key,
                UploadId = uploadId,
                PartETags = etags.OrderBy(x => x.Key).Select(x => new PartETag(x.Key, x.Value)).ToList()
            };
            client.CompleteMultipartUpload(request);
            return GetFile(key);
        }

        public void AbortMultipart(string key, string uploadId)
        {
            client.AbortMultipartUpload(new AbortMultipartUploadRequest
            {
                BucketName = options.Bucket,
                Key = NormalizeFileKey(key),
                UploadId = uploadId
            });
        }

        private List<S3Object> ListRecursive(string prefix)
        {
            var result = new List<S3Object>();
            string token = null;
            do
            {
                var response = client.ListObjectsV2(new ListObjectsV2Request
                {
                    BucketName = options.Bucket,
                    Prefix = prefix,
                    ContinuationToken = token,
                    MaxKeys = 1000
                });
                if (response.S3Objects != null) result.AddRange(response.S3Objects);
                token = response.IsTruncated.GetValueOrDefault() ? response.NextContinuationToken : null;
            }
            while (!string.IsNullOrEmpty(token));
            return result;
        }

        private void CopyObjectVerified(string sourceKey, string destinationKey)
        {
            var source = client.GetObjectMetadata(new GetObjectMetadataRequest { BucketName = options.Bucket, Key = sourceKey });
            if (source.ContentLength >= 5L * 1024L * 1024L * 1024L)
                MultipartCopy(sourceKey, destinationKey, source.ContentLength);
            else
                client.CopyObject(new CopyObjectRequest
                {
                    SourceBucket = options.Bucket,
                    SourceKey = sourceKey,
                    DestinationBucket = options.Bucket,
                    DestinationKey = destinationKey
                });

            var destination = client.GetObjectMetadata(new GetObjectMetadataRequest { BucketName = options.Bucket, Key = destinationKey });
            if (destination.ContentLength != source.ContentLength)
                throw new IOException("MEGA S4 copy verification failed for " + destinationKey);
        }

        private void MultipartCopy(string sourceKey, string destinationKey, long contentLength)
        {
            var init = client.InitiateMultipartUpload(new InitiateMultipartUploadRequest
            {
                BucketName = options.Bucket,
                Key = destinationKey
            });

            try
            {
                var parts = new List<PartETag>();
                long first = 0;
                var partNumber = 1;
                while (first < contentLength)
                {
                    var last = Math.Min(contentLength - 1, first + MultipartCopyPartSize - 1);
                    var response = client.CopyPart(new CopyPartRequest
                    {
                        SourceBucket = options.Bucket,
                        SourceKey = sourceKey,
                        DestinationBucket = options.Bucket,
                        DestinationKey = destinationKey,
                        UploadId = init.UploadId,
                        PartNumber = partNumber,
                        FirstByte = first,
                        LastByte = last
                    });
                    parts.Add(new PartETag(partNumber, response.ETag));
                    first = last + 1;
                    partNumber++;
                }

                client.CompleteMultipartUpload(new CompleteMultipartUploadRequest
                {
                    BucketName = options.Bucket,
                    Key = destinationKey,
                    UploadId = init.UploadId,
                    PartETags = parts
                });
            }
            catch
            {
                try
                {
                    client.AbortMultipartUpload(new AbortMultipartUploadRequest
                    {
                        BucketName = options.Bucket,
                        Key = destinationKey,
                        UploadId = init.UploadId
                    });
                }
                catch { }
                throw;
            }
        }

        private void DeleteKeys(IEnumerable<string> keys)
        {
            var batch = new List<KeyVersion>(1000);
            foreach (var key in keys.Distinct(StringComparer.Ordinal))
            {
                batch.Add(new KeyVersion { Key = key });
                if (batch.Count == 1000)
                {
                    client.DeleteObjects(new DeleteObjectsRequest { BucketName = options.Bucket, Objects = batch });
                    batch = new List<KeyVersion>(1000);
                }
            }
            if (batch.Count > 0)
                client.DeleteObjects(new DeleteObjectsRequest { BucketName = options.Bucket, Objects = batch });
        }

        private static MegaS4FolderEntry FolderFromPrefix(string prefix, DateTime modifiedUtc)
        {
            return new MegaS4FolderEntry
            {
                Key = NormalizeFolder(prefix),
                Name = LeafName(prefix.TrimEnd('/')),
                ModifiedUtc = modifiedUtc
            };
        }

        internal static string NormalizeFolder(string value)
        {
            var key = Normalize(value);
            return key.Length == 0 ? string.Empty : key.TrimEnd('/') + "/";
        }

        internal static string NormalizeFileKey(string value)
        {
            return Normalize(value).TrimEnd('/');
        }

        internal static string Combine(string parent, string name)
        {
            var prefix = NormalizeFolder(parent);
            var leaf = Normalize(name).Trim('/');
            if (leaf.Length == 0) throw new ArgumentException("S4 object name cannot be empty.", "name");
            return prefix + leaf;
        }

        private static string Normalize(string value)
        {
            if (string.IsNullOrEmpty(value)) return string.Empty;
            var key = value.Replace('\\', '/').TrimStart('/');
            while (key.Contains("//")) key = key.Replace("//", "/");
            if (key.Split('/').Any(part => part == "." || part == ".."))
                throw new ArgumentException("Relative path components are not allowed in S4 keys.", "value");
            if (key.IndexOf('\0') >= 0) throw new ArgumentException("NUL is not allowed in S4 keys.", "value");
            return key;
        }

        private static string LeafName(string key)
        {
            if (string.IsNullOrEmpty(key)) return string.Empty;
            key = key.TrimEnd('/');
            var slash = key.LastIndexOf('/');
            return slash < 0 ? key : key.Substring(slash + 1);
        }

        private static bool IsNotFound(AmazonS3Exception ex)
        {
            return ex != null &&
                   (string.Equals(ex.ErrorCode, "NoSuchKey", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(ex.ErrorCode, "NotFound", StringComparison.OrdinalIgnoreCase) ||
                    (int)ex.StatusCode == 404);
        }

        private sealed class ResponseStreamWrapper : Stream
        {
            private readonly GetObjectResponse response;
            private Stream Inner { get { return response.ResponseStream; } }

            public ResponseStreamWrapper(GetObjectResponse response)
            {
                if (response == null) throw new ArgumentNullException("response");
                this.response = response;
            }

            public override bool CanRead { get { return Inner.CanRead; } }
            public override bool CanSeek { get { return Inner.CanSeek; } }
            public override bool CanWrite { get { return false; } }
            public override long Length { get { return response.ContentLength; } }
            public override long Position { get { return Inner.Position; } set { Inner.Position = value; } }
            public override void Flush() { Inner.Flush(); }
            public override int Read(byte[] buffer, int offset, int count) { return Inner.Read(buffer, offset, count); }
            public override long Seek(long offset, SeekOrigin origin) { return Inner.Seek(offset, origin); }
            public override void SetLength(long value) { throw new NotSupportedException(); }
            public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }

            protected override void Dispose(bool disposing)
            {
                if (disposing) response.Dispose();
                base.Dispose(disposing);
            }
        }
    }
}
