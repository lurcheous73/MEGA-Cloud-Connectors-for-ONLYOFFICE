using System;

namespace ASC.Files.Thirdparty.BrimstoneMegaCloud
{
    // BRIMSTONE CUSTOM CODE.
    // One immutable-ish view of a MEGA node as returned by the pinned MEGAcmd
    // browse contract. Handle is the remote identity; names/parents are metadata.
    internal sealed class BrimstoneMegaCloudEntry
    {
        public string Handle { get; set; }
        public string ParentHandle { get; set; }
        public string Name { get; set; }
        public string Flags { get; set; }
        public int VersionCount { get; set; }
        public long Size { get; set; }
        public DateTime ModifiedUtc { get; set; }

        public bool IsFolder
        {
            get { return !string.IsNullOrEmpty(Flags) && Flags[0] == 'd'; }
        }

        public bool IsFile
        {
            get { return !string.IsNullOrEmpty(Flags) && Flags[0] == '-'; }
        }
    }
}
