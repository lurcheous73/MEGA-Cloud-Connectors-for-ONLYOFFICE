using System;
using System.Runtime.InteropServices;

namespace ASC.Files.Thirdparty.MegaCloud
{
    internal static class MegaCloudNative
    {
        private const string Library = "onlyoffice_mega_bridge";

        internal enum Result
        {
            Ok = 0,
            Error = -1,
            MfaRequired = -1001,
            AuthFailed = -1002,
            NotFound = -1003,
            Conflict = -1004,
            Timeout = -1005,
            Cancelled = -1006
        }

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate int WriteCallback(IntPtr data, ulong length, IntPtr userData);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
        internal static extern IntPtr oomb_create(string appKey, string userAgent, string stateDir);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        internal static extern void oomb_destroy(IntPtr context);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr oomb_last_error(IntPtr context);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        internal static extern void oomb_free_string(IntPtr value);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
        internal static extern int oomb_login(IntPtr context, string email, string password, uint timeoutSeconds);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
        internal static extern int oomb_login_mfa(IntPtr context, string email, string password, string code, uint timeoutSeconds);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
        internal static extern int oomb_fast_login(IntPtr context, string session, uint timeoutSeconds);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int oomb_fetch_nodes(IntPtr context, uint timeoutSeconds);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr oomb_dump_session(IntPtr context);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int oomb_logout(IntPtr context, uint timeoutSeconds);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        internal static extern ulong oomb_root_handle(IntPtr context);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr oomb_get_node_json(IntPtr context, ulong handle);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr oomb_list_children_json(IntPtr context, ulong parentHandle);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
        internal static extern int oomb_create_folder(IntPtr context, ulong parentHandle, string name, out ulong resultHandle, uint timeoutSeconds);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
        internal static extern int oomb_rename_node(IntPtr context, ulong handle, string name, uint timeoutSeconds);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int oomb_move_node(IntPtr context, ulong handle, ulong newParentHandle, uint timeoutSeconds);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int oomb_remove_node(IntPtr context, ulong handle, uint timeoutSeconds);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
        internal static extern int oomb_copy_node(IntPtr context, ulong handle, ulong newParentHandle, string newName, out ulong resultHandle, uint timeoutSeconds);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int oomb_stream_download(IntPtr context, ulong handle, ulong offset, WriteCallback callback, IntPtr userData, uint timeoutSeconds);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
        internal static extern int oomb_upload_file(IntPtr context, string localPath, ulong parentHandle, string remoteName, out ulong resultHandle, uint timeoutSeconds);

        [DllImport(Library, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
        internal static extern int oomb_replace_file(IntPtr context, string localPath, ulong existingHandle, out ulong resultHandle, uint timeoutSeconds);

        internal static string LastError(IntPtr context)
        {
            return PtrToUtf8(oomb_last_error(context), false);
        }

        internal static string DumpSession(IntPtr context)
        {
            return PtrToUtf8(oomb_dump_session(context), true);
        }

        internal static string GetNodeJson(IntPtr context, ulong handle)
        {
            return PtrToUtf8(oomb_get_node_json(context, handle), true);
        }

        internal static string ListChildrenJson(IntPtr context, ulong parentHandle)
        {
            return PtrToUtf8(oomb_list_children_json(context, parentHandle), true);
        }

        private static string PtrToUtf8(IntPtr value, bool release)
        {
            if (value == IntPtr.Zero) return null;
            try
            {
                var length = 0;
                while (Marshal.ReadByte(value, length) != 0) length++;
                var bytes = new byte[length];
                Marshal.Copy(value, bytes, 0, length);
                return System.Text.Encoding.UTF8.GetString(bytes);
            }
            finally
            {
                if (release) oomb_free_string(value);
            }
        }
    }
}
