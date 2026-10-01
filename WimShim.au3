; #INDEX# =======================================================================================================================
; Title .........: WimShim
; AutoIt Version : 3.3.14.5
; Description ...: Functions for creating and manipulating WIM images.
; Author(s) .....: Jonathan Larochelle (MadDogVachon)
; Dll ...........: WimShim.dll, libwim-15.dll (64 bits version of libwim-15.dll only)
; ===============================================================================================================================

#include-once
#include <WinAPIFiles.au3>
#include <Array.au3>
#include <MsgBoxConstants.au3>

If Not @AutoItX64 Then
	MsgBox($MB_OK + $MB_ICONERROR + $MB_TASKMODAL + $MB_TOPMOST, "Error", "The library only works with the 64-bit AutoIt (AutoIt3_x64.exe)")
	Exit
EndIf


; #CONSTANTS# ===================================================================================================================
; WimLib_compression_type
Global Enum $WIMLIB_COMPRESSION_TYPE_NONE, $WIMLIB_COMPRESSION_TYPE_XPRESS, $WIMLIB_COMPRESSION_TYPE_LZX, $WIMLIB_COMPRESSION_TYPE_LZMS
; WimLib_progress_msg
Global Enum $WIMLIB_PROGRESS_MSG_EXTRACT_IMAGE_BEGIN, $WIMLIB_PROGRESS_MSG_EXTRACT_TREE_BEGIN, $WIMLIB_PROGRESS_MSG_EXTRACT_FILE_STRUCTURE = 3, $WIMLIB_PROGRESS_MSG_EXTRACT_STREAMS, _
        $WIMLIB_PROGRESS_MSG_EXTRACT_SPWM_PART_BEGIN, $WIMLIB_PROGRESS_MSG_EXTRACT_METADATA, $WIMLIB_PROGRESS_MSG_EXTRACT_IMAGE_END, $WIMLIB_PROGRESS_MSG_EXTRACT_TREE_END, $WIMLIB_PROGRESS_MSG_SCAN_BEGIN, _
        $WIMLIB_PROGRESS_MSG_SCAN_DENTRY, $WIMLIB_PROGRESS_MSG_SCAN_END, $WIMLIB_PROGRESS_MSG_WRITE_STREAMS, $WIMLIB_PROGRESS_MSG_WRITE_METADATA_BEGIN, $WIMLIB_PROGRESS_MSG_WRITE_METADATA_END, _
        $WIMLIB_PROGRESS_MSG_RENAME, $WIMLIB_PROGRESS_MSG_VERIFY_INTEGRITY, $WIMLIB_PROGRESS_MSG_CALC_INTEGRITY, $WIMLIB_PROGRESS_MSG_SPLIT_BEGIN_PART = 19, $WIMLIB_PROGRESS_MSG_SPLIT_END_PART, _
        $WIMLIB_PROGRESS_MSG_UPDATE_BEGIN_COMMAND, $WIMLIB_PROGRESS_MSG_UPDATE_END_COMMAND, $WIMLIB_PROGRESS_MSG_REPLACE_FILE_IN_WIM, $WIMLIB_PROGRESS_MSG_WIMBOOT_EXCLUDE, $WIMLIB_PROGRESS_MSG_DONE_WITH_FILE = 26, _
        $WIMLIB_PROGRESS_MSG_BEGIN_VERIFY_IMAGE, $WIMLIB_PROGRESS_MSG_END_VERIFY_IMAGE, $WIMLIB_PROGRESS_MSG_VERIFY_STREAMS, $WIMLIB_PROGRESS_MSG_TEST_FILE_EXCLUSION, $WIMLIB_PROGRESS_MSG_HANDLE_ERROR
; WimLib_progress_status
Global Enum $WIMLIB_PROGRESS_STATUS_CONTINUE, $WIMLIB_PROGRESS_STATUS_ABORT
; WimLib_update_op
Global Const $WIMLIB_UPDATE_OP_ADD = 0
; WimLib_error_code
Global Enum $WIMLIB_ERR_SUCCESS, $WIMLIB_ERR_ALREADY_LOCKED, $WIMLIB_ERR_DECOMPRESSION, $WIMLIB_ERR_FUSE = 6, $WIMLIB_ERR_GLOB_HAD_NO_MATCHES = 8, $WIMLIB_ERR_ICONV_NOT_AVAILABLE, $WIMLIB_ERR_IMAGE_COUNT, _
        $WIMLIB_ERR_IMAGE_NAME_COLLISION, $WIMLIB_ERR_INSUFFICIENT_PRIVILEGES, $WIMLIB_ERR_INTEGRITY, $WIMLIB_ERR_INVALID_CAPTURE_CONFIG, $WIMLIB_ERR_INVALID_CHUNK_SIZE, $WIMLIB_ERR_INVALID_COMPRESSION_TYPE, _
        $WIMLIB_ERR_INVALID_HEADER, $WIMLIB_ERR_INVALID_IMAGE, $WIMLIB_ERR_INVALID_INTEGRITY_TABLE, $WIMLIB_ERR_INVALID_LOOKUP_TABLE_ENTRY, $WIMLIB_ERR_INVALID_METADATA_RESOURCE, $WIMLIB_ERR_INVALID_MULTIBYTE_STRING, _
        $WIMLIB_ERR_INVALID_OVERLAY, $WIMLIB_ERR_INVALID_PARAM, $WIMLIB_ERR_INVALID_PART_NUMBER, $WIMLIB_ERR_INVALID_PIPABLE_WIM, $WIMLIB_ERR_INVALID_REPARSE_DATA, $WIMLIB_ERR_INVALID_RESOURCE_HASH, _
        $WIMLIB_ERR_INVALID_UTF16_STRING = 30, $WIMLIB_ERR_INVALID_UTF8_STRING, $WIMLIB_ERR_IS_DIRECTORY, $WIMLIB_ERR_IS_SPLIT_WIM, $WIMLIB_ERR_LIBXML_UTF16_HANDLER_NOT_AVAILABLE, $WIMLIB_ERR_LINK, _
        $WIMLIB_ERR_METADATA_NOT_FOUND, $WIMLIB_ERR_MKDIR, $WIMLIB_ERR_MQUEUE, $WIMLIB_ERR_NOMEM, $WIMLIB_ERR_NOTDIR, $WIMLIB_ERR_NOTEMPTY, $WIMLIB_ERR_NOT_A_REGULAR_FILE, $WIMLIB_ERR_NOT_A_WIM_FILE, $WIMLIB_ERR_NOT_PIPABLE, _
        $WIMLIB_ERR_NO_FILENAME, $WIMLIB_ERR_NTFS_3G, $WIMLIB_ERR_OPEN, $WIMLIB_ERR_OPENDIR, $WIMLIB_ERR_PATH_DOES_NOT_EXIST, $WIMLIB_ERR_READ, $WIMLIB_ERR_READLINK, $WIMLIB_ERR_RENAME, _
        $WIMLIB_ERR_REPARSE_POINT_FIXUP_FAILED = 54, $WIMLIB_ERR_RESOURCE_NOT_FOUND, $WIMLIB_ERR_RESOURCE_ORDER, $WIMLIB_ERR_SET_ATTRIBUTES, $WIMLIB_ERR_SET_REPARSE_DATA, $WIMLIB_ERR_SET_SECURITY, $WIMLIB_ERR_SET_SHORT_NAME, _
        $WIMLIB_ERR_SET_TIMESTAMPS, $WIMLIB_ERR_SPLIT_INVALID, $WIMLIB_ERR_STAT, $WIMLIB_ERR_UNEXPECTED_END_OF_FILE = 65, $WIMLIB_ERR_UNICODE_STRING_NOT_REPRESENTABLE, $WIMLIB_ERR_UNKNOWN_VERSION, $WIMLIB_ERR_UNSUPPORTED, _
        $WIMLIB_ERR_UNSUPPORTED_FILE, $WIMLIB_ERR_WIM_IS_READONLY = 71, $WIMLIB_ERR_WRITE, $WIMLIB_ERR_XML, $WIMLIB_ERR_WIM_IS_ENCRYPTED, $WIMLIB_ERR_WIMBOOT, $WIMLIB_ERR_ABORTED_BY_PROGRESS, _
        $WIMLIB_ERR_UNKNOWN_PROGRESS_STATUS, $WIMLIB_ERR_MKNOD, $WIMLIB_ERR_FVE_LOCKED_VOLUME = 82, $WIMLIB_ERR_UNABLE_TO_READ_CAPTURE_CONFIG, $WIMLIB_ERR_WIM_IS_INCOMPLETE, $WIMLIB_ERR_COMPACTION_NOT_POSSIBLE, _
        $WIMLIB_ERR_IMAGE_HAS_MULTIPLE_REFERENCES, $WIMLIB_ERR_DUPLICATE_EXPORTED_IMAGE, $WIMLIB_ERR_CONCURRENT_MODIFICATION_DETECTED, $WIMLIB_ERR_SNAPSHOT_FAILURE, $WIMLIB_ERR_INVALID_XATTR, $WIMLIB_ERR_SET_XATTR
; WimLib_CHANGE
Global Const $WIMLIB_CHANGE_READONLY_FLAG                       = 0x00000001
Global Const $WIMLIB_CHANGE_GUID                                = 0x00000002
Global Const $WIMLIB_CHANGE_BOOT_INDEX                          = 0x00000004
Global Const $WIMLIB_CHANGE_RPFIX_FLAG                          = 0x00000008
; WimLib_ADD_FLAG
Global Const $WIMLIB_ADD_FLAG_NTFS                              = 0x00000001
Global Const $WIMLIB_ADD_FLAG_DEREFERENCE                       = 0x00000002
Global Const $WIMLIB_ADD_FLAG_VERBOSE                           = 0x00000004
Global Const $WIMLIB_ADD_FLAG_BOOT                              = 0x00000008
Global Const $WIMLIB_ADD_FLAG_UNIX_DATA                         = 0x00000010
Global Const $WIMLIB_ADD_FLAG_NO_ACLS                           = 0x00000020
Global Const $WIMLIB_ADD_FLAG_STRICT_ACLS                       = 0x00000040
Global Const $WIMLIB_ADD_FLAG_EXCLUDE_VERBOSE                   = 0x00000080
Global Const $WIMLIB_ADD_FLAG_RPFIX                             = 0x00000100
Global Const $WIMLIB_ADD_FLAG_NORPFIX                           = 0x00000200
Global Const $WIMLIB_ADD_FLAG_NO_UNSUPPORTED_EXCLUDE            = 0x00000400
Global Const $WIMLIB_ADD_FLAG_WINCONFIG                         = 0x00000800
Global Const $WIMLIB_ADD_FLAG_WIMBOOT                           = 0x00001000
Global Const $WIMLIB_ADD_FLAG_NO_REPLACE                        = 0x00002000
Global Const $WIMLIB_ADD_FLAG_TEST_FILE_EXCLUSION               = 0x00004000
Global Const $WIMLIB_ADD_FLAG_SNAPSHOT                          = 0x00008000
Global Const $WIMLIB_ADD_FLAG_FILE_PATHS_UNNEEDED               = 0x00010000
; WimLib_WRITE_FLAG
Global Const $WIMLIB_WRITE_FLAG_CHECK_INTEGRITY                 = 0x00000001
Global Const $WIMLIB_WRITE_FLAG_NO_CHECK_INTEGRITY              = 0x00000002
Global Const $WIMLIB_WRITE_FLAG_PIPABLE                         = 0x00000004
Global Const $WIMLIB_WRITE_FLAG_NOT_PIPABLE                     = 0x00000008
Global Const $WIMLIB_WRITE_FLAG_RECOMPRESS                      = 0x00000010
Global Const $WIMLIB_WRITE_FLAG_FSYNC                           = 0x00000020
Global Const $WIMLIB_WRITE_FLAG_REBUILD                         = 0x00000040
Global Const $WIMLIB_WRITE_FLAG_SOFT_DELETE                     = 0x00000080
Global Const $WIMLIB_WRITE_FLAG_IGNORE_READONLY_FLAG            = 0x00000100
Global Const $WIMLIB_WRITE_FLAG_SKIP_EXTERNAL_WIMS              = 0x00000200
Global Const $WIMLIB_WRITE_FLAG_SKIP_EXTERNAL_WIM               = $WIMLIB_WRITE_FLAG_SKIP_EXTERNAL_WIMS ; old (misspelled) name
Global Const $WIMLIB_WRITE_FLAG_STREAMS_OK                      = 0x00000400
Global Const $WIMLIB_WRITE_FLAG_RETAIN_GUID                     = 0x00000800
Global Const $WIMLIB_WRITE_FLAG_SOLID                           = 0x00001000
Global Const $WIMLIB_WRITE_FLAG_SEND_DONE_WITH_FILE_MESSAGES    = 0x00002000
Global Const $WIMLIB_WRITE_FLAG_NO_SOLID_SORT                   = 0x00004000
Global Const $WIMLIB_WRITE_FLAG_UNSAFE_COMPACT                  = 0x00008000
; WimLib_DELETE_FLAG
Global Const $WIMLIB_DELETE_FLAG_FORCE                          = 0x00000001
Global Const $WIMLIB_DELETE_FLAG_RECURSIVE                      = 0x00000002
; WimLib_EXPORT_FLAG
Global Const $WIMLIB_EXPORT_FLAG_BOOT                           = 0x00000001
Global Const $WIMLIB_EXPORT_FLAG_NO_NAMES                       = 0x00000002
Global Const $WIMLIB_EXPORT_FLAG_NO_DESCRIPTIONS                = 0x00000004
Global Const $WIMLIB_EXPORT_FLAG_GIFT                           = 0x00000008
Global Const $WIMLIB_EXPORT_FLAG_WIMBOOT                        = 0x00000010
; WimLib_UPDATE_FLAG_SEND_PROGRESS
Global Const $WIMLIB_UPDATE_FLAG_SEND_PROGRESS                  = 0x00000001
; Kept for compatibility with the old (misspelled) name
Global Const $WIMLIB_PROGRESS_MSG_WRITE_METADATA_EN             = $WIMLIB_PROGRESS_MSG_WRITE_METADATA_END
; Extract flags
Global Const $WIMLIB_EXTRACT_FLAG_NTFS                          = 0x00000001
Global Const $WIMLIB_EXTRACT_FLAG_RECOVER_DATA                  = 0x00000002
Global Const $WIMLIB_EXTRACT_FLAG_UNIX_DATA                     = 0x00000020
Global Const $WIMLIB_EXTRACT_FLAG_NO_ACLS                       = 0x00000040
Global Const $WIMLIB_EXTRACT_FLAG_STRICT_ACLS                   = 0x00000080
Global Const $WIMLIB_EXTRACT_FLAG_RPFIX                         = 0x00000100
Global Const $WIMLIB_EXTRACT_FLAG_NORPFIX                       = 0x00000200
Global Const $WIMLIB_EXTRACT_FLAG_REPLACE_INVALID_FILENAMES     = 0x00000800
Global Const $WIMLIB_EXTRACT_FLAG_ALL_CASE_CONFLICTS            = 0x00001000
Global Const $WIMLIB_EXTRACT_FLAG_STRICT_TIMESTAMPS             = 0x00002000
Global Const $WIMLIB_EXTRACT_FLAG_STRICT_SHORT_NAMES            = 0x00004000
Global Const $WIMLIB_EXTRACT_FLAG_STRICT_SYMLINKS               = 0x00008000
Global Const $WIMLIB_EXTRACT_FLAG_NO_ATTRIBUTES                 = 0x00100000
Global Const $WIMLIB_EXTRACT_FLAG_TO_STDOUT                     = 0x00000400
Global Const $WIMLIB_EXTRACT_FLAG_GLOB_PATHS                    = 0x00040000
Global Const $WIMLIB_EXTRACT_FLAG_STRICT_GLOB                   = 0x00080000
Global Const $WIMLIB_EXTRACT_FLAG_NO_PRESERVE_DIR_STRUCTURE     = 0x00200000
Global Const $WIMLIB_EXTRACT_FLAG_COMPACT_XPRESS4K              = 0x01000000
Global Const $WIMLIB_EXTRACT_FLAG_COMPACT_XPRESS8K              = 0x02000000
Global Const $WIMLIB_EXTRACT_FLAG_COMPACT_XPRESS16K             = 0x04000000
Global Const $WIMLIB_EXTRACT_FLAG_COMPACT_LZX                   = 0x08000000
Global Const $WIMLIB_EXTRACT_FLAG_WIMBOOT                       = 0x00400000
; Images
Global Const $WIMLIB_PROGRESS_MSG_UNMOUNT_BEGIN                 = 25
Global Const $WIMLIB_ERR_MOUNTED_IMAGE_IS_BUSY                  = 79
Global Const $WIMLIB_ERR_NOT_A_MOUNTPOINT                       = 80
Global Const $WIMLIB_ERR_NOT_PERMITTED_TO_UNMOUNT               = 81
Global Const $WIMLIB_NO_IMAGE                                   = 0
Global Const $WIMLIB_ALL_IMAGES                                 = -1
; Shim error codes (see WimShim.h). Codes >= 0 are wimlib's own.
Global Const $WIM_SHIM_ERR_BUSY                                 = -100 ; a job is already running
Global Const $WIM_SHIM_ERR_THREAD                               = -101 ; unable to start the worker thread
Global Const $WIM_SHIM_ERR_NO_JOB                               = -102 ; no job to wait for / cancel
; ===============================================================================================================================

Global $g_hWim = -1

; ======================================================================
; DLL mgmt
; ======================================================================
; Loads WimShim.dll and initialises wimlib.
; libwim-15.dll is searched in the folder of WimShim.dll (SetDllDirectoryW), not only in AutoIt's own folder.
Func Wim_LoadDLL($sPath = @ScriptDir & "\WimShim.dll")
    If Wim_IsLoaded() Then Return True
    If Not @AutoItX64 Then Return SetError(1, 0, False) ; needs AutoIt3_x64.exe
    If Not FileExists($sPath) Then Return SetError(2, 0, False)

    Local $sDir = StringLeft($sPath, StringInStr($sPath, "\", 0, -1) - 1)
    If $sDir <> "" Then DllCall("kernel32.dll", "bool", "SetDllDirectoryW", "wstr", $sDir)

    Local $hDll = DllOpen($sPath)
    If $hDll = -1 Then Return SetError(3, 0, False)

    Local $aRet = DllCall($hDll, "int:cdecl", "Wim_Init")
    If @error Or $aRet[0] <> 0 Then
        DllClose($hDll)
        Return SetError(4, 0, False)
    EndIf
    $g_hWim = $hDll
    Return True
EndFunc

Func Wim_UnloadDLL()
    If $g_hWim <> -1 Then
        DllCall($g_hWim, "none:cdecl", "Wim_Shutdown")
        DllClose($g_hWim)
        $g_hWim = -1
    EndIf
EndFunc

Func Wim_IsLoaded()
    Return ($g_hWim <> -1)
EndFunc

; ======================================================================
; Error / Version
; ======================================================================
Func Wim_ErrorString($code)
    If Not Wim_IsLoaded() Then Return ""
    Local $aRet = DllCall($g_hWim, "wstr:cdecl", "Wim_ErrorString", _
        "int", $code)
    If @error Then Return ""
    Return $aRet[0]
EndFunc

Func Wim_Version()
    If Not Wim_IsLoaded() Then Return ""
    Local $aRet = DllCall($g_hWim, "wstr:cdecl", "Wim_GetVersion")
    If @error Then Return ""
    Return $aRet[0]
EndFunc

Func Wim_HelloWorld()
    If Not Wim_IsLoaded() Then Return ""
    Local $aRet = DllCall($g_hWim, "str:cdecl", "HelloWorld")
    If @error Then Return ""
    Return $aRet[0]
EndFunc

Func _GetPhaseName($iPhase)
    Switch $iPhase
        Case $WIMLIB_PROGRESS_MSG_EXTRACT_IMAGE_BEGIN
            Return "Extract Image Begin"
        Case $WIMLIB_PROGRESS_MSG_EXTRACT_TREE_BEGIN
            Return "Extract Tree Begin"
        Case $WIMLIB_PROGRESS_MSG_EXTRACT_FILE_STRUCTURE
            Return "Extract File Structure"
        Case $WIMLIB_PROGRESS_MSG_EXTRACT_STREAMS
            Return "Extract Streams"
        Case $WIMLIB_PROGRESS_MSG_EXTRACT_SPWM_PART_BEGIN
            Return "Extract SPWM Part"
        Case $WIMLIB_PROGRESS_MSG_EXTRACT_METADATA
            Return "Extract Metadata"
        Case $WIMLIB_PROGRESS_MSG_EXTRACT_IMAGE_END
            Return "Extract Image End"
        Case $WIMLIB_PROGRESS_MSG_EXTRACT_TREE_END
            Return "Extract Tree End"
        Case $WIMLIB_PROGRESS_MSG_SCAN_BEGIN
            Return "Scan Begin"
        Case $WIMLIB_PROGRESS_MSG_SCAN_DENTRY
            Return "Scanning"
        Case $WIMLIB_PROGRESS_MSG_SCAN_END
            Return "Scan End"
        Case $WIMLIB_PROGRESS_MSG_WRITE_STREAMS
            Return "Write Streams"
        Case $WIMLIB_PROGRESS_MSG_WRITE_METADATA_BEGIN
            Return "Write Metadata Begin"
        Case $WIMLIB_PROGRESS_MSG_WRITE_METADATA_END
            Return "Write Metadata End"
        Case $WIMLIB_PROGRESS_MSG_CALC_INTEGRITY
            Return "Calculate Integrity"
        Case $WIMLIB_PROGRESS_MSG_VERIFY_INTEGRITY
            Return "Verify Integrity"
        Case $WIMLIB_PROGRESS_MSG_BEGIN_VERIFY_IMAGE
            Return "Verify Image"
        Case $WIMLIB_PROGRESS_MSG_VERIFY_STREAMS
            Return "Verify Streams"
        Case $WIMLIB_PROGRESS_MSG_SPLIT_BEGIN_PART
            Return "Split Begin Part"
        Case $WIMLIB_PROGRESS_MSG_SPLIT_END_PART
            Return "Split End Part"
        Case Else
            Return "Phase " & $iPhase
    EndSwitch
EndFunc


; ======================================================================
; Progress queries
; Output strings are received in DllStruct buffers (a "wstr" parameter
; initialised with "" would be a zero-length buffer the DLL overflows).
; ======================================================================
Func __Wim_Str($tStruct)
    Return DllStructGetData($tStruct, 1)
EndFunc

; ----------------------------------------------------------------------
; Wim_QueryScan() -> [rc, phase, current_path, nb_files, nb_dirs, scanned_size, size_unit, elapsed_s, remaining_s]
; ----------------------------------------------------------------------
Func Wim_QueryScan()
    If Not Wim_IsLoaded() Then Return SetError(1, 0, 0)
    Local $tPath = DllStructCreate("wchar[1040]")
    Local $tUnit = DllStructCreate("wchar[10]")
    Local $aRet = DllCall($g_hWim, "int:cdecl", "Wim_Query_Scan", _
        "int*",     0, _    ; phase
        "ptr",      DllStructGetPtr($tPath), _  ; current_path
        "int*",     0, _    ; nb_files
        "int*",     0, _    ; nb_dirs
        "int*",     0, _    ; scanned_size
        "ptr",      DllStructGetPtr($tUnit), _  ; size_unit
        "int*",     0, _    ; elapsed_s
        "int*",     0)      ; remaining_s
    If @error Then Return SetError(1, 0, 0)
    $aRet[2] = __Wim_Str($tPath)
    $aRet[6] = __Wim_Str($tUnit)
    Return $aRet
EndFunc

; ----------------------------------------------------------------------
; Wim_Query_CaptureAppend() -> array, index = position of the DLL parameter:
; [0]rc [1]phase [2]elapsed_from_start_s [3]ThreadCount [4]current_path [5]total_bytes [6]total_bytes_Unit
; [7]completed_bytes [8]completed_bytes_Unit [9]total_streams [10]completed_streams [11]percent (0-100, double)
; [12]elapsed_s [13]remaining_s [14]total_parts [15]completed_parts [16]completed_compressed_MiB [17]returncode
; Also valid for Apply and Split (fields that do not apply stay 0).
; ----------------------------------------------------------------------
Func Wim_Query_CaptureAppend()
    If Not Wim_IsLoaded() Then Return SetError(1, 0, 0)
    Local $tPath = DllStructCreate("wchar[1040]")
    Local $tTotU = DllStructCreate("wchar[10]")
    Local $tCmpU = DllStructCreate("wchar[10]")
    Local $aRet = DllCall($g_hWim, "int:cdecl", "Wim_Query_CaptureAppend", _
        "int*",     0, _    ; phase
        "int*",     0, _    ; elapsed_from_start_s
        "int*",     0, _    ; ThreadCount
        "ptr",      DllStructGetPtr($tPath), _  ; current_path
        "int*",     0, _    ; total_bytes
        "ptr",      DllStructGetPtr($tTotU), _  ; total_bytes_Unit
        "int*",     0, _    ; completed_bytes
        "ptr",      DllStructGetPtr($tCmpU), _  ; completed_bytes_Unit
        "int*",     0, _    ; total_streams
        "int*",     0, _    ; completed_streams
        "double*",  0, _    ; percent
        "int*",     0, _    ; elapsed_s
        "int*",     0, _    ; remaining_s
        "int*",     0, _    ; total_parts
        "int*",     0, _    ; completed_parts
        "int*",     0, _    ; completed_compressed_bytes (MiB)
        "int*",     0)      ; returncode
    If @error Then Return SetError(1, 0, 0)
    $aRet[4] = __Wim_Str($tPath)
    $aRet[6] = __Wim_Str($tTotU)
    $aRet[8] = __Wim_Str($tCmpU)
    Return $aRet
EndFunc

; ----------------------------------------------------------------------
; Wim_Query_Verify() -> array:
; [0]rc [1]phase [2]elapsed_from_start_s [3]total_bytes [4]total_bytes_Unit [5]completed_bytes [6]completed_bytes_Unit
; [7]total_streams [8]completed_streams [9]percent [10]elapsed_s [11]remaining_s [12]returncode
; ----------------------------------------------------------------------
Func Wim_Query_Verify()
    If Not Wim_IsLoaded() Then Return SetError(1, 0, 0)
    Local $tTotU = DllStructCreate("wchar[10]")
    Local $tCmpU = DllStructCreate("wchar[10]")
    Local $aRet = DllCall($g_hWim, "int:cdecl", "Wim_Query_Verify", _
        "int*",     0, _    ; phase
        "int*",     0, _    ; elapsed_from_start_s
        "int*",     0, _    ; total_bytes
        "ptr",      DllStructGetPtr($tTotU), _  ; total_bytes_Unit
        "int*",     0, _    ; completed_bytes
        "ptr",      DllStructGetPtr($tCmpU), _  ; completed_bytes_Unit
        "int*",     0, _    ; total_streams
        "int*",     0, _    ; completed_streams
        "double*",  0, _    ; percent
        "int*",     0, _    ; elapsed_s
        "int*",     0, _    ; remaining_s
        "int*",     0)      ; returncode
    If @error Then Return SetError(1, 0, 0)
    $aRet[4] = __Wim_Str($tTotU)
    $aRet[6] = __Wim_Str($tCmpU)
    Return $aRet
EndFunc


; ======================================================================
; Job control (one asynchronous job at a time: capture, append, apply, split, verify)
; ======================================================================
; 1 while the worker thread runs
Func Wim_IsRunning()
    Local $aRet = DllCall($g_hWim, "int:cdecl", "Wim_IsRunning")
    If @error Then Return SetError(1, 0, 0)
    Return $aRet[0]
EndFunc

; Requests the stop of the running job; it then ends with $WIMLIB_ERR_ABORTED_BY_PROGRESS.
; Returns 0, or $WIM_SHIM_ERR_NO_JOB if nothing is running.
Func Wim_Cancel()
    Local $aRet = DllCall($g_hWim, "int:cdecl", "Wim_Cancel")
    If @error Then Return SetError(1, 0, -1)
    Return $aRet[0]
EndFunc

; Waits for whatever job is running (same as the typed Wim_WaitXxx) and returns its result code.
; $fnTick: optional function (name as a string, e.g. "_MyTick", or a Func reference) called every $iSleep ms
;          while the job runs (progress display...). If it returns False the job is cancelled (Wim_Cancel)
;          and the wait goes on until the job ends.
Func Wim_Wait($fnTick = Default, $iSleep = 100)
    Local $bCancelled = False
    Local $bTick = IsFunc($fnTick) Or (IsString($fnTick) And $fnTick <> "")
    While Wim_IsRunning()
        If $bTick And Not $bCancelled Then
            If Call($fnTick) = False Then
                Wim_Cancel()
                $bCancelled = True
            EndIf
        EndIf
        Sleep($iSleep)
    WEnd
    Return Wim_WaitCapture()
EndFunc


; ======================================================================
; Wim_GetWimInfo() -> Array
; [ rc, imageCount, bootIndex, compType, hasIntegrity, chunkSize, totalBytes, partNumber, totalParts, isReadonly ]
; rc = code wimlib (0 = success)
; ======================================================================
Func Wim_GetWimInfo($sWim)
    Local $aRet = DllCall($g_hWim, "int:cdecl", "Wim_GetWimInfo", _
        "wstr",     $sWim, _    ; wimPath
        "int*",     0, _        ; imageCount
        "int*",     0, _        ; bootIndex
        "int*",     0, _        ; compressionType
        "int*",     0, _        ; hasIntegrity
        "uint*",    0, _        ; chunkSize
        "uint64*",  0, _        ; totalBytes
        "int*",     0, _        ; partNumber
        "int*",     0, _        ; totalParts
        "int*",     0)          ; isReadonly
    If @error Then Return SetError(1, 0, 0)
    ; $aRet = [rc, wimPath, imageCount, bootIndex, ...]: drop the echoed wimPath
    Local $a[10]
    $a[0] = $aRet[0]
    For $i = 1 To 9
        $a[$i] = $aRet[$i + 1]
    Next
    Return $a
EndFunc

; ======================================================================
; Wim_ListImages($sWim) -> [rc, imageCount, textLines]
; textLines = "idx|name|desc|flags\n..." (CRs removed here)
; ======================================================================
Func Wim_ListImages($sWim)
    Local $aRet = DllCall($g_hWim, "wstr:cdecl", "Wim_ListImages", _
        "wstr",     $sWim, _    ; wimPath
        "int*",     0, _        ; imageCount
        "int*",     0)          ; returncode
    If @error Then Return SetError(1, 0, 0)
    Local $a[3]
    $a[0] = $aRet[3]
    $a[1] = $aRet[2]
    $a[2] = StringStripCR($aRet[0])
    Return $a
EndFunc

; ======================================================================
; Wim_GetImageInfoEx($sWim, $idx) -> detailed array
; DLL line: "name|desc|flags|dirCount|fileCount|totalBytes|hardLinkBytes|creationTime|lastModTime"
; Array:    [rc, isBoot, name, desc, flags, dirCount, fileCount, totalBytes, hardLinkBytes, creationTime, lastModTime]
; Times are "YYYY-MM-DD HH:MM:SS" (UTC). A '|' inside name/desc breaks the split.
; ======================================================================
Func Wim_GetImageInfoEx($sWim, $idx)
    Local $aRet = DllCall($g_hWim, "wstr:cdecl", "Wim_GetImageInfo", _
        "wstr",     $sWim, _    ; wimPath
        "int",      $idx, _     ; imageIndex
        "int*",     0, _        ; isBoot
        "int*",     0)          ; returncode
    If @error Then Return SetError(1, 0, 0)
    Local $parts = StringSplit($aRet[0], "|", 2) ; 0-based, no count element

    Local $a[11]
    $a[0] = $aRet[4]            ; rc
    $a[1] = $aRet[3]            ; isBoot
    For $i = 0 To 8
        If $i < UBound($parts) Then
            $a[$i + 2] = $parts[$i]
        Else
            $a[$i + 2] = ""
        EndIf
    Next
    For $i = 4 To 8             ; flags, dirs, files, totalBytes, hardLinkBytes
        $a[$i] = Number($a[$i])
    Next
    Return $a
EndFunc

; ======================================================================
; Wim_GetImageProperty($sWim, $idx, $propName) -> string ("" if absent)
; @extended = wimlib return code
; ======================================================================
Func Wim_GetImageProperty($sWim, $idx, $propName)
    Local $aRet = DllCall($g_hWim, "wstr:cdecl", "Wim_GetImageProperty", _
        "wstr",     $sWim, _        ; wimPath
        "int",      $idx, _         ; imageIndex
        "wstr",     $propName, _    ; propName
        "int*",     0)              ; returncode
    If @error Then Return SetError(1, 0, "")
    Return SetError(0, $aRet[4], $aRet[0])
EndFunc

; ======================================================================
; Wim_GetXml($sWim) -> [rc, sizeChars, xmlText]
; ======================================================================
Func Wim_GetXml($sWim)
    Local $aRet = DllCall($g_hWim, "wstr:cdecl", "Wim_GetXml", _
        "wstr",     $sWim, _    ; wimPath
        "uint64*",  0, _        ; sizeChars
        "int*",     0)          ; returncode
    If @error Then Return SetError(1, 0, 0)
    Local $a[3]
    $a[0] = $aRet[3]
    $a[1] = $aRet[2]
    $a[2] = $aRet[0]
    Return $a
EndFunc


; ======================================================================
; Modify an existing WIM (synchronous). Return: wimlib rc (0 = success)
; ======================================================================
; $iImage = $WIMLIB_ALL_IMAGES to delete every image
Func Wim_DeleteImage($sWim, $iImage, $iWriteFlags = 0)
    Local $aRet = DllCall($g_hWim, "int:cdecl", "Wim_DeleteImage", _
        "wstr",     $sWim, _
        "int",      $iImage, _
        "int",      $iWriteFlags)
    If @error Then Return -1
    Return $aRet[0]
EndFunc

; $sProp e.g. "NAME", "DESCRIPTION", "FLAGS", "WINDOWS/EDITIONID"; $sValue = "" removes it
Func Wim_SetImageProperty($sWim, $iImage, $sProp, $sValue, $iWriteFlags = 0)
    Local $aRet = DllCall($g_hWim, "int:cdecl", "Wim_SetImageProperty", _
        "wstr",     $sWim, _
        "int",      $iImage, _
        "wstr",     $sProp, _
        "wstr",     $sValue, _
        "int",      $iWriteFlags)
    If @error Then Return -1
    Return $aRet[0]
EndFunc

; $iBoot = 0 => no boot image
Func Wim_SetBootIndex($sWim, $iBoot, $iWriteFlags = 0)
    Local $aRet = DllCall($g_hWim, "int:cdecl", "Wim_SetBootIndex", _
        "wstr",     $sWim, _
        "int",      $iBoot, _
        "int",      $iWriteFlags)
    If @error Then Return -1
    Return $aRet[0]
EndFunc

; Copies image $iSrcImage ($WIMLIB_ALL_IMAGES for all) of $sSrcWim into $sDestWim (created if missing).
; $sName / $sDesc: "" = keep the source ones (single image only)
Func Wim_ExportImage($sSrcWim, $iSrcImage, $sDestWim, $sName = "", $sDesc = "", $iExportFlags = 0, $iWriteFlags = 0)
    Local $aRet = DllCall($g_hWim, "int:cdecl", "Wim_ExportImage", _
        "wstr",     $sSrcWim, _
        "int",      $iSrcImage, _
        "wstr",     $sDestWim, _
        "wstr",     $sName, _
        "wstr",     $sDesc, _
        "int",      $iExportFlags, _
        "int",      $iWriteFlags)
    If @error Then Return -1
    Return $aRet[0]
EndFunc


; ======================================================================
; CAPTURE (async) — name & description supported
; Pass "" (empty string) to let the shim generate them.
; Returns 0 if the job started, else an error code (see Wim_ErrorString).
; $chunkSize is rounded to the nearest value allowed by the compression type (0 = default).
; ======================================================================
Func Wim_StartCapture($sSrc, $sDest, $sName = "", $sDesc = "", $iComp = $WIMLIB_COMPRESSION_TYPE_LZX, $iCompLvl = 50, $addFlags = 0, $writeFlags = $WIMLIB_WRITE_FLAG_NO_CHECK_INTEGRITY, $chunkSize = 0, $ThreadCount = 0)
    Local $aRet = DllCall($g_hWim, "int:cdecl", "Wim_StartCapture", _
        "wstr",     $sSrc, _        ; srcDir
        "wstr",     $sDest, _       ; destWim
        "wstr",     $sName, _       ; imageName
        "wstr",     $sDesc, _       ; imageDesc
        "int",      $iComp, _       ; CompressionType
        "int",      $iCompLvl, _    ; CompressionLevel
        "int",      $addFlags, _    ; addFlags
        "int",      $writeFlags, _  ; writeFlags
        "uint",     $chunkSize, _   ; chunkSizeBytes
        "int",      $ThreadCount)   ; threadCount
    If @error Then Return -1
    Return $aRet[0]
EndFunc

Func Wim_WaitCapture()
    Local $aRet = DllCall($g_hWim, "int:cdecl", "Wim_WaitCapture")
    If @error Then Return -1
    Return $aRet[0]
EndFunc

; ======================================================================
; APPEND (async) — name & description supported
; Adds an image to an existing WIM.
; $sName / $sDesc empty => auto.
; $comp = -1 keeps the current compression; otherwise $WIMLIB_COMPRESSION_TYPE_*.
; NOTE: to really recompress the whole WIM add $WIMLIB_WRITE_FLAG_RECOMPRESS
;       (and often $WIMLIB_WRITE_FLAG_REBUILD).
; ======================================================================
Func Wim_StartAppend($sSrc, $sDest, $sName = "", $sDesc = "", $comp = -1, $iCompLvl = 50, $addFlags = 0, $writeFlags = 0, $chunkSize = 0, $ThreadCount = 0)
    Local $aRet = DllCall($g_hWim, "int:cdecl", "Wim_StartAppend", _
        "wstr",     $sSrc, _        ; srcDir
        "wstr",     $sDest, _       ; destWim
        "wstr",     $sName, _       ; imageName
        "wstr",     $sDesc, _       ; imageDesc
        "int",      $comp, _        ; CompressionType
        "int",      $iCompLvl, _    ; CompressionLevel
        "int",      $addFlags, _    ; addFlags
        "int",      $writeFlags, _  ; writeFlags
        "uint",     $chunkSize, _   ; chunkSizeBytes
        "int",      $ThreadCount)   ; threadCount
    If @error Then Return -1
    Return $aRet[0]
EndFunc

Func Wim_WaitAppend()
    Local $aRet = DllCall($g_hWim, "int:cdecl", "Wim_WaitAppend")
    If @error Then Return -1
    Return $aRet[0]
EndFunc


; ======================================================================
; APPLY (async)
; - $sWimFile    : source .wim
; - $sImageId    : image number ("1"), image name, or "all"
; - $sTargetDir  : destination folder (must exist)
; - $iApplyFlags : $WIMLIB_EXTRACT_FLAG_*
; Returns 0 if the job started. Progress: Wim_Query_CaptureAppend().
; ======================================================================
Func Wim_StartApply($sWimFile, $sImageId, $sTargetDir, $iApplyFlags = 0)
    Local $aRet = DllCall($g_hWim, "int:cdecl", "Wim_StartApply", _
        "wstr",     $sWimFile, _    ; wimFile
        "wstr",     $sImageId, _    ; imageId
        "wstr",     $sTargetDir, _  ; destDir
        "int",      $iApplyFlags)   ; extractFlags
    If @error Then Return SetError(1, 0, -1)
    Return $aRet[0]
EndFunc

Func Wim_WaitApply()
    Local $aRet = DllCall($g_hWim, "int:cdecl", "Wim_WaitApply")
    If @error Then Return -1
    Return $aRet[0]
EndFunc


; ======================================================================
; SPLIT (async)
; Splits a WIM into SWM parts.
; - $sSrc           : source .wim
; - $sSwmPartFormat : first part name (e.g. "C:\out\part.swm" -> part.swm, part2.swm, ...)
; - $iPartSize      : maximum size of a part, in bytes
; - $iWriteFlags    : $WIMLIB_WRITE_FLAG_*
; Returns 0 if the job started. Progress: Wim_GetSplitProgress() or Wim_Query_CaptureAppend().
; ======================================================================
Func Wim_StartSplit($sSrc, $sSwmPartFormat, $iPartSize, $iWriteFlags = 0)
    Local $aRet = DllCall($g_hWim, "int:cdecl", "Wim_StartSplit", _
        "wstr",     $sSrc, _
        "wstr",     $sSwmPartFormat, _
        "uint64",   $iPartSize, _
        "int",      $iWriteFlags)
    If @error Or Not IsArray($aRet) Then Return SetError(1, 0, -1)
    Return $aRet[0]
EndFunc

Func Wim_WaitSplit()
    Local $aRet = DllCall($g_hWim, "int:cdecl", "Wim_WaitSplit")
    If @error Then Return -1
    Return $aRet[0]
EndFunc

; Current progress (0-100) of the Split job.
Func Wim_GetSplitProgress()
    Local $aRet = DllCall($g_hWim, "double:cdecl", "Wim_GetSplitProgress")
    If @error Or Not IsArray($aRet) Then Return SetError(1, 0, -1)
    Return $aRet[0]
EndFunc


; ======================================================================
; VERIFY (async)
; ======================================================================
Func Wim_StartVerify($sWim, $iVerifyFlags = 0)
    Local $aRet = DllCall($g_hWim, "int:cdecl", "Wim_StartVerify", _
        "wstr",     $sWim, _
        "int",      $iVerifyFlags)
    If @error Then Return -1
    Return $aRet[0]
EndFunc

Func Wim_WaitVerify()
    Local $aRet = DllCall($g_hWim, "int:cdecl", "Wim_WaitVerify")
    If @error Then Return -1
    Return $aRet[0]
EndFunc
