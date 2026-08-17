#!/usr/bin/env bash
# BRIMSTONE CUSTOM CODE — v0.002cc disposable runtime smoke test.
# Proves ProviderInfo -> DAO transport/identity layer -> pinned MEGAcmd using a
# COPY of an already-authenticated provider slot. It deliberately stops before
# ONLYOFFICE Folder/File projection because TenantUtil.DateTimeFromUtc requires
# a fully bootstrapped CoreContext/TenantManager, which this standalone harness
# does not have. Production code remains unchanged and continues to use tenant
# timezone conversion inside the real WebStudio process.
#
# This script never installs the candidate DLL, writes the ONLYOFFICE database,
# or mutates the original MEGA session state.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH="v0.002cc-mega-cloud"
IMAGE="onlyoffice/communityserver:12.8.0.1971"
LIVE_CONTAINER="${ONLYOFFICE_CONTAINER:-onlyoffice-community-server}"
LIVE_DLL="/var/www/onlyoffice/WebStudio/bin/ASC.Files.Thirdparty.dll"
COMPILE_GATE="$ROOT/tools/BRIMSTONE-v0.002cc-compile-only.sh"
BIN="$ROOT/build/communityserver-v0.002cc-src/web/studio/ASC.Web.Studio/bin"
CANDIDATE="$BIN/ASC.Files.Thirdparty.dll"
ENGINE="$ROOT/build/mega-cloud-v0.001cc/megacmd-prefix"
SOURCE_STATE_ROOT="$ROOT/build/mega-cloud-v0.001cc/megacmd-state"
SMOKE_ROOT="$ROOT/build/brimstone-v0.002cc-runtime-smoke"
SMOKE_STATE_ROOT="$SMOKE_ROOT/state"
HARNESS="$SMOKE_ROOT/BrimstoneMegaCloudRuntimeSmoke.cs"

BRIMSTONE_LIVE_BEFORE=""
BRIMSTONE_SESSION_BEFORE=""
BRIMSTONE_SOURCE_SESSION=""

fail(){ echo "BRIMSTONE FAIL: $*" >&2; exit 1; }

validate_slot(){
    local slot="${1:-test1}"
    [[ "$slot" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || fail "slot must contain only letters, digits, underscore or hyphen (max 32 chars)"
    printf '%s' "$slot"
}

live_hash(){
    docker exec "$LIVE_CONTAINER" sha256sum "$LIVE_DLL" | awk '{print $1}'
}

verify_immutability_on_exit(){
    local rc=$?
    trap - EXIT
    set +e

    if [[ -n "$BRIMSTONE_LIVE_BEFORE" && -n "$BRIMSTONE_SESSION_BEFORE" && -n "$BRIMSTONE_SOURCE_SESSION" ]]; then
        local live_after session_after
        live_after="$(live_hash 2>/dev/null)"
        session_after="$(sha256sum "$BRIMSTONE_SOURCE_SESSION" 2>/dev/null | awk '{print $1}')"

        echo
        echo "=== BRIMSTONE IMMUTABILITY POSTCHECK ==="
        echo "live DLL before:     $BRIMSTONE_LIVE_BEFORE"
        echo "live DLL after:      $live_after"
        echo "source session hash: $session_after"

        if [[ "$live_after" != "$BRIMSTONE_LIVE_BEFORE" ]]; then
            echo "BRIMSTONE FAIL: live ASC.Files.Thirdparty.dll changed during disposable smoke" >&2
            rc=1
        else
            echo "PASS: live ASC.Files.Thirdparty.dll NOT MODIFIED"
        fi

        if [[ "$session_after" != "$BRIMSTONE_SESSION_BEFORE" ]]; then
            echo "BRIMSTONE FAIL: original saved MEGA session changed during disposable smoke" >&2
            rc=1
        else
            echo "PASS: original saved MEGA session NOT MODIFIED"
        fi

        echo "database:            NOT TOUCHED"
    fi

    exit "$rc"
}
trap verify_immutability_on_exit EXIT

main(){
    local slot
    slot="$(validate_slot "${1:-test1}")"
    local source_slot="$SOURCE_STATE_ROOT/$slot"
    local source_session="$source_slot/home/.megaCmd/session"

    echo "=== BRIMSTONE MEGA CLOUD v0.002cc DISPOSABLE RUNTIME SMOKE ==="
    [[ -d "$ROOT/.git" ]] || fail "connector repository missing"
    [[ "$(git -C "$ROOT" branch --show-current)" == "$BRANCH" ]] || fail "expected branch $BRANCH"
    [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]] || fail "connector repository is dirty"
    [[ -s "$COMPILE_GATE" ]] || fail "compile-only gate missing"
    [[ -x "$ENGINE/usr/bin/mega-exec" ]] || fail "pinned MEGAcmd engine missing"
    [[ -s "$source_session" ]] || fail "saved source session missing for slot $slot"
    docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "required image not local: $IMAGE"
    docker inspect "$LIVE_CONTAINER" >/dev/null 2>&1 || fail "CommunityServer container missing"

    BRIMSTONE_SOURCE_SESSION="$source_session"
    BRIMSTONE_LIVE_BEFORE="$(live_hash)"
    BRIMSTONE_SESSION_BEFORE="$(sha256sum "$source_session" | awk '{print $1}')"

    echo "branch:             $(git -C "$ROOT" branch --show-current)"
    echo "head:               $(git -C "$ROOT" rev-parse HEAD)"
    echo "source slot:        $slot"
    echo "source session:     READ ONLY / COPIED"
    echo "live DLL before:    $BRIMSTONE_LIVE_BEFORE"
    echo "live stack:         NOT MODIFIED"
    echo

    # Rebuild first so the runtime candidate is guaranteed to come from the
    # current clean branch rather than an older assembly left in build/.
    bash "$COMPILE_GATE" build
    [[ -s "$CANDIDATE" ]] || fail "candidate DLL missing after compile gate"

    echo
    echo "=== PREPARE DISPOSABLE SESSION COPY ==="
    rm -rf "$SMOKE_ROOT"
    mkdir -p "$SMOKE_STATE_ROOT"
    chmod 700 "$SMOKE_ROOT" "$SMOKE_STATE_ROOT"
    cp -a "$source_slot" "$SMOKE_STATE_ROOT/$slot"
    chmod -R go-rwx "$SMOKE_STATE_ROOT/$slot"
    [[ -s "$SMOKE_STATE_ROOT/$slot/home/.megaCmd/session" ]] || fail "disposable session copy failed"

    cat > "$HARNESS" <<'CS'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;

internal static class BrimstoneMegaCloudRuntimeSmoke
{
    private const int ProviderId = 9001;
    private const string ExpectedPrefix = "sboxbrimstonemegacc-9001";

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException("BRIMSTONE SMOKE FAIL: " + message);
    }

    private static object Property(object value, string name)
    {
        var p = value.GetType().GetProperty(name, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
        if (p == null) throw new MissingMemberException(value.GetType().FullName, name);
        return p.GetValue(value, null);
    }

    private static bool BoolProperty(object value, string name)
    {
        return Convert.ToBoolean(Property(value, name), CultureInfo.InvariantCulture);
    }

    private static void SetProperty(object value, string name, object propertyValue)
    {
        var p = value.GetType().GetProperty(name, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
        if (p == null) throw new MissingMemberException(value.GetType().FullName, name);
        p.SetValue(value, propertyValue, null);
    }

    private static List<object> Objects(object enumerable)
    {
        var result = new List<object>();
        foreach (var item in (IEnumerable)enumerable) result.Add(item);
        return result;
    }

    private static MethodInfo FindInstanceMethod(Type type, string name, Type parameterType)
    {
        for (var current = type; current != null; current = current.BaseType)
        {
            foreach (var method in current.GetMethods(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.DeclaredOnly))
            {
                if (method.Name != name) continue;
                var p = method.GetParameters();
                if (p.Length == 1 && p[0].ParameterType == parameterType) return method;
            }
        }
        throw new MissingMethodException(type.FullName, name + "(" + parameterType.FullName + ")");
    }

    private static Type FindTypeInDirectory(string directory, string fullName)
    {
        foreach (var path in Directory.GetFiles(directory, "*.dll"))
        {
            try
            {
                var assembly = Assembly.LoadFrom(path);
                var type = assembly.GetType(fullName, false);
                if (type != null) return type;
            }
            catch
            {
                // Optional WebStudio assemblies may have irrelevant load-time
                // dependencies. Keep looking for the exact required type.
            }
        }
        return null;
    }

    public static int Main(string[] args)
    {
        try
        {
            Require(args.Length == 2, "usage: smoke <candidate-dll> <state-slot>");
            var candidatePath = Path.GetFullPath(args[0]);
            var slot = args[1];
            var bin = Path.GetDirectoryName(candidatePath);

            Console.WriteLine("=== BRIMSTONE REFLECTION LOAD ===");
            var thirdparty = Assembly.LoadFrom(candidatePath);
            var folderTypeType = FindTypeInDirectory(bin, "ASC.Files.Core.FolderType");
            Require(folderTypeType != null, "ASC.Files.Core.FolderType could not be resolved from staged WebStudio assemblies");
            var folderType = Enum.Parse(folderTypeType, "USER");

            var providerType = thirdparty.GetType("ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudProviderInfo", true);
            var selectorType = thirdparty.GetType("ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudDaoSelector", true);
            var infoType = thirdparty.GetType("ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudDaoSelector+BrimstoneMegaCloudInfo", true);
            var folderDaoType = thirdparty.GetType("ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudFolderDao", true);
            var fileDaoType = thirdparty.GetType("ASC.Files.Thirdparty.BrimstoneMegaCloud.BrimstoneMegaCloudFileDao", true);

            var provider = Activator.CreateInstance(
                providerType,
                new object[] {
                    ProviderId,
                    "BrimstoneMegaCloud",
                    "Brimstone MEGA Cloud Smoke",
                    slot,
                    Guid.NewGuid(),
                    folderType,
                    DateTime.UtcNow
                });
            Console.WriteLine("PASS: BrimstoneMegaCloudProviderInfo instantiated");

            var checkAccess = providerType.GetMethod("CheckAccess", BindingFlags.Instance | BindingFlags.Public);
            Require(checkAccess != null, "CheckAccess missing");
            Require((bool)checkAccess.Invoke(provider, null), "ProviderInfo.CheckAccess returned false");
            Console.WriteLine("PASS: ProviderInfo.CheckAccess resumed copied MEGA session and browsed root");

            var rootId = Convert.ToString(Property(provider, "RootFolderId"), CultureInfo.InvariantCulture);
            Require(rootId == ExpectedPrefix, "unexpected root provider ID: " + rootId);
            Console.WriteLine("PASS: root ID = " + rootId);

            var selector = Activator.CreateInstance(selectorType, true);
            var info = Activator.CreateInstance(infoType, true);
            SetProperty(info, "ProviderInfo", provider);
            SetProperty(info, "Handle", string.Empty);
            SetProperty(info, "IdPrefix", rootId);

            var folderDao = Activator.CreateInstance(
                folderDaoType,
                BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic,
                null,
                new object[] { info, selector },
                CultureInfo.InvariantCulture);
            var fileDao = Activator.CreateInstance(
                fileDaoType,
                BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic,
                null,
                new object[] { info, selector },
                CultureInfo.InvariantCulture);
            Console.WriteLine("PASS: read-only folder and file DAOs instantiated");

            var getCloudItems = FindInstanceMethod(folderDaoType, "GetCloudItems", typeof(object));
            var makeId = FindInstanceMethod(folderDaoType, "MakeId", typeof(string));
            var convertId = FindInstanceMethod(selectorType, "ConvertId", typeof(object));

            Console.WriteLine("=== BRIMSTONE ROOT DAO TRANSPORT BROWSE ===");
            var rootEntries = Objects(getCloudItems.Invoke(folderDao, new object[] { rootId }));
            Require(rootEntries.Count > 0, "root DAO transport returned no entries");

            object selectedFolder = null;
            string selectedHandle = null;
            string selectedExternalId = null;

            foreach (var entry in rootEntries)
            {
                var handle = Convert.ToString(Property(entry, "Handle"), CultureInfo.InvariantCulture);
                var parent = Convert.ToString(Property(entry, "ParentHandle"), CultureInfo.InvariantCulture);
                var name = Convert.ToString(Property(entry, "Name"), CultureInfo.InvariantCulture);
                var isFolder = BoolProperty(entry, "IsFolder");
                var isFile = BoolProperty(entry, "IsFile");
                Require(!string.IsNullOrEmpty(handle), "root entry has empty MEGA handle");
                Require(string.IsNullOrEmpty(parent), "root entry has unexpected parent handle");
                Require(isFolder || isFile, "root entry has unsupported MEGA type");

                var externalId = Convert.ToString(makeId.Invoke(folderDao, new object[] { handle }), CultureInfo.InvariantCulture);
                Require(externalId.StartsWith(ExpectedPrefix + "-", StringComparison.Ordinal), "root entry ID is outside Brimstone handle namespace");
                Require(Convert.ToString(convertId.Invoke(selector, new object[] { externalId }), CultureInfo.InvariantCulture) == handle,
                        "selector did not round-trip Brimstone external ID to MEGA handle");

                Console.WriteLine((isFolder ? "FOLDER: " : "FILE:   ") + name + " | H:" + handle + " | " + externalId);

                if (selectedFolder == null && isFolder)
                {
                    selectedFolder = entry;
                    selectedHandle = handle;
                    selectedExternalId = externalId;
                }
            }
            Require(selectedFolder != null, "root DAO transport returned no folder to use for nested handle browse");
            Console.WriteLine("PASS: root DAO transport returned " + rootEntries.Count + " handle-native entrie(s)");

            Console.WriteLine("=== BRIMSTONE HANDLE-NATIVE NESTED DAO TRANSPORT BROWSE ===");
            Console.WriteLine("selected root folder: " + Convert.ToString(Property(selectedFolder, "Name"), CultureInfo.InvariantCulture));
            var childEntries = Objects(getCloudItems.Invoke(folderDao, new object[] { selectedExternalId }));
            Require(childEntries.Count > 0, "nested DAO transport returned no entries");

            string firstFolderName = null;
            string firstFileName = null;
            foreach (var entry in childEntries)
            {
                var handle = Convert.ToString(Property(entry, "Handle"), CultureInfo.InvariantCulture);
                var parent = Convert.ToString(Property(entry, "ParentHandle"), CultureInfo.InvariantCulture);
                var name = Convert.ToString(Property(entry, "Name"), CultureInfo.InvariantCulture);
                var isFolder = BoolProperty(entry, "IsFolder");
                var isFile = BoolProperty(entry, "IsFile");
                Require(parent == selectedHandle, "nested entry parent handle mismatch");
                Require(isFolder || isFile, "nested entry has unsupported MEGA type");

                var externalId = Convert.ToString(makeId.Invoke(folderDao, new object[] { handle }), CultureInfo.InvariantCulture);
                Require(externalId.StartsWith(ExpectedPrefix + "-", StringComparison.Ordinal), "nested entry ID is outside Brimstone handle namespace");
                Require(Convert.ToString(convertId.Invoke(selector, new object[] { externalId }), CultureInfo.InvariantCulture) == handle,
                        "nested selector ID round-trip failed");

                Console.WriteLine((isFolder ? "FOLDER: " : "FILE:   ") + name + " | H:" + handle + " | " + externalId);
                if (isFolder && firstFolderName == null) firstFolderName = name;
                if (isFile && firstFileName == null) firstFileName = name;
            }
            Console.WriteLine("PASS: nested DAO transport returned " + childEntries.Count + " handle-native entrie(s)");

            // Exercise the concrete folder/file DAOs without projecting to
            // ONLYOFFICE Folder/File objects (which requires CoreContext tenant
            // bootstrap in a real WebStudio process).
            if (firstFolderName != null)
            {
                var folderExists = folderDaoType.GetMethod("IsExist", new Type[] { typeof(string), typeof(string) });
                Require(folderExists != null, "FolderDao.IsExist missing");
                Require((bool)folderExists.Invoke(folderDao, new object[] { firstFolderName, selectedExternalId }),
                        "FolderDao.IsExist failed for known MEGA child folder");
                Console.WriteLine("PASS: concrete FolderDao.IsExist resolved known nested folder");
            }

            if (firstFileName != null)
            {
                var fileExists = fileDaoType.GetMethod("IsExist", new Type[] { typeof(string), typeof(object) });
                Require(fileExists != null, "FileDao.IsExist missing");
                Require((bool)fileExists.Invoke(fileDao, new object[] { firstFileName, selectedExternalId }),
                        "FileDao.IsExist failed for known MEGA child file");
                Console.WriteLine("PASS: concrete FileDao.IsExist resolved known nested file");
            }

            var disposable1 = folderDao as IDisposable;
            var disposable2 = fileDao as IDisposable;
            var disposable3 = provider as IDisposable;
            if (disposable1 != null) disposable1.Dispose();
            if (disposable2 != null) disposable2.Dispose();
            if (disposable3 != null) disposable3.Dispose();

            Console.WriteLine("BRIMSTONE: ProviderInfo -> DAO transport/identity -> handle-native MEGA browse PASS");
            Console.WriteLine("NOTE: ONLYOFFICE Folder/File projection intentionally deferred to live tenant-context test");
            return 0;
        }
        catch (TargetInvocationException ex)
        {
            Console.Error.WriteLine(ex.InnerException == null ? ex.ToString() : ex.InnerException.ToString());
            return 1;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.ToString());
            return 1;
        }
    }
}
CS

    echo
    echo "=== RUN DISPOSABLE PROVIDER/DAO TRANSPORT SMOKE ==="
    docker run --rm \
        --entrypoint /bin/bash \
        -v "$ROOT:/work" \
        -e BRIMSTONE_MEGA_CLOUD_ENGINE_PREFIX=/work/build/mega-cloud-v0.001cc/megacmd-prefix \
        -e BRIMSTONE_MEGA_CLOUD_STATE_ROOT=/work/build/brimstone-v0.002cc-runtime-smoke/state \
        "$IMAGE" -lc '
set -Eeuo pipefail
SMOKE=/work/build/brimstone-v0.002cc-runtime-smoke
BIN=/work/build/communityserver-v0.002cc-src/web/studio/ASC.Web.Studio/bin
CANDIDATE="$BIN/ASC.Files.Thirdparty.dll"
command -v mcs >/dev/null 2>&1 || { echo "BRIMSTONE FAIL: mcs missing from exact CommunityServer image" >&2; exit 1; }
export MONO_PATH="$BIN"
mcs -optimize+ -out:"$SMOKE/BrimstoneMegaCloudRuntimeSmoke.exe" "$SMOKE/BrimstoneMegaCloudRuntimeSmoke.cs"
mono "$SMOKE/BrimstoneMegaCloudRuntimeSmoke.exe" "$CANDIDATE" "'"$slot"'"
'

    echo
    echo "=== BRIMSTONE v0.002cc DISPOSABLE TRANSPORT SMOKE PASS ==="
    echo "candidate:           $(sha256sum "$CANDIDATE" | awk '{print $1}')"
    echo "database:            NOT TOUCHED"
    echo "live stack:          NOT MODIFIED"
}

main "${1:-test1}"
