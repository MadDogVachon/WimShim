#include-once
#include <WinAPIFiles.au3>
#include <Array.au3>
#include <MsgBoxConstants.au3>

; ======================================================================
; WimLib.au3 – UDF AutoIt pour WimShim.dll
;   (nom & description supportés pour Capture / Append)
; ======================================================================

Global $g_hWim = -1

; États
Global Const $WIM_ST_IDLE    = 0
Global Const $WIM_ST_RUNNING = 1
Global Const $WIM_ST_DONE    = 2
Global Const $WIM_ST_ERROR   = 3

; Compression
Global Const $COMP_NONE   = 0
Global Const $COMP_XPRESS = 1
Global Const $COMP_LZX    = 2
Global Const $COMP_LZMS   = 3

; Add Flags (subset)
Global Const $ADD_NTFS        = 0x00000001
Global Const $ADD_DEREFERENCE = 0x00000002
Global Const $ADD_VERBOSE     = 0x00000004

; Write Flags (subset)
Global Const $WRITE_CHECK_INTEGRITY    = 0x00000001
Global Const $WRITE_NO_CHECK_INTEGRITY = 0x00000002
Global Const $WRITE_RECOMPRESS         = 0x00000010
Global Const $WRITE_REBUILD            = 0x00000040
Global Const $WRITE_IGNORE_READONLY    = 0x00000100
Global Const $WRITE_RETAIN_GUID        = 0x00000800

; Apply Flags
Global Const $WIMLIB_EXTRACT_FLAG_NONE = 0

; ======================================================================
; DLL mgmt
; ======================================================================
Func Wim_LoadDLL($sPath = @ScriptDir & "\WimShim.dll")
    $g_hWim = DllOpen($sPath)
    If $g_hWim = -1 Then
        $g_hWim = -1
        Return False
    EndIf
    Local $r = DllCall($g_hWim, "int:cdecl", "Wim_Init")
    If @error Or $r[0] <> 0 Then
        DllClose($g_hWim)
        $g_hWim = -1
        Return False
    EndIf
    Return True
EndFunc

Func Wim_UnloadDLL()
    If $g_hWim <> -1 Then
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
    Local $r = DllCall($g_hWim, "wstr:cdecl", "Wim_ErrorString", "int", $code)
    If @error Then Return ""
    Return $r[0]
EndFunc

Func Wim_Version()
    If Not Wim_IsLoaded() Then Return ""
    Local $r = DllCall($g_hWim, "wstr:cdecl", "Wim_GetVersion")
    If @error Then Return ""
    Return $r[0]
EndFunc

; ======================================================================
; Wim_GetWimInfo() -> Array
; [ rc, imageCount, bootIndex, compType, hasIntegrity, chunkSize, totalBytes, partNumber, totalParts, isReadonly ]
; rc = code wimlib (0 = success)
; ======================================================================
Func Wim_GetWimInfo($sWim)
    Local $r = DllCall($g_hWim, "int:cdecl", "Wim_GetWimInfo", _
        "wstr",    $sWim, _
        "int*",    0, _
        "int*",    0, _
        "int*",    0, _
        "int*",    0, _
        "uint*",   0, _
        "uint64*", 0, _
        "int*",    0, _
        "int*",    0, _
        "int*",    0)
    If @error Then Return SetError(1, 0, 0)

    Local $a[10]
    $a[0] = $r[0]  ; rc
    $a[1] = $r[2]  ; imageCount
    $a[2] = $r[3]  ; bootIndex
    $a[3] = $r[4]  ; compType
    $a[4] = $r[5]  ; hasIntegrity
    $a[5] = $r[6]  ; chunkSize
    $a[6] = $r[7]  ; totalBytes
    $a[7] = $r[8]  ; partNumber
    $a[8] = $r[9]  ; totalParts
    $a[9] = $r[10] ; isReadonly
    Return $a
EndFunc

; ======================================================================
; Wim_ListImages($sWim) -> [rc, imageCount, textLines]
; textLines = "idx|name|desc|flags\n..." (CRs supprimés dans wrapper)
; ======================================================================
Func Wim_ListImages($sWim)
    Local $r = DllCall($g_hWim, "wstr:cdecl", "Wim_ListImages", _
        "wstr", $sWim, _
        "int*", 0, _
        "int*", 0)
    If @error Then Return SetError(1, 0, 0)
    Local $rc   = $r[2]
    Local $cnt  = $r[3]
    Local $text = StringStripCR($r[0])
    Local $a[3]
    $a[0] = $rc
    $a[1] = $cnt
    $a[2] = $text
    Return $a
EndFunc

; ======================================================================
; Wim_GetImageInfoEx($sWim, $idx) -> array détaillée
; Retour interne: "name|desc|flags|dirCount|fileCount|totalBytes|hardLinkBytes|creationTime|lastModTime"
; Array AutoIt:  [rc, isBoot, name, desc, flags, dirCount, fileCount, totalBytes, hardLinkBytes, creationTime, lastModTime]
; ======================================================================
Func Wim_GetImageInfoEx($sWim, $idx)
    Local $r = DllCall($g_hWim, "wstr:cdecl", "Wim_GetImageInfo", _
        "wstr", $sWim, _
        "int",  $idx, _
        "int*", 0, _
        "int*", 0)
    If @error Then Return SetError(1, 0, 0)
    Local $rc     = $r[2]
    Local $isBoot = $r[3]
    Local $line   = $r[0]
    Local $parts  = StringSplit($line, "|", 1)

    Local $name="", $desc="", $flags="", $dirs="", $files="", $tot="", $hlb="", $ctime="", $mtime=""
    If $parts[0] >= 1 Then $name  = $parts[1]
    If $parts[0] >= 2 Then $desc  = $parts[2]
    If $parts[0] >= 3 Then $flags = $parts[3]
    If $parts[0] >= 4 Then $dirs  = $parts[4]
    If $parts[0] >= 5 Then $files = $parts[5]
    If $parts[0] >= 6 Then $tot   = $parts[6]
    If $parts[0] >= 7 Then $hlb   = $parts[7]
    If $parts[0] >= 8 Then $ctime = $parts[8]
    If $parts[0] >= 9 Then $mtime = $parts[9]

    Local $a[11]
    $a[0] = $rc
    $a[1] = $isBoot
    $a[2] = $name
    $a[3] = $desc
    $a[4] = Number($flags)
    $a[5] = Number($dirs)
    $a[6] = Number($files)
    $a[7] = Number($tot)
    $a[8] = Number($hlb)
    $a[9] = $ctime
    $a[10]= $mtime
    Return $a
EndFunc

; ======================================================================
; Wim_GetImageProperty($sWim, $idx, $propName) -> string
; ======================================================================
Func Wim_GetImageProperty($sWim, $idx, $propName)
    Local $r = DllCall($g_hWim, "wstr:cdecl", "Wim_GetImageProperty", _
        "wstr", $sWim, _
        "int",  $idx, _
        "wstr", $propName, _
        "int*", 0)
    If @error Then Return SetError(1, 0, "")
    Return $r[0] ; $r[4] = rc
EndFunc

; ======================================================================
; Wim_GetXml($sWim) -> [rc, sizeChars, xmlText]
; ======================================================================
Func Wim_GetXml($sWim)
    Local $r = DllCall($g_hWim, "wstr:cdecl", "Wim_GetXml", _
        "wstr",    $sWim, _
        "int*",    0, _
        "uint64*", 0) ; size_t
    If @error Then Return SetError(1, 0, 0)
    Local $rc   = $r[2]
    Local $sz   = $r[3]
    Local $text = $r[0]
    Local $a[3]
    $a[0] = $rc
    $a[1] = $sz
    $a[2] = $text
    Return $a
EndFunc

; ======================================================================
; CAPTURE (async) — *** NOM & DESC SUPPORTÉS ***
; Passer "" (chaîne vide) pour laisser Shim générer automatiquement.
; ======================================================================
Func Wim_StartCapture($sSrc, $sDest, $sName = "", $sDesc = "", $iComp = $COMP_LZX, $iCompLvl = 50, $addFlags = 0, $writeFlags = $WRITE_NO_CHECK_INTEGRITY, $chunkSize = 0, $ThreadCount = 0)
    Local $r = DllCall($g_hWim, "int:cdecl", "Wim_StartCapture", _
        "wstr", $sSrc, _
        "wstr", $sDest, _
        "wstr", $sName, _
        "wstr", $sDesc, _
        "int",  $iComp, _
        "int",  $iCompLvl, _
        "int",  $addFlags, _
        "int",  $writeFlags, _
        "uint", $chunkSize, _
        "int",  $ThreadCount)
    If @error Then Return -1
    Return $r[0]
EndFunc

Func Wim_QueryCapture()
    Local $aRet = DllCall($g_hWim, "int", "Wim_QueryCapture", _
        "int*", 0, "int*", 0, "double*", 0, "int*", 0, "int*", 0, "int*", 0)
    If @error Then Return SetError(1, 0, 0)
    Return $aRet
EndFunc

Func Wim_WaitCapture()
    Local $r = DllCall($g_hWim, "int:cdecl", "Wim_WaitCapture")
    If @error Then Return -1
    Return $r[0]
EndFunc

; ======================================================================
; APPEND (async) — *** NOM & DESC SUPPORTÉS ***
; Ajoute une image au WIM existant.
; $sName / $sDesc vides => auto.
; $comp = -1 pour conserver compression actuelle; sinon $COMP_*.
; NOTE: Pour réellement re‑compresser tout le WIM (uniformiser),
;       ajoutez $WRITE_RECOMPRESS (et souvent $WRITE_REBUILD).
; ======================================================================
Func Wim_StartAppend($sSrc, $sDest, $sName = "", $sDesc = "", $comp = -1, $iCompLvl = 50, $addFlags = 0, $writeFlags = 0, $chunkSize = 0, $ThreadCount = 0)
    Local $ret = DllCall($g_hWim, "int:cdecl", "Wim_StartAppend", _
        "wstr", $sSrc, _
        "wstr", $sDest, _
        "wstr", $sName, _
        "wstr", $sDesc, _
        "int",  $comp, _
        "int",  $iCompLvl, _
        "int",  $addFlags, _
        "int",  $writeFlags, _
        "uint", $chunkSize, _
        "int",  $ThreadCount)
    If @error Then Return -1
    Return $ret[0]
EndFunc

Func Wim_QueryAppend()
    Local $ret = DllCall($g_hWim, "int:cdecl", "Wim_QueryAppend", _
		"int*", 0, "int*", 0, "double*", 0, "int*", 0, "int*", 0, "int*", 0)
    If @error Then Return SetError(1, 0, 0)
    Return $ret
EndFunc

Func Wim_WaitAppend()
    Local $ret = DllCall($g_hWim, "int:cdecl", "Wim_WaitAppend")
    If @error Then Return -1
    Return $ret[0]
EndFunc


; =================================================================
; Wim_StartSplit
; Lance la tâche de Split (fractionnement d’un WIM en SWM).
; - $sWimPath       : Chemin complet du fichier source .wim
; - $sSwmPartFormat : Format des fichiers .swm à générer (ex: "part.swm")
; - $iPartSize      : Taille maximale d’un segment (en octets)
; - $iWriteFlags    : Drapeaux WIMLIB_WRITE_FLAG_*
;
; Retourne 0 si succès, ou un code d’erreur sinon.
; =================================================================
Func Wim_StartApply($sWimFile, $sImageId, $sTargetDir, $iApplyFlags = 0)
    Local $res = DllCall("WimShim.dll", "int", "Wim_StartApply", _
        "wstr", $sWimFile, _
        "wstr", $sImageId, _
        "wstr", $sTargetDir, _
        "int",  $iApplyFlags)
    If @error Then Return SetError(1, 0, -1)
    Return $res[0]
EndFunc

Func Wim_QueryApplyImage()
    Local $aRet = DllCall($g_hWim, "int", "Wim_QueryApplyImage", _
        "int*", 0, "int*", 0, "double*", 0, "int*", 0, "int*", 0, "int*", 0)
    If @error Then Return SetError(1, 0, 0)
    Return $aRet
EndFunc


; =================================================================
; Wim_StartSplit
; Lance la tâche de Split (fractionnement d’un WIM en SWM).
; - $sWimPath       : Chemin complet du fichier source .wim
; - $sSwmPartFormat : Format des fichiers .swm à générer (ex: "part.swm")
; - $iPartSize      : Taille maximale d’un segment (en octets)
; - $iWriteFlags    : Drapeaux WIMLIB_WRITE_FLAG_*
;
; Retourne 0 si succès, ou un code d’erreur sinon.
; =================================================================
Func Wim_StartSplit($sSrc, $sSwmPartFormat, $iPartSize, $iWriteFlags)
	Local $ret = DllCall($g_hWim, "int:cdecl", "Wim_StartSplit", "wstr", $sSrc, "wstr", $sSwmPartFormat, "uint64", $iPartSize, "int", $iWriteFlags)
	If @error Or Not IsArray($ret) Then Return SetError(1, 0, -1)
	Return $ret[0]
EndFunc

Func Wim_GetSplitProgress()	; Retourne le progrès courant (0–100) de la tâche de Split.
	Local $ret = DllCall($g_hWim, "int:cdecl", "Wim_GetSplitProgress")
	If @error Or Not IsArray($ret) Then Return SetError(1, 0, -1)
	Return $ret[0]
EndFunc


; ======================================================================
; VERIFY (async + sync helper)
; ======================================================================
Func Wim_StartVerify($sWim, $iVerifyFlags = 0)
    Local $r = DllCall($g_hWim, "int:cdecl", "Wim_StartVerify", "wstr", $sWim, "int", $iVerifyFlags)
    If @error Then Return -1
    Return $r[0]
EndFunc

Func Wim_QueryVerify()
    Local $ret = DllCall($g_hWim, "int:cdecl", "Wim_QueryVerify", "int*", 0, "double*", 0, "int*", 0)
    If @error Then Return SetError(1, 0, 0)
    Return $ret
EndFunc

Func Wim_WaitVerify()
    Local $r = DllCall($g_hWim, "int:cdecl", "Wim_WaitVerify")
    If @error Then Return -1
    Return $r[0]
EndFunc

Func Wim_Verify($sWim, $iVerifyFlags = 0)
    Local $rc = Wim_StartVerify($sWim, $iVerifyFlags)
    If $rc <> 0 Then Return $rc
    While 1
        Local $q = Wim_QueryVerify()
        If @error Then ExitLoop
        Local $st = $q[1]
        If $st = $WIM_ST_DONE Or $st = $WIM_ST_ERROR Then ExitLoop
        Sleep(50)
    WEnd
    Return Wim_WaitVerify()
EndFunc
