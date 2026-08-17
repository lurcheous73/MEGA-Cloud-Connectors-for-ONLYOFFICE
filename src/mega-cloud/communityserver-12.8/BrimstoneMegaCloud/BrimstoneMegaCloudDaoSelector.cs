using System;
using System.Globalization;
using System.Text.RegularExpressions;

using ASC.Core;
using ASC.Files.Core;
using ASC.Files.Core.Security;
using ASC.Web.Files.Classes;

namespace ASC.Files.Thirdparty.BrimstoneMegaCloud
{
    internal sealed class BrimstoneMegaCloudDaoSelector : RegexDaoSelectorBase<string>
    {
        internal sealed class BrimstoneMegaCloudInfo
        {
            public BrimstoneMegaCloudProviderInfo ProviderInfo { get; set; }
            public string Handle { get; set; }
            public string IdPrefix { get; set; }
        }

        public BrimstoneMegaCloudDaoSelector()
            : base(new Regex(@"^sboxbrimstonemegacc-\d+(?:-[A-Za-z0-9_-]+)?$",
                             RegexOptions.Compiled | RegexOptions.IgnoreCase))
        {
        }

        public override IFileDao GetFileDao(object id)
        {
            return new BrimstoneMegaCloudFileDao(GetInfo(id), this);
        }

        public override IFolderDao GetFolderDao(object id)
        {
            return new BrimstoneMegaCloudFolderDao(GetInfo(id), this);
        }

        public override ITagDao GetTagDao(object id)
        {
            return new BrimstoneMegaCloudTagDao(GetInfo(id), this);
        }

        public override ISecurityDao GetSecurityDao(object id)
        {
            return new BrimstoneMegaCloudSecurityDao(GetInfo(id), this);
        }

        public override object ConvertId(object id)
        {
            int providerId;
            string handle;
            if (!BrimstoneMegaCloudId.TryParse(id, out providerId, out handle))
                throw new ArgumentException("Id is not a Brimstone MEGA Cloud id", "id");
            return handle;
        }

        public override object GetIdCode(object id)
        {
            int providerId;
            string handle;
            return BrimstoneMegaCloudId.TryParse(id, out providerId, out handle)
                ? (object)providerId.ToString(CultureInfo.InvariantCulture)
                : base.GetIdCode(id);
        }

        private BrimstoneMegaCloudInfo GetInfo(object id)
        {
            if (id == null) throw new ArgumentNullException("id");

            int providerId;
            string handle;
            if (!BrimstoneMegaCloudId.TryParse(id, out providerId, out handle))
                throw new ArgumentException("Id is not a Brimstone MEGA Cloud id", "id");

            BrimstoneMegaCloudProviderInfo providerInfo;
            using (var providerDao = Global.DaoFactory.GetProviderDao())
            {
                try
                {
                    providerInfo = (BrimstoneMegaCloudProviderInfo)providerDao.GetProviderInfo(providerId);
                }
                catch (InvalidOperationException)
                {
                    throw new ProviderInfoArgumentException("Provider id not found or you have no access");
                }
            }

            return new BrimstoneMegaCloudInfo
            {
                ProviderInfo = providerInfo,
                Handle = handle,
                IdPrefix = BrimstoneMegaCloudId.Root(providerId)
            };
        }

        public void RenameProvider(BrimstoneMegaCloudProviderInfo providerInfo, string newTitle)
        {
            using (var providerDao = new CachedProviderAccountDao(
                CoreContext.TenantManager.GetCurrentTenant().TenantId,
                FileConstant.DatabaseId))
            {
                providerDao.UpdateProviderInfo(providerInfo.ID, newTitle, null, providerInfo.RootFolderType);
                providerInfo.UpdateTitle(newTitle);
            }
        }
    }
}
