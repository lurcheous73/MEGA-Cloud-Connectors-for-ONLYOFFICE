using System;
using System.Collections.Generic;

using ASC.Files.Core;

namespace ASC.Files.Thirdparty.BrimstoneMegaCloud
{
    internal sealed class BrimstoneMegaCloudTagDao : BrimstoneMegaCloudDaoBase, ITagDao
    {
        public BrimstoneMegaCloudTagDao(BrimstoneMegaCloudDaoSelector.BrimstoneMegaCloudInfo info,
                                        BrimstoneMegaCloudDaoSelector selector)
            : base(info, selector)
        {
        }

        private static IEnumerable<Tag> Empty() { return new Tag[0]; }

        public IEnumerable<Tag> GetTags(Guid subject, TagType tagType, IEnumerable<FileEntry> fileEntries) { return Empty(); }
        public IEnumerable<Tag> GetTags(TagType tagType, IEnumerable<FileEntry> fileEntries) { return Empty(); }
        public IEnumerable<Tag> GetTags(Guid owner, TagType tagType) { return Empty(); }
        public IEnumerable<Tag> GetTags(string name, TagType tagType) { return Empty(); }
        public IEnumerable<Tag> GetTags(string[] names, TagType tagType) { return Empty(); }
        public IEnumerable<Tag> GetNewTags(Guid subject, Folder parentFolder, bool deepSearch) { return Empty(); }
        public IEnumerable<Tag> GetNewTags(Guid subject, IEnumerable<FileEntry> fileEntries) { return Empty(); }
        public IEnumerable<Tag> GetNewTags(Guid subject, FileEntry fileEntry) { return Empty(); }
        public IEnumerable<Tag> SaveTags(IEnumerable<Tag> tag) { return Empty(); }
        public IEnumerable<Tag> SaveTags(Tag tag) { return Empty(); }
        public void UpdateNewTags(IEnumerable<Tag> tag) { }
        public void UpdateNewTags(Tag tag) { }
        public void RemoveTags(IEnumerable<Tag> tag) { }
        public void RemoveTags(Tag tag) { }
        public IEnumerable<Tag> GetTags(object entryID, FileEntryType entryType, TagType tagType) { return Empty(); }
        public void MarkAsNew(Guid subject, FileEntry fileEntry) { }
    }
}
