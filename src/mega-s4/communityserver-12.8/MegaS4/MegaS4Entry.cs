using System;

namespace ASC.Files.Thirdparty.MegaS4
{
    internal abstract class MegaS4Entry
    {
        public string Key { get; set; }
        public string Name { get; set; }
        public DateTime ModifiedUtc { get; set; }
        public abstract bool IsFolder { get; }
    }

    internal sealed class MegaS4FolderEntry : MegaS4Entry
    {
        public override bool IsFolder { get { return true; } }
    }

    internal sealed class MegaS4FileEntry : MegaS4Entry
    {
        public long Size { get; set; }
        public string ETag { get; set; }
        public override bool IsFolder { get { return false; } }
    }
}
