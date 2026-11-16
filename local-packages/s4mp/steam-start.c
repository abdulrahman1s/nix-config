/* The launcher starts this helper after preparing its normal multiplayer files.
 * Its Linux supervisor then starts the real, unmodified game through Steam. */
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <shellapi.h>

static wchar_t directory[32768], pending[32768];

static void append(wchar_t *destination, const wchar_t *source) {
    while (*destination) ++destination;
    while ((*destination++ = *source++)) {}
}

static DWORD string_length(const wchar_t *string) {
    DWORD length = 0;
    while (string[length]) ++length;
    return length;
}

static BOOL write_bytes(HANDLE file, const void *data, DWORD size) {
    DWORD written;
    return WriteFile(file, data, size, &written, NULL) && written == size;
}

static int start(void) {
    DWORD length = GetEnvironmentVariableW(L"LOCALAPPDATA", directory, 32000);
    if (!length || length >= 32000) return 1;
    append(directory, L"\\com.s4mp.launcher\\steam-start");
    CreateDirectoryW(directory, NULL);
    append(pending, directory);
    append(pending, L"\\request.tmp");
    HANDLE file = CreateFileW(pending, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 2;
    int argc;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    DWORD count = argc > 0 ? (DWORD)argc - 1 : 0;
    BOOL ok = argv && count <= 128 && write_bytes(file, "S4MP", 4)
              && write_bytes(file, &count, sizeof(count));
    for (DWORD i = 0; ok && i < count; ++i) {
        DWORD size = string_length(argv[i + 1]) * sizeof(wchar_t);
        ok = size <= 65536 && write_bytes(file, &size, sizeof(size))
             && write_bytes(file, argv[i + 1], size);
    }
    if (argv) LocalFree(argv);
    FlushFileBuffers(file);
    CloseHandle(file);
    append(directory, L"\\request");
    if (ok) ok = MoveFileExW(pending, directory,
                             MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    if (!ok) { DeleteFileW(pending); return 3; }
    for (int i = 0; i < 150; ++i) {
        if (GetFileAttributesW(directory) == INVALID_FILE_ATTRIBUTES) return 0;
        Sleep(100);
    }
    MessageBoxW(NULL, L"Open S4MP using the S4MP Early Access application shortcut "
                      L"so its Linux Steam launch helper is running.",
                L"S4MP Steam launch helper", MB_OK | MB_ICONERROR);
    return 4;
}

void WINAPI entry(void) {
    ExitProcess(start());
}
