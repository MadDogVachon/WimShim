; #INDEX# =======================================================================================================================
; Title .........: WimShim_Test
; Description ...: Automated test suite for WimShim.au3 / WimShim.dll (wimlib bridge).
;                  Generates its own data, runs every exported function, compares the result of Apply with the source tree
;                  (MD5) and prints PASS / FAIL lines on the console and in WimShim_Test.log.
; Usage .........: AutoIt3_x64.exe WimShim_Test.au3 [/ui] [/keep] [/big] [/dir=<work folder>] [/dll=<path to WimShim.dll>]
;                    /ui    progress bar + message box at the end (default: silent, exit code = number of failures)
;                    /keep  do not delete the work folder at the end
;                    /big   ~600 MiB of data instead of ~30 MiB (to watch the progress for real)
;                    /dir   work folder (default @TempDir\WimShimTest); use it to test on a slow drive
; ===============================================================================================================================
#AutoIt3Wrapper_UseX64=y
#include <Array.au3>
#include <Crypt.au3>
#include <File.au3>
#include <FileConstants.au3>
#include <MsgBoxConstants.au3>
#include <String.au3>
#include <WinAPIHObj.au3>
#include <WinAPIFiles.au3>
#include "WimShim.au3"

Opt('MustDeclareVars', 1)

; ================================================================
; Global variables
; ================================================================
Global $g_iPass = 0, $g_iFail = 0, $g_iSkip = 0
Global $g_sLog = @ScriptDir & "\WimShim_Test.log"
Global $g_bUI = False, $g_bKeep = False, $g_bBig = False
Global $g_sRoot = @TempDir & "\WimShimTest"
Global $g_sDll = ""

; Progress sampling (filled by _Tick)
Global $g_iSamples = 0, $g_fLastPct = 0, $g_bPctDecreased = False, $g_fMaxPct = 0, $g_iMaxThreads = 0
Global $g_sPhasesSeen = "|", $g_iCancelAfterMs = -1, $g_hTickTimer = 0, $g_sTickKind = "capture", $g_bUIProgress = False

; Data set description (filled by _CreateData)
Global $g_sCapture, $g_sAppend, $g_iCapFiles, $g_iCapDirs, $g_iCapBytes, $g_iAppFiles, $g_iAppDirs, $g_iAppBytes
Global Const $MB = 1024 * 1024


_ParseCmdLine()
_Main()


; ================================================================
; Main
; ================================================================
Func _Main()
    FileDelete($g_sLog)
    _Log("WimShim test suite - " & @YEAR & "-" & @MON & "-" & @MDAY & " " & @HOUR & ":" & @MIN & ":" & @SEC)

    DirRemove($g_sRoot, 1)
    DirCreate($g_sRoot)
    _Log("Work folder: " & $g_sRoot)

    If _T_Load() Then
        _T_Validation()
        _CreateData()
        _T_Capture()
        _T_Info()
        _T_Verify()
        _T_Append()
        _T_Apply()
        _T_Split()
        _T_Modify()
        _T_Busy_Cancel()
    EndIf

    Wim_UnloadDLL()
    If Not $g_bKeep Then DirRemove($g_sRoot, 1)

    Local $sSummary = "PASS=" & $g_iPass & "  FAIL=" & $g_iFail & "  SKIP=" & $g_iSkip
    _Log(@CRLF & "==== " & $sSummary & " ====")
    If $g_bUI Then MsgBox(($g_iFail ? $MB_ICONERROR : $MB_ICONINFORMATION), "WimShim_Test", $sSummary & @CRLF & @CRLF & "Log: " & $g_sLog)
    Exit $g_iFail
EndFunc


; ================================================================
; 1. DLL loading, version, error strings
; ================================================================
Func _T_Load()
    _Section("DLL / version / errors")

    If $g_sDll = "" Then
        Local $aTry[3] = [@ScriptDir & "\x64\Debug\WimShim.dll", @ScriptDir & "\x64\Release\WimShim.dll", @ScriptDir & "\WimShim.dll"]
        For $s In $aTry
            If FileExists($s) Then
                $g_sDll = $s
                ExitLoop
            EndIf
        Next
    EndIf
    _Check($g_sDll <> "" And FileExists($g_sDll), "WimShim.dll found", $g_sDll)
    If $g_sDll = "" Then Return False

    _Check(Not Wim_IsLoaded(), "not loaded before Wim_LoadDLL")
    Local $bOk = Wim_LoadDLL($g_sDll)
    _Check($bOk, "Wim_LoadDLL", "@error=" & @error)
    If Not $bOk Then Return False
    _Check(Wim_IsLoaded(), "Wim_IsLoaded after load")
    _Check(Wim_LoadDLL($g_sDll), "Wim_LoadDLL twice is harmless")

    _Check(Wim_HelloWorld() = "Hello World from DLL!", "HelloWorld", Wim_HelloWorld())
    Local $sVer = Wim_Version()
    _Check(StringRegExp($sVer, "^\d+\.\d+\.\d+"), "Wim_Version looks like x.y.z", $sVer)
    _Log("       wimlib " & $sVer)

    _Check(Wim_ErrorString($WIMLIB_ERR_SUCCESS) <> "", "ErrorString(SUCCESS)", Wim_ErrorString($WIMLIB_ERR_SUCCESS))
    _Check(Wim_ErrorString($WIMLIB_ERR_INVALID_PARAM) <> "", "ErrorString(INVALID_PARAM)")
    _Check(StringInStr(Wim_ErrorString($WIM_SHIM_ERR_BUSY), "already"), "ErrorString(SHIM_ERR_BUSY)", Wim_ErrorString($WIM_SHIM_ERR_BUSY))
    _Check(Wim_ErrorString($WIM_SHIM_ERR_NO_JOB) <> "", "ErrorString(SHIM_ERR_NO_JOB)")
    _Check(Wim_ErrorString($WIM_SHIM_ERR_THREAD) <> "", "ErrorString(SHIM_ERR_THREAD)")
    _Check(Wim_ErrorString(-999) <> "", "ErrorString(unknown negative code) does not crash")
    Return True
EndFunc


; ================================================================
; 2. Parameter validation and failures (nothing must crash)
; ================================================================
Func _T_Validation()
    _Section("Invalid parameters / errors")
    Local $sMissing = $g_sRoot & "\does_not_exist.wim"

    _Check(Wim_WaitCapture() = $WIM_SHIM_ERR_NO_JOB, "Wait without job -> NO_JOB", Wim_WaitCapture())
    _Check(Wim_Cancel() = $WIM_SHIM_ERR_NO_JOB, "Cancel without job -> NO_JOB")
    _Check(Wim_IsRunning() = 0, "IsRunning without job = 0")

    Local $a = Wim_GetWimInfo($sMissing)
    _Check(IsArray($a) And $a[0] <> 0, "GetWimInfo on a missing file fails", IsArray($a) ? "rc=" & $a[0] : "no array")
    $a = Wim_ListImages($sMissing)
    _Check(IsArray($a) And $a[0] <> 0 And $a[1] = 0, "ListImages on a missing file fails")
    $a = Wim_GetImageInfoEx($sMissing, 1)
    _Check(IsArray($a) And $a[0] <> 0, "GetImageInfoEx on a missing file fails")
    $a = Wim_GetXml($sMissing)
    _Check(IsArray($a) And $a[0] <> 0 And $a[2] = "", "GetXml on a missing file fails")
    Local $s = Wim_GetImageProperty($sMissing, 1, "NAME")
    _Check($s = "" And @extended <> 0, "GetImageProperty on a missing file fails", "rc=" & @extended)

    ; not a WIM file
    Local $sFake = $g_sRoot & "\fake.wim"
    FileWrite($sFake, "this is not a wim file" & _StringRepeat("x", 5000))
    $a = Wim_GetWimInfo($sFake)
    _Check(IsArray($a) And $a[0] = $WIMLIB_ERR_NOT_A_WIM_FILE, "GetWimInfo on a text file -> NOT_A_WIM_FILE", IsArray($a) ? "rc=" & $a[0] : "")
    _Check(Wim_DeleteImage($sFake, 1) <> 0, "DeleteImage on a text file fails")

    ; async jobs that fail
    Local $rc = Wim_StartCapture($g_sRoot & "\no_such_folder", $g_sRoot & "\x.wim")
    _Check($rc = 0, "StartCapture on a missing folder starts the job", "rc=" & $rc)
    $rc = Wim_WaitCapture()
    _Check($rc <> 0, "...and the job reports an error", "rc=" & $rc & " " & Wim_ErrorString($rc))
    _Check(Wim_WaitCapture() = $WIM_SHIM_ERR_NO_JOB, "second Wait -> NO_JOB")

    $rc = Wim_StartApply($sMissing, "1", $g_sRoot)
    _Check($rc = 0, "StartApply on a missing wim starts the job")
    $rc = Wim_WaitApply()
    _Check($rc <> 0, "...and the job reports an error", "rc=" & $rc)

    $rc = Wim_StartVerify($sMissing)
    $rc = ($rc = 0) ? Wim_WaitVerify() : $rc
    _Check($rc <> 0, "Verify of a missing wim fails", "rc=" & $rc)

    $rc = Wim_StartSplit($sMissing, $g_sRoot & "\p.swm", 1 * $MB)
    $rc = ($rc = 0) ? Wim_WaitSplit() : $rc
    _Check($rc <> 0, "Split of a missing wim fails", "rc=" & $rc)
    _Check(Wim_StartSplit($sMissing, $g_sRoot & "\p.swm", 0) = $WIMLIB_ERR_INVALID_PARAM, "Split with part size 0 -> INVALID_PARAM")

    ; Sets of calls still possible after the failures
    _Check(Wim_IsRunning() = 0, "no job left running after the failures")
EndFunc


; ================================================================
; Data generation
; ================================================================
Func _CreateData()
    _Section("Test data generation")
    $g_sCapture = $g_sRoot & "\Capture"
    $g_sAppend = $g_sRoot & "\Append"
    Local $iBig = $g_bBig ? 100 : 4         ; MiB of random data per big file
    Local $iNbBig = $g_bBig ? 6 : 6

    ; ---- Capture tree ----
    DirCreate($g_sCapture & "\docs\sub\deep")
    DirCreate($g_sCapture & "\empty_dir")
    DirCreate($g_sCapture & "\data")
    DirCreate($g_sCapture & "\unicode_éàü")
    FileWrite($g_sCapture & "\readme.txt", "WimShim test file" & @CRLF)
    FileWrite($g_sCapture & "\docs\empty.bin", "")
    FileWrite($g_sCapture & "\docs\sub\deep\text.txt", _StringRepeat("Lorem ipsum dolor sit amet, consectetur adipiscing elit." & @CRLF, 40000))
    FileWrite($g_sCapture & "\unicode_éàü\fichier accentué - été.txt", "Contenu accentué : àéîõü ç ñ")
    For $i = 1 To $iNbBig
        _WriteRandomFile($g_sCapture & "\data\random" & $i & ".bin", $iBig * $MB)
    Next
    FileCopy($g_sCapture & "\data\random1.bin", $g_sCapture & "\data\duplicate_of_random1.bin")     ; dedup
    _CountTree($g_sCapture, $g_iCapFiles, $g_iCapDirs, $g_iCapBytes)
    _Check($g_iCapFiles > 0, "Capture tree created", $g_iCapFiles & " files, " & $g_iCapDirs & " dirs, " & _FmtBytes($g_iCapBytes))

    ; ---- Append tree ----
    DirCreate($g_sAppend & "\more\stuff")
    FileWrite($g_sAppend & "\second.txt", "Second image" & @CRLF)
    FileWrite($g_sAppend & "\more\stuff\log.txt", _StringRepeat("log line" & @CRLF, 5000))
    _WriteRandomFile($g_sAppend & "\more\blob.bin", 2 * $MB)
    _CountTree($g_sAppend, $g_iAppFiles, $g_iAppDirs, $g_iAppBytes)
    _Check($g_iAppFiles > 0, "Append tree created", $g_iAppFiles & " files, " & $g_iAppDirs & " dirs, " & _FmtBytes($g_iAppBytes))
EndFunc


; ================================================================
; 3. Capture (every compression type, chunk sizes, integrity, auto name/desc)
; ================================================================
Func _T_Capture()
    _Section("Capture")
    Local $sWim

    ; --- compression matrix: "type|label|requested chunk|expected chunk (0 = not checked)|level"
    Local $aCases[5] = [ _
        $WIMLIB_COMPRESSION_TYPE_NONE & "|NONE|0|0|0", _
        $WIMLIB_COMPRESSION_TYPE_XPRESS & "|XPRESS 64K|" & 64 * 1024 & "|" & 64 * 1024 & "|50", _
        $WIMLIB_COMPRESSION_TYPE_LZX & "|LZX 1M|" & $MB & "|" & $MB & "|50", _
        $WIMLIB_COMPRESSION_TYPE_LZX & "|LZX 100000 -> 128K|100000|" & 128 * 1024 & "|20", _
        $WIMLIB_COMPRESSION_TYPE_LZMS & "|LZMS 256K|" & 256 * 1024 & "|" & 256 * 1024 & "|30"]
    For $i = 0 To UBound($aCases) - 1
        Local $aC = StringSplit($aCases[$i], "|", 2)    ; [0]type [1]label [2]chunk [3]expected chunk [4]level
        Local $iType = Number($aC[0]), $sLabel = $aC[1], $iChunkReq = Number($aC[2]), $iChunkExp = Number($aC[3]), $iLevel = Number($aC[4])
        $sWim = $g_sRoot & "\cap_" & $i & ".wim"
        Local $sName = "Cap " & $sLabel, $sDesc = "Description of " & $sLabel
        _ProgressBegin("Capture " & $sLabel)
        Local $rc = Wim_StartCapture($g_sCapture, $sWim, $sName, $sDesc, $iType, $iLevel, 0, $WIMLIB_WRITE_FLAG_NO_CHECK_INTEGRITY, $iChunkReq, 0)
        _Check($rc = 0, "StartCapture " & $sLabel, "rc=" & $rc & " " & Wim_ErrorString($rc))
        If $rc <> 0 Then ContinueLoop
        $rc = _WaitJob("capture")
        _Check($rc = 0, "Capture " & $sLabel & " finishes OK", "rc=" & $rc & " " & Wim_ErrorString($rc))
        If $rc <> 0 Then ContinueLoop

        Local $a = Wim_GetWimInfo($sWim)
        If Not _Check(IsArray($a) And $a[0] = 0, "  GetWimInfo") Then ContinueLoop
        _Check($a[1] = 1, "  1 image", "count=" & $a[1])
        _Check($a[3] = $iType, "  compression type = " & _CompName($iType), "got " & _CompName($a[3]))
        If $iChunkExp > 0 Then _Check($a[5] = $iChunkExp, "  chunk size = " & _FmtBytes($iChunkExp), "got " & $a[5])
        _Check($a[4] = 0, "  no integrity table (NO_CHECK_INTEGRITY)")
        _Check($a[7] = 1 And $a[8] = 1, "  part 1/1", $a[7] & "/" & $a[8])
        _Check(FileGetSize($sWim) > 0, "  file exists, " & _FmtBytes(FileGetSize($sWim)))
        If $iType = $WIMLIB_COMPRESSION_TYPE_NONE Then
            _Check(FileGetSize($sWim) >= $g_iCapBytes - 5 * $MB, "  NONE: size ~ data size (dedup applies)")
        Else
            _Check(FileGetSize($sWim) < $g_iCapBytes, "  compressed < source (text + dedup)", FileGetSize($sWim) & " vs " & $g_iCapBytes)
        EndIf
        _CheckProgressSamples("  progress")
    Next

    ; --- reference wim used by the next tests: LZX, integrity table
    $sWim = $g_sRoot & "\Test.wim"
    _ProgressBegin("Capture reference wim")
    Local $sRefName = "Capture_" & @YEAR & @MON & @MDAY & "_" & @HOUR & @MIN & @SEC
    Local $rcRef = Wim_StartCapture($g_sCapture, $sWim, $sRefName, "Initial image of the Capture folder", $WIMLIB_COMPRESSION_TYPE_LZX, 50, 0, $WIMLIB_WRITE_FLAG_CHECK_INTEGRITY, 0, 0)
    _Check($rcRef = 0, "StartCapture (reference, integrity)")
    $rcRef = _WaitJob("capture")
    _Check($rcRef = 0, "Reference capture OK", "rc=" & $rcRef)
    Local $aI = Wim_GetWimInfo($sWim)
    _Check(IsArray($aI) And $aI[4] = 1, "reference wim has an integrity table")
    _CheckProgressSamples("  progress")

    ; --- scan progress after the capture
    Local $aScan = Wim_QueryScan()
    If _Check(IsArray($aScan), "Wim_QueryScan returns an array") Then
        _Check($aScan[3] >= $g_iCapFiles - 1, "  scan: files >= expected", $aScan[3] & " vs " & $g_iCapFiles)
        _Check($aScan[4] >= $g_iCapDirs, "  scan: dirs >= expected", $aScan[4] & " vs " & $g_iCapDirs)
        _Check($aScan[6] <> "", "  scan: size unit", "'" & $aScan[6] & "' " & $aScan[5])
        _Log("       scan -> " & $aScan[3] & " files, " & $aScan[4] & " dirs, " & $aScan[5] & " " & $aScan[6] & ", path=" & $aScan[2])
    EndIf

    ; --- automatic name and description
    $sWim = $g_sRoot & "\auto.wim"
    Local $rc2 = Wim_StartCapture($g_sCapture & "\docs", $sWim, "", "", $WIMLIB_COMPRESSION_TYPE_XPRESS)
    If _Check($rc2 = 0, "StartCapture with empty name/desc") Then
        _Check(_WaitJob("capture") = 0, "  capture OK")
        Local $aImg = Wim_GetImageInfoEx($sWim, 1)
        If IsArray($aImg) Then
            _Check($aImg[2] = "docs", "  auto name = folder name", $aImg[2])
            _Check($aImg[3] = "Captured from docs", "  auto desc", $aImg[3])
        EndIf
    EndIf

    ; --- trailing backslash on the source folder
    $sWim = $g_sRoot & "\auto2.wim"
    If Wim_StartCapture($g_sCapture & "\docs\", $sWim, "", "") = 0 Then
        _Check(Wim_WaitCapture() = 0, "capture with a trailing backslash")
        Local $aImg2 = Wim_GetImageInfoEx($sWim, 1)
        If IsArray($aImg2) Then _Check($aImg2[2] = "docs", "  auto name without the trailing backslash", $aImg2[2])
    EndIf

    ; --- thread count
    $sWim = $g_sRoot & "\threads.wim"
    If Wim_StartCapture($g_sCapture, $sWim, "T", "", $WIMLIB_COMPRESSION_TYPE_LZX, 20, 0, 0, 0, 2) = 0 Then
        _Check(Wim_WaitCapture() = 0, "capture with 2 threads")
        _Check(_Wim_Rc(Wim_GetWimInfo($sWim)) = 0, "  resulting wim is valid")
    EndIf
EndFunc


; ================================================================
; 4. Informations (wim, images, properties, XML)
; ================================================================
Func _T_Info()
    _Section("Info / images / properties / XML")
    Local $sWim = $g_sRoot & "\Test.wim"

    Local $a = Wim_GetWimInfo($sWim)
    If Not _Check(IsArray($a) And $a[0] = 0, "GetWimInfo") Then Return
    _Check(UBound($a) = 10, "  10 elements", UBound($a))
    _Check($a[1] = 1, "  imageCount = 1")
    _Check($a[2] = 0, "  bootIndex = 0")
    _Check($a[3] = $WIMLIB_COMPRESSION_TYPE_LZX, "  compression = LZX")
    _Check($a[4] = 1, "  hasIntegrity = 1")
    _Check($a[5] > 0, "  chunkSize > 0", $a[5])
    _Check($a[6] > 0 And $a[6] <= FileGetSize($sWim) + 1, "  totalBytes ~ file size", $a[6] & " vs " & FileGetSize($sWim))
    _Check($a[7] = 1 And $a[8] = 1, "  part 1/1")
    _Check($a[9] = 0, "  not read-only")

    Local $aL = Wim_ListImages($sWim)
    If _Check(IsArray($aL) And $aL[0] = 0, "ListImages") Then
        _Check($aL[1] = 1, "  count = 1")
        Local $aLine = StringSplit(StringStripWS($aL[2], 2), "|", 2)
        _Check(UBound($aLine) = 4 And $aLine[0] = "1" And StringLeft($aLine[1], 8) = "Capture_", "  line = idx|name|desc|flags", $aL[2])
        _Check(StringInStr($aL[2], "Initial image of the Capture folder") > 0, "  description in the list")
    EndIf

    Local $aImg = Wim_GetImageInfoEx($sWim, 1)
    If _Check(IsArray($aImg) And $aImg[0] = 0, "GetImageInfoEx(1)") Then
        _Check(UBound($aImg) = 11, "  11 elements")
        _Check($aImg[1] = 0, "  not boot")
        _Check(StringLeft($aImg[2], 8) = "Capture_", "  name", $aImg[2])
        _Check($aImg[3] = "Initial image of the Capture folder", "  description", $aImg[3])
        _Check($aImg[6] = $g_iCapFiles, "  fileCount = files created", $aImg[6] & " vs " & $g_iCapFiles)
        _Check($aImg[5] = $g_iCapDirs Or $aImg[5] = $g_iCapDirs + 1, "  dirCount = dirs created (root included or not)", $aImg[5] & " vs " & $g_iCapDirs)
        _Check($aImg[7] = $g_iCapBytes, "  totalBytes = sum of the file sizes", $aImg[7] & " vs " & $g_iCapBytes)
        _Check($aImg[8] >= 0, "  hardLinkBytes is numeric", $aImg[8])
        _Check(StringRegExp($aImg[9], "^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$"), "  creationTime format", "'" & $aImg[9] & "'")
        _Check(StringRegExp($aImg[10], "^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$"), "  lastModTime format", "'" & $aImg[10] & "'")
        _Check(Number(StringLeft($aImg[9], 4)) >= @YEAR - 1, "  creationTime is recent", $aImg[9])
    EndIf
    $aImg = Wim_GetImageInfoEx($sWim, 2)
    _Check(IsArray($aImg) And $aImg[0] = $WIMLIB_ERR_INVALID_IMAGE, "GetImageInfoEx(2) on a 1-image wim -> INVALID_IMAGE", IsArray($aImg) ? $aImg[0] : "")
    $aImg = Wim_GetImageInfoEx($sWim, 0)
    _Check(IsArray($aImg) And $aImg[0] <> 0, "GetImageInfoEx(0) fails")

    _Check(StringLeft(Wim_GetImageProperty($sWim, 1, "NAME"), 8) = "Capture_", "GetImageProperty NAME")
    _Check(Wim_GetImageProperty($sWim, 1, "DESCRIPTION") = "Initial image of the Capture folder", "GetImageProperty DESCRIPTION")
    _Check(Number(Wim_GetImageProperty($sWim, 1, "FILECOUNT")) = $g_iCapFiles, "GetImageProperty FILECOUNT")
    _Check(Number(Wim_GetImageProperty($sWim, 1, "TOTALBYTES")) = $g_iCapBytes, "GetImageProperty TOTALBYTES")
    Local $sNone = Wim_GetImageProperty($sWim, 1, "NO_SUCH_PROPERTY")
    _Check($sNone = "" And @error = 0 And @extended = 0, "GetImageProperty of an absent property = '' with rc 0")

    Local $aX = Wim_GetXml($sWim)
    If _Check(IsArray($aX) And $aX[0] = 0, "GetXml") Then
        _Check(StringInStr($aX[2], "<WIM>") > 0 And StringInStr($aX[2], "</WIM>") > 0, "  well-formed UTF-16 text (<WIM>...</WIM>)", StringLeft($aX[2], 60))
        _Check(StringInStr($aX[2], "Initial image of the Capture folder") > 0, "  contains the description")
        _Check($aX[1] = StringLen($aX[2]), "  sizeChars = text length", $aX[1] & " vs " & StringLen($aX[2]))
        FileDelete(@ScriptDir & "\wiminfo.xml")
        FileWrite(@ScriptDir & "\wiminfo.xml", $aX[2])
        _Check(FileExists(@ScriptDir & "\wiminfo.xml"), "  XML written to wiminfo.xml")
        FileDelete(@ScriptDir & "\wiminfo.xml")
    EndIf
EndFunc


; ================================================================
; 5. Verify (good wim, corrupted wim)
; ================================================================
Func _T_Verify()
    _Section("Verify")
    Local $sWim = $g_sRoot & "\Test.wim"

    _ProgressBegin("Verify")
    $g_sTickKind = "verify"
    Local $rc = Wim_StartVerify($sWim, 0)
    _Check($rc = 0, "StartVerify", "rc=" & $rc)
    $rc = _WaitJob("verify")
    _Check($rc = 0, "Verify of a good wim = 0", "rc=" & $rc & " " & Wim_ErrorString($rc))
    Local $q = Wim_Query_Verify()
    If _Check(IsArray($q), "Wim_Query_Verify returns an array") Then
        _Check(UBound($q) = 13, "  13 elements", UBound($q))
        _Check($q[9] = 100, "  percent = 100 at the end", $q[9])
        _Check($q[12] = 0, "  returncode = 0")
        _Check($q[7] > 0 And $q[8] = $q[7], "  completed streams = total streams", $q[8] & "/" & $q[7])
        _Check($q[4] <> "" And $q[6] <> "", "  units", $q[3] & " " & $q[4] & " / " & $q[5] & " " & $q[6])
    EndIf
    _CheckProgressSamples("  progress")

    ; Corrupt a copy: flip one byte in the middle (uncompressed wim => stream hash mismatch)
    Local $sBad = $g_sRoot & "\corrupt.wim"
    FileCopy($g_sRoot & "\cap_0.wim", $sBad, 1)
    _FlipByte($sBad, Int(FileGetSize($sBad) / 2))
    $rc = Wim_StartVerify($sBad, 0)
    $rc = ($rc = 0) ? _WaitJob("verify") : $rc
    _Check($rc <> 0, "Verify of a corrupted wim fails", "rc=" & $rc & " " & Wim_ErrorString($rc))
    _Check($rc = $WIMLIB_ERR_INVALID_RESOURCE_HASH Or $rc = $WIMLIB_ERR_DECOMPRESSION Or $rc = $WIMLIB_ERR_INTEGRITY, "  error is a hash / integrity error", $rc)
    Local $q2 = Wim_Query_Verify()
    _Check(IsArray($q2) And $q2[12] = $rc, "  Query_Verify.returncode = job result")
    $g_sTickKind = "capture"
EndFunc


; ================================================================
; 6. Append
; ================================================================
Func _T_Append()
    _Section("Append")
    Local $sWim = $g_sRoot & "\Test.wim"
    Local $sName = "Append_" & @YEAR & @MON & @MDAY & "_" & @HOUR & @MIN & @SEC

    ; keep compression (-1)
    _ProgressBegin("Append")
    Local $rc = Wim_StartAppend($g_sAppend, $sWim, $sName, "Added folder Append", -1, 50, 0, $WIMLIB_WRITE_FLAG_CHECK_INTEGRITY, 0, 0)
    _Check($rc = 0, "StartAppend (compression -1)", "rc=" & $rc)
    $rc = _WaitJob("append")
    _Check($rc = 0, "Append OK", "rc=" & $rc & " " & Wim_ErrorString($rc))
    _CheckProgressSamples("  progress")

    Local $a = Wim_GetWimInfo($sWim)
    If _Check(IsArray($a) And $a[0] = 0, "GetWimInfo after append") Then
        _Check($a[1] = 2, "  2 images", $a[1])
        _Check($a[3] = $WIMLIB_COMPRESSION_TYPE_LZX, "  compression kept (LZX)", _CompName($a[3]))
        _Check($a[4] = 1, "  integrity table kept")
    EndIf
    Local $aImg = Wim_GetImageInfoEx($sWim, 2)
    If _Check(IsArray($aImg) And $aImg[0] = 0, "GetImageInfoEx(2)") Then
        _Check($aImg[2] = $sName, "  name", $aImg[2])
        _Check($aImg[3] = "Added folder Append", "  description", $aImg[3])
        _Check($aImg[6] = $g_iAppFiles, "  fileCount", $aImg[6] & " vs " & $g_iAppFiles)
        _Check($aImg[7] = $g_iAppBytes, "  totalBytes", $aImg[7] & " vs " & $g_iAppBytes)
    EndIf
    Local $aImg1 = Wim_GetImageInfoEx($sWim, 1)
    _Check(IsArray($aImg1) And $aImg1[6] = $g_iCapFiles, "image 1 untouched by the append")

    ; same name again => collision
    $rc = Wim_StartAppend($g_sAppend, $sWim, $sName, "again")
    $rc = ($rc = 0) ? Wim_WaitAppend() : $rc
    _Check($rc = $WIMLIB_ERR_IMAGE_NAME_COLLISION, "Append with an existing name -> IMAGE_NAME_COLLISION", "rc=" & $rc & " " & Wim_ErrorString($rc))
    $a = Wim_GetWimInfo($sWim)
    _Check(IsArray($a) And $a[1] = 2, "wim still has 2 images after the failed append")

    ; automatic name/desc
    $rc = Wim_StartAppend($g_sAppend & "\more", $sWim)
    $rc = ($rc = 0) ? Wim_WaitAppend() : $rc
    _Check($rc = 0, "Append with default parameters", "rc=" & $rc)
    $aImg = Wim_GetImageInfoEx($sWim, 3)
    If IsArray($aImg) Then
        _Check($aImg[2] = "more" And $aImg[3] = "Captured from more", "  auto name/desc", $aImg[2] & " / " & $aImg[3])
    EndIf

    ; append to a missing wim
    $rc = Wim_StartAppend($g_sAppend, $g_sRoot & "\missing.wim", "x", "y")
    $rc = ($rc = 0) ? Wim_WaitAppend() : $rc
    _Check($rc <> 0, "Append to a missing wim fails", "rc=" & $rc)

    ; change compression: XPRESS + RECOMPRESS on a copy
    Local $sCopy = $g_sRoot & "\recompress.wim"
    FileCopy($g_sRoot & "\cap_2.wim", $sCopy, 1)   ; LZX 1M
    $rc = Wim_StartAppend($g_sAppend, $sCopy, "Recompressed", "", $WIMLIB_COMPRESSION_TYPE_XPRESS, 30, 0, $WIMLIB_WRITE_FLAG_RECOMPRESS + $WIMLIB_WRITE_FLAG_REBUILD, 32 * 1024, 0)
    $rc = ($rc = 0) ? Wim_WaitAppend() : $rc
    _Check($rc = 0, "Append + RECOMPRESS + REBUILD (LZX -> XPRESS)", "rc=" & $rc & " " & Wim_ErrorString($rc))
    Local $aRc = Wim_GetWimInfo($sCopy)
    If IsArray($aRc) And $aRc[0] = 0 Then
        _Check($aRc[1] = 2, "  2 images", $aRc[1])
        _Check($aRc[3] = $WIMLIB_COMPRESSION_TYPE_XPRESS, "  wim is now XPRESS", _CompName($aRc[3]))
    EndIf
    Local $rcV = Wim_StartVerify($sCopy)
    $rcV = ($rcV = 0) ? Wim_WaitVerify() : $rcV
    _Check($rcV = 0, "  recompressed wim verifies", "rc=" & $rcV)
EndFunc


; ================================================================
; 7. Apply (content compared with the source)
; ================================================================
Func _T_Apply()
    _Section("Apply")
    Local $sWim = $g_sRoot & "\Test.wim"
    Local $sSigCap = _TreeSig($g_sCapture)
    Local $sSigApp = _TreeSig($g_sAppend)
    _Check($sSigCap <> "", "source signature computed", StringLen($sSigCap) & " chars")

    ; by index
    Local $sDest = $g_sRoot & "\Apply1"
    DirCreate($sDest)
    _ProgressBegin("Apply image 1")
    Local $rc = Wim_StartApply($sWim, "1", $sDest, 0)
    _Check($rc = 0, "StartApply image 1", "rc=" & $rc)
    $rc = _WaitJob("apply")
    _Check($rc = 0, "Apply image 1 OK", "rc=" & $rc & " " & Wim_ErrorString($rc))
    _Check(_TreeSig($sDest) == $sSigCap, "  applied tree identical to the source (names, sizes, MD5, empty dirs)")
    _CheckProgressSamples("  progress")
    Local $q = Wim_Query_CaptureAppend()
    If IsArray($q) Then
        _Check($q[11] = 100 And $q[17] = 0, "  final query: percent=100 returncode=0", $q[11] & " / " & $q[17])
        _Check($q[5] > 0 And $q[6] <> "", "  total bytes + unit reported", $q[5] & " " & $q[6])
    EndIf

    ; by image name
    Local $aImg2 = Wim_GetImageInfoEx($sWim, 2)
    Local $sDest2 = $g_sRoot & "\Apply2"
    DirCreate($sDest2)
    $rc = Wim_StartApply($sWim, $aImg2[2], $sDest2)
    $rc = ($rc = 0) ? Wim_WaitApply() : $rc
    _Check($rc = 0, "Apply by image NAME", "rc=" & $rc & " " & Wim_ErrorString($rc))
    _Check(_TreeSig($sDest2) == $sSigApp, "  applied tree identical to the Append folder")

    ; by the real index 2
    Local $sDest3 = $g_sRoot & "\Apply3"
    DirCreate($sDest3)
    $rc = Wim_StartApply($sWim, "2", $sDest3)
    $rc = ($rc = 0) ? Wim_WaitApply() : $rc
    _Check($rc = 0 And _TreeSig($sDest3) == $sSigApp, "Apply image 2 by index")

    ; every image compression type can be applied
    For $i = 0 To 4
        Local $sD = $g_sRoot & "\ApplyC" & $i
        DirCreate($sD)
        $rc = Wim_StartApply($g_sRoot & "\cap_" & $i & ".wim", "1", $sD)
        $rc = ($rc = 0) ? Wim_WaitApply() : $rc
        _Check($rc = 0 And _TreeSig($sD) == $sSigCap, "Apply of cap_" & $i & ".wim (" & _CompName(_Wim_Field(Wim_GetWimInfo($g_sRoot & "\cap_" & $i & ".wim"), 3)) & ") identical", "rc=" & $rc)
        DirRemove($sD, 1)
    Next

    ; errors
    $rc = Wim_StartApply($sWim, "99", $g_sRoot & "\ApplyErr")
    $rc = ($rc = 0) ? Wim_WaitApply() : $rc
    _Check($rc = $WIMLIB_ERR_INVALID_IMAGE, "Apply of image 99 -> INVALID_IMAGE", "rc=" & $rc & " " & Wim_ErrorString($rc))
    $rc = Wim_StartApply($sWim, "no such image name", $g_sRoot & "\ApplyErr")
    $rc = ($rc = 0) ? Wim_WaitApply() : $rc
    _Check($rc = $WIMLIB_ERR_INVALID_IMAGE, "Apply of an unknown image name -> INVALID_IMAGE", "rc=" & $rc)

    DirRemove($sDest, 1)
    DirRemove($sDest2, 1)
    DirRemove($sDest3, 1)
EndFunc


; ================================================================
; 8. Split
; ================================================================
Func _T_Split()
    _Section("Split")
    Local $sWim = $g_sRoot & "\cap_0.wim"               ; uncompressed, ~ data size => several parts
    Local $sSwm = $g_sRoot & "\split\part.swm"
    DirCreate($g_sRoot & "\split")
    Local $iPart = $g_bBig ? 150 * $MB : 10 * $MB

    $g_sTickKind = "split"
    _ProgressBegin("Split")
    Local $rc = Wim_StartSplit($sWim, $sSwm, $iPart, 0)
    _Check($rc = 0, "StartSplit", "rc=" & $rc & " " & Wim_ErrorString($rc))
    $rc = _WaitJob("split")
    _Check($rc = 0, "Split finishes OK", "rc=" & $rc & " " & Wim_ErrorString($rc))
    _Check(Wim_GetSplitProgress() = 100, "GetSplitProgress = 100 at the end", Wim_GetSplitProgress())
    _CheckProgressSamples("  progress")

    Local $aParts = _FileListToArray($g_sRoot & "\split", "part*.swm", $FLTA_FILES)
    Local $iParts = IsArray($aParts) ? $aParts[0] : 0
    _Check($iParts >= 2, "several .swm parts written", $iParts)
    Local $iTotal = 0, $bOk = True
    For $i = 1 To $iParts
        Local $sPart = $g_sRoot & "\split\" & $aParts[$i]
        Local $aP = Wim_GetWimInfo($sPart)
        $iTotal += FileGetSize($sPart)
        If Not (IsArray($aP) And $aP[0] = 0 And $aP[8] = $iParts) Then
            $bOk = False
            _Log("       bad part " & $aParts[$i] & ": " & (IsArray($aP) ? "rc=" & $aP[0] & " parts=" & $aP[8] : "?"))
        EndIf
        _Check(FileGetSize($sPart) <= $iPart + 4 * $MB, "  " & $aParts[$i] & " size <= part size (+ overhead)", _FmtBytes(FileGetSize($sPart)))
    Next
    _Check($bOk, "every part reports totalParts = " & $iParts)
    Local $aP1 = Wim_GetWimInfo($sSwm)
    _Check(IsArray($aP1) And $aP1[7] = 1 And $aP1[8] = $iParts, "part.swm is part 1/" & $iParts)
    _Check($iTotal >= FileGetSize($sWim) - 1 * $MB, "sum of the parts ~ source size", _FmtBytes($iTotal) & " vs " & _FmtBytes(FileGetSize($sWim)))

    ; existing output + too small part size
    $rc = Wim_StartSplit($g_sRoot & "\does_not_exist.wim", $sSwm, $iPart)
    $rc = ($rc = 0) ? Wim_WaitSplit() : $rc
    _Check($rc <> 0, "Split of a missing wim fails")
    $g_sTickKind = "capture"
EndFunc


; ================================================================
; 9. Modify an existing wim: properties, boot index, export, delete
; ================================================================
Func _T_Modify()
    _Section("Properties / boot / export / delete")
    Local $sWim = $g_sRoot & "\modify.wim"
    FileCopy($g_sRoot & "\Test.wim", $sWim, 1)           ; 3 images
    Local $a = Wim_GetWimInfo($sWim)
    _Check(IsArray($a) And $a[1] = 3, "working copy has 3 images", IsArray($a) ? $a[1] : "")

    ; SetImageProperty
    Local $rc = Wim_SetImageProperty($sWim, 1, "NAME", "Renamed image", $WIMLIB_WRITE_FLAG_CHECK_INTEGRITY)
    _Check($rc = 0, "SetImageProperty NAME", "rc=" & $rc & " " & Wim_ErrorString($rc))
    _Check(Wim_GetImageProperty($sWim, 1, "NAME") = "Renamed image", "  NAME read back")
    $rc = Wim_SetImageProperty($sWim, 1, "DESCRIPTION", "Accents: éàü")
    _Check($rc = 0 And Wim_GetImageProperty($sWim, 1, "DESCRIPTION") = "Accents: éàü", "SetImageProperty DESCRIPTION (accents)", "rc=" & $rc)
    $rc = Wim_SetImageProperty($sWim, 1, "DESCRIPTION", "")
    _Check($rc = 0 And Wim_GetImageProperty($sWim, 1, "DESCRIPTION") = "", "SetImageProperty with '' removes the property", "rc=" & $rc)
    $rc = Wim_SetImageProperty($sWim, 1, "FLAGS", "Enterprise")
    _Check($rc = 0 And Wim_GetImageProperty($sWim, 1, "FLAGS") = "Enterprise", "SetImageProperty FLAGS", "rc=" & $rc)
    $rc = Wim_SetImageProperty($sWim, 2, "NAME", "Renamed image")
    _Check($rc = $WIMLIB_ERR_IMAGE_NAME_COLLISION, "SetImageProperty NAME colliding with image 1 -> IMAGE_NAME_COLLISION", "rc=" & $rc)
    _Check(Wim_SetImageProperty($sWim, 9, "NAME", "x") <> 0, "SetImageProperty on image 9 fails")
    _Check(Wim_SetImageProperty($sWim, 0, "NAME", "x") = $WIMLIB_ERR_INVALID_PARAM, "SetImageProperty on image 0 -> INVALID_PARAM")

    ; Boot index
    $rc = Wim_SetBootIndex($sWim, 2)
    _Check($rc = 0, "SetBootIndex(2)", "rc=" & $rc & " " & Wim_ErrorString($rc))
    $a = Wim_GetWimInfo($sWim)
    _Check(IsArray($a) And $a[2] = 2, "  bootIndex = 2", IsArray($a) ? $a[2] : "")
    Local $aB = Wim_GetImageInfoEx($sWim, 2)
    _Check(IsArray($aB) And $aB[1] = 1, "  image 2 isBoot = 1")
    $aB = Wim_GetImageInfoEx($sWim, 1)
    _Check(IsArray($aB) And $aB[1] = 0, "  image 1 isBoot = 0")
    _Check(Wim_SetBootIndex($sWim, 9) <> 0, "SetBootIndex(9) on a 3-image wim fails")
    $rc = Wim_SetBootIndex($sWim, 0)
    $a = Wim_GetWimInfo($sWim)
    _Check($rc = 0 And IsArray($a) And $a[2] = 0, "SetBootIndex(0) clears the boot image")

    ; Export: new wim
    Local $sExp = $g_sRoot & "\export.wim"
    $rc = Wim_ExportImage($sWim, 2, $sExp)
    _Check($rc = 0, "ExportImage 2 -> new wim", "rc=" & $rc & " " & Wim_ErrorString($rc))
    $a = Wim_GetWimInfo($sExp)
    If _Check(IsArray($a) And $a[0] = 0 And $a[1] = 1, "  export.wim has 1 image") Then
        _Check($a[3] = $WIMLIB_COMPRESSION_TYPE_LZX, "  compression copied from the source (LZX)", _CompName($a[3]))
        Local $aE = Wim_GetImageInfoEx($sExp, 1)
        _Check(IsArray($aE) And $aE[7] = $g_iAppBytes, "  exported content size", IsArray($aE) ? $aE[7] : "")
    EndIf
    ; Export: existing wim + new name/description
    $rc = Wim_ExportImage($sWim, 1, $sExp, "Exported copy", "Exported description")
    _Check($rc = 0, "ExportImage 1 -> existing wim with a new name", "rc=" & $rc & " " & Wim_ErrorString($rc))
    $a = Wim_GetWimInfo($sExp)
    _Check(IsArray($a) And $a[1] = 2, "  export.wim now has 2 images")
    _Check(Wim_GetImageProperty($sExp, 2, "NAME") = "Exported copy" And Wim_GetImageProperty($sExp, 2, "DESCRIPTION") = "Exported description", "  new name/description applied")
    ; Export again: name collision
    $rc = Wim_ExportImage($sWim, 1, $sExp, "Exported copy")
    _Check($rc <> 0, "ExportImage with an existing name fails", "rc=" & $rc & " " & Wim_ErrorString($rc))
    ; Export all images
    Local $sExpAll = $g_sRoot & "\export_all.wim"
    $rc = Wim_ExportImage($sWim, $WIMLIB_ALL_IMAGES, $sExpAll)
    $a = Wim_GetWimInfo($sExpAll)
    _Check($rc = 0 And IsArray($a) And $a[1] = 3, "ExportImage ALL_IMAGES -> 3 images", "rc=" & $rc)
    _Check(Wim_ExportImage($g_sRoot & "\missing.wim", 1, $sExp) <> 0, "ExportImage from a missing wim fails")
    _Check(Wim_ExportImage($sWim, 0, $sExp) = $WIMLIB_ERR_INVALID_PARAM, "ExportImage of image 0 -> INVALID_PARAM")

    ; The exported wim is usable: verify + apply
    Local $rcV = Wim_StartVerify($sExp)
    $rcV = ($rcV = 0) ? Wim_WaitVerify() : $rcV
    _Check($rcV = 0, "exported wim verifies", "rc=" & $rcV)

    ; Delete image
    $rc = Wim_DeleteImage($sWim, 1, $WIMLIB_WRITE_FLAG_CHECK_INTEGRITY)
    _Check($rc = 0, "DeleteImage(1)", "rc=" & $rc & " " & Wim_ErrorString($rc))
    $a = Wim_GetWimInfo($sWim)
    If _Check(IsArray($a) And $a[1] = 2, "  2 images left", IsArray($a) ? $a[1] : "") Then
        Local $aD = Wim_GetImageInfoEx($sWim, 1)
        _Check(IsArray($aD) And StringLeft($aD[2], 7) = "Append_", "  old image 2 is now image 1", IsArray($aD) ? $aD[2] : "")
    EndIf
    _Check(Wim_DeleteImage($sWim, 9) = $WIMLIB_ERR_INVALID_IMAGE, "DeleteImage(9) -> INVALID_IMAGE")
    _Check(Wim_DeleteImage($sWim, 0) = $WIMLIB_ERR_INVALID_PARAM, "DeleteImage(0) -> INVALID_PARAM")
    $rc = Wim_DeleteImage($sWim, $WIMLIB_ALL_IMAGES)
    $a = Wim_GetWimInfo($sWim)
    _Check($rc = 0 And IsArray($a) And $a[1] = 0, "DeleteImage(ALL_IMAGES) -> empty wim", "rc=" & $rc)
    $rcV = Wim_StartVerify($g_sRoot & "\export_all.wim")
    $rcV = ($rcV = 0) ? Wim_WaitVerify() : $rcV
    _Check($rcV = 0, "untouched export_all.wim still verifies", "rc=" & $rcV)
EndFunc


; ================================================================
; 10. Job control: busy, cancel, IsRunning, Wim_Wait callback
; ================================================================
Func _T_Busy_Cancel()
    _Section("Job control (busy / cancel / IsRunning)")

    ; --- busy: a second job is refused while the first one runs
    Local $sWim = $g_sRoot & "\busy.wim"
    Local $rc = Wim_StartCapture($g_sCapture, $sWim, "busy", "", $WIMLIB_COMPRESSION_TYPE_LZMS, 100, 0, 0, 0, 1)
    _Check($rc = 0, "StartCapture (LZMS 100, 1 thread: slow)", "rc=" & $rc)
    If Wim_IsRunning() Then
        _Check(True, "IsRunning = 1 while the job runs")
        Local $rc2 = Wim_StartCapture($g_sCapture, $g_sRoot & "\busy2.wim")
        _Check($rc2 = $WIM_SHIM_ERR_BUSY, "second StartCapture -> BUSY", "rc=" & $rc2)
        $rc2 = Wim_StartApply($sWim, "1", $g_sRoot)
        _Check($rc2 = $WIM_SHIM_ERR_BUSY, "StartApply during a job -> BUSY", "rc=" & $rc2)
        $rc2 = Wim_StartVerify($sWim)
        _Check($rc2 = $WIM_SHIM_ERR_BUSY, "StartVerify during a job -> BUSY", "rc=" & $rc2)
        $rc2 = Wim_StartSplit($sWim, $g_sRoot & "\b.swm", $MB)
        _Check($rc2 = $WIM_SHIM_ERR_BUSY, "StartSplit during a job -> BUSY", "rc=" & $rc2)
        $rc2 = Wim_StartAppend($g_sAppend, $sWim)
        _Check($rc2 = $WIM_SHIM_ERR_BUSY, "StartAppend during a job -> BUSY", "rc=" & $rc2)

        ; --- cancel
        Sleep(300)
        Local $hT = TimerInit()
        _Check(Wim_Cancel() = 0, "Wim_Cancel while running -> 0")
        $rc = Wim_WaitCapture()
        If $rc = $WIMLIB_ERR_ABORTED_BY_PROGRESS Then
            _Check(True, "cancelled job ends with ABORTED_BY_PROGRESS", "after " & Round(TimerDiff($hT)) & " ms")
            Else
            _Skip("cancel: job finished before the cancel was noticed", "rc=" & $rc)
        EndIf
    Else
        _Skip("busy / cancel: the job was already over", "rc=" & Wim_WaitCapture())
    EndIf
    _Check(Wim_IsRunning() = 0, "IsRunning = 0 when over")

    ; --- a new job works after a cancel
    $sWim = $g_sRoot & "\after_cancel.wim"
    $rc = Wim_StartCapture($g_sCapture & "\docs", $sWim, "after", "", $WIMLIB_COMPRESSION_TYPE_XPRESS)
    _Check($rc = 0 And Wim_WaitCapture() = 0, "a new capture works after the cancel")

    ; --- Wim_Wait with a tick callback that cancels
    $g_iCancelAfterMs = 200
    $g_hTickTimer = TimerInit()
    $rc = Wim_StartCapture($g_sCapture, $g_sRoot & "\tick.wim", "tick", "", $WIMLIB_COMPRESSION_TYPE_LZMS, 100, 0, 0, 0, 1)
    If $rc = 0 Then
        Local $iWait = Wim_Wait("_Tick")
        If $iWait = $WIMLIB_ERR_ABORTED_BY_PROGRESS Then
            _Check(True, "Wim_Wait(tick returning False) cancels the job")
        Else
            _Skip("Wim_Wait cancel: job finished first", "rc=" & $iWait)
        EndIf
    EndIf
    $g_iCancelAfterMs = -1

    ; --- Wim_Wait without tick, no job left
    _Check(Wim_Wait() = $WIM_SHIM_ERR_NO_JOB, "Wim_Wait with no job -> NO_JOB")

    ; --- a finished job that was never waited for does not block the next one
    $rc = Wim_StartCapture($g_sCapture & "\docs", $g_sRoot & "\nowait.wim", "nowait", "", $WIMLIB_COMPRESSION_TYPE_NONE)
    Local $hW = TimerInit()
    While Wim_IsRunning() And TimerDiff($hW) < 30000
        Sleep(50)
    WEnd
    Local $rcNext = Wim_StartCapture($g_sCapture & "\docs", $g_sRoot & "\nowait2.wim", "nowait2", "", $WIMLIB_COMPRESSION_TYPE_NONE)
    _Check($rc = 0 And $rcNext = 0, "a finished job never waited for does not block the next start", "rc=" & $rc & "/" & $rcNext)
    Wim_WaitCapture()
EndFunc


; ================================================================
; Job waiting + progress sampling
; ================================================================
Func _ProgressBegin($sTitle)
    $g_iSamples = 0
    $g_fLastPct = 0
    $g_fMaxPct = 0
    $g_bPctDecreased = False
    $g_iMaxThreads = 0
    $g_sPhasesSeen = "|"
    $g_hTickTimer = TimerInit()
    If $g_bUI Then
        ProgressOn("WimShim_Test", $sTitle, "", -1, -1)
        $g_bUIProgress = True
    EndIf
    _Log("  ... " & $sTitle)
EndFunc

; Waits for the running job; returns its code. Samples the progress meanwhile.
Func _WaitJob($sKind = "")
    #forceref $sKind
    Local $rc = Wim_Wait("_Tick", 50)
    If $g_bUIProgress Then
        ProgressOff()
        $g_bUIProgress = False
    EndIf
    Return $rc
EndFunc

; Called by Wim_Wait every 50 ms. Returns False to cancel the job.
Func _Tick()
    Local $fPct = 0, $sExtra = ""
    Switch $g_sTickKind
        Case "split"
            $fPct = Wim_GetSplitProgress()
        Case "verify"
            Local $v = Wim_Query_Verify()
            If IsArray($v) Then
                $fPct = $v[9]
                _NotePhase($v[1])
                $sExtra = $v[5] & " " & $v[6] & " / " & $v[3] & " " & $v[4]
            EndIf
        Case Else
            Local $a = Wim_Query_CaptureAppend()
            If IsArray($a) Then
                $fPct = $a[11]
                _NotePhase($a[1])
                If $a[3] > $g_iMaxThreads Then $g_iMaxThreads = $a[3]
                $sExtra = _GetPhaseName($a[1]) & " " & $a[7] & " " & $a[8] & " / " & $a[5] & " " & $a[6] & " - elapsed " & $a[12] & "s, remaining " & $a[13] & "s"
                If $a[4] <> "" And $a[1] = $WIMLIB_PROGRESS_MSG_SCAN_DENTRY Then $sExtra &= @CRLF & $a[4]
            EndIf
    EndSwitch

    $g_iSamples += 1
    If $fPct > $g_fMaxPct Then $g_fMaxPct = $fPct
    If $fPct < $g_fLastPct - 0.0001 And $g_sTickKind <> "capture" Then $g_bPctDecreased = True   ; capture/append legitimately restart at 0 for the next phase
    $g_fLastPct = $fPct

    If $g_bUIProgress Then ProgressSet(Int($fPct), $sExtra, Round($fPct, 1) & " %")
    If $g_iCancelAfterMs >= 0 And TimerDiff($g_hTickTimer) >= $g_iCancelAfterMs Then Return False
    Return True
EndFunc

Func _NotePhase($iPhase)
    If Not StringInStr($g_sPhasesSeen, "|" & $iPhase & "|") Then $g_sPhasesSeen &= $iPhase & "|"
EndFunc

Func _CheckProgressSamples($sLabel)
    _Check($g_fMaxPct >= 0 And $g_fMaxPct <= 100.0001, $sLabel & ": percent stays within 0..100", "max=" & $g_fMaxPct)
    _Check(Not $g_bPctDecreased, $sLabel & ": percent never goes backwards")
    _Log("       " & $g_iSamples & " samples, max " & Round($g_fMaxPct, 2) & "%, phases " & $g_sPhasesSeen & ", threads " & $g_iMaxThreads)
EndFunc


; ================================================================
; Helpers
; ================================================================
Func _ParseCmdLine()
    For $i = 1 To $CmdLine[0]
        Local $s = $CmdLine[$i]
        Select
            Case $s = "/ui"
                $g_bUI = True
            Case $s = "/keep"
                $g_bKeep = True
            Case $s = "/big"
                $g_bBig = True
            Case StringLeft($s, 5) = "/dir="
                $g_sRoot = StringMid($s, 6)
            Case StringLeft($s, 5) = "/dll="
                $g_sDll = StringMid($s, 6)
        EndSelect
    Next
EndFunc

Func _Log($s)
    ConsoleWrite($s & @CRLF)
    FileWriteLine($g_sLog, $s)
EndFunc

Func _Section($s)
    _Log(@CRLF & "--- " & $s & " ---")
EndFunc

; Returns $bCond (so it can be used in If)
Func _Check($bCond, $sName, $sDetail = "")
    If $bCond Then
        $g_iPass += 1
        _Log("[PASS] " & $sName)
    Else
        $g_iFail += 1
        _Log("[FAIL] " & $sName & ($sDetail <> "" ? "  -> " & $sDetail : ""))
    EndIf
    Return $bCond
EndFunc

Func _Skip($sName, $sDetail = "")
    $g_iSkip += 1
    _Log("[SKIP] " & $sName & ($sDetail <> "" ? "  -> " & $sDetail : ""))
EndFunc

; Random (incompressible) file, written by 1 MiB blocks
Func _WriteRandomFile($sPath, $iBytes)
    Local $tBuf = DllStructCreate("byte[" & $MB & "]")
    Local $hFile = FileOpen($sPath, $FO_OVERWRITE + $FO_CREATEPATH + $FO_BINARY)
    Local $iLeft = $iBytes
    While $iLeft > 0
        Local $iChunk = ($iLeft > $MB) ? $MB : $iLeft
        DllCall("advapi32.dll", "bool", "SystemFunction036", "struct*", $tBuf, "ulong", $MB)     ; RtlGenRandom
        FileWrite($hFile, BinaryMid(DllStructGetData($tBuf, 1), 1, $iChunk))
        $iLeft -= $iChunk
    WEnd
    FileClose($hFile)
EndFunc

Func _FlipByte($sPath, $iOffset)
    Local $hFile = _WinAPI_CreateFile($sPath, 2, 4)
    If Not $hFile Then Return False
    Local $tB = DllStructCreate("byte")
    Local $iRead = 0, $iWritten = 0
    _WinAPI_SetFilePointer($hFile, $iOffset)
    _WinAPI_ReadFile($hFile, $tB, 1, $iRead)
    DllStructSetData($tB, 1, BitXOR(DllStructGetData($tB, 1), 0xFF))
    _WinAPI_SetFilePointer($hFile, $iOffset)
    _WinAPI_WriteFile($hFile, $tB, 1, $iWritten)
    _WinAPI_CloseHandle($hFile)
    Return $iWritten = 1
EndFunc

; Number of files / directories / total bytes under $sDir (root not counted)
Func _CountTree($sDir, ByRef $iFiles, ByRef $iDirs, ByRef $iBytes)
    $iFiles = 0
    $iDirs = 0
    $iBytes = 0
    Local $a = _FileListToArrayRec($sDir, "*", $FLTAR_FILESFOLDERS, $FLTAR_RECUR, $FLTAR_NOSORT, $FLTAR_FULLPATH)
    If Not IsArray($a) Then Return
    For $i = 1 To $a[0]
        If StringInStr(FileGetAttrib($a[$i]), "D") Then
            $iDirs += 1
        Else
            $iFiles += 1
            $iBytes += FileGetSize($a[$i])
        EndIf
    Next
EndFunc

; "D|rel" for directories, "F|rel|size|md5" for files, sorted; identical trees give identical strings
Func _TreeSig($sDir)
    Local $a = _FileListToArrayRec($sDir, "*", $FLTAR_FILESFOLDERS, $FLTAR_RECUR, $FLTAR_SORT, $FLTAR_RELPATH)
    If Not IsArray($a) Then Return ""
    Local $s = ""
    For $i = 1 To $a[0]
        Local $sFull = $sDir & "\" & $a[$i]
        If StringInStr(FileGetAttrib($sFull), "D") Then
            $s &= "D|" & $a[$i] & @LF
        Else
            $s &= "F|" & $a[$i] & "|" & FileGetSize($sFull) & "|" & Hex(_Crypt_HashFile($sFull, $CALG_MD5)) & @LF
        EndIf
    Next
    Return $s
EndFunc

Func _Wim_Rc($a)
    Return IsArray($a) ? $a[0] : -1
EndFunc

Func _Wim_Field($a, $i)
    Return IsArray($a) ? $a[$i] : -1
EndFunc

Func _FmtBytes($n)
    Local $KB = 1024, $MB2 = $KB * 1024, $GB = $MB2 * 1024
    If $n >= $GB Then Return Round($n / $GB, 2) & " GiB"
    If $n >= $MB2 Then Return Round($n / $MB2, 2) & " MiB"
    If $n >= $KB Then Return Round($n / $KB, 2) & " KiB"
    Return $n & " B"
EndFunc

Func _CompName($i)
    Switch $i
        Case $WIMLIB_COMPRESSION_TYPE_NONE
            Return "NONE"
        Case $WIMLIB_COMPRESSION_TYPE_XPRESS
            Return "XPRESS"
        Case $WIMLIB_COMPRESSION_TYPE_LZX
            Return "LZX"
        Case $WIMLIB_COMPRESSION_TYPE_LZMS
            Return "LZMS"
    EndSwitch
    Return "?"
EndFunc
