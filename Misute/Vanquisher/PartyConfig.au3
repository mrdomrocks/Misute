#include-once
#include "Config.au3"
#include "Log.au3"

#cs ----------------------------------------------------------------------------

    PartyConfig.au3

    The team the bot takes into a zone, read from Vanquisher.ini.

    Guild Wars caps the party size per area, so one team will not do: a 4 man
    area needs three companions, a 6 man area five and an 8 man area seven. The
    ini therefore has one section per size:

        [Team4]                 [Team6]                 [Team8]
        Hero1=Norgu             Hero1=Norgu             Hero1=Norgu
        Hero2=Gwen              ...                     ...
        Henchman1=2001          Henchman1=2001          Henchman1=2001

    Heroes are named (the API resolves the name to a hero id). Henchmen are
    listed by their player number, because henchman names are not readable from
    the client - the number is shown by any agent inspector and is stable.

    Slots are filled heroes first, then henchmen, and the list is trimmed to the
    area's limit, so an over-filled section is harmless.

#ce ----------------------------------------------------------------------------

#Region Storage
;~ Parallel arrays, one entry per configured slot: name/number and its kind.
Global Const $ePARTY_HERO = 0
Global Const $ePARTY_HENCHMAN = 1

Global $g_aPartyTeam4[0][2]
Global $g_aPartyTeam6[0][2]
Global $g_aPartyTeam8[0][2]

Global Const $ePARTY_SLOT_VALUE = 0
Global Const $ePARTY_SLOT_KIND = 1
#EndRegion Storage

#Region Loading
;~ Description: Reads Vanquisher.ini, writing a commented default first if it
;~              does not exist yet. Safe to call again to pick up edits.
Func PartyConfig_Load()
	If Not FileExists($PARTY_INI_FILE) Then PartyConfig_WriteDefault()

	$g_aPartyTeam4 = PartyConfig_ReadSection("Team4", 3)
	$g_aPartyTeam6 = PartyConfig_ReadSection("Team6", 5)
	$g_aPartyTeam8 = PartyConfig_ReadSection("Team8", 7)

	VqLog_Info("Party setup loaded: " & PartyConfig_Describe(4) & " / " & _
			PartyConfig_Describe(6) & " / " & PartyConfig_Describe(8) & ".")
	Return True
EndFunc   ;==>PartyConfig_Load

;~ Description: Reads one [TeamN] section into a slot array. $iSlots is the
;~              number of companions the area allows (party size minus you).
Func PartyConfig_ReadSection($sSection, $iSlots)
	Local $aSlots[0][2]

	For $i = 1 To $iSlots
		Local $sHero = StringStripWS(IniRead($PARTY_INI_FILE, $sSection, "Hero" & $i, ""), 3)
		If $sHero <> "" Then PartyConfig_AddSlot($aSlots, $sHero, $ePARTY_HERO)
	Next

	For $i = 1 To $iSlots
		Local $sHenchman = StringStripWS(IniRead($PARTY_INI_FILE, $sSection, "Henchman" & $i, ""), 3)
		If $sHenchman <> "" Then PartyConfig_AddSlot($aSlots, $sHenchman, $ePARTY_HENCHMAN)
	Next

	; More companions than the area allows would fail the last invite anyway.
	If UBound($aSlots) > $iSlots Then ReDim $aSlots[$iSlots][2]
	Return $aSlots
EndFunc   ;==>PartyConfig_ReadSection

Func PartyConfig_AddSlot(ByRef $aSlots, $sValue, $iKind)
	Local $iIndex = UBound($aSlots)
	ReDim $aSlots[$iIndex + 1][2]
	$aSlots[$iIndex][$ePARTY_SLOT_VALUE] = $sValue
	$aSlots[$iIndex][$ePARTY_SLOT_KIND] = $iKind
EndFunc   ;==>PartyConfig_AddSlot

;~ Description: Creates a starter ini so a first run has something sensible to
;~              show and something obvious to edit.
Func PartyConfig_WriteDefault()
	Local $sDefault = _
			"; Misute Vanquisher party setup." & @CRLF & _
			"; One section per area size. Heroes are named, henchmen use their" & @CRLF & _
			"; player number. Blank or missing entries are simply skipped." & @CRLF & @CRLF & _
			"[Team4]" & @CRLF & _
			"Hero1=Norgu" & @CRLF & _
			"Hero2=Gwen" & @CRLF & _
			"Hero3=Olias" & @CRLF & @CRLF & _
			"[Team6]" & @CRLF & _
			"Hero1=Norgu" & @CRLF & _
			"Hero2=Gwen" & @CRLF & _
			"Hero3=Olias" & @CRLF & _
			"Hero4=Master of Whispers" & @CRLF & _
			"Hero5=Xandra" & @CRLF & @CRLF & _
			"[Team8]" & @CRLF & _
			"Hero1=Norgu" & @CRLF & _
			"Hero2=Gwen" & @CRLF & _
			"Hero3=Razah" & @CRLF & _
			"Hero4=Master of Whispers" & @CRLF & _
			"Hero5=Olias" & @CRLF & _
			"Hero6=Livia" & @CRLF & _
			"Hero7=Xandra" & @CRLF

	FileWrite($PARTY_INI_FILE, $sDefault)
	VqLog_Info("Wrote a default party setup to " & $PARTY_INI_FILE & ".")
EndFunc   ;==>PartyConfig_WriteDefault
#EndRegion Loading

#Region Accessors
;~ Description: The slot array for an area's party size, or an empty array when
;~              the size is not one the game uses.
Func PartyConfig_GetTeam($iPartySize)
	Switch $iPartySize
		Case 4
			Return $g_aPartyTeam4
		Case 6
			Return $g_aPartyTeam6
		Case 8
			Return $g_aPartyTeam8
	EndSwitch

	Local $aEmpty[0][2]
	Return SetError(1, 0, $aEmpty)
EndFunc   ;==>PartyConfig_GetTeam

Func PartyConfig_GetCount($iPartySize)
	Local $aTeam = PartyConfig_GetTeam($iPartySize)
	Return UBound($aTeam)
EndFunc   ;==>PartyConfig_GetCount

;~ Description: One line per party size for the GUI, eg "4 man: Norgu, Gwen".
Func PartyConfig_Describe($iPartySize)
	Local $aTeam = PartyConfig_GetTeam($iPartySize)
	If UBound($aTeam) = 0 Then Return $iPartySize & " man: (not configured)"

	Local $sNames = ""
	For $i = 0 To UBound($aTeam) - 1
		If $i > 0 Then $sNames &= ", "
		$sNames &= $aTeam[$i][$ePARTY_SLOT_VALUE]
		If $aTeam[$i][$ePARTY_SLOT_KIND] = $ePARTY_HENCHMAN Then $sNames &= " (hench)"
	Next

	Return $iPartySize & " man: " & $sNames
EndFunc   ;==>PartyConfig_Describe
#EndRegion Accessors
