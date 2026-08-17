using System;
using System.Collections.Generic;

using ASC.Files.Core;
using ASC.Files.Core.Security;

namespace ASC.Files.Thirdparty.MegaS4
{
    internal sealed class MegaS4SecurityDao : MegaS4DaoBase, ISecurityDao
    {
        public MegaS4SecurityDao(MegaS4DaoSelector.MegaS4Info info, MegaS4DaoSelector selector)
            : base(info, selector) { }

        public void SetShare(FileShareRecord record) { }
        public IEnumerable<FileShareRecord> GetShares(IEnumerable<Guid> subjects) { return null; }
        public IEnumerable<FileShareRecord> GetShares(IEnumerable<FileEntry> entries) { return null; }
        public IEnumerable<FileShareRecord> GetShares(FileEntry entry) { return null; }
        public void RemoveSubjects(IEnumerable<Guid> subjects) { }
        public IEnumerable<FileShareRecord> GetPureShareRecords(IEnumerable<FileEntry> entries) { return null; }
        public IEnumerable<FileShareRecord> GetPureShareRecords(FileEntry entry) { return null; }
        public void DeleteShareRecords(IEnumerable<FileShareRecord> records) { }
        public bool IsShared(object entryId, FileEntryType type) { return false; }
    }
}
