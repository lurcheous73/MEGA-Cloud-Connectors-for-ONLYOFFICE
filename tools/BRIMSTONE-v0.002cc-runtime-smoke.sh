#!/usr/bin/env bash
# BRIMSTONE CUSTOM CODE — v0.002cc disposable runtime smoke test.
# Proves ProviderInfo -> read-only DAO -> pinned MEGAcmd using a COPY of an
# already-authenticated provider slot. It never installs the candidate DLL,
# writes the ONLYOFFICE database, or mutates the original MEGA session state.
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
HARNESS_EXE="$SMOKE_ROOT/BrimstoneMegaCloudRuntimeSmoke.exe"

fail(){ echo "BRIMSTONE FAIL: $*" >&2; exit 1; }

validate_slot(){
    local slot="${1:-test1}"
    [[ "$slot" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || fail "slot must contain only letters, digits, underscore or hyphen (max 32 chars)"
    printf '%s' "$slot"
}

live_hash(){
    docker exec "$LIVE_CONTAINER" sha256sum "$LIVE_DLL" | awk '{print $1}'
}

main(){
    local slot
    slot="$(validate_slot "${1:-test1}")"
    local source_slot="$SOURCE_STATE_ROOT/$slot"
    local source_session="$source_slot/home/.megaCmd/session"

    echo "=== BRIMSTONE MEGA CLOUD v0.002cc DISPOSABLE RUNTIME SMOKE ==="
    [[ -d "$ROOT/.git" ]] || fail "connector repository missing"
    [[ "$(git -C "$ROOT" branch --show-current)" == "$BRANCH" ]] || fail "expected branch $BRANCH"
    [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]] || fail "connector repository is dirty"
    [[ -x "$COMPILE_GATE" || -s "$COMPILE_GATE" ]] || fail "compile-only gate missing"
    [[ -x "$ENGINE/usr/bin/mega-exec" ]] || fail "pinned MEGAcmd engine missing"
    [[ -s "$source_session" ]] || fail "saved source session missing for slot $slot"
    docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "required image not local: $IMAGE"
    docker inspect "$LIVE_CONTAINER" >/dev/null 2>&1 || fail "CommunityServer container missing"

    local live_before session_before
    live_before="$(live_hash)"
    session_before="$(sha256sum "$source_session" | awk '{print $1}')"

    echo "branch:             $(git -C "$ROOT" branch --show-current)"
    echo "head:               $(git -C "$ROOT" rev-parse HEAD)"
    echo "source slot:        $slot"
    echo "source session:     READ ONLY / COPIED"
    echo "live DLL before:    $live_before"
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
using System.Linq;
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

    private static MethodInfo OneObjectArgumentMethod(Type type, string name)
    {
        foreach (var method in type.GetMethods(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic))
        {
            if (method.Name != name) continue;
            var p = method.GetParameters();
            if (p.Length == 1 && p[0].ParameterType == typeof(object)) return method;
        }
        throw new MissingMethodException(type.FullName, name + "(object)");
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
                // Some optional WebStudio assemblies have load-time dependencies
                // irrelevant to this smoke test. Keep looking for the exact type.
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

            var getFolders = OneObjectArgumentMethod(folderDaoType, "GetFolders");
            var getFiles = OneObjectArgumentMethod(fileDaoType, "GetFiles");

            Console.WriteLine("=== BRIMSTONE ROOT DAO BROWSE ===");
            var rootFolders = Objects(getFolders.Invoke(folderDao, new object[] { rootId }));
            Require(rootFolders.Count > 0, "root DAO browse returned no folders");
            foreach (var folder in rootFolders)
            {
                var title = Convert.ToString(Property(folder, "Title"), CultureInfo.InvariantCulture);
                var id = Convert.ToString(Property(folder, "ID"), CultureInfo.InvariantCulture);
                var providerId = Convert.ToInt32(Property(folder, "ProviderId"), CultureInfo.InvariantCulture);
                Require(id.StartsWith(ExpectedPrefix + "-", StringComparison.Ordinal), "folder ID is outside Brimstone handle namespace");
                Require(providerId == ProviderId, "folder ProviderId mismatch");
                Console.WriteLine("FOLDER: " + title + " | " + id);
            }
            Console.WriteLine("PASS: root DAO returned " + rootFolders.Count + " handle-native folder(s)");

            object selected = null;
            List<object> selectedFolders = null;
            List<object> selectedFiles = null;

            foreach (var folder in rootFolders)
            {
                var id = Property(folder, "ID");
                var childFolders = Objects(getFolders.Invoke(folderDao, new object[] { id }));
                var childFiles = Objects(getFiles.Invoke(fileDao, new object[] { id }));
                if (childFolders.Count + childFiles.Count > 0)
                {
                    selected = folder;
                    selectedFolders = childFolders;
                    selectedFiles = childFiles;
                    break;
                }
            }

            Require(selected != null, "no root folder exposed any nested DAO entries");
            Console.WriteLine("=== BRIMSTONE HANDLE-NATIVE SUBFOLDER DAO BROWSE ===");
            Console.WriteLine("selected root folder: " + Convert.ToString(Property(selected, "Title"), CultureInfo.InvariantCulture));
            foreach (var folder in selectedFolders)
            {
                var title = Convert.ToString(Property(folder, "Title"), CultureInfo.InvariantCulture);
                var id = Convert.ToString(Property(folder, "ID"), CultureInfo.InvariantCulture);
                Require(id.StartsWith(ExpectedPrefix + "-", StringComparison.Ordinal), "nested folder ID is outside Brimstone handle namespace");
                Console.WriteLine("FOLDER: " + title + " | " + id);
            }
            foreach (var file in selectedFiles)
            {
                var title = Convert.ToString(Property(file, "Title"), CultureInfo.InvariantCulture);
                var id = Convert.ToString(Property(file, "ID"), CultureInfo.InvariantCulture);
                Require(id.StartsWith(ExpectedPrefix + "-", StringComparison.Ordinal), "file ID is outside Brimstone handle namespace");
                Console.WriteLine("FILE:   " + title + " | " + id);
            }
            Require(selectedFolders.Count + selectedFiles.Count > 0, "nested browse returned no entries");
            Console.WriteLine("PASS: nested DAO browse returned " + selectedFolders.Count + " folder(s) and " + selectedFiles.Count + " file(s)");

            var disposable1 = folderDao as IDisposable;
            var disposable2 = fileDao as IDisposable;
            var disposable3 = provider as IDisposable;
            if (disposable1 != null) disposable1.Dispose();
            if (disposable2 != null) disposable2.Dispose();
            if (disposable3 != null) disposable3.Dispose();

            Console.WriteLine("BRIMSTONE: ProviderInfo -> DAO -> handle-native MEGA browse PASS");
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
    echo "=== RUN DISPOSABLE PROVIDER/DAO SMOKE ==="
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

    local live_after session_after
    live_after="$(live_hash)"
    session_after="$(sha256sum "$source_session" | awk '{print $1}')"
    [[ "$live_after" == "$live_before" ]] || fail "live ASC.Files.Thirdparty.dll changed during disposable smoke"
    [[ "$session_after" == "$session_before" ]] || fail "original saved MEGA session changed during disposable smoke"

    echo
    echo "=== BRIMSTONE v0.002cc RUNTIME SMOKE PASS ==="
    echo "candidate:           $(sha256sum "$CANDIDATE" | awk '{print $1}')"
    echo "live DLL before:     $live_before"
    echo "live DLL after:      $live_after"
    echo "source session hash: $session_after"
    echo "original session:    NOT MODIFIED"
    echo "database:            NOT TOUCHED"
    echo "live stack:          NOT MODIFIED"
}

main "${1:-test1}"
