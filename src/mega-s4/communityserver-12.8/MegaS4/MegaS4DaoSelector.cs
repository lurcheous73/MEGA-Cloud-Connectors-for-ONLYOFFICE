using System;
using System.Globalization;
using System.Text.RegularExpressions;

using ASC.Core;
using ASC.Files.Core;
using ASC.Files.Core.Security;
using ASC.Web.Files.Classes;

namespace ASC.Files.Thirdparty.MegaS4
{
    internal sealed class MegaS4DaoSelector : RegexDaoSelectorBase<string>
    {
        internal sealed class MegaS4Info
        {
            public MegaS4ProviderInfo ProviderInfo { get; set; }
            public string Key { get; set; }
            public string IdPrefix { get; set; }
        }

        public MegaS4DaoSelector()
            : base(new Regex(@"^sbox-megas4-\d+(?:-[A-Za-z0-9_-]+)?$", RegexOptions.Compiled | RegexOptions.IgnoreCase))
        {
        }

        public override IFileDao GetFileDao(object id)
        {
            return new MegaS4FileDao(GetInfo(id), this);
        }

        public override IFolderDao GetFolderDao(object id)
        {
            return new MegaS4FolderDao(GetInfo(id), this);
        }

        public override ITagDao GetTagDao(object id)
        {
            return new MegaS4TagDao(GetInfo(id), this);
        }

        public override ISecurityDao GetSecurityDao(object id)
        {
            return new MegaS4SecurityDao(GetInfo(id), this);
        }

        public override object ConvertId(object id)
        {
            int linkId;
            string key;
            if (!MegaS4Id.TryParse(id, out linkId, out key)) throw new ArgumentException("Id is not a MEGA S4 id", "id");
            return key;
        }

        public override object GetIdCode(object id)
        {
            int linkId;
            string key;
            return MegaS4Id.TryParse(id, out linkId, out key) ? (object)linkId.ToString(CultureInfo.InvariantCulture) : base.GetIdCode(id);
        }

        private MegaS4Info GetInfo(object id)
        {
            if (id == null) throw new ArgumentNullException("id");
            int linkId;
            string key;
            if (!MegaS4Id.TryParse(id, out linkId, out key)) throw new ArgumentException("Id is not a MEGA S4 id", "id");

            MegaS4ProviderInfo providerInfo;
            using (var providerDao = Global.DaoFactory.GetProviderDao())
            {
                try
                {
                    providerInfo = (MegaS4ProviderInfo)providerDao.GetProviderInfo(linkId);
                }
                catch (InvalidOperationException)
                {
                    throw new ProviderInfoArgumentException("Provider id not found or you have no access");
                }
            }

            return new MegaS4Info
            {
                ProviderInfo = providerInfo,
                Key = key,
                IdPrefix = MegaS4Id.Root(linkId)
            };
        }

        public void RenameProvider(MegaS4ProviderInfo providerInfo, string newTitle)
        {
            using (var providerDao = new CachedProviderAccountDao(CoreContext.TenantManager.GetCurrentTenant().TenantId, FileConstant.DatabaseId))
            {
                providerDao.UpdateProviderInfo(providerInfo.ID, newTitle, null, providerInfo.RootFolderType);
                providerInfo.UpdateTitle(newTitle);
            }
        }
    }
}
