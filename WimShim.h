#ifndef SHIM_WIMLIB_H
#define SHIM_WIMLIB_H

#include <wchar.h>
#include <stdint.h>
#include <stddef.h>   /* size_t */

#ifdef __cplusplus
extern "C" {
#endif


    /* ================================================================
     *  Hello World!
     * ================================================================ */
    __declspec(dllexport) const char* HelloWorld(void);


    /* ================================================================
     *  API exportée (cdecl)
     *  Un seul job simultané par type (capture, append, check, verify).
     * ================================================================ */

     /* Version / init / erreur */
    __declspec(dllexport) const wchar_t* __cdecl Wim_GetVersion(void);
    __declspec(dllexport) int            __cdecl Wim_Init(void);
    __declspec(dllexport) const wchar_t* __cdecl Wim_ErrorString(int code);


    /* ================================================================
     * GLOBAL INFO (conteneur)
     * ================================================================ */
    __declspec(dllexport) int __cdecl Wim_GetWimInfo(
        const wchar_t* wimPath,
        int* imageCount,
        int* bootIndex,
        int* compressionType,
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
     * retCode = code wimlib (0=ok)
     * imageCount = # d'images
     * Buffer statique réutilisé à chaque appel (copiez si besoin).
     * ================================================================ */
    __declspec(dllexport) const wchar_t* __cdecl Wim_ListImages(
        const wchar_t* wimPath,
        int* retCode,
        int* imageCount);


    /* ================================================================
     * INFO DÉTAILLÉE D'UNE IMAGE
     * Retour : "name|desc|flags|dirCount|fileCount|totalBytes|hardLinkBytes|creationTime|lastModTime"
     * isBoot = 1 si imageIndex == bootIndex
     * retCode = code wimlib
     * ================================================================ */
    __declspec(dllexport) const wchar_t* __cdecl Wim_GetImageInfo(
        const wchar_t* wimPath,
        int imageIndex,      /* 1-based */
        int* retCode,
        int* isBoot);


    /* ================================================================
     * PROPRIÉTÉ GÉNÉRIQUE
     * propName ex: L"NAME", L"DESCRIPTION", L"FLAGS", L"TOTAL_BYTES"...
     * Retour : string valeur propriété (ou L"" si absente)
     * ================================================================ */
    __declspec(dllexport) const wchar_t* __cdecl Wim_GetImageProperty(
        const wchar_t* wimPath,
        int imageIndex,
        const wchar_t* propName,
        int* retCode);


    /* ================================================================
     * XML COMPLET
     * Retour : pointeur vers buffer XML Unicode
     * sizeChars = longueur (sans terminaison) si demandé
     * ================================================================ */
    __declspec(dllexport) const wchar_t* __cdecl Wim_GetXml(
        const wchar_t* wimPath,
        int* retCode,
        size_t* sizeChars);


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
        int compressionType,
        int CompressionLevel,
        int addFlags,
        int writeFlags,
        uint32_t chunkSizeBytes,
        int threadCount);

    __declspec(dllexport) int __cdecl Wim_QueryCapture(
        int* phase,
        int* status,
        double* percent,
        int* elapsed_s,
        int* remaining_s,
        int* retcode);

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

    __declspec(dllexport) int __cdecl Wim_QueryAppend(
        int* status,
        int* phase,
        double* percent,
        int* elapsed_s,
        int* remaining_s,
        int* retcode);

    __declspec(dllexport) int __cdecl Wim_WaitAppend(void);


    /* ================================================================
     * Apply
     * ================================================================ */
    int __cdecl Wim_StartApply(
        const wchar_t* wimFile, 
        const wchar_t* imageId, 
        const wchar_t* destDir, 
        int extractFlags);

    __declspec(dllexport) int __cdecl Wim_QueryApply(
        int* status,
        int* phase,
        double* percent,
        int* elapsed_s,
        int* remaining_s,
        int* retcode);


    /* ================================================================
     * Split
     * ================================================================ */
    int __cdecl Wim_StartSplit(
        const wchar_t* srcWim,
        const wchar_t* partPathFmt,
        uint64_t partSize,
        int writeFlags);

    __declspec(dllexport) double __cdecl Wim_GetSplitProgress(void);


    /* ================================================================
     * Verify
     * ================================================================ */
    __declspec(dllexport) int __cdecl Wim_StartVerify(
        const wchar_t* wimPath,
        int verifyFlags);

    __declspec(dllexport) int __cdecl Wim_QueryVerify(
        int* status,
        double* percent,
        int* retcode);

    __declspec(dllexport) int __cdecl Wim_WaitVerify(void);

#ifdef __cplusplus
}
#endif

#endif /* SHIM_WIMLIB_H */
