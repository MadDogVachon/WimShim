#include "WimShim.au3"
#include <MsgBoxConstants.au3>
#RequireAdmin
Opt('MustDeclareVars', 1)

; ================================================================
; Constantes et variables globales
; ================================================================
; Calcule le chemin du dossier parent
Local $sParentDir = StringLeft(@ScriptDir, StringInStr(@ScriptDir, "\", 0, -1) - 1)

Global $sDossierTest	= $sParentDir & "\Test\"
Global $sSrc			= $sDossierTest & "Capture"
Global $sSrcAppend		= $sDossierTest & "Append"
Global $sOut			= $sDossierTest & "Test.wim"
Global $sApplyDest		= "L:\WimShim\Apply"
Global $iChunkBlock		= 1024 * 1024

; Paramètres de capture
Global $iComp			= $COMP_LZX
Global $iCompLevel		= 50
Global $iAdd			= 0
Global $iWriteFlags		= $WRITE_CHECK_INTEGRITY
Global $iChunk			= $iChunkBlock * 64
Global $iThreadCount	= 0
Global $sCapName		= "Capture_" & @YEAR & @MON & @MDAY & "_" & @HOUR & @MIN
Global $sCapDesc		= "Sauvegarde initiale du dossier TestFolder"

; Paramètres pour Append
Global $sAppName		= "Append_" & @YEAR & @MON & @MDAY & "_" & @HOUR & @MIN
Global $sAppDesc		= "Ajout du dossier TestFolderAppend"
; IMPORTANT :
;	- compress = -1  => utiliser les paramètres de compression du WIM existants (append rapide, mix possible)
;	- changer compression -> $COMP_* + $WRITE_RECOMPRESS (et souvent $WRITE_REBUILD)
Global $iAppComp		= -1
Global $iAppCompLevel	= 50
Global $iAppAdd			= 0
Global $iAppWriteFlags	= $WRITE_CHECK_INTEGRITY
Global $iAppChunk		= 0
Global $iAppThreadCount	= 0

; Paramètres pour Apply
Global $iApplyImageId	= "1"
Global $iApplyFlags		= 0
Global $sApplyConfig	= @ScriptDir & "\Config.ini"

; Paramètres pour split
Global $sSplitDest		= $sDossierTest & "Test_Part.swm"
Global $SplitSizeBytes	= $iChunkBlock * 150 ; 150 MiB

;~ MsgBox(0, "tata",	"$sDossierTest:   " & $sDossierTest & @CRLF & _
;~ 					"$sSrc:                 " & $sSrc & @CRLF & _
;~ 					"$sOut:                " & $sOut & @CRLF & _
;~ 					"$sSrcAppend:    " & $sSrcAppend & @CRLF & _
;~ 					"$sApplyDest:     " & $sApplyDest & @CRLF & _
;~ 					"$sSplitDest:       " & $sSplitDest)


; ================================================================
; Démarrage du script
; ================================================================
If Not Wim_LoadDLL(@ScriptDir & "\x64\Debug\WimShim.dll") Then
    _Message($MB_ICONERROR, "Erreur", "Wim_LoadDLL a échoué.")
    Exit
EndIf

Local $msg = "Choisissez une action à exécuter :" & @CRLF & _
			"1. Capture   2. Append" & @CRLF & _
			"3. Apply       4. Verify" & @CRLF & _
			"5. Split" & @CRLF & _
			"9. GetInfo    0. HelloWorld" & @CRLF & _
			"Annuler pour quitter."

Local $choice = InputBox("Menu de test WimShim", $msg, "3")
If @error Then Exit

Switch $choice
	Case "1"
		_TestCapture()
	Case "2"
		_TestAppend()
	Case "3"
		_TestApply()
	Case "4"
		_TestVerify()
	Case "5"
		_TestSplit()
	Case "9"
		_TestGetInfo()
	Case "0"
		_TestHelloWorld()
	Case Else
		_Message($MB_ICONWARNING, "Erreur de saisie", "Choix non valide.")
EndSwitch

GoExit()


; ================================================================
; Fonctions de test
; ================================================================

## HelloWorld
; Appelle la fonction HelloWorld de la DLL.
Func _TestHelloWorld()
    Local $ret = DllCall($g_hWim, "str:cdecl", "HelloWorld")
    If @error Then
        _Message($MB_ICONERROR, "Erreur", "Appel de HelloWorld a échoué")
    Else
        _Message($MB_ICONINFORMATION, "HelloWorld", $ret[0])
    EndIf
	Exit
EndFunc

## Capture	; -----     -----     -----     -----     -----
; Capture un dossier dans un fichier WIM.
Func _TestCapture()
    FileDelete($sOut)
    ProgressOn("Capture WIM", "Initialisation...", "", -1, -1)

    Local $r = Wim_StartCapture($sSrc, $sOut, $sCapName, $sCapDesc, $iComp, $iCompLevel, $iAdd, $iWriteFlags, $iChunk, $iThreadCount)
    If $r <> 0 Then
        _HandleError("Capture", "StartCapture a échoué", $r)
        Return
    EndIf

    _WaitAndShowProgress("Capture WIM", "Wim_QueryCapture")

    $r = Wim_WaitCapture()
    If $r <> 0 Then
        _HandleError("Capture", "WaitCapture a échoué", $r)
    Else
        _Message($MB_ICONINFORMATION, "Capture", "Capture terminée avec succès.")
    EndIf
EndFunc

## Append	; -----     -----     -----     -----     -----
; Ajoute un nouveau dossier en tant qu'image dans un fichier WIM existant.
Func _TestAppend()
    If Not FileExists($sOut) Then
        _Message($MB_ICONERROR, "Erreur", "Le fichier WIM (" & $sOut & ") n'existe pas. Veuillez lancer la capture d'abord.")
        Return
    EndIf

    ProgressOn("Append WIM", "Initialisation...", "", -1, -1)
    Local $r = Wim_StartAppend($sSrcAppend, $sOut, $sAppName, $sAppDesc, $iAppComp, $iAppCompLevel, $iAppAdd, $iAppWriteFlags, $iAppChunk, $iAppThreadCount)
    If $r <> 0 Then
        _HandleError("Append", "StartAppend a échoué", $r)
        Return
    EndIf

    _WaitAndShowProgress("Append WIM", "Wim_QueryAppend")

    $r = Wim_WaitAppend()
    If $r <> 0 Then
        _HandleError("Append", "WaitAppend a échoué", $r)
    Else
        _Message($MB_ICONINFORMATION, "Append", "Ajout terminé avec succès.")
    EndIf
EndFunc

## Apply	; -----     -----     -----     -----     -----
; Applique une image WIM vers un dossier de destination.
Func _TestApply()
    If Not FileExists($sOut) Then
        _Message($MB_ICONERROR, "Erreur", "Le fichier WIM (" & $sOut & ") n'existe pas. Veuillez lancer la capture d'abord.")
        Return
    EndIf

    DirRemove($sApplyDest, 1)
    DirCreate($sApplyDest)
    ProgressOn("Apply WIM", "Initialisation...", "", -1, -1)

    Local $r = Wim_StartApply($sOut, $iApplyImageId, $sApplyDest, $iApplyFlags)
    If $r <> 0 Then
        _HandleError("Apply", "ApplyImage a échoué", $r)
        Return
    EndIf

    _WaitAndShowProgress("Apply WIM", "Wim_QueryApplyImage")

	MsgBox(0, "Tata", "Fin d'apply")

;~     $r = Wim_WaitApply()
;~     If $r <> 0 Then
;~         _HandleError("Apply", "WaitApply a échoué", $r)
;~     Else
;~         _Message($MB_ICONINFORMATION, "Apply", "Application de l'image terminée avec succès.")
;~     EndIf
EndFunc

## Verify	; -----     -----     -----     -----     -----
; Vérifie l'intégrité d'un fichier WIM.
Func _TestVerify()
    If Not FileExists($sOut) Then
        _Message($MB_ICONERROR, "Erreur", "Le fichier WIM (" & $sOut & ") n'existe pas.")
        Return
    EndIf

    Local $r = Wim_StartVerify($sOut, 0)
    If $r <> 0 Then
        _HandleError("Verify", "StartVerify a échoué", $r)
        Return
    EndIf

    ProgressOn("Verify WIM", "Vérification en cours...", "", -1, -1)
    Local $old = -1
    While 1
        Local $a = Wim_QueryVerify()
        If @error Then ExitLoop
        Local $status = $a[1], $percent = $a[2]
        If $percent <> $old Then
            ProgressSet($percent, "Progression: " & $percent & "%", "Vérification en cours...")
            $old = $percent
        EndIf
        If $status = $WIM_ST_DONE Or $status = $WIM_ST_ERROR Then ExitLoop
        Sleep(250)
    WEnd
    ProgressOff()

    $r = Wim_WaitVerify()
    If $r <> 0 Then
        _HandleError("Verify", "WaitVerify a échoué", $r)
    Else
        _Message($MB_ICONINFORMATION, "Verify", "Vérification terminée avec succès.")
    EndIf
EndFunc

## Split	; -----     -----     -----     -----     -----
; Diviser un fichier WIM en plusieurs parties.
Func _TestSplit()
	ProgressOn("Split WIM", "Initialisation...", "", -1, -1)
	Local $rc = Wim_StartSplit($sOut, $sSplitDest, $SplitSizeBytes, 0)
	If $rc <> 0 Then
		ProgressOff()
		_Message($MB_ICONERROR, "Split", "Code final=" & $rc & " (" & Wim_ErrorString($rc) & ")")
		GoExit()
	EndIf

	Local $hTimer = TimerInit()
	Do
		Local $progress = Wim_GetSplitProgress()
		If @error Then ExitLoop

		Local $iDuration = TimerDiff($hTimer)
		ProgressSet($progress, "Écoulé: " & _FmtSec($iDuration) & "  Restant≈: " & _FmtSec((100 - $progress) * $iDuration), "Progression Split : " & $progress & "%")
		Sleep(250)
	Until $progress >= 100
	ProgressOff()

    _Message($MB_ICONINFORMATION, "Split", "Split terminé.")
EndFunc

## GetInfo	; -----     -----     -----     -----     -----
; Récupère et affiche les informations du fichier WIM.
Func _TestGetInfo()
    If Not FileExists($sOut) Then
        _Message($MB_ICONERROR, "Erreur", "Le fichier WIM (" & $sOut & ") n'existe pas. Veuillez lancer la capture d'abord.")
        Return
    EndIf

    ; Obtenir les informations générales du WIM
    Local $aInfo = Wim_GetWimInfo($sOut)
    If Not @error Then
        _Message($MB_ICONINFORMATION, "Info (générales)", _FmtInfoArr($aInfo))
    EndIf

    ; Lister les images
    Local $aList = Wim_ListImages($sOut)
    If $aList[0] = 0 Then
        Local $lines = StringSplit($aList[2], @LF, 1)
        Local $msg = "Images=" & $aList[1] & @CRLF
        For $i = 1 To $lines[0]
            Local $L = $lines[$i]
            If $L = "" Then ContinueLoop
            Local $p = StringSplit($L, "|", 1)
            $msg &= $p[1] & ": " & $p[2] & " [" & $p[3] & "]" & @CRLF
        Next
        _Message($MB_ICONINFORMATION, "Liste images", $msg)
    EndIf

    ; Obtenir les informations détaillées de la première image
    Local $img1 = Wim_GetImageInfoEx($sOut, 1)
    If $img1[0] = 0 Then
        Local $msg = "Image #1" & @CRLF & _
                     "Nom=" & $img1[2] & @CRLF & _
                     "Desc=" & $img1[3] & @CRLF & _
                     "Total=" & _FmtBytes($img1[7]) & @CRLF & _
                     "Créé=" & $img1[9] & @CRLF & _
                     "Modifié=" & $img1[10]
        _Message($MB_ICONINFORMATION, "Image 1", $msg)
    EndIf

    ; Sauvegarder l'XML
    Local $x = Wim_GetXml($sOut)
    If $x[0] = 0 Then
        Local $sXmlPath = @ScriptDir & "\wiminfo.xml"
        FileDelete($sXmlPath)
        FileWrite($sXmlPath, $x[2])
        _Message($MB_ICONINFORMATION, "XML", "Fichier XML sauvegardé à : " & $sXmlPath)
    EndIf
EndFunc


; ==================================================================
; Fonctions utilitaires
; ==================================================================
Func GoExit()
    Wim_UnloadDLL()
    Exit
EndFunc

Func _Message($Type, $sTitre, $sMessage)
	ClipPut($sMessage)
    MsgBox($Type, $sTitre, $sMessage)
	GoExit()
EndFunc

Func _FmtBytes($n)
    Local $KB = 1024, $MB = $KB * 1024, $GB = $MB * 1024
    If $n >= $GB Then Return Round($n / $GB, 2) & " GiB"
    If $n >= $MB Then Return Round($n / $MB, 2) & " MiB"
    If $n >= $KB Then Return Round($n / $KB, 2) & " KiB"
    Return $n & " B"
EndFunc

Func _FmtInfoArr(ByRef $a)
    If Not IsArray($a) Then Return "?"
    Return "rc=" & $a[0] & " (" & Wim_ErrorString($a[0]) & ")" & @CRLF & _
           "Images=" & $a[1] & @CRLF & _
           "BootIndex=" & $a[2] & @CRLF & _
           "Compression=" & _CompName($a[3]) & " (" & $a[3] & ")" & @CRLF & _
           "Integrity=" & ($a[4] ? "Oui" : "Non") & @CRLF & _
           "ChunkSize=" & _FmtBytes($a[5]) & @CRLF & _
           "TotalBytes=" & _FmtBytes($a[6]) & @CRLF & _
           "Part=" & $a[7] & "/" & $a[8] & @CRLF & _
           "Readonly=" & ($a[9] ? "Oui" : "Non")
EndFunc

Func _FmtSec($iSec)
    If $iSec < 0 Then Return "?"
    Local $h = Int($iSec / 3600)
    Local $m = Int(Mod($iSec, 3600) / 60)
    Local $s = Mod($iSec, 60)
    Return StringFormat("%02u:%02u:%02u", $h, $m, $s)
EndFunc

Func _CompName($i)
    Switch $i
        Case $COMP_NONE
            Return "NONE"
        Case $COMP_XPRESS
            Return "XPRESS"
        Case $COMP_LZX
            Return "LZX"
        Case $COMP_LZMS
            Return "LZMS"
    EndSwitch
    Return "?"
EndFunc

Func _HandleError($sAction, $sMessage, $iCode)
    ProgressOff()
    _Message($MB_ICONERROR, $sAction & " - Erreur", $sMessage & @CRLF & "Code=" & $iCode & " (" & Wim_ErrorString($iCode) & ")")
EndFunc

Func _WaitAndShowProgress($sTitle, $sQueryFunc)
	Local $hTimer = TimerInit()
    Local $old = -1, $iTotalDuration, $iDuration, $sDuration, $a
	Local $iDurationMax = 0, $iDurationMaxWhen = 0, $iDurationMaxPercent = 0

    While 1
		$a = Call($sQueryFunc)
        If @error Then ExitLoop

        Local $status = $a[1], $phase = $a[2], $percent = $a[3], $elapsed = $a[4], $remain = $a[5]
		$iTotalDuration = $elapsed + $remain

		If TimerDiff($hTimer) >= 1000 Then
			$hTimer = TimerInit()
			If $iTotalDuration > $iDurationMax Then
				$iDurationMax = $iTotalDuration
				$iDurationMaxWhen = $elapsed
				$iDurationMaxPercent = $percent
			EndIf
			ConsoleWrite("$status: " & $status & ", $phase: " & $phase & ", $percent: " & $percent & "%, $elapsed: " & _FmtSec($elapsed) & ", $remain: " & _FmtSec($remain) & _
					"			Current total duration: " & _FmtSec($iTotalDuration) & _
					"			$iDurationMax: " & _FmtSec($iDurationMax) & ", $iDurationMaxWhen: " & _FmtSec($iDurationMaxWhen) & ", $iDurationMaxPercent: " & $iDurationMaxPercent & "%" & @CRLF)
		EndIf

        If $phase = 0 Then
            $iDuration = $elapsed
            $sDuration = _FmtSec($elapsed)
            Local $sStatusText = "Phase 1 : " & $percent & "%"
        Else
            $iDuration += $elapsed
            $sDuration = _FmtSec($iDuration)
            Local $sStatusText = "Phase 2 : " & $percent & "%"
        EndIf

		If $percent = 0 Then
			$sStatusText = " Initialisation..."
		Else
			$sStatusText = " (" & $sStatusText & ")"
		EndIf

        If $percent <> $old Then
            ProgressSet($percent, "Écoulé: " & $sDuration & ", Restant≈: " & _FmtSec($remain) & ", Total: " & _FmtSec($iTotalDuration), $sTitle & $sStatusText)
            $old = $percent
        EndIf
        If $status = $WIM_ST_DONE Or $status = $WIM_ST_ERROR Then ExitLoop
        Sleep(250)
    WEnd
    ProgressOff()
EndFunc