// BRIMSTONE CUSTOM CODE.
// v0.001cc: isolated proof of the official MEGA SDK authentication/session/root-node lifecycle.
// This probe deliberately does not contain ONLYOFFICE integration code and never prints passwords
// or MEGA session keys. A successful session is written only to a caller-selected 0600 file.

#include <megaapi.h>

#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#if defined(__unix__) || defined(__APPLE__)
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace BrimstoneMegaCloud
{

using namespace mega;

static const char* const kDefaultUserAgent = "BrimstoneMegaCloud/0.001cc";
static const std::chrono::seconds kRequestTimeout(90);

class BrimstoneRequestWaiter final : public MegaRequestListener
{
public:
    void onRequestFinish(MegaApi*, MegaRequest*, MegaError* error) override
    {
        std::lock_guard<std::mutex> lock(mutex_);
        errorCode_ = error ? error->getErrorCode() : -1;
        errorText_ = error && error->getErrorString() ? error->getErrorString() : "Unknown MEGA SDK error";
        finished_ = true;
        condition_.notify_all();
    }

    bool Wait(std::chrono::seconds timeout)
    {
        std::unique_lock<std::mutex> lock(mutex_);
        return condition_.wait_for(lock, timeout, [this]() { return finished_; });
    }

    int ErrorCode() const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return errorCode_;
    }

    std::string ErrorText() const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return errorText_;
    }

private:
    mutable std::mutex mutex_;
    std::condition_variable condition_;
    bool finished_ = false;
    int errorCode_ = -1;
    std::string errorText_;
};

std::string GetEnv(const char* name, bool required)
{
    const char* value = std::getenv(name);
    if (value && *value)
    {
        return std::string(value);
    }
    if (required)
    {
        throw std::runtime_error(std::string("Missing required environment variable: ") + name);
    }
    return std::string();
}

std::string JsonEscape(const std::string& value)
{
    std::ostringstream output;
    for (unsigned char c : value)
    {
        switch (c)
        {
            case '"': output << "\\\""; break;
            case '\\': output << "\\\\"; break;
            case '\b': output << "\\b"; break;
            case '\f': output << "\\f"; break;
            case '\n': output << "\\n"; break;
            case '\r': output << "\\r"; break;
            case '\t': output << "\\t"; break;
            default:
                if (c < 0x20)
                {
                    output << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                           << static_cast<unsigned int>(c) << std::dec;
                }
                else
                {
                    output << static_cast<char>(c);
                }
        }
    }
    return output.str();
}

std::string HandleText(MegaHandle handle)
{
    std::ostringstream output;
    output << std::hex << std::setw(16) << std::setfill('0') << handle;
    return output.str();
}

std::string ErrorSymbol(int code)
{
    switch (code)
    {
        case MegaError::API_EMFAREQUIRED: return "MFA_REQUIRED";
        case MegaError::API_EAPPKEY: return "APP_KEY_INVALID";
        case MegaError::API_EACCESS: return "ACCESS_DENIED";
        case MegaError::API_ENOENT: return "NOT_FOUND";
        case MegaError::API_EOVERQUOTA: return "OVER_QUOTA";
        default: return "MEGA_API_ERROR";
    }
}

void EmitError(const std::string& stage, int code, const std::string& text)
{
    std::cout << "{\"ok\":false,\"stage\":\"" << JsonEscape(stage)
              << "\",\"code\":" << code
              << ",\"symbol\":\"" << ErrorSymbol(code)
              << "\",\"error\":\"" << JsonEscape(text) << "\"}" << std::endl;
}

void EmitLocalError(const std::string& stage, const std::string& text)
{
    std::cout << "{\"ok\":false,\"stage\":\"" << JsonEscape(stage)
              << "\",\"code\":null,\"symbol\":\"BRIMSTONE_LOCAL_ERROR\",\"error\":\""
              << JsonEscape(text) << "\"}" << std::endl;
}

std::string ReadSessionFile(const std::filesystem::path& path)
{
    std::ifstream input(path, std::ios::binary);
    if (!input)
    {
        throw std::runtime_error("Unable to open Brimstone MEGA session file: " + path.string());
    }
    std::ostringstream buffer;
    buffer << input.rdbuf();
    std::string session = buffer.str();
    if (session.empty())
    {
        throw std::runtime_error("Brimstone MEGA session file is empty: " + path.string());
    }
    return session;
}

void WriteSessionFile(const std::filesystem::path& path, const std::string& session)
{
    if (session.empty())
    {
        throw std::runtime_error("MEGA SDK returned an empty session key");
    }

    if (path.has_parent_path())
    {
        std::filesystem::create_directories(path.parent_path());
    }

    {
        std::ofstream output(path, std::ios::binary | std::ios::trunc);
        if (!output)
        {
            throw std::runtime_error("Unable to create Brimstone MEGA session file: " + path.string());
        }
        output.write(session.data(), static_cast<std::streamsize>(session.size()));
        if (!output)
        {
            throw std::runtime_error("Unable to write Brimstone MEGA session file: " + path.string());
        }
    }

#if defined(__unix__) || defined(__APPLE__)
    if (::chmod(path.c_str(), S_IRUSR | S_IWUSR) != 0)
    {
        throw std::runtime_error("Unable to chmod Brimstone MEGA session file to 0600: " + path.string());
    }
#endif
}

std::string DumpSession(MegaApi& api)
{
    char* rawSession = api.dumpSession();
    if (!rawSession)
    {
        throw std::runtime_error("MEGA SDK dumpSession() returned null");
    }
    std::string session(rawSession);
    delete[] rawSession;
    return session;
}

bool RunRequest(const std::string& stage,
                const std::function<void(BrimstoneRequestWaiter*)>& start,
                int& errorCode,
                std::string& errorText)
{
    BrimstoneRequestWaiter waiter;
    start(&waiter);
    if (!waiter.Wait(kRequestTimeout))
    {
        errorCode = -10001;
        errorText = "Timed out waiting for MEGA SDK request completion";
        return false;
    }

    errorCode = waiter.ErrorCode();
    errorText = waiter.ErrorText();
    if (errorCode != MegaError::API_OK)
    {
        return false;
    }
    return true;
}

void EmitRoot(MegaApi& api, const std::string& mode, bool sessionSaved)
{
    MegaNode* root = api.getRootNode();
    if (!root)
    {
        throw std::runtime_error("MEGA SDK getRootNode() returned null after successful fetchNodes()");
    }

    MegaNodeList* children = api.getChildren(root);
    if (!children)
    {
        delete root;
        throw std::runtime_error("MEGA SDK getChildren(root) returned null");
    }

    std::cout << "{\"ok\":true,\"mode\":\"" << JsonEscape(mode)
              << "\",\"session_saved\":" << (sessionSaved ? "true" : "false")
              << ",\"root_handle\":\"" << HandleText(root->getHandle())
              << "\",\"children\":[";

    for (int i = 0; i < children->size(); ++i)
    {
        MegaNode* node = children->get(i);
        if (!node)
        {
            continue;
        }

        if (i > 0)
        {
            std::cout << ',';
        }

        const char* rawName = node->getName();
        const std::string name = rawName ? rawName : std::string();
        const bool isFile = node->isFile();
        const bool isFolder = node->isFolder();
        const int64_t size = isFile ? node->getSize() : 0;
        const int64_t mtime = isFile ? node->getModificationTime() : 0;

        std::cout << "{\"handle\":\"" << HandleText(node->getHandle())
                  << "\",\"type\":\"" << (isFile ? "file" : (isFolder ? "folder" : "other"))
                  << "\",\"name\":\"" << JsonEscape(name)
                  << "\",\"size\":" << size
                  << ",\"mtime\":" << mtime << '}';
    }

    std::cout << "]}" << std::endl;

    delete children;
    delete root;
}

int Run(const std::string& mode)
{
#if defined(__unix__) || defined(__APPLE__)
    ::umask(0077);
#endif

    const std::string appKey = GetEnv("BRIMSTONE_MEGA_APP_KEY", true);
    const std::string configuredAgent = GetEnv("BRIMSTONE_MEGA_USER_AGENT", false);
    const std::string userAgent = configuredAgent.empty() ? kDefaultUserAgent : configuredAgent;
    const std::string cacheValue = GetEnv("BRIMSTONE_MEGA_CACHE_DIR", true);
    const std::string sessionValue = GetEnv("BRIMSTONE_MEGA_SESSION_FILE", true);

    const std::filesystem::path cacheDir(cacheValue);
    const std::filesystem::path sessionFile(sessionValue);
    std::filesystem::create_directories(cacheDir);

    MegaApi::setLogLevel(MegaApi::LOG_LEVEL_ERROR);
    MegaApi api(appKey.c_str(), cacheDir.c_str(), userAgent.c_str());

    int errorCode = 0;
    std::string errorText;

    if (mode == "auth-root")
    {
        const std::string email = GetEnv("BRIMSTONE_MEGA_EMAIL", true);
        const std::string password = GetEnv("BRIMSTONE_MEGA_PASSWORD", true);
        const std::string mfa = GetEnv("BRIMSTONE_MEGA_MFA", false);

        const bool loginOk = RunRequest(
            "login",
            [&](BrimstoneRequestWaiter* listener)
            {
                if (mfa.empty())
                {
                    api.login(email.c_str(), password.c_str(), listener);
                }
                else
                {
                    api.multiFactorAuthLogin(email.c_str(), password.c_str(), mfa.c_str(), listener);
                }
            },
            errorCode,
            errorText);

        if (!loginOk)
        {
            EmitError("login", errorCode, errorText);
            return errorCode == MegaError::API_EMFAREQUIRED ? 26 : 3;
        }
    }
    else if (mode == "resume-root")
    {
        const std::string session = ReadSessionFile(sessionFile);
        const bool loginOk = RunRequest(
            "fast-login",
            [&](BrimstoneRequestWaiter* listener)
            {
                api.fastLogin(session.c_str(), listener);
            },
            errorCode,
            errorText);

        if (!loginOk)
        {
            EmitError("fast-login", errorCode, errorText);
            return 4;
        }
    }
    else
    {
        throw std::runtime_error("Unknown mode. Use auth-root or resume-root");
    }

    const bool fetchOk = RunRequest(
        "fetch-nodes",
        [&](BrimstoneRequestWaiter* listener)
        {
            api.fetchNodes(listener);
        },
        errorCode,
        errorText);

    if (!fetchOk)
    {
        EmitError("fetch-nodes", errorCode, errorText);
        return 5;
    }

    const std::string refreshedSession = DumpSession(api);
    WriteSessionFile(sessionFile, refreshedSession);
    EmitRoot(api, mode, true);
    return 0;
}

} // namespace BrimstoneMegaCloud

int main(int argc, char** argv)
{
    try
    {
        if (argc != 2)
        {
            BrimstoneMegaCloud::EmitLocalError("arguments", "Usage: brimstone-mega-cloud-probe <auth-root|resume-root>");
            return 2;
        }
        return BrimstoneMegaCloud::Run(argv[1]);
    }
    catch (const std::exception& exception)
    {
        BrimstoneMegaCloud::EmitLocalError("exception", exception.what());
        return 10;
    }
    catch (...)
    {
        BrimstoneMegaCloud::EmitLocalError("exception", "Unknown native exception");
        return 11;
    }
}
