#pragma once

#include <stdint.h>

#if defined(_WIN32)
#define OOMB_API __declspec(dllexport)
#else
#define OOMB_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Stable C ABI between ONLYOFFICE managed code and the official MEGA C++ SDK.
 *
 * The C++ implementation owns MegaApi and all asynchronous listener objects.
 * Each exported operation presents a bounded synchronous result to P/Invoke.
 * Returned strings are UTF-8 and must be released with oomb_free_string().
 */

typedef struct oomb_context oomb_context;

typedef enum oomb_result {
    OOMB_OK = 0,
    OOMB_ERROR = -1,
    OOMB_AUTH_MFA_REQUIRED = -1001,
    OOMB_AUTH_FAILED = -1002,
    OOMB_NOT_FOUND = -1003,
    OOMB_CONFLICT = -1004,
    OOMB_TIMEOUT = -1005,
    OOMB_CANCELLED = -1006
} oomb_result;

typedef int (*oomb_write_callback)(const uint8_t* data, uint64_t length, void* user_data);

typedef struct oomb_node_info {
    uint64_t handle;
    uint64_t parent_handle;
    int is_folder;
    int64_t size;
    int64_t modified_unix;
    const char* name_utf8;
} oomb_node_info;

/* Lifecycle */
OOMB_API oomb_context* oomb_create(const char* app_key_utf8, const char* user_agent_utf8, const char* sdk_state_dir_utf8);
OOMB_API void oomb_destroy(oomb_context* ctx);
OOMB_API const char* oomb_last_error(oomb_context* ctx);
OOMB_API void oomb_free_string(const char* value);

/* Authentication/session. Passwords are consumed only for the login call. */
OOMB_API int oomb_login(oomb_context* ctx, const char* email_utf8, const char* password_utf8, uint32_t timeout_seconds);
OOMB_API int oomb_login_mfa(oomb_context* ctx, const char* email_utf8, const char* password_utf8, const char* mfa_code_utf8, uint32_t timeout_seconds);
OOMB_API int oomb_fast_login(oomb_context* ctx, const char* session_utf8, uint32_t timeout_seconds);
OOMB_API int oomb_fetch_nodes(oomb_context* ctx, uint32_t timeout_seconds);
OOMB_API const char* oomb_dump_session(oomb_context* ctx);
OOMB_API int oomb_logout(oomb_context* ctx, uint32_t timeout_seconds);

/* Metadata/navigation. JSON list output keeps the ABI stable as metadata evolves. */
OOMB_API uint64_t oomb_root_handle(oomb_context* ctx);
OOMB_API const char* oomb_get_node_json(oomb_context* ctx, uint64_t handle);
OOMB_API const char* oomb_list_children_json(oomb_context* ctx, uint64_t parent_handle);

/* Mutating operations return the resulting node handle where applicable. */
OOMB_API int oomb_create_folder(oomb_context* ctx, uint64_t parent_handle, const char* name_utf8, uint64_t* result_handle, uint32_t timeout_seconds);
OOMB_API int oomb_rename_node(oomb_context* ctx, uint64_t handle, const char* name_utf8, uint32_t timeout_seconds);
OOMB_API int oomb_move_node(oomb_context* ctx, uint64_t handle, uint64_t new_parent_handle, uint32_t timeout_seconds);
OOMB_API int oomb_remove_node(oomb_context* ctx, uint64_t handle, uint32_t timeout_seconds);
OOMB_API int oomb_copy_node(oomb_context* ctx, uint64_t handle, uint64_t new_parent_handle, const char* new_name_utf8, uint64_t* result_handle, uint32_t timeout_seconds);

/*
 * Streaming download uses the MEGA SDK transfer-data callback path and writes
 * directly into the managed ONLYOFFICE response/consumer stream.
 */
OOMB_API int oomb_stream_download(oomb_context* ctx, uint64_t handle, uint64_t offset, oomb_write_callback callback, void* user_data, uint32_t timeout_seconds);

/*
 * Current MEGA SDK uploads are path-oriented. ONLYOFFICE will stage only the
 * single incoming stream to a protected temporary file, call this operation,
 * then immediately remove the staging file. This is not a sync/mirror layer.
 */
OOMB_API int oomb_upload_file(oomb_context* ctx, const char* local_path_utf8, uint64_t parent_handle, const char* remote_name_utf8, uint64_t* result_handle, uint32_t timeout_seconds);
OOMB_API int oomb_replace_file(oomb_context* ctx, const char* local_path_utf8, uint64_t existing_handle, uint64_t* result_handle, uint32_t timeout_seconds);

#ifdef __cplusplus
}
#endif
