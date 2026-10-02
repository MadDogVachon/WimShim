#ifndef SHIM_WIMLIB_H
#define SHIM_WIMLIB_H

#include <wchar.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif


    /* ================================================================
     *  Hello World!
     * ================================================================ */
    __declspec(dllexport) const char* HelloWorld(void);


    /* ================================================================
     *  Shim-specific error codes (codes >= 0 are wimlib's)
     * ================================================================ */
#define WIM_SHIM_ERR_BUSY     (-100)   /* a job is already running               */
#define WIM_SHIM_ERR_THREAD   (-101)   /* unable to start the worker thread      */
#define WIM_SHIM_ERR_NO_JOB   (-102)   /* no job to wait for / cancel            */

    /* ================================================================
     *  Asynchronous job control (one job at a time)
     *  Wim_IsRunning : 1 while the worker thread is running.
     *  Wim_Cancel    : requests a stop; the job then ends with
     *                  WIMLIB_ERR_ABORTED_BY_PROGRESS.
     * ================================================================ */
    __declspec(dllexport) int __cdecl Wim_IsRunning(void);
    __declspec(dllexport) int __cdecl Wim_Cancel(void);

    /* ================================================================
     *  Capture configuration file (wimcapture --config format: [ExclusionList]...)
     *  used by the next Wim_StartCapture / Wim_StartAppend. NULL or "" = none.
     *  Returns 0, WIM_SHIM_ERR_BUSY, or WIMLIB_ERR_OPEN if the file is missing.
     *  Solid mode: pass WIMLIB_WRITE_FLAG_SOLID in writeFlags; CompressionType and
     *  chunkSizeBytes then apply to the solid resources (wimcapture --solid).
     * ================================================================ */
    __declspec(dllexport) int __cdecl Wim_SetCaptureConfig(const wchar_t* configPath);

    /* ================================================================
     *  Modify an existing WIM (synchronous)
     *  imageIndex = -1 (WIMLIB_ALL_IMAGES) accepted by DeleteImage / ExportImage.
     *  Empty value => property removed.  bootIndex 0 => no boot image.
     * ================================================================ */
    __declspec(dllexport) int __cdecl Wim_DeleteImage(const wchar_t* wimPath, int imageIndex, int writeFlags);
    __declspec(dllexport) int __cdecl Wim_SetImageProperty(const wchar_t* wimPath, int imageIndex,
        const wchar_t* propName, const wchar_t* value, int writeFlags);
    __declspec(dllexport) int __cdecl Wim_SetBootIndex(const wchar_t* wimPath, int bootIndex, int writeFlags);
    __declspec(dllexport) int __cdecl Wim_ExportImage(const wchar_t* srcWim, int srcImage,
        const wchar_t* destWim, const wchar_t* destName, const wchar_t* destDesc,
        int exportFlags, int writeFlags);


    /* ================================================================
     *  API exportée (cdecl)
     *  Un seul job simultané par type (capture, append, check, verify).
     * ================================================================ */

     /* Version / init / erreur */
    __declspec(dllexport) const wchar_t* __cdecl Wim_GetVersion(void);
    __declspec(dllexport) int            __cdecl Wim_Init(void);
    __declspec(dllexport) void           __cdecl Wim_Shutdown(void);
    __declspec(dllexport) const wchar_t* __cdecl Wim_ErrorString(int code);

    __declspec(dllexport) int __cdecl Wim_Query_Scan(
        int* phase,
        wchar_t* current_path,
        int* nb_files,
        int* nb_dirs,
        int* scanned_size,
        wchar_t* size_unit,
        int* elapsed_s,
        int* remaining_s);

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
        int* returncode);

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
        int* returncode);


    /* ================================================================
     * GLOBAL INFO (conteneur)
     * ================================================================ */
    __declspec(dllexport) int __cdecl Wim_GetWimInfo(
        const wchar_t* wimPath,
        int* imageCount,
        int* bootIndex,
        int* CompressionType,
        int* hasIntegrity,
        uint32_t* chunkSize,
        uint64_t* totalBytes,
        int* partNumber,
        int* totalParts,
        int* isReadonly);


    /* ================================================================
     * LISTE DES IMAGES
     * Retour : pointeur vers buffer statique Unicode
     * Format : "idx|name|desc|flags\nidx|name|desc|flags\n..."
     * Champs name/desc vides si non présents.
     * flags = décimal (voir wimlib.h image_flags / XML <FLAGS>).
     * returncode = code wimlib (0=ok)
     * imageCount = # d'images
     * Buffer statique réutilisé à chaque appel (copiez si besoin).
     * ================================================================ */
    __declspec(dllexport) const wchar_t* __cdecl Wim_ListImages(
        const wchar_t* wimPath,
        int* imageCount,
        int* returncode);


    /* ================================================================
     * INFO DÉTAILLÉE D'UNE IMAGE
     * Retour : "name|desc|flags|dirCount|fileCount|totalBytes|hardLinkBytes|creationTime|lastModTime"
     * isBoot = 1 si imageIndex == bootIndex
     * returncode = code wimlib
     * ================================================================ */
    __declspec(dllexport) const wchar_t* __cdecl Wim_GetImageInfo(
        const wchar_t* wimPath,
        int imageIndex,      /* 1-based */
        int* isBoot,
        int* returncode);


    /* ================================================================
     * PROPRIÉTÉ GÉNÉRIQUE
     * propName ex: L"NAME", L"DESCRIPTION", L"FLAGS", L"TOTAL_BYTES"...
     * Retour : string valeur propriété (ou L"" si absente)
     * ================================================================ */
    __declspec(dllexport) const wchar_t* __cdecl Wim_GetImageProperty(
        const wchar_t* wimPath,
        int imageIndex,
        const wchar_t* propName,
        int* returncode);


    /* ================================================================
     * XML COMPLET
     * Retour : pointeur vers buffer XML Unicode
     * sizeChars = longueur (sans terminaison) si demandé
     * ================================================================ */
    __declspec(dllexport) const wchar_t* __cdecl Wim_GetXml(
        const wchar_t* wimPath,
        size_t* sizeChars,
        int* returncode);


    /* ================================================================
     * CAPTURE (asynchrone interne)
     *
     * imageName / imageDesc peuvent être NULL ou "".
     *   - imageName vide  -> auto: Snapshot_YYYY-MM-DD_HH-MM-SS
     *   - imageDesc vide  -> "No description"
     * ================================================================ */
    __declspec(dllexport) int __cdecl Wim_StartCapture(
        const wchar_t* srcDir,
        const wchar_t* destWim,
        const wchar_t* imageName,
        const wchar_t* imageDesc,
        int CompressionType,
        int CompressionLevel,
        int addFlags,
        int writeFlags,
        uint32_t chunkSizeBytes,
        int threadCount);

    __declspec(dllexport) int __cdecl Wim_WaitCapture(void);


    /* ================================================================
     * APPEND (asynchrone interne)
     *
     * CompressionType: -1 = conserver compression actuelle du WIM.
     * chunkSz: ignoré sauf si CompressionType >= 0 ET appelant fournit RECOMPRESS/REBUILD.
     * imageName / imageDesc : règles comme ci‑dessus.
     * ================================================================ */
    __declspec(dllexport) int __cdecl Wim_StartAppend(
        const wchar_t* srcDir,
        const wchar_t* destWim,
        const wchar_t* imageName,
        const wchar_t* imageDesc,
        int CompressionType,
        int CompressionLevel,
        int addFlags,
        int writeFlags,
        uint32_t chunkSizeBytes,
        int threadCount);

    __declspec(dllexport) int __cdecl Wim_WaitAppend(void);


    /* ================================================================
     * Apply
     * ================================================================ */
    __declspec(dllexport) int __cdecl Wim_StartApply(
        const wchar_t* wimFile, 
        const wchar_t* imageId, 
        const wchar_t* destDir, 
        int extractFlags);

    __declspec(dllexport) int __cdecl Wim_WaitApply(void);


    /* ================================================================
     * Split
     * ================================================================ */
    __declspec(dllexport) int __cdecl Wim_StartSplit(
        const wchar_t* srcWim,
        const wchar_t* partPathFmt,
        uint64_t partSize,
        int writeFlags);

    __declspec(dllexport) int __cdecl Wim_WaitSplit(void);

    /* Pourcentage 0-100 (double) du split en cours. */
    __declspec(dllexport) double __cdecl Wim_GetSplitProgress(void);


    /* ================================================================
     * Verify
     * ================================================================ */
    __declspec(dllexport) int __cdecl Wim_StartVerify(
        const wchar_t* wimPath,
        int verifyFlags);

    __declspec(dllexport) int __cdecl Wim_WaitVerify(void);

#ifdef __cplusplus
}
#endif

#endif /* SHIM_WIMLIB_H */
