// SPDX-License-Identifier: GPL-3.0-only
#ifndef SCRCPY_TERMLOG_H
#define SCRCPY_TERMLOG_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TermLogCore TermLogCore;
// Calls for a handle must be serialized on one worker queue, never the UI thread.
// The host sets ADB to its bundled executable before creating a handle.
TermLogCore *termlog_create(const char *serial, char **error_json);
char *termlog_request(TermLogCore *core, const char *request_json);
void termlog_free_string(char *value);
void termlog_destroy(TermLogCore *core);

#ifdef __cplusplus
}
#endif
#endif
