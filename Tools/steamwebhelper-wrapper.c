#define UNICODE
#define _UNICODE
#include <windows.h>
#include <stdlib.h>
#include <wchar.h>

static const wchar_t *tail_args(void) {
    const wchar_t *p = GetCommandLineW();
    int quoted = 0;
    while (*p) {
        if (*p == L'"') quoted = !quoted;
        else if (*p == L' ' && !quoted) break;
        ++p;
    }
    while (*p == L' ') ++p;
    return p;
}

int wmain(void) {
    wchar_t self[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, self, MAX_PATH);
    if (!n || n >= MAX_PATH) return 1;

    wchar_t *slash = wcsrchr(self, L'\\');
    if (!slash) return 1;
    *(slash + 1) = 0;

    const wchar_t *realName = L"steamwebhelper_real.exe";
    size_t realCap = wcslen(self) + wcslen(realName) + 1;
    wchar_t *real = calloc(realCap, sizeof(wchar_t));
    if (!real) return 1;
    wcscpy(real, self);
    wcscat(real, realName);

    const wchar_t *flags = L"--disable-gpu --single-process";
    const wchar_t *args = tail_args();
    size_t cmdCap = wcslen(real) + wcslen(flags) + wcslen(args) + 8;
    wchar_t *cmd = calloc(cmdCap, sizeof(wchar_t));
    if (!cmd) { free(real); return 1; }
    _snwprintf(cmd, cmdCap, L"\"%ls\" %ls %ls", real, flags, args);

    STARTUPINFOW si = {0};
    PROCESS_INFORMATION pi = {0};
    si.cb = sizeof(si);

    BOOL ok = CreateProcessW(real, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi);
    free(cmd);
    free(real);
    if (!ok) return 1;

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
}
