/*************************************************************
 * ShimWimlib WinRE Native Wrapper
 * ----------------------------------------------------------------------------
 * A minimal C/C++ DLL that wraps wimlib (libwim-15.dll) behind a very simple,
 * AutoIt-friendly API: create/capture/apply WIM images with progress polling.
 *
 * Target environment: WinRE / minimal Windows PE where PowerShell & full .NET
 * are unavailable. AutoIt can load this DLL via DllOpen/DllCall.
 *
 * Build: Visual Studio 2022, x64 (or x86 if your WinRE is 32-bit) Dynamic DLL.
 * Requires wimlib headers + import lib (libwim.lib) or we load the DLL at runtime.
 *
 * Key exported functions (flat, C ABI, __stdcall for AutoIt convenience):
 *   int   __stdcall Wim_Init(void);
 *   int   __stdcall Wim_Shutdown(void);
 *
 *   * Asynchronous capture of a directory tree to a WIM file.
 *   * Returns >=0 task handle; <0 error.
 *   int   __stdcall Wim_BeginCapture(const wchar_t *srcPath, const wchar_t *destWim,
 *                                    const wchar_t *imageName, int compressionType); // -1=default
 *
 *   * Asynchronous apply(extract) of a WIM image to a directory.
 *   int   __stdcall Wim_BeginApply(const wchar_t* srcWim, int imageIndex,
 *                                  const wchar_t* destPath);
 *
 *   * Poll progress.All time values in seconds.
 *   * percent: 0 - 100 (may exceed 100 briefly if lib reports > total; clamp)
 *   * elapsed : seconds since task start
 *   * remaining : simple ETA based on linear extrapolation; -1 unknown
 *   * state: 0 = pending, 1 = running, 2 = success, 3 = error, 4 = aborted
 *   * wimErr : last wimlib error code(0 if none)
 *   int   __stdcall Wim_GetProgress(int taskHandle,
 *                                   int* percent, int* elapsed, int* remaining,
 *                                   int* state, int* wimErr);
 *
 *   * Request cancel.Returns 0 success.
 *   int   __stdcall Wim_Cancel(int taskHandle);
 *
 *   * Retrieve last error string for completed / errored task.
 *   * buffer receives UTF - 16 text; cchBuffer includes NUL.
 *   int   __stdcall Wim_GetLastErrorText(int taskHandle, wchar_t* buffer, int cchBuffer);
 *
 * ----------------------------------------------------------------------------
 * IMPLEMENTATION NOTES
 * ----------------------------------------------------------------------------
 * 1. Thread per task : We spawn a worker thread that performs the wimlib call.
 *    Progress callback from wimlib updates an atomic snapshot stored in TASK.
 * 2. Simple handle table : fixed - size array(adjust TASK_MAX) indexed by int.
 * 3. Timing : we collect start tick(GetTickCount64).ETA derived from reported
 *    bytes processed / total bytes(when available) OR from percent.
 * 4. Unicode : wimlib on Windows is built with wimlib_tchar == wchar_t; we pass
 *    wide strings directly.If your build differs, add conversion.
 * 5. Error handling : we capture first non - zero wimlib error in the TASK record.
 * 6. Cancel : we set TASK.cancelRequested; progress callback returns non - zero to
 *    abort operation(wimlib honours abort if callback returns WIMLIB_PROGRESS_STATUS_ABORT).
 *
 * ----------------------------------------------------------------------------
 * LICENSE REMINDER
 * ----------------------------------------------------------------------------
 * This shim merely wraps GPLv3 / LGPLv3 wimlib.If you distribute binaries that
 * statically link or bundle libwim, you must comply with the relevant license.
 * If you dynamically ship libwim - 15.dll unchanged, you must still provide access
 * to the corresponding source and license texts.Consult legal if in doubt.
 *
 * ----------------------------------------------------------------------------
 * QUICK START(see bottom of file for full step - by - step Visual Studio guide)
 * ----------------------------------------------------------------------------
 * 1. Build wimlib for WinRE arch(or obtain prebuilt libwim - 15.dll + libwim.lib).
 * 2. Create VS DLL project; add this file + wimlib include / lib paths.
 * 3. Build ShimWimlib.dll.
 * 4. Copy ShimWimlib.dll + libwim - 15.dll into same folder as AutoIt exe.
 * 5. In AutoIt : DllOpen("ShimWimlib.dll"); call Wim_Init(); Wim_BeginCapture(...);
 * 6. Poll Wim_GetProgress() until state >= 2.
 *
 * ----------------------------------------------------------------------------
 * CAPTURE / APPEND (nom & description) :
 *   - Si imageName == NULL ou vide => derive automatiquement depuis srcDir.
 *   - Si imageDesc == NULL ou vide => "Captured from <basename>".
 *   - Pour Append : même logique; on ajoute une image dans un WIM
 *     existant (RW). Compression/chunk forcés seulement si CompressionType >= 0.
 *
 * NOTE COMPRESSION À L’APPEND :
 *   - CompressionType == -1 : ne touche pas aux réglages d’écriture; image ajoutée
 *     avec compression héritée de la session actuelle (celle du WIM).
 *   - CompressionType >= 0  : on tente wimlib_set_output_compression_type().
 *   - Pour réellement recalculer les flux existants, l’appelant doit
 *     inclure WIMLIB_WRITE_FLAG_RECOMPRESS (et éventuellement REBUILD).
 *************************************************************/

#include <windows.h>
#include <wchar.h>
#include <time.h>
//#include <math.h>       // Vraiment nécessaire pour mon code ?
#include <stdint.h>
#include <process.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include "wimlib.h"
#include "WimShim.h"


/* ================================================================== */
/*  GLOBALS variables                                                 */
/* ================================================================== */
/*  General                                                           */
static time_t g_StartTime = 0;
static time_t g_PhaseStartTime = 0;

static HANDLE  g_hThread = NULL;
static volatile LONG g_ThreadCount = 0;
static volatile LONG g_Phase = 0;
static volatile LONG g_Percent = 0;
static volatile LONG g_PercentDecimal = 0;
static volatile LONG g_Elapsed = 0;
static volatile LONG g_Remaining = 0;
static volatile LONG g_returncode = 0;

static volatile LONG g_Flags = 0;
static wchar_t g_SourceFilePath[MAX_PATH * 4];
static wchar_t g_SourceFolderPath[MAX_PATH * 4];
static wchar_t g_DestinationFilePath[MAX_PATH * 4];
static wchar_t g_DestinationFolderPath[MAX_PATH * 4];

static volatile LONG g_total_bytes = 0;
static wchar_t g_total_bytes_Unit[10];
static volatile LONG g_completed_bytes = 0;
static wchar_t g_completed_bytes_Unit[10];
static volatile LONG g_total_streams = 0;
static volatile LONG g_completed_streams = 0;
static volatile LONG g_total_parts = 0;
static volatile LONG g_Cancel = 0;                      /* set by Wim_Cancel, honoured by ProgressCallBack */

/*  Split                                                             */
static volatile LONG g_SplitActive = 0;
static uint64_t g_SplitTotalBytes = 0;
static uint64_t g_SplitDoneBytes = 0;                   /* bytes of the parts already finished */
static uint64_t g_SplitPartSize = 0;

/* Info buffers (not re-entrant; copy if needed)                      */
#define SHIM_MAX_INFO_CHARS   (32 * 1024)
static wchar_t g_InfoBuf[SHIM_MAX_INFO_CHARS];          // reused by Wim_GetImageInfo / Wim_ListImages
static wchar_t g_InfoPropBuf[2048];
static wchar_t* g_XmlBuf = NULL;                        // Wim_GetXml: grown on demand (the XML of a big WIM exceeds 32K chars)
static size_t   g_XmlCap = 0;

/*  Scan                                                              */
static struct wimlib_progress_info_scan g_lastScanProgress;
static wchar_t g_ScanCurrentPath[MAX_PATH * 4];
static volatile LONG g_ScanNbFiles = 0;
static volatile LONG g_ScanNbFolders = 0;
static volatile LONG g_ScanTotalFilesSize = 0;
static wchar_t g_ScanUnit[10];

/*  Append, Capture                                                   */
static wchar_t g_ImageName[512];
static wchar_t g_ImageDesc[1024];
static wchar_t g_CaptureConfig[MAX_PATH * 4];           /* capture configuration file ("" = none), see Wim_SetCaptureConfig */
static volatile LONG g_CompressionType = WIMLIB_COMPRESSION_TYPE_LZX;
static volatile LONG g_CompressionLevel = 50;
static volatile LONG g_ChunkSizeBytes = 0;
static volatile LONG g_AddFlags = 0;
static volatile LONG g_WriteFlags = 0;
static volatile LONG g_completed_parts = 0;
static volatile LONG g_completed_compressed_bytes = 0;

/*  Extract                                                           */
static wchar_t g_ImageId[64];
static volatile LONG g_part_number = 0;
static volatile LONG g_current_file_count = 0;
static volatile LONG g_end_file_count = 0;


 /* ------------------------------------------------------------------ */
 /* Helpers Interlocked                                                */
static __inline LONG atomic_read32(volatile LONG* p) {
    return InterlockedCompareExchange(p, 0, 0);
}
static __inline void atomic_write32(volatile LONG* p, LONG v) {
    InterlockedExchange(p, v);
}

/* Whole-number percent (0 / 100): also resets the decimal scale. */
static __inline void set_percent_int(LONG v) {
    InterlockedExchange(&g_PercentDecimal, 0);
    InterlockedExchange(&g_Percent, v);
}

// Fix typo in wimlib function name (wimlib 1.14.4)
#if defined(HAVE_WIMLIB_SET_IMAGE_DESCRIPTON) || 1
#define wimlib_set_image_description wimlib_set_image_descripton
#endif

/* ------------------------------------------------------------------ */
/* Chunk tables                                                       */
static const uint32_t g_allowed_xpress[] = {
    4u * 1024u, 8u * 1024u, 16u * 1024u, 32u * 1024u, 64u * 1024u,
};
static const uint32_t g_allowed_lzx[] = {
    32u * 1024u, 64u * 1024u, 128u * 1024u, 256u * 1024u,
    512u * 1024u, 1u * 1024u * 1024u, 2u * 1024u * 1024u,
};
static const uint32_t g_allowed_lzms[] = {
    32u * 1024u, 64u * 1024u, 128u * 1024u, 256u * 1024u,
    512u * 1024u, 1u * 1024u * 1024u, 2u * 1024u * 1024u,
    4u * 1024u * 1024u, 8u * 1024u * 1024u, 16u * 1024u * 1024u,
    32u * 1024u * 1024u, 64u * 1024u * 1024u, 128u * 1024u * 1024u,
    256u * 1024u * 1024u, 512u * 1024u * 1024u,
    1u * 1024u * 1024u * 1024u,
};

static uint32_t nearest_allowed(uint32_t req, const uint32_t* tbl, size_t cnt)
{
    if (cnt == 0) return 0;
    if (req <= tbl[0]) return tbl[0];
    if (req >= tbl[cnt - 1]) return tbl[cnt - 1];
    for (size_t i = 1; i < cnt; ++i) {
        if (req == tbl[i]) return tbl[i];
        if (req < tbl[i]) {
            const uint32_t lo = tbl[i - 1];
            const uint32_t hi = tbl[i];
            return ((req - lo) <= (hi - req)) ? lo : hi;
        }
    }
    return tbl[cnt - 1];
}

#ifndef _countof
# define _countof(x) (sizeof(x) / sizeof((x)[0]))
#endif

static uint32_t sanitize_chunk_size(enum wimlib_compression_type CompressionType, uint32_t req)
{
    if (req == 0)
        return 0; /* auto */
    switch (CompressionType) {
    case WIMLIB_COMPRESSION_TYPE_XPRESS:
        return nearest_allowed(req, g_allowed_xpress, _countof(g_allowed_xpress));
    case WIMLIB_COMPRESSION_TYPE_LZX:
        return nearest_allowed(req, g_allowed_lzx, _countof(g_allowed_lzx));
    case WIMLIB_COMPRESSION_TYPE_LZMS:
        return nearest_allowed(req, g_allowed_lzms, _countof(g_allowed_lzms));
    default:
        return 0;
    }
}

/* ------------------------------------------------------------------ */
/* Auto image name / desc                                             */
static void derive_image_name(const wchar_t* srcDir, wchar_t* out, size_t out_cch)
{
    if (!out || out_cch == 0) return;
    out[0] = 0;

    if (srcDir && *srcDir) {
        /* last path component */
        const wchar_t* p = srcDir;
        const wchar_t* last = p;
        while (*p) {
            if (*p == L'\\' || *p == L'/') {
                if (*(p + 1) != 0)
                    last = p + 1;
            }
            ++p;
        }
        if (*last) {
            wcsncpy_s(out, out_cch, last, _TRUNCATE);
            size_t n = wcslen(out);
            while (n > 0 && (out[n - 1] == L'\\' || out[n - 1] == L'/'))
                out[--n] = 0;                               /* "C:\dir\" -> "dir" */
            if (n > 0)
                return;
        }
    }
    /* fallback */
    ULONGLONG tick = GetTickCount64();
    _snwprintf_s(out, out_cch, _TRUNCATE, L"Image_%llu", (unsigned long long)tick);
}

static void derive_image_desc(const wchar_t* srcDir, wchar_t* out, size_t out_cch)
{
    if (!out || out_cch == 0) return;
    wchar_t tmp[260];
    derive_image_name(srcDir, tmp, _countof(tmp));
    _snwprintf_s(out, out_cch, _TRUNCATE, L"Captured from %s", tmp);
}


/* ================================================================== */
/* % helpers                                                          */
/* ================================================================== */
static __inline int percent_from_u64(uint64_t done, uint64_t total)
{
    if (total == 0) return 0;

    LONG nbDecimal;
    // Logique adaptative basée sur la taille du total
    if (total <= 1000000000ULL) { nbDecimal = 0; }        // <= 1 milliard    // Entier
    else if (total <= 10000000000ULL) { nbDecimal = 1; }  // <= 10 milliard   // 1 décimale
    else if (total <= 100000000000ULL) { nbDecimal = 2; } // <= 100 milliards // 2 décimales
    else { nbDecimal = 3; }                               // > 100 milliards  // 3 décimales

    atomic_write32(&g_PercentDecimal, nbDecimal);

    /* The result is scaled by 10^nbDecimal: 100% must be scaled too. */
    if (done >= total) return (int)(100.0 * pow(10.0, (double)nbDecimal) + 0.5);
    double d = ((double)done * 100.0) / (double)total;
    if (d < 0.0) d = 0.0;
    if (d > 100.0) d = 100.0;

    return (int)(d * pow(10.0, (double)nbDecimal) + 0.5);
}

static void shim_wcsncpyz(wchar_t* dst, size_t cap, const wchar_t* src)
{
    if (!dst || cap == 0) return;
    if (!src) {
        dst[0] = L'\0';
        return;
    }
    wcsncpy_s(dst, cap, src, _TRUNCATE);
}

/* Retourne chaîne propriété image; NULL => "" */
static const wchar_t* shim_get_img_prop(
    WIMStruct* Wim,
    int idx,
    const wchar_t* prop)
{
    const wimlib_tchar* p = wimlib_get_image_property(Wim, idx, prop);
    return (const wchar_t*)(p ? p : L"");
}

/* XML time (<PROP><HIGHPART>0x..</HIGHPART><LOWPART>0x..</LOWPART>) -> "YYYY-MM-DD HH:MM:SS" (UTC); "" if absent */
static void shim_get_img_time(WIMStruct* Wim, int idx, const wchar_t* prop, wchar_t* out, size_t out_cch)
{
    wchar_t path[96];
    out[0] = L'\0';

    _snwprintf_s(path, _countof(path), _TRUNCATE, L"%s/HIGHPART", prop);
    const wchar_t* hi = shim_get_img_prop(Wim, idx, path);
    _snwprintf_s(path, _countof(path), _TRUNCATE, L"%s/LOWPART", prop);
    const wchar_t* lo = shim_get_img_prop(Wim, idx, path);
    if (!*hi && !*lo)
        return;

    ULARGE_INTEGER u;
    u.HighPart = (DWORD)wcstoul(hi, NULL, 16);
    u.LowPart = (DWORD)wcstoul(lo, NULL, 16);

    FILETIME ft;
    SYSTEMTIME st;
    ft.dwHighDateTime = u.HighPart;
    ft.dwLowDateTime = u.LowPart;
    if (FileTimeToSystemTime(&ft, &st))
        _snwprintf_s(out, out_cch, _TRUNCATE, L"%04u-%02u-%02u %02u:%02u:%02u",
            st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
}
#define GIBIBYTE_MIN_NBYTES 10000000000ULL
#define MEBIBYTE_MIN_NBYTES 10000000ULL
#define KIBIBYTE_MIN_NBYTES 10000ULL

void value_unit_into_variables(uint64_t value, volatile LONG* size_ret, wchar_t* unit_buf)
{
    unsigned shift;
    const wchar_t* unit;
    if (!size_ret || !unit_buf) return;

    if (value >= GIBIBYTE_MIN_NBYTES) {
        shift = 30;
        unit = L"GiB";
    }
    else if (value >= MEBIBYTE_MIN_NBYTES) {
        shift = 20;
        unit = L"MiB";
    }
    else if (value >= KIBIBYTE_MIN_NBYTES) {
        shift = 10;
        unit = L"KiB";
    }
    else {
        shift = 0;
        unit = L"bytes";
    }

    atomic_write32(size_ret, (LONG)(value >> shift));
    wcsncpy_s(unit_buf, 10, unit, _TRUNCATE);
}

static void 
report_scan_progress(
    const struct wimlib_progress_info_scan* scan, 
    bool done)
{
    uint64_t prev_count;
    uint64_t cur_count;

    prev_count = g_lastScanProgress.num_nondirs_scanned + g_lastScanProgress.num_dirs_scanned;
    cur_count = scan->num_nondirs_scanned + scan->num_dirs_scanned;

    if (done || prev_count == 0 || cur_count >= prev_count + 500 || cur_count % 512 == 0)
    {
        g_lastScanProgress = *scan;

        // Fichiers et dossiers scannés
        atomic_write32(&g_ScanNbFiles, (LONG)scan->num_nondirs_scanned);
        atomic_write32(&g_ScanNbFolders, (LONG)scan->num_dirs_scanned);

        // Chemin courant
        shim_wcsncpyz(g_ScanCurrentPath, _countof(g_ScanCurrentPath), (const wchar_t*)scan->cur_path);

        // Taille scannée + unité
        value_unit_into_variables(scan->num_bytes_scanned, &g_ScanTotalFilesSize, g_ScanUnit);
        atomic_write32(&g_Elapsed, (int)difftime(time(NULL), g_StartTime));
        atomic_write32(&g_Remaining, 0);
    }
}


/* ================================================================== */
/*  API EXPORTÉE – Version / Init / Error / Info scan                 */
/* ================================================================== */
const wchar_t* __cdecl Wim_GetVersion(void) {
    return (const wchar_t*)wimlib_get_version_string();
}

int __cdecl Wim_Init(void) {
    return wimlib_global_init(0);
}

void __cdecl Wim_Shutdown(void) {
    /* Never tear wimlib down under a running worker thread. */
    if (g_hThread && WaitForSingleObject(g_hThread, 0) == WAIT_TIMEOUT)
        return;
    if (g_hThread) {
        CloseHandle(g_hThread);
        g_hThread = NULL;
    }
    free(g_XmlBuf);
    g_XmlBuf = NULL;
    g_XmlCap = 0;
    wimlib_global_cleanup();
}

const wchar_t* __cdecl Wim_ErrorString(int code) {
    switch (code) {
    case WIM_SHIM_ERR_BUSY:         return L"A job is already running";
    case WIM_SHIM_ERR_THREAD:
    case -301: case -401: case -501:
                                    return L"Unable to start the worker thread";
    case WIM_SHIM_ERR_NO_JOB:
    case -302: case -402:           return L"No job to wait for";
    default:
        if (code < 0)
            return L"Unknown shim error";
        return (const wchar_t*)wimlib_get_error_string((enum wimlib_error_code)code);
    }
}


/* ================================================================== */
/*  Wim_GetWimInfo                                                    */
/* ================================================================== */
int __cdecl Wim_GetWimInfo(
    const wchar_t* wimPath,
    int* imageCount,
    int* bootIndex,
    int* CompressionType,
    int* hasIntegrity,
    uint32_t* chunkSize,
    uint64_t* totalBytes,
    int* partNumber,
    int* totalParts,
    int* isReadonly)
{
    if (!wimPath)
        return WIMLIB_ERR_INVALID_PARAM;

    WIMStruct* Wim = NULL;
    /* Open read-only */
    int ret = wimlib_open_wim(wimPath, 0, &Wim);
    if (ret != 0)
        return ret;

    struct wimlib_wim_info WimInfo;
    ret = wimlib_get_wim_info(Wim, &WimInfo);
    if (ret == 0) {
        if (imageCount)      *imageCount = (int)WimInfo.image_count;
        if (bootIndex)       *bootIndex = (int)WimInfo.boot_index;
        if (CompressionType) *CompressionType = (int)WimInfo.compression_type;
        if (hasIntegrity)    *hasIntegrity = WimInfo.has_integrity_table ? 1 : 0;
        if (chunkSize)       *chunkSize = WimInfo.chunk_size;
        if (totalBytes)      *totalBytes = WimInfo.total_bytes;
        if (partNumber)      *partNumber = (int)WimInfo.part_number;
        if (totalParts)      *totalParts = (int)WimInfo.total_parts;
        if (isReadonly)      *isReadonly = (WimInfo.is_readonly || WimInfo.is_marked_readonly) ? 1 : 0;
    }

    wimlib_free(Wim);
    return ret;
}


/* ================================================================== */
/*  Progress callbacks                                                */
/* ================================================================== */
__declspec(dllexport) int __cdecl Wim_Query_Scan(
    int* phase,
    wchar_t* current_path,
    int* nb_files,
    int* nb_dirs,
    int* scanned_size,
    wchar_t* size_unit,
    int* elapsed_s,
    int* remaining_s)
{
    if (phase)                      *phase                      = atomic_read32(&g_Phase);
    if (current_path)               wcsncpy_s(current_path, MAX_PATH * 4, g_ScanCurrentPath, _TRUNCATE);
    if (nb_files)                   *nb_files                   = atomic_read32(&g_ScanNbFiles);
    if (nb_dirs)                    *nb_dirs                    = atomic_read32(&g_ScanNbFolders);
    if (scanned_size)               *scanned_size               = atomic_read32(&g_ScanTotalFilesSize);
    if (size_unit)                  wcsncpy_s(size_unit, 10, g_ScanUnit, _TRUNCATE);
    if (elapsed_s)                  *elapsed_s                  = atomic_read32(&g_Elapsed);
    if (remaining_s)                *remaining_s                = atomic_read32(&g_Remaining);
    return 0;
}

__declspec(dllexport) int __cdecl Wim_Query_CaptureAppend(
    int* phase,
    int* elapsed_from_start_s,
    int* ThreadCount,
    wchar_t* current_path,
    int* total_bytes,
    wchar_t* total_bytes_Unit,
    int* completed_bytes,
    wchar_t* completed_bytes_Unit,
    int* total_streams,
    int* completed_streams,
    double* percent,
    int* elapsed_s,
    int* remaining_s,
    int* total_parts,
    int* completed_parts,
    int* completed_compressed_bytes,
    int* returncode)
{
    if (phase)                      *phase                      = atomic_read32(&g_Phase);
    if (elapsed_from_start_s)       *elapsed_from_start_s       = (int)difftime(time(NULL), g_StartTime);
    if (ThreadCount)                *ThreadCount                = atomic_read32(&g_ThreadCount);
    if (current_path)               wcsncpy_s(current_path, MAX_PATH * 4, g_ScanCurrentPath, _TRUNCATE);
    if (total_bytes)                *total_bytes                = atomic_read32(&g_total_bytes);
    if (total_bytes_Unit)           wcsncpy_s(total_bytes_Unit, 10, g_total_bytes_Unit, _TRUNCATE);
    if (completed_bytes)            *completed_bytes            = atomic_read32(&g_completed_bytes);
    if (completed_bytes_Unit)       wcsncpy_s(completed_bytes_Unit, 10, g_completed_bytes_Unit, _TRUNCATE);
    if (total_streams)              *total_streams              = atomic_read32(&g_total_streams);
    if (completed_streams)          *completed_streams          = atomic_read32(&g_completed_streams);
    if (percent)                    *percent                    = atomic_read32(&g_Percent) / pow(10.0, (double)atomic_read32(&g_PercentDecimal));
    if (elapsed_s)                  *elapsed_s                  = atomic_read32(&g_Elapsed);
    if (remaining_s)                *remaining_s                = atomic_read32(&g_Remaining);
    if (total_parts)                *total_parts                = atomic_read32(&g_total_parts);
    if (completed_parts)            *completed_parts            = atomic_read32(&g_completed_parts);
    if (completed_compressed_bytes) *completed_compressed_bytes = atomic_read32(&g_completed_compressed_bytes);
    if (returncode)                 *returncode                 = atomic_read32(&g_returncode);
    return 0;
}

__declspec(dllexport) int __cdecl Wim_Query_Verify(
    int* phase,
    int* elapsed_from_start_s,
    int* total_bytes,
    wchar_t* total_bytes_Unit,
    int* completed_bytes,
    wchar_t* completed_bytes_Unit,
    int* total_streams,
    int* completed_streams,
    double* percent,
    int* elapsed_s,
    int* remaining_s,
    int* returncode)
{
    if (phase)                      *phase = atomic_read32(&g_Phase);
    if (elapsed_from_start_s)       *elapsed_from_start_s = (int)difftime(time(NULL), g_StartTime);
    if (total_bytes)                *total_bytes = atomic_read32(&g_total_bytes);
    if (total_bytes_Unit)           wcsncpy_s(total_bytes_Unit, 10, g_total_bytes_Unit, _TRUNCATE);
    if (completed_bytes)            *completed_bytes = atomic_read32(&g_completed_bytes);
    if (completed_bytes_Unit)       wcsncpy_s(completed_bytes_Unit, 10, g_completed_bytes_Unit, _TRUNCATE);
    if (total_streams)              *total_streams = atomic_read32(&g_total_streams);
    if (completed_streams)          *completed_streams = atomic_read32(&g_completed_streams);
    if (percent)                    *percent = atomic_read32(&g_Percent) / pow(10.0, (double)atomic_read32(&g_PercentDecimal));
    if (elapsed_s)                  *elapsed_s = atomic_read32(&g_Elapsed);
    if (remaining_s)                *remaining_s = atomic_read32(&g_Remaining);
    if (returncode)                 *returncode = atomic_read32(&g_returncode);
    return 0;
}

/* Progress callback function passed to various wimlib functions. */
static enum wimlib_progress_status __cdecl ProgressCallBack(
    enum wimlib_progress_msg msg,
    union wimlib_progress_info* info,
    void* ctx)
{
    (void)ctx;

    time_t now = time(NULL);
    uint64_t total = 0;
    uint64_t done = 0;
    int percent = 0;
    int elapsed = (int)difftime(now, g_StartTime);   /* default: seconds since job start */
    int remain = 0;

    if (atomic_read32(&g_Cancel))
        return WIMLIB_PROGRESS_STATUS_ABORT;

    switch (msg) {
        case WIMLIB_PROGRESS_MSG_EXTRACT_IMAGE_BEGIN:       // = 0
            // "image.c" gives image number, name, wim file name, flags and destination.
            break;

        case WIMLIB_PROGRESS_MSG_EXTRACT_TREE_BEGIN:        // = 1
            // Not present in "image.c".
            break;

        case WIMLIB_PROGRESS_MSG_EXTRACT_FILE_STRUCTURE:    // = 3
            if (atomic_read32(&g_Phase) != WIMLIB_PROGRESS_MSG_EXTRACT_FILE_STRUCTURE) {
                atomic_write32(&g_Phase, WIMLIB_PROGRESS_MSG_EXTRACT_FILE_STRUCTURE);
                g_PhaseStartTime = now;
                atomic_write32(&g_end_file_count, 0);
                atomic_write32(&g_current_file_count, 0);
            }

            total = info->extract.end_file_count;

            if (total >= 2000) {
                atomic_write32(&g_end_file_count, (LONG)total);
                uint64_t done = info->extract.current_file_count;
                atomic_write32(&g_current_file_count, (LONG)done);

                percent = percent_from_u64(done, total);
                atomic_write32(&g_Percent, percent);
                percent = (int)(percent / pow(10.0, (double)atomic_read32(&g_PercentDecimal)));

                elapsed = (int)difftime(now, g_PhaseStartTime);
                if (percent > 0 && percent < 100) {
                    double spp = (double)elapsed / (double)percent;
                    remain = (int)((100.0 - percent) * spp);
                }

                if (percent >= 100)
                    remain = 0;
            }
            else {
                set_percent_int(0);
            }
            break;

        case WIMLIB_PROGRESS_MSG_EXTRACT_STREAMS:           // = 4
            if (atomic_read32(&g_Phase) != WIMLIB_PROGRESS_MSG_EXTRACT_STREAMS) {
                atomic_write32(&g_Phase, WIMLIB_PROGRESS_MSG_EXTRACT_STREAMS);
                g_PhaseStartTime = now;
            }

            if (info->extract.total_bytes > 0) {
                done = info->extract.completed_bytes;
                total = info->extract.total_bytes;
                value_unit_into_variables(total, &g_total_bytes, g_total_bytes_Unit);
                value_unit_into_variables(done, &g_completed_bytes, g_completed_bytes_Unit);
                atomic_write32(&g_total_streams, (LONG)info->extract.total_streams);
                atomic_write32(&g_completed_streams, (LONG)info->extract.completed_streams);
                atomic_write32(&g_total_parts, (LONG)info->extract.total_parts);
                atomic_write32(&g_part_number, (LONG)info->extract.part_number);
                percent = percent_from_u64(done, total);
                atomic_write32(&g_Percent, percent);
                percent = (int)(percent / pow(10.0, (double)atomic_read32(&g_PercentDecimal)));
            }

            elapsed = (int)difftime(now, g_StartTime);
            if (percent > 0 && percent < 100) {
                double spp = (double)elapsed / (double)percent;
                remain = (int)((100.0 - percent) * spp);
            }
            break;

        case WIMLIB_PROGRESS_MSG_EXTRACT_SPWM_PART_BEGIN:   // = 5
            if (atomic_read32(&g_Phase) != WIMLIB_PROGRESS_MSG_EXTRACT_SPWM_PART_BEGIN) {
                atomic_write32(&g_Phase, WIMLIB_PROGRESS_MSG_EXTRACT_SPWM_PART_BEGIN);
                g_PhaseStartTime = now;
            }




            //if (info->extract.total_parts != 1) {
            //    imagex_printf(T("\nReading split pipable WIM part %u of %u\n"),
            //        info->extract.part_number,
            //        info->extract.total_parts);
            //}
            break;

        case WIMLIB_PROGRESS_MSG_EXTRACT_METADATA:          // = 6
            if (atomic_read32(&g_Phase) != WIMLIB_PROGRESS_MSG_EXTRACT_METADATA) {
                atomic_write32(&g_Phase, WIMLIB_PROGRESS_MSG_EXTRACT_METADATA);
                g_PhaseStartTime = now;
            }


			// Les métadonnées sont appliquées après l’extraction des fichiers et dossiers.



            //if (info->extract.end_file_count >= 2000) {
            //    percent_done = TO_PERCENT(info->extract.current_file_count,
            //        info->extract.end_file_count);
            //    imagex_printf(T("\rApplying metadata to files: %"PRIu64" of %"PRIu64" (%u%%) done"),
            //        info->extract.current_file_count,
            //        info->extract.end_file_count, percent_done);
            //    if (info->extract.current_file_count == info->extract.end_file_count)
            //        imagex_printf(T("\n"));
            //}
            break;

        case WIMLIB_PROGRESS_MSG_EXTRACT_IMAGE_END:         // = 7
            atomic_write32(&g_Phase, WIMLIB_PROGRESS_MSG_EXTRACT_IMAGE_END);
            elapsed = (int)difftime(now, g_StartTime);
            set_percent_int(100);
            break;

        case WIMLIB_PROGRESS_MSG_EXTRACT_TREE_END:          // = 8
            // Not present in "image.c".
            break;

        case WIMLIB_PROGRESS_MSG_SCAN_BEGIN:                // = 9
            // "image.c" only gives the source folder.
            break;

        case WIMLIB_PROGRESS_MSG_SCAN_DENTRY:               // = 10
            if (atomic_read32(&g_Phase) != WIMLIB_PROGRESS_MSG_SCAN_DENTRY) {
                atomic_write32(&g_Phase, WIMLIB_PROGRESS_MSG_SCAN_DENTRY);
                g_PhaseStartTime = now;
            }

            const struct wimlib_progress_info_scan* scan;
		    scan = &info->scan;

            switch (scan->status) {
                case WIMLIB_SCAN_DENTRY_OK:             // = 0
                    report_scan_progress(&info->scan, false);
                    break;

                case WIMLIB_SCAN_DENTRY_EXCLUDED:       // = 1
                    // "image.c" lists excluded files and folders.
                    break;

                case WIMLIB_SCAN_DENTRY_UNSUPPORTED:    // = 2
                    // "image.c" lists excluded unsupported files or folders.
                    break;

                case WIMLIB_SCAN_DENTRY_FIXED_SYMLINK:  // = 4
			        // "image.c" warns about how junctions are managed.
                    break;

                default:
                    break;
            }
            break;

        case WIMLIB_PROGRESS_MSG_SCAN_END:                  // = 11
            if (atomic_read32(&g_Phase) != WIMLIB_PROGRESS_MSG_SCAN_END) {
                atomic_write32(&g_Phase, WIMLIB_PROGRESS_MSG_SCAN_END);
            }
            report_scan_progress(&info->scan, true);
            // Not present in "image.c".
            break;

        case WIMLIB_PROGRESS_MSG_WRITE_STREAMS:             // = 12
            if (atomic_read32(&g_Phase) != WIMLIB_PROGRESS_MSG_WRITE_STREAMS) {
                atomic_write32(&g_Phase, WIMLIB_PROGRESS_MSG_WRITE_STREAMS);
                g_PhaseStartTime = now;
            }

            //        if (last_split_progress.total_bytes != 0) {     /* wimlib_split() in progress; use the split-specific * progress message.  */             
            ////             report_split_progress(info->write_streams.completed_compressed_bytes);
            //            break;
            //        }

            if (atomic_read32(&g_SplitActive)) {
                /* wimlib_split(): progress is relative to the whole source WIM, not to the current part. */
                if (g_SplitTotalBytes > 0) {
                    done = g_SplitDoneBytes + info->write_streams.completed_compressed_bytes;
                    if (done > g_SplitTotalBytes) done = g_SplitTotalBytes;
                    percent = percent_from_u64(done, g_SplitTotalBytes);
                    atomic_write32(&g_Percent, percent);
                }
                break;
            }

            if (info->write_streams.compression_type != WIMLIB_COMPRESSION_TYPE_NONE)
                atomic_write32(&g_ThreadCount, info->write_streams.num_threads);
            atomic_write32(&g_completed_compressed_bytes, (LONG)(info->write_streams.completed_compressed_bytes >> 20));

            total = info->write_streams.total_bytes;

            if (total > 0) {
                value_unit_into_variables(total, &g_total_bytes, g_total_bytes_Unit);
                done = info->write_streams.completed_bytes;
                value_unit_into_variables(done, &g_completed_bytes, g_completed_bytes_Unit);

                atomic_write32(&g_total_streams, (LONG)info->write_streams.total_streams);
                atomic_write32(&g_completed_streams, (LONG)info->write_streams.completed_streams);

                percent = percent_from_u64(done, total);
                atomic_write32(&g_Percent, percent);
                percent = (int)(percent / pow(10.0, (double)atomic_read32(&g_PercentDecimal)));

                elapsed = (int)difftime(now, g_PhaseStartTime);
                if (percent > 0 && percent < 100) {
                    double spp = (double)elapsed / (double)percent;
                    remain = (int)((100.0 - percent) * spp);
                }

                if (percent >= 100)
                    remain = 0;
            }
            else {
                set_percent_int(0);
            }
            break;

        case WIMLIB_PROGRESS_MSG_WRITE_METADATA_BEGIN:      // = 13
            if (atomic_read32(&g_Phase) != WIMLIB_PROGRESS_MSG_WRITE_METADATA_BEGIN) {
                atomic_write32(&g_Phase, WIMLIB_PROGRESS_MSG_WRITE_METADATA_BEGIN);
                g_PhaseStartTime = now;
            }
            break;

        case WIMLIB_PROGRESS_MSG_WRITE_METADATA_END:        // = 14
            if (atomic_read32(&g_Phase) != WIMLIB_PROGRESS_MSG_WRITE_METADATA_END) {
                atomic_write32(&g_Phase, WIMLIB_PROGRESS_MSG_WRITE_METADATA_END);
                g_PhaseStartTime = now;
            }

            elapsed = (int)difftime(now, g_StartTime);
            set_percent_int(100);
            break;

        case WIMLIB_PROGRESS_MSG_RENAME:                    // = 15
            // Not present in "image.c".
            break;

		case WIMLIB_PROGRESS_MSG_VERIFY_INTEGRITY:          // = 16
            if (atomic_read32(&g_Phase) != WIMLIB_PROGRESS_MSG_VERIFY_INTEGRITY) {
                atomic_write32(&g_Phase, WIMLIB_PROGRESS_MSG_VERIFY_INTEGRITY);
                g_PhaseStartTime = now;
            }




            //unit_shift = get_unit(info->integrity.total_bytes, &unit_name);
            //percent_done = TO_PERCENT(info->integrity.completed_bytes,
            //    info->integrity.total_bytes);
            //imagex_printf(T("\rVerifying integrity of \"%"TS"\": %"PRIu64" %"TS" "
            //    "of %"PRIu64" %"TS" (%u%%) done"),
            //    info->integrity.filename,
            //    info->integrity.completed_bytes >> unit_shift,
            //    unit_name,
            //    info->integrity.total_bytes >> unit_shift,
            //    unit_name,
            //    percent_done);
            //if (info->integrity.completed_bytes == info->integrity.total_bytes)
            //    imagex_printf(T("\n"));
            break;

		case WIMLIB_PROGRESS_MSG_CALC_INTEGRITY:            // = 17
            if (atomic_read32(&g_Phase) != WIMLIB_PROGRESS_MSG_CALC_INTEGRITY) {
                atomic_write32(&g_Phase, WIMLIB_PROGRESS_MSG_CALC_INTEGRITY);
                g_PhaseStartTime = now;
            }

            if (info->integrity.total_bytes > 0) {
                done = info->integrity.completed_bytes;
                total = info->integrity.total_bytes;
                percent = percent_from_u64(done, total);
                atomic_write32(&g_Percent, percent);
                percent = (int)(percent / pow(10.0, (double)atomic_read32(&g_PercentDecimal)));

                elapsed = (int)difftime(now, g_PhaseStartTime);
                if (percent > 0 && percent < 100) {
                    double spp = (double)elapsed / (double)percent;
                    remain = (int)((100.0 - percent) * spp);
                }

                if (percent >= 100)
                    remain = 0;
            }
            else {
                elapsed = 0;
                remain = 0;
                set_percent_int(0);
            }
            break;

		case WIMLIB_PROGRESS_MSG_SPLIT_BEGIN_PART:          // = 19
            if (atomic_read32(&g_Phase) != WIMLIB_PROGRESS_MSG_SPLIT_BEGIN_PART) {
                atomic_write32(&g_Phase, WIMLIB_PROGRESS_MSG_SPLIT_BEGIN_PART);
                g_PhaseStartTime = now;
            }
            g_SplitTotalBytes = info->split.total_bytes;
            g_SplitDoneBytes = info->split.completed_bytes;
            atomic_write32(&g_total_parts, (LONG)info->split.total_parts);
            atomic_write32(&g_completed_parts, (LONG)info->split.cur_part_number - 1);
            if (info->split.total_bytes > 0)
                atomic_write32(&g_Percent, percent_from_u64(info->split.completed_bytes, info->split.total_bytes));
            break;

		case WIMLIB_PROGRESS_MSG_SPLIT_END_PART:            // = 20
            if (atomic_read32(&g_Phase) != WIMLIB_PROGRESS_MSG_SPLIT_END_PART) {
                atomic_write32(&g_Phase, WIMLIB_PROGRESS_MSG_SPLIT_END_PART);
            }
            g_SplitTotalBytes = info->split.total_bytes;
            g_SplitDoneBytes = info->split.completed_bytes;
            atomic_write32(&g_total_parts, (LONG)info->split.total_parts);
            atomic_write32(&g_completed_parts, (LONG)info->split.cur_part_number);
            if (info->split.total_bytes > 0)
                atomic_write32(&g_Percent, percent_from_u64(info->split.completed_bytes, info->split.total_bytes));
            break;

        case WIMLIB_PROGRESS_MSG_UPDATE_BEGIN_COMMAND:      // = 21
            // Not present in "image.c".
            break;

		case WIMLIB_PROGRESS_MSG_UPDATE_END_COMMAND:        // = 22
            if (atomic_read32(&g_Phase) != WIMLIB_PROGRESS_MSG_UPDATE_END_COMMAND) {
                atomic_write32(&g_Phase, WIMLIB_PROGRESS_MSG_UPDATE_END_COMMAND);
                g_PhaseStartTime = now;
            }




            //switch (info->update.command->op) {
            //case WIMLIB_UPDATE_OP_DELETE:
            //    //imagex_printf(T("Deleted WIM path \"%"TS"\"\n"),
            //    //    info->update.command->delete_.wim_path);
            //    break;
            //case WIMLIB_UPDATE_OP_RENAME:
            //    //imagex_printf(T("Renamed WIM path \"%"TS"\" => \"%"TS"\"\n"),
            //    //    info->update.command->rename.wim_source_path,
            //    //    info->update.command->rename.wim_target_path);
            //    break;
            //case WIMLIB_UPDATE_OP_ADD:
            //default:
            //    break;
            //}
            break;

		case WIMLIB_PROGRESS_MSG_REPLACE_FILE_IN_WIM:       // = 23
            if (atomic_read32(&g_Phase) != WIMLIB_PROGRESS_MSG_REPLACE_FILE_IN_WIM) {
                atomic_write32(&g_Phase, WIMLIB_PROGRESS_MSG_REPLACE_FILE_IN_WIM);
                g_PhaseStartTime = now;
            }




            //imagex_printf(T("Updating \"%"TS"\" in WIM image\n"),
            //    info->replace.path_in_wim);
            break;

		case WIMLIB_PROGRESS_MSG_WIMBOOT_EXCLUDE:           // = 24
            if (atomic_read32(&g_Phase) != WIMLIB_PROGRESS_MSG_WIMBOOT_EXCLUDE) {
                atomic_write32(&g_Phase, WIMLIB_PROGRESS_MSG_WIMBOOT_EXCLUDE);
                g_PhaseStartTime = now;
            }




            //imagex_printf(T("\nExtracting \"%"TS"\" as normal file (not WIMBoot pointer)\n"),
            //    info->wimboot_exclude.path_in_wim);
            break;

        case WIMLIB_PROGRESS_MSG_DONE_WITH_FILE:            // = 26
            // Not present in "image.c".
            break;

		case WIMLIB_PROGRESS_MSG_BEGIN_VERIFY_IMAGE:        // = 27
            if (atomic_read32(&g_Phase) != WIMLIB_PROGRESS_MSG_BEGIN_VERIFY_IMAGE) {
                atomic_write32(&g_Phase, WIMLIB_PROGRESS_MSG_BEGIN_VERIFY_IMAGE);
                g_PhaseStartTime = now;
            }




            //imagex_printf(T("Verifying metadata for image %"PRIu32" of %"PRIu32"\n"),
            //    info->verify_image.current_image,
            //    info->verify_image.total_images);
            break;

        case WIMLIB_PROGRESS_MSG_END_VERIFY_IMAGE:          // = 28
            // Not present in "image.c".
            break;

		case WIMLIB_PROGRESS_MSG_VERIFY_STREAMS:            // = 29
            if (atomic_read32(&g_Phase) != WIMLIB_PROGRESS_MSG_VERIFY_STREAMS) {
                atomic_write32(&g_Phase, WIMLIB_PROGRESS_MSG_VERIFY_STREAMS);
                g_PhaseStartTime = now;
            }

            total = info->verify_streams.total_bytes;

            if (total > 0) {
                value_unit_into_variables(total, &g_total_bytes, g_total_bytes_Unit);
                done = info->verify_streams.completed_bytes;
                value_unit_into_variables(done, &g_completed_bytes, g_completed_bytes_Unit);

                atomic_write32(&g_total_streams, (LONG)info->verify_streams.total_streams);
                atomic_write32(&g_completed_streams, (LONG)info->verify_streams.completed_streams);

                percent = percent_from_u64(done, total);
                atomic_write32(&g_Percent, percent);
                percent = (int)(percent / pow(10.0, (double)atomic_read32(&g_PercentDecimal)));

                elapsed = (int)difftime(now, g_PhaseStartTime);
                if (percent > 0 && percent < 100) {
                    double spp = (double)elapsed / (double)percent;
                    remain = (int)((100.0 - percent) * spp);
                }

                if (percent >= 100)
                    remain = 0;
            }
            else {
                set_percent_int(0);
            }
            break;

        case WIMLIB_PROGRESS_MSG_TEST_FILE_EXCLUSION:       // = 30
            // Not present in "image.c".
            break;

        case WIMLIB_PROGRESS_MSG_HANDLE_ERROR:              // = 31
            // Not present in "image.c".
            break;

        default:
            // Present in "image.c" and do nothing.
            break;
    }

    atomic_write32(&g_Elapsed, elapsed);
    atomic_write32(&g_Remaining, remain);
    return WIMLIB_PROGRESS_STATUS_CONTINUE;
}


/*     ===== ===== ===== ===== =====     ===== ===== ===== ===== =====     ===== ===== ===== ===== =====     ===== ===== ===== ===== =====     ===== ===== ===== ===== =====     */


/* ================================================================== */
/*  HelloWorld                                                        */
/* ================================================================== */
__declspec(dllexport) const char* HelloWorld(void) {
    return "Hello World from DLL!";
}


/* ================================================================== */
/*  Wim Informations                                                  */
/* ================================================================== */
__declspec(dllexport) const wchar_t* __cdecl Wim_ListImages(const wchar_t* wimPath, int* imageCount, int* returncode)
{
    if (returncode)    *returncode = WIMLIB_ERR_INVALID_PARAM;
    if (imageCount) *imageCount = 0;
    g_InfoBuf[0] = L'\0';

    if (!wimPath)
        return g_InfoBuf;

    WIMStruct* Wim = NULL;
    int ret = wimlib_open_wim(wimPath, 0, &Wim);
    if (returncode) *returncode = ret;
    if (ret != 0) {
        if (Wim) wimlib_free(Wim);
        return g_InfoBuf;
    }

    struct wimlib_wim_info WimInfo;
    ret = wimlib_get_wim_info(Wim, &WimInfo);
    if (returncode) *returncode = ret;
    if (ret != 0) {
        wimlib_free(Wim);
        return g_InfoBuf;
    }
    if (imageCount) *imageCount = (int)WimInfo.image_count;

    /* Build lines */
    wchar_t* p = g_InfoBuf;
    size_t  cap = SHIM_MAX_INFO_CHARS;
    p[0] = L'\0';

    for (int i = 1; i <= (int)WimInfo.image_count; i++) {
        const wchar_t* nm = shim_get_img_prop(Wim, i, L"NAME");
        const wchar_t* desc = shim_get_img_prop(Wim, i, L"DESCRIPTION");
        const wchar_t* fls = shim_get_img_prop(Wim, i, L"FLAGS");
        int wrote = _snwprintf_s(p, cap, _TRUNCATE, L"%d|%s|%s|%s\n", i, nm, desc, fls);
        if (wrote < 0)
            break;
        size_t used = wcsnlen_s(p, cap);
        p += used;
        if (used >= cap)
            break;
        cap -= used;
    }

    wimlib_free(Wim);
    return g_InfoBuf;
}

__declspec(dllexport) const wchar_t* __cdecl Wim_GetImageInfo(const wchar_t* wimPath,
    int imageIndex,
    int* isBoot,
    int* returncode)
{
    if (returncode) *returncode = WIMLIB_ERR_INVALID_PARAM;
    if (isBoot)  *isBoot = 0;
    g_InfoBuf[0] = L'\0';

    if (!wimPath || imageIndex <= 0)
        return g_InfoBuf;

    WIMStruct* Wim = NULL;
    int ret = wimlib_open_wim(wimPath, 0, &Wim);
    if (returncode) *returncode = ret;
    if (ret != 0) {
        if (Wim) wimlib_free(Wim);
        return g_InfoBuf;
    }

    struct wimlib_wim_info WimInfo;
    ret = wimlib_get_wim_info(Wim, &WimInfo);
    if (returncode) *returncode = ret;
    if (ret != 0) {
        wimlib_free(Wim);
        return g_InfoBuf;
    }

    if (imageIndex > (int)WimInfo.image_count) {
        if (returncode) *returncode = WIMLIB_ERR_INVALID_IMAGE;
        wimlib_free(Wim);
        return g_InfoBuf;
    }

    if (isBoot)
        *isBoot = ((int)WimInfo.boot_index == imageIndex) ? 1 : 0;

    /* Gather props */
    const wchar_t* nm = shim_get_img_prop(Wim, imageIndex, L"NAME");
    const wchar_t* desc = shim_get_img_prop(Wim, imageIndex, L"DESCRIPTION");
    const wchar_t* flags = shim_get_img_prop(Wim, imageIndex, L"FLAGS");
    const wchar_t* dirs = shim_get_img_prop(Wim, imageIndex, L"DIRCOUNT");
    const wchar_t* files = shim_get_img_prop(Wim, imageIndex, L"FILECOUNT");
    const wchar_t* tot = shim_get_img_prop(Wim, imageIndex, L"TOTALBYTES");
    const wchar_t* hlbytes = shim_get_img_prop(Wim, imageIndex, L"HARDLINKBYTES");
    wchar_t ctime[32], mtime[32];
    shim_get_img_time(Wim, imageIndex, L"CREATIONTIME", ctime, _countof(ctime));
    shim_get_img_time(Wim, imageIndex, L"LASTMODIFICATIONTIME", mtime, _countof(mtime));

    _snwprintf_s(g_InfoBuf, _countof(g_InfoBuf), _TRUNCATE,
        L"%s|%s|%s|%s|%s|%s|%s|%s|%s",
        nm, desc, flags, dirs, files, tot, hlbytes, ctime, mtime);

    wimlib_free(Wim);
    return g_InfoBuf;
}

__declspec(dllexport) const wchar_t* __cdecl Wim_GetImageProperty(const wchar_t* wimPath,
    int imageIndex,
    const wchar_t* propName,
    int* returncode)
{
    if (returncode) *returncode = WIMLIB_ERR_INVALID_PARAM;
    g_InfoPropBuf[0] = L'\0';

    if (!wimPath || !propName || imageIndex <= 0)
        return g_InfoPropBuf;

    WIMStruct* Wim = NULL;
    int ret = wimlib_open_wim(wimPath, 0, &Wim);
    if (returncode) *returncode = ret;
    if (ret != 0) {
        if (Wim) wimlib_free(Wim);
        return g_InfoPropBuf;
    }

    struct wimlib_wim_info WimInfo;
    ret = wimlib_get_wim_info(Wim, &WimInfo);
    if (ret == 0 && imageIndex > (int)WimInfo.image_count)
        ret = WIMLIB_ERR_INVALID_IMAGE;
    if (returncode) *returncode = ret;
    if (ret != 0) {
        wimlib_free(Wim);
        return g_InfoPropBuf;
    }

    const wchar_t* val = shim_get_img_prop(Wim, imageIndex, propName);
    shim_wcsncpyz(g_InfoPropBuf, _countof(g_InfoPropBuf), val);

    wimlib_free(Wim);
    return g_InfoPropBuf;
}


/* wimlib allocates the XML buffer with its own malloc (release UCRT => process heap). Calling free() here
 * would be wrong in a Debug build (/MDd: debug heap), so release it on the process heap directly. */
static void shim_free_wimlib_buffer(void* p)
{
    if (p)
        HeapFree(GetProcessHeap(), 0, p);
}

__declspec(dllexport) const wchar_t* __cdecl Wim_GetXml(const wchar_t* wimPath,
    size_t* sizeChars,
    int* returncode)
{
    static const wchar_t empty[] = L"";

    if (returncode) *returncode = WIMLIB_ERR_INVALID_PARAM;
    if (sizeChars)  *sizeChars = 0;

    if (!wimPath)
        return empty;

    WIMStruct* Wim = NULL;
    int ret = wimlib_open_wim(wimPath, 0, &Wim);
    if (returncode) *returncode = ret;
    if (ret != 0) {
        if (Wim) wimlib_free(Wim);
        return empty;
    }

    void* xmlbuf = NULL;
    size_t xmlsz = 0;
    ret = wimlib_get_xml_data(Wim, &xmlbuf, &xmlsz);    /* raw UTF-16LE document (may start with a BOM) */
    wimlib_free(Wim);
    if (returncode) *returncode = ret;
    if (ret != 0 || !xmlbuf)
        return empty;

    size_t nchars = xmlsz / sizeof(wchar_t);
    const wchar_t* src = (const wchar_t*)xmlbuf;
    if (nchars > 0 && src[0] == 0xFEFF) {               /* skip BOM */
        src++;
        nchars--;
    }

    if (g_XmlCap < nchars + 1) {
        wchar_t* nb = (wchar_t*)realloc(g_XmlBuf, (nchars + 1) * sizeof(wchar_t));
        if (!nb) {
            shim_free_wimlib_buffer(xmlbuf);
            if (returncode) *returncode = WIMLIB_ERR_NOMEM;
            return empty;
        }
        g_XmlBuf = nb;
        g_XmlCap = nchars + 1;
    }
    memcpy(g_XmlBuf, src, nchars * sizeof(wchar_t));
    g_XmlBuf[nchars] = L'\0';
    shim_free_wimlib_buffer(xmlbuf);

    if (sizeChars) *sizeChars = nchars;
    return g_XmlBuf;
}


/* ================================================================== */
/*  Modification of an existing WIM (synchronous)                     */
/* ================================================================== */
__declspec(dllexport) int __cdecl Wim_DeleteImage(const wchar_t* wimPath, int imageIndex, int writeFlags)
{
    if (!wimPath || imageIndex == 0)
        return WIMLIB_ERR_INVALID_PARAM;

    WIMStruct* Wim = NULL;
    int ret = wimlib_open_wim(wimPath, WIMLIB_OPEN_FLAG_WRITE_ACCESS, &Wim);
    if (ret != 0)
        return ret;

    ret = wimlib_delete_image(Wim, imageIndex);         /* WIMLIB_ALL_IMAGES (-1) allowed */
    if (ret == 0)
        ret = wimlib_overwrite(Wim, writeFlags, 0);
    wimlib_free(Wim);
    return ret;
}

__declspec(dllexport) int __cdecl Wim_SetImageProperty(
    const wchar_t* wimPath,
    int imageIndex,
    const wchar_t* propName,
    const wchar_t* value,
    int writeFlags)
{
    if (!wimPath || !propName || imageIndex <= 0)
        return WIMLIB_ERR_INVALID_PARAM;

    WIMStruct* Wim = NULL;
    int ret = wimlib_open_wim(wimPath, WIMLIB_OPEN_FLAG_WRITE_ACCESS, &Wim);
    if (ret != 0)
        return ret;

    ret = wimlib_set_image_property(Wim, imageIndex, propName, (value && *value) ? value : NULL);
    if (ret == 0)
        ret = wimlib_overwrite(Wim, writeFlags, 0);
    wimlib_free(Wim);
    return ret;
}

__declspec(dllexport) int __cdecl Wim_SetBootIndex(const wchar_t* wimPath, int bootIndex, int writeFlags)
{
    if (!wimPath || bootIndex < 0)
        return WIMLIB_ERR_INVALID_PARAM;

    WIMStruct* Wim = NULL;
    int ret = wimlib_open_wim(wimPath, WIMLIB_OPEN_FLAG_WRITE_ACCESS, &Wim);
    if (ret != 0)
        return ret;

    struct wimlib_wim_info info;
    memset(&info, 0, sizeof(info));
    info.boot_index = (uint32_t)bootIndex;              /* 0 = no boot image */
    ret = wimlib_set_wim_info(Wim, &info, WIMLIB_CHANGE_BOOT_INDEX);
    if (ret == 0)
        ret = wimlib_overwrite(Wim, writeFlags, 0);
    wimlib_free(Wim);
    return ret;
}

/* Exports srcImage (or all images if -1) of srcWim into destWim (created if missing).
 * destName / destDesc: NULL or "" keep the source ones (only when exporting one image). */
__declspec(dllexport) int __cdecl Wim_ExportImage(
    const wchar_t* srcWim,
    int srcImage,
    const wchar_t* destWim,
    const wchar_t* destName,
    const wchar_t* destDesc,
    int exportFlags,
    int writeFlags)
{
    if (!srcWim || !destWim || srcImage == 0)
        return WIMLIB_ERR_INVALID_PARAM;

    WIMStruct* Src = NULL;
    WIMStruct* Dst = NULL;
    int ret = wimlib_open_wim(srcWim, 0, &Src);
    if (ret != 0)
        return ret;

    if (GetFileAttributesW(destWim) != INVALID_FILE_ATTRIBUTES) {
        ret = wimlib_open_wim(destWim, WIMLIB_OPEN_FLAG_WRITE_ACCESS, &Dst);
        if (ret == 0)
            ret = wimlib_export_image(Src, srcImage, Dst,
                (destName && *destName) ? destName : NULL,
                (destDesc && *destDesc) ? destDesc : NULL, exportFlags);
        if (ret == 0)
            ret = wimlib_overwrite(Dst, writeFlags, 0);
    }
    else {
        struct wimlib_wim_info si;
        ret = wimlib_get_wim_info(Src, &si);
        if (ret == 0)
            ret = wimlib_create_new_wim((enum wimlib_compression_type)si.compression_type, &Dst);
        if (ret == 0)
            ret = wimlib_export_image(Src, srcImage, Dst,
                (destName && *destName) ? destName : NULL,
                (destDesc && *destDesc) ? destDesc : NULL, exportFlags);
        if (ret == 0)
            ret = wimlib_write(Dst, destWim, WIMLIB_ALL_IMAGES, writeFlags, 0);
    }

    if (Dst) wimlib_free(Dst);
    wimlib_free(Src);
    return ret;
}


/* ================================================================== */
/*  Job management (one asynchronous job at a time)                   */
/* ================================================================== */
/* Must be called BEFORE touching the shared parameter buffers. */
static int job_check_idle(void)
{
    if (g_hThread) {
        if (WaitForSingleObject(g_hThread, 0) == WAIT_TIMEOUT)
            return WIM_SHIM_ERR_BUSY;
        CloseHandle(g_hThread);                         /* previous job finished but never waited for */
        g_hThread = NULL;
    }
    return 0;
}

static void job_reset_progress(void)
{
    g_StartTime = time(NULL);
    g_PhaseStartTime = g_StartTime;
    set_percent_int(0);
    atomic_write32(&g_Phase, 0);
    atomic_write32(&g_Elapsed, 0);
    atomic_write32(&g_Remaining, 0);
    atomic_write32(&g_returncode, 0);
    atomic_write32(&g_Cancel, 0);
    atomic_write32(&g_SplitActive, 0);
    atomic_write32(&g_total_bytes, 0);
    atomic_write32(&g_completed_bytes, 0);
    atomic_write32(&g_total_streams, 0);
    atomic_write32(&g_completed_streams, 0);
    atomic_write32(&g_total_parts, 0);
    atomic_write32(&g_completed_parts, 0);
    atomic_write32(&g_completed_compressed_bytes, 0);
    atomic_write32(&g_ScanNbFiles, 0);
    atomic_write32(&g_ScanNbFolders, 0);
    atomic_write32(&g_ScanTotalFilesSize, 0);
    g_total_bytes_Unit[0] = g_completed_bytes_Unit[0] = g_ScanUnit[0] = g_ScanCurrentPath[0] = L'\0';
    memset(&g_lastScanProgress, 0, sizeof(g_lastScanProgress));
    g_SplitTotalBytes = g_SplitDoneBytes = 0;
}

static int job_launch(unsigned(__stdcall* fn)(void*), int errNoThread)
{
    job_reset_progress();
    uintptr_t th = _beginthreadex(NULL, 0, fn, NULL, 0, NULL);
    if (!th)
        return errNoThread;
    g_hThread = (HANDLE)th;
    return 0;
}

static int job_wait(void)
{
    if (!g_hThread)
        return WIM_SHIM_ERR_NO_JOB;
    WaitForSingleObject(g_hThread, INFINITE);
    CloseHandle(g_hThread);
    g_hThread = NULL;
    return atomic_read32(&g_returncode);
}

__declspec(dllexport) int __cdecl Wim_IsRunning(void)
{
    return (g_hThread && WaitForSingleObject(g_hThread, 0) == WAIT_TIMEOUT) ? 1 : 0;
}

/* Asks the running job to stop; the job then ends with WIMLIB_ERR_ABORTED_BY_PROGRESS. */
__declspec(dllexport) int __cdecl Wim_Cancel(void)
{
    if (!Wim_IsRunning())
        return WIM_SHIM_ERR_NO_JOB;
    atomic_write32(&g_Cancel, 1);
    return 0;
}

/* Capture configuration file (exclusion list, wimcapture --config format) used by the next
 * captures / appends. NULL or "" = no configuration (nothing excluded). */
__declspec(dllexport) int __cdecl Wim_SetCaptureConfig(const wchar_t* configPath)
{
    if (Wim_IsRunning())
        return WIM_SHIM_ERR_BUSY;
    if (configPath && *configPath && GetFileAttributesW(configPath) == INVALID_FILE_ATTRIBUTES)
        return WIMLIB_ERR_OPEN;
    shim_wcsncpyz(g_CaptureConfig, _countof(g_CaptureConfig), configPath);
    return 0;
}

static void store_name_desc(const wchar_t* imageName, const wchar_t* imageDesc)
{
    shim_wcsncpyz(g_ImageName, _countof(g_ImageName), imageName);
    shim_wcsncpyz(g_ImageDesc, _countof(g_ImageDesc), imageDesc);
}


/* ================================================================== */
/*  CAPTURE                                                           */
/* ================================================================== */
static unsigned __stdcall CaptureThread(void* unused)
{
    (void)unused;

    enum wimlib_compression_type CompressionType = (enum wimlib_compression_type)atomic_read32(&g_CompressionType);
    int CompressionLevel = atomic_read32(&g_CompressionLevel);
    /* VERBOSE: without it wimlib sends no SCAN_DENTRY messages (no scan progress). Nothing is printed. */
    int addFlags = atomic_read32(&g_AddFlags) | WIMLIB_ADD_FLAG_VERBOSE;
    int writeFlags = atomic_read32(&g_WriteFlags);
    uint32_t chunkReq = (uint32_t)atomic_read32(&g_ChunkSizeBytes);
    uint32_t chunkSize = sanitize_chunk_size(CompressionType, chunkReq);
    int threads = atomic_read32(&g_ThreadCount);

    /* Local copies of name/desc */
    wchar_t nameBuf[512];
    wchar_t descBuf[1024];
    const wchar_t* nm = g_ImageName;
    const wchar_t* ds = g_ImageDesc;
    if (!nm || !*nm) {
        derive_image_name(g_SourceFolderPath, nameBuf, _countof(nameBuf));
        nm = nameBuf;
    }
    if (!ds || !*ds) {
        derive_image_desc(g_SourceFolderPath, descBuf, _countof(descBuf));
        ds = descBuf;
    }

    WIMStruct* Wim = NULL;
    int ret = wimlib_create_new_wim(CompressionType, &Wim);
    if (ret != 0) goto done;

    if (CompressionLevel > 0)
        (void)wimlib_set_default_compression_level(CompressionType, (unsigned int)CompressionLevel);

    /* Registered before add_image so that the scan phase is reported too. */
    wimlib_register_progress_function(Wim, ProgressCallBack, NULL);

    /* capture source -> new image w/ name */
    ret = wimlib_add_image(Wim, g_SourceFolderPath, nm, g_CaptureConfig[0] ? g_CaptureConfig : NULL, addFlags);
    if (ret != 0) { wimlib_free(Wim); goto done; }

    /* set description (image just added = #1) */
    (void)wimlib_set_image_description(Wim, 1, ds);

    /* Solid mode (like wimcapture --solid): chunk size / compression apply to the solid resources. */
    if (writeFlags & WIMLIB_WRITE_FLAG_SOLID) {
        if (CompressionType != WIMLIB_COMPRESSION_TYPE_NONE)
            (void)wimlib_set_output_pack_compression_type(Wim, CompressionType);
        if (chunkSize > 0)
            (void)wimlib_set_output_pack_chunk_size(Wim, chunkSize);
    }
    else if (chunkSize > 0)
        (void)wimlib_set_output_chunk_size(Wim, chunkSize);

    ret = wimlib_write(Wim, g_DestinationFilePath, WIMLIB_ALL_IMAGES, writeFlags, threads);
    wimlib_free(Wim);

done:
    atomic_write32(&g_returncode, ret);
    if (ret == 0) set_percent_int(100);
    _endthreadex(0);
    return 0;
}

__declspec(dllexport) int __cdecl Wim_StartCapture(const wchar_t* srcDir,
    const wchar_t* destWim,
    const wchar_t* imageName,
    const wchar_t* imageDesc,
    int CompressionType,
    int CompressionLevel,
    int addFlags,
    int writeFlags,
    uint32_t chunkSizeBytes,
    int threadCount)
{
    if (!srcDir || !destWim)
        return WIMLIB_ERR_INVALID_PARAM;

    int busy = job_check_idle();
    if (busy) return busy;

    shim_wcsncpyz(g_SourceFolderPath, _countof(g_SourceFolderPath), srcDir);
    shim_wcsncpyz(g_DestinationFilePath, _countof(g_DestinationFilePath), destWim);
    store_name_desc(imageName, imageDesc);

    switch (CompressionType) {
    case WIMLIB_COMPRESSION_TYPE_NONE:
    case WIMLIB_COMPRESSION_TYPE_XPRESS:
    case WIMLIB_COMPRESSION_TYPE_LZX:
    case WIMLIB_COMPRESSION_TYPE_LZMS:
        atomic_write32(&g_CompressionType, CompressionType);
        break;
    default:
        atomic_write32(&g_CompressionType, WIMLIB_COMPRESSION_TYPE_LZX);
        break;
    }

    atomic_write32(&g_CompressionLevel, CompressionLevel);
    atomic_write32(&g_AddFlags, addFlags);
    atomic_write32(&g_WriteFlags, writeFlags);
    atomic_write32(&g_ChunkSizeBytes, (LONG)chunkSizeBytes);
    atomic_write32(&g_ThreadCount, threadCount);

    return job_launch(CaptureThread, WIM_SHIM_ERR_THREAD);
}

__declspec(dllexport) int __cdecl Wim_WaitCapture(void)
{
    return job_wait();
}


/* ================================================================== */
/*  APPEND                                                            */
/* ================================================================== */
static unsigned __stdcall AppendThread(void* unused)
{
    (void)unused;

    int CompressionType = atomic_read32(&g_CompressionType);
    int CompressionLevel = atomic_read32(&g_CompressionLevel);
    /* VERBOSE: without it wimlib sends no SCAN_DENTRY messages (no scan progress). Nothing is printed. */
    int addFlags = atomic_read32(&g_AddFlags) | WIMLIB_ADD_FLAG_VERBOSE;
    int WriteFlags = atomic_read32(&g_WriteFlags);
    uint32_t chunkSize = (uint32_t)atomic_read32(&g_ChunkSizeBytes);
    int threads = atomic_read32(&g_ThreadCount);

    /* local name/desc resolved */
    wchar_t nameBuf[512];
    wchar_t descBuf[1024];
    const wchar_t* nm = g_ImageName;
    const wchar_t* ds = g_ImageDesc;
    if (!nm || !*nm) {
        derive_image_name(g_SourceFolderPath, nameBuf, _countof(nameBuf));
        nm = nameBuf;
    }
    if (!ds || !*ds) {
        derive_image_desc(g_SourceFolderPath, descBuf, _countof(descBuf));
        ds = descBuf;
    }

    WIMStruct* Wim = NULL;
    /* Open existing RW */
    int ret = wimlib_open_wim(g_DestinationFilePath, WIMLIB_OPEN_FLAG_WRITE_ACCESS, &Wim);
    if (ret != 0) goto done;

    wimlib_register_progress_function(Wim, ProgressCallBack, NULL);

    /* Forcer compression/chunk UNIQUEMENT si CompressionType >= 0 */
    if (CompressionType >= 0) {
        enum wimlib_compression_type Compression_Type = (enum wimlib_compression_type)CompressionType;
        (void)wimlib_set_output_compression_type(Wim, Compression_Type);

        if (CompressionLevel > 0)
            (void)wimlib_set_default_compression_level(Compression_Type, (unsigned int)CompressionLevel);

        uint32_t safe = sanitize_chunk_size(Compression_Type, chunkSize);
        if (WriteFlags & WIMLIB_WRITE_FLAG_SOLID) {
            if (Compression_Type != WIMLIB_COMPRESSION_TYPE_NONE)
                (void)wimlib_set_output_pack_compression_type(Wim, Compression_Type);
            if (safe > 0)
                (void)wimlib_set_output_pack_chunk_size(Wim, safe);
        }
        else if (safe > 0)
            (void)wimlib_set_output_chunk_size(Wim, safe);
    }

    /* Ajouter image */
    ret = wimlib_add_image(Wim, g_SourceFolderPath, nm, g_CaptureConfig[0] ? g_CaptureConfig : NULL, addFlags);
    if (ret != 0) { wimlib_free(Wim); goto done; }

    /* Mettre description sur la dernière image ajoutée */
    struct wimlib_wim_info WimInfo;
    if (wimlib_get_wim_info(Wim, &WimInfo) == 0) {
        int newIdx = (int)WimInfo.image_count;
        (void)wimlib_set_image_description(Wim, newIdx, ds);
    }

    /* Appliquer modifications */
    ret = wimlib_overwrite(Wim, WriteFlags, threads);
    wimlib_free(Wim);

done:
    atomic_write32(&g_returncode, ret);
    if (ret == 0) set_percent_int(100);
    _endthreadex(0);
    return 0;
}

__declspec(dllexport) int __cdecl Wim_StartAppend(const wchar_t* srcDir,
    const wchar_t* destWim,
    const wchar_t* imageName,
    const wchar_t* imageDesc,
    int CompressionType,
    int CompressionLevel,
    int addFlags,
    int writeFlags,
    uint32_t chunkSizeBytes,
    int threadCount)
{
    if (!srcDir || !destWim)
        return WIMLIB_ERR_INVALID_PARAM;

    int busy = job_check_idle();
    if (busy) return busy;

    shim_wcsncpyz(g_SourceFolderPath, _countof(g_SourceFolderPath), srcDir);
    shim_wcsncpyz(g_DestinationFilePath, _countof(g_DestinationFilePath), destWim);
    store_name_desc(imageName, imageDesc);

    atomic_write32(&g_CompressionType, CompressionType);
    atomic_write32(&g_CompressionLevel, CompressionLevel);
    atomic_write32(&g_AddFlags, addFlags);
    atomic_write32(&g_WriteFlags, writeFlags);
    atomic_write32(&g_ChunkSizeBytes, (LONG)chunkSizeBytes);
    atomic_write32(&g_ThreadCount, threadCount);

    return job_launch(AppendThread, WIM_SHIM_ERR_THREAD);
}

__declspec(dllexport) int __cdecl Wim_WaitAppend(void)
{
    return job_wait();
}


/* ================================================================== */
/*  APPLY / EXTRACT                                                   */
/* ================================================================== */
static unsigned __stdcall ApplyThread(void* unused)
{
    (void)unused;

    int imageIndex;
    WIMStruct* Wim = NULL;
    int ret = wimlib_open_wim(g_SourceFilePath, 0, &Wim);
    if (ret != 0) goto done;

    /* Résoudre index: number, image name, or "all" */
    imageIndex = _wtoi(g_ImageId);
    if (imageIndex <= 0)
        imageIndex = wimlib_resolve_image(Wim, g_ImageId);
    if (imageIndex == WIMLIB_NO_IMAGE) {
        ret = WIMLIB_ERR_INVALID_IMAGE;
        goto done;
    }

    wimlib_register_progress_function(Wim, ProgressCallBack, NULL);

    /* Extraire les fichiers */
    ret = wimlib_extract_image(Wim, imageIndex, g_DestinationFolderPath, atomic_read32(&g_Flags));

done:
    if (Wim) wimlib_free(Wim);
    atomic_write32(&g_returncode, ret);
    if (ret == 0) set_percent_int(100);
    _endthreadex(0);
    return 0;
}

__declspec(dllexport) int __cdecl Wim_StartApply(
    const wchar_t* wimFile,
    const wchar_t* imageId,
    const wchar_t* destDir,
    int extractFlags)
{
    if (!wimFile || !imageId || !destDir)
        return WIMLIB_ERR_INVALID_PARAM;

    int busy = job_check_idle();
    if (busy) return busy;

    shim_wcsncpyz(g_SourceFilePath, _countof(g_SourceFilePath), wimFile);
    shim_wcsncpyz(g_ImageId, _countof(g_ImageId), imageId);
    shim_wcsncpyz(g_DestinationFolderPath, _countof(g_DestinationFolderPath), destDir);
    atomic_write32(&g_Flags, extractFlags);
    atomic_write32(&g_part_number, 0);

    return job_launch(ApplyThread, WIM_SHIM_ERR_THREAD);
}

__declspec(dllexport) int __cdecl Wim_WaitApply(void)
{
    return job_wait();
}


/* ================================================================== */
/*  SPLIT                                                             */
/* ================================================================== */
static unsigned __stdcall SplitThread(void* unused)
{
    (void)unused;

    WIMStruct* Wim = NULL;
    int ret = wimlib_open_wim(g_SourceFilePath, 0, &Wim);   /* Lecture seule */
    if (ret == 0) {
        atomic_write32(&g_SplitActive, 1);
        wimlib_register_progress_function(Wim, ProgressCallBack, NULL);
        ret = wimlib_split(Wim, g_DestinationFilePath, g_SplitPartSize, atomic_read32(&g_WriteFlags));
        wimlib_free(Wim);
        atomic_write32(&g_SplitActive, 0);
    }

    atomic_write32(&g_returncode, ret);
    if (ret == 0) set_percent_int(100);
    _endthreadex(0);
    return 0;
}

__declspec(dllexport) int __cdecl Wim_StartSplit(
    const wchar_t* srcWim,
    const wchar_t* partPathFmt,
    uint64_t partSize,
    int writeFlags)
{
    if (!srcWim || !partPathFmt || partSize == 0)
        return WIMLIB_ERR_INVALID_PARAM;

    int busy = job_check_idle();
    if (busy) return busy;

    shim_wcsncpyz(g_SourceFilePath, _countof(g_SourceFilePath), srcWim);
    shim_wcsncpyz(g_DestinationFilePath, _countof(g_DestinationFilePath), partPathFmt);
    g_SplitPartSize = partSize;
    atomic_write32(&g_WriteFlags, writeFlags);

    return job_launch(SplitThread, WIM_SHIM_ERR_THREAD);
}

__declspec(dllexport) int __cdecl Wim_WaitSplit(void)
{
    return job_wait();
}

__declspec(dllexport) double __cdecl Wim_GetSplitProgress(void)
{
    return atomic_read32(&g_Percent) / pow(10.0, (double)atomic_read32(&g_PercentDecimal));
}


/* ================================================================== */
/*  VERIFY                                                            */
/* ================================================================== */
static unsigned __stdcall VerifyThread(void* unused)
{
    (void)unused;

    int verifyFlags = atomic_read32(&g_Flags);

    WIMStruct* Wim = NULL;
    int ret = wimlib_open_wim(g_SourceFilePath, 0 /* read-only */, &Wim);
    if (ret == 0) {
        wimlib_register_progress_function(Wim, ProgressCallBack, NULL);
        ret = wimlib_verify_wim(Wim, verifyFlags);
        wimlib_free(Wim);
    }

    atomic_write32(&g_returncode, ret);
    if (ret == 0) set_percent_int(100);
    _endthreadex(0);
    return 0;
}

__declspec(dllexport) int __cdecl Wim_StartVerify(
    const wchar_t* wimPath,
    int verifyFlags)
{
    if (!wimPath)
        return WIMLIB_ERR_INVALID_PARAM;

    int busy = job_check_idle();
    if (busy) return busy;

    shim_wcsncpyz(g_SourceFilePath, _countof(g_SourceFilePath), wimPath);
    atomic_write32(&g_Flags, verifyFlags);

    return job_launch(VerifyThread, WIM_SHIM_ERR_THREAD);
}

__declspec(dllexport) int __cdecl Wim_WaitVerify(void)
{
    return job_wait();
}
