#include-once
#include "Config.au3"
#include "Log.au3"
#include "GuildWars.au3"

#cs ----------------------------------------------------------------------------

    Maps.au3

    The zone database and the per-zone runtime status. Adding a zone is one
    Maps_Register() line in Maps_Load() plus a Route_<Name>() in Routes/.

    A row holds the zone's name, map id, region and route name. The rest is
    filled in while the bot runs: the outpost the attempt starts from (resolved
    from the character's unlocked outposts, so zones without an outpost of
    their own need no special handling), the area's party limit, and the
    status / attempts / last-result trio the GUI shows.

#ce ----------------------------------------------------------------------------

#Region Field layout
Global Const $eMAP_NAME = 0, $eMAP_MAP_ID = 1, $eMAP_REGION = 2, $eMAP_ROUTE = 3
Global Const $eMAP_OUTPOST_ID = 4, $eMAP_OUTPOST_NAME = 5, $eMAP_PARTY_SIZE = 6
Global Const $eMAP_STATUS = 7, $eMAP_ATTEMPTS = 8, $eMAP_LAST_RESULT = 9
Global Const $eMAP_FIELDS = 10

Global Const $eMAPSTATUS_UNKNOWN = 0      ; not looked at yet this run
Global Const $eMAPSTATUS_PENDING = 1      ; needs vanquishing
Global Const $eMAPSTATUS_ACTIVE = 2       ; being worked on right now
Global Const $eMAPSTATUS_VANQUISHED = 3   ; confirmed complete
Global Const $eMAPSTATUS_FAILED = 4       ; gave up after $MAX_RETRIES

Global $g_aMaps[0][$eMAP_FIELDS]
#EndRegion Field layout

#Region Zone list
;~ Description: Builds the zone database - every vanquishable zone the routes
;~              cover, straight from the reference bot. Call once at startup.
Func Maps_Load()
	Local $iCount = 0

	; --- Prophecies --------------------------------------------------
	$iCount += Maps_Register("Ascalon Foothills", 103, "Ascalon", "AscalonFoothills")
	$iCount += Maps_Register("Diessa Lowlands", 13, "Ascalon", "DiessaLowlands")
	$iCount += Maps_Register("Dragons Gullet", 105, "Ascalon", "DragonsGullet")
	$iCount += Maps_Register("Eastern Frontier", 107, "Ascalon", "EasternFrontier")
	$iCount += Maps_Register("Flame Temple Corridor", 106, "Ascalon", "FlameTempleCorridor")
	$iCount += Maps_Register("Old Ascalon", 33, "Ascalon", "OldAscalon")
	$iCount += Maps_Register("Pockmark Flats", 104, "Ascalon", "PockmarkFlats")
	$iCount += Maps_Register("Regent Valley", 101, "Ascalon", "RegentValley")
	$iCount += Maps_Register("The Breach", 102, "Ascalon", "TheBreach")
	$iCount += Maps_Register("Diviners Ascent", 110, "Crystal Desert", "DivinersAscent")
	$iCount += Maps_Register("Prophets Path", 113, "Crystal Desert", "ProphetsPath")
	$iCount += Maps_Register("Salt Flats", 114, "Crystal Desert", "SaltFlats")
	$iCount += Maps_Register("Skyward Reach", 115, "Crystal Desert", "SkywardReach")
	$iCount += Maps_Register("The Arid Sea", 112, "Crystal Desert", "TheAridSea")
	$iCount += Maps_Register("The Scar", 108, "Crystal Desert", "TheScar")
	$iCount += Maps_Register("Vulture Drifts", 111, "Crystal Desert", "VultureDrifts")
	$iCount += Maps_Register("Cursed Lands", 56, "Kryta", "CursedLands")
	$iCount += Maps_Register("Kessex Peak", 64, "Kryta", "KessexPeak")
	$iCount += Maps_Register("Lions Gate", 415, "Kryta", "LionsGate")
	$iCount += Maps_Register("Majestys Rest", 60, "Kryta", "MajestysRest")
	$iCount += Maps_Register("Nebo Terrace", 59, "Kryta", "NeboTerrace")
	$iCount += Maps_Register("North Kryta Province", 58, "Kryta", "NorthKrytaProvince")
	$iCount += Maps_Register("Scoundrels Rise", 54, "Kryta", "ScoundrelsRise")
	$iCount += Maps_Register("Stingray Strand", 63, "Kryta", "StingrayStrand")
	$iCount += Maps_Register("Talmark Wilderness", 17, "Kryta", "TalmarkWilderness")
	$iCount += Maps_Register("Tears of the Fallen", 53, "Kryta", "TearsoftheFallen")
	$iCount += Maps_Register("The Black Curtain", 18, "Kryta", "TheBlackCurtain")
	$iCount += Maps_Register("Twin Serpent Lakes", 61, "Kryta", "TwinSerpentLakes")
	$iCount += Maps_Register("Watchtower Coast", 62, "Kryta", "WatchtowerCoast")
	$iCount += Maps_Register("Dry Top", 47, "Maguuma", "DryTop")
	$iCount += Maps_Register("Ettins Back", 44, "Maguuma", "EttinsBack")
	$iCount += Maps_Register("Mamnoon Lagoon", 42, "Maguuma", "MamnoonLagoon")
	$iCount += Maps_Register("Reed Bog", 45, "Maguuma", "ReedBog")
	$iCount += Maps_Register("Sage Lands", 41, "Maguuma", "SageLands")
	$iCount += Maps_Register("Silverwood", 43, "Maguuma", "Silverwood")
	$iCount += Maps_Register("Tangle Root", 48, "Maguuma", "TangleRoot")
	$iCount += Maps_Register("The Falls", 46, "Maguuma", "TheFalls")
	$iCount += Maps_Register("Anvil Rock", 89, "N Shiverpeaks", "AnvilRock")
	$iCount += Maps_Register("Deldrimor Bowl", 100, "N Shiverpeaks", "DeldrimorBowl")
	$iCount += Maps_Register("Griffons Mouth", 27, "N Shiverpeaks", "GriffonsMouth")
	$iCount += Maps_Register("Iron Horse Mine", 88, "N Shiverpeaks", "IronHorseMine")
	$iCount += Maps_Register("Travelers Vale", 99, "N Shiverpeaks", "TravelersVale")
	$iCount += Maps_Register("Perdition Rock", 121, "Ring of Fire", "PerditionRock")
	$iCount += Maps_Register("Dreadnoughts Drift", 97, "S Shiverpeaks", "DreadnoughtsDrift")
	$iCount += Maps_Register("Frozen Forest", 98, "S Shiverpeaks", "FrozenForest")
	$iCount += Maps_Register("Grenths Footprint", 191, "S Shiverpeaks", "GrenthsFootprint")
	$iCount += Maps_Register("Ice Floe", 94, "S Shiverpeaks", "IceFloe")
	$iCount += Maps_Register("Icedome", 87, "S Shiverpeaks", "IceDome")
	$iCount += Maps_Register("Lornars Pass", 90, "S Shiverpeaks", "LornarsPass")
	$iCount += Maps_Register("Mineral Springs", 96, "S Shiverpeaks", "MineralSprings")
	$iCount += Maps_Register("Snake Dance", 91, "S Shiverpeaks", "SnakeDance")
	$iCount += Maps_Register("Spearhead Peak", 93, "S Shiverpeaks", "SpearheadPeak")
	$iCount += Maps_Register("Talus Chute", 26, "S Shiverpeaks", "TalusChute")
	$iCount += Maps_Register("Tascas Demise", 92, "S Shiverpeaks", "TascasDemise")
	$iCount += Maps_Register("Witmans Folly", 95, "S Shiverpeaks", "WitmansFolly")
	; --- Factions ----------------------------------------------------
	$iCount += Maps_Register("Arborstone", 244, "Echovald", "Arborstone")
	$iCount += Maps_Register("Drazach Thicket", 195, "Echovald", "DrazachThicket")
	$iCount += Maps_Register("Ferndale", 210, "Echovald", "Ferndale")
	$iCount += Maps_Register("Melandrus Hope", 201, "Echovald", "MelandrusHope")
	$iCount += Maps_Register("Morostav Trail", 205, "Echovald", "MorostavTrail")
	$iCount += Maps_Register("Mourning Veil Falls", 209, "Echovald", "MourningVeilFalls")
	$iCount += Maps_Register("The Eternal Grove", 128, "Echovald", "TheEternalGrove")
	$iCount += Maps_Register("Archipelagos", 198, "Jade Sea", "Archipelagos")
	$iCount += Maps_Register("Boreas Seabed", 247, "Jade Sea", "BoreasSeabed")
	$iCount += Maps_Register("Gyala Hatchery", 144, "Jade Sea", "GyalaHatchery")
	$iCount += Maps_Register("Maishang Hills", 199, "Jade Sea", "MaishangHills")
	$iCount += Maps_Register("Mount Qinkai", 200, "Jade Sea", "MountQinkai")
	$iCount += Maps_Register("Rheas Crater", 202, "Jade Sea", "RheasCrater")
	$iCount += Maps_Register("Silent Surf", 203, "Jade Sea", "SilentSurf")
	$iCount += Maps_Register("Unwaking Waters", 227, "Jade Sea", "UnwakingWaters")
	$iCount += Maps_Register("Bukdek Byway", 240, "Kaineng", "BukdekByway")
	$iCount += Maps_Register("Nahpui Quarter", 265, "Kaineng", "NahpuiQuarter")
	$iCount += Maps_Register("Pongmei Valley", 211, "Kaineng", "PongmeiValley")
	$iCount += Maps_Register("Raisu Palace", 233, "Kaineng", "RaisuPalace")
	$iCount += Maps_Register("Shadows Passage", 232, "Kaineng", "ShadowsPassage")
	$iCount += Maps_Register("Shenzun Tunnels", 197, "Kaineng", "ShenzunTunnels")
	$iCount += Maps_Register("Sunjiang District", 256, "Kaineng", "SunjiangDistrict")
	$iCount += Maps_Register("Tahnnakai Temple", 269, "Kaineng", "TahnnakiTemple")
	$iCount += Maps_Register("Wajjun Bazaar", 239, "Kaineng", "WajjunBazaar")
	$iCount += Maps_Register("Xaquang Skyway", 31, "Kaineng", "XaquangSkyway")
	$iCount += Maps_Register("Haiju Lagoon", 237, "Shing Jea", "HaijuLagoon")
	$iCount += Maps_Register("Jaya Bluffs", 196, "Shing Jea", "JayaBluffs")
	$iCount += Maps_Register("Kinya Province", 236, "Shing Jea", "KinyaProvince")
	$iCount += Maps_Register("Minister Chos Estate", 245, "Shing Jea", "MinisterChosEstate")
	$iCount += Maps_Register("Panjiang Peninsula", 235, "Shing Jea", "PanjiangPeninsula")
	$iCount += Maps_Register("Saoshang Trail", 313, "Shing Jea", "SaoshangTrail")
	$iCount += Maps_Register("Sunqua Vale", 238, "Shing Jea", "SunquaVale")
	$iCount += Maps_Register("Zen Daijun", 246, "Shing Jea", "ZenDaijun")
	; --- Nightfall ---------------------------------------------------
	$iCount += Maps_Register("Crystal Overlook", 448, "Desolation", "CrystalOverlook")
	$iCount += Maps_Register("Jokos Domain", 437, "Desolation", "JokosDomain")
	$iCount += Maps_Register("Poisoned Outcrops", 443, "Desolation", "PoisonedOutcrops")
	$iCount += Maps_Register("The Alkali Pan", 446, "Desolation", "TheAlkaliPan")
	$iCount += Maps_Register("The Ruptured Heart", 439, "Desolation", "TheRupturedHeart")
	$iCount += Maps_Register("The Shattered Ravines", 441, "Desolation", "TheShatteredRavines")
	$iCount += Maps_Register("The Sulfurous Wastes", 444, "Desolation", "TheSulfurousWastes")
	$iCount += Maps_Register("Cliffs of Dohjok", 432, "Istan", "CliffsOfDohjok")
	$iCount += Maps_Register("Fahranur, the First City", 481, "Istan", "FahranurTheFirstCity")
	$iCount += Maps_Register("Issnur Isles", 486, "Istan", "IssnurIsles")
	$iCount += Maps_Register("Lahtenda Bog", 484, "Istan", "LahtendaBog")
	$iCount += Maps_Register("Mehtani Keys", 488, "Istan", "MehtaniKeys")
	$iCount += Maps_Register("Plains of Jarin", 430, "Istan", "PlainsofJarin")
	$iCount += Maps_Register("Zehlon Reach", 483, "Istan", "ZehlonReach")
	$iCount += Maps_Register("Arkjok Ward", 380, "Kourna", "ArkjokWard")
	$iCount += Maps_Register("Bahdok Caverns", 377, "Kourna", "BahdokCaverns")
	$iCount += Maps_Register("Barbarous Shore", 375, "Kourna", "BarbarousShore")
	$iCount += Maps_Register("Dejarin Estate", 379, "Kourna", "DejarinEstate")
	$iCount += Maps_Register("Gandara, the Moon Fortress", 382, "Kourna", "GandaraTheMoonFortress")
	$iCount += Maps_Register("Jahai Bluffs", 369, "Kourna", "JahaiBluffs")
	$iCount += Maps_Register("Marga Coast", 371, "Kourna", "MargaCoast")
	$iCount += Maps_Register("Sunward Marches", 373, "Kourna", "SunwardMarches")
	$iCount += Maps_Register("The Floodplain of Mahnkelon", 384, "Kourna", "TheFloodplainOfMahnkelon")
	$iCount += Maps_Register("Turais Procession", 386, "Kourna", "TuraisProcession")
	$iCount += Maps_Register("Forum Highlands", 399, "Vabbi", "ForumHighlands")
	$iCount += Maps_Register("Garden of Seborhin", 394, "Vabbi", "GardenOfSeborhin")
	$iCount += Maps_Register("Holdings of Chokhin", 395, "Vabbi", "HoldingsOfChokhin")
	$iCount += Maps_Register("Resplendent Makuun", 402, "Vabbi", "ResplendentMakuun")
	$iCount += Maps_Register("The Hidden City of Ahdashim", 413, "Vabbi", "TheHiddenCityOfAhdashim")
	$iCount += Maps_Register("The Mirror of Lyss", 419, "Vabbi", "TheMirrorOfLyss")
	$iCount += Maps_Register("Vehjin Mines", 397, "Vabbi", "VehjinMines")
	$iCount += Maps_Register("Vehtendi Valley", 406, "Vabbi", "VehtendiValley")
	$iCount += Maps_Register("Wilderness of Bahdza", 404, "Vabbi", "WildernessOfBahdza")
	$iCount += Maps_Register("Yatendi Canyons", 392, "Vabbi", "YatendiCanyons")
	; --- Eye of the North --------------------------------------------
	$iCount += Maps_Register("Dalada Uplands", 647, "Charr Homelands", "DaladaUplands")
	$iCount += Maps_Register("Grothmar Wardowns", 649, "Charr Homelands", "GrothmarWardowns")
	$iCount += Maps_Register("Sacnoth Valley", 651, "Charr Homelands", "SacnothValley")
	$iCount += Maps_Register("Bjora Marches", 482, "Far Shiverpeaks", "BjoraMarches")
	$iCount += Maps_Register("Drakkar Lake", 513, "Far Shiverpeaks", "DrakkarLake")
	$iCount += Maps_Register("Ice Cliff Chasms", 499, "Far Shiverpeaks", "IceCliffChasms")
	$iCount += Maps_Register("Jaga Moraine", 546, "Far Shiverpeaks", "JagaMoraine")
	$iCount += Maps_Register("Norrhart Domains", 548, "Far Shiverpeaks", "NorrhartDomains")
	$iCount += Maps_Register("Varajar Fells", 553, "Far Shiverpeaks", "VarajarFells")
	$iCount += Maps_Register("Alcazia Tangle", 572, "Tarnished Coast", "AlcaziaTangle")
	$iCount += Maps_Register("Arbor Bay", 485, "Tarnished Coast", "ArborBay")
	$iCount += Maps_Register("Magus Stones", 569, "Tarnished Coast", "MagusStones")
	$iCount += Maps_Register("Riven Earth", 501, "Tarnished Coast", "RivenEarth")
	$iCount += Maps_Register("Sparkfly Swamp", 558, "Tarnished Coast", "SparkflySwamp")
	$iCount += Maps_Register("Verdant Cascades", 566, "Tarnished Coast", "VerdantCascades")

	VqLog_Info($iCount & " zones loaded from the map database.")
	Return $iCount
EndFunc   ;==>Maps_Load

;~ Description: Adds one zone. Returns 1 so Maps_Load() can count.
Func Maps_Register($sName, $iMapId, $sRegion, $sRoute)
	Local $iIndex = UBound($g_aMaps)
	ReDim $g_aMaps[$iIndex + 1][$eMAP_FIELDS]

	$g_aMaps[$iIndex][$eMAP_NAME] = $sName
	$g_aMaps[$iIndex][$eMAP_MAP_ID] = $iMapId
	$g_aMaps[$iIndex][$eMAP_REGION] = $sRegion
	$g_aMaps[$iIndex][$eMAP_ROUTE] = $sRoute
	$g_aMaps[$iIndex][$eMAP_OUTPOST_ID] = 0
	$g_aMaps[$iIndex][$eMAP_OUTPOST_NAME] = ""
	$g_aMaps[$iIndex][$eMAP_PARTY_SIZE] = 0
	$g_aMaps[$iIndex][$eMAP_STATUS] = $eMAPSTATUS_UNKNOWN
	$g_aMaps[$iIndex][$eMAP_ATTEMPTS] = 0
	$g_aMaps[$iIndex][$eMAP_LAST_RESULT] = ""

	Return 1
EndFunc   ;==>Maps_Register
#EndRegion Zone list

#Region Accessors
Func Maps_Count()
	Return UBound($g_aMaps)
EndFunc   ;==>Maps_Count

Func Maps_IsValidIndex($iIndex)
	Return ($iIndex >= 0 And $iIndex < UBound($g_aMaps))
EndFunc   ;==>Maps_IsValidIndex

Func Maps_GetField($iIndex, $iField)
	If Not Maps_IsValidIndex($iIndex) Then Return SetError(1, 0, "")
	Return $g_aMaps[$iIndex][$iField]
EndFunc   ;==>Maps_GetField

Func Maps_SetField($iIndex, $iField, $vValue)
	If Not Maps_IsValidIndex($iIndex) Then Return SetError(1, 0, False)
	$g_aMaps[$iIndex][$iField] = $vValue
	Return True
EndFunc   ;==>Maps_SetField

Func Maps_GetName($iIndex)
	Return Maps_GetField($iIndex, $eMAP_NAME)
EndFunc   ;==>Maps_GetName

Func Maps_GetMapId($iIndex)
	Return Maps_GetField($iIndex, $eMAP_MAP_ID)
EndFunc   ;==>Maps_GetMapId

Func Maps_GetRegion($iIndex)
	Return Maps_GetField($iIndex, $eMAP_REGION)
EndFunc   ;==>Maps_GetRegion

Func Maps_GetRoute($iIndex)
	Return Maps_GetField($iIndex, $eMAP_ROUTE)
EndFunc   ;==>Maps_GetRoute

Func Maps_GetOutpostId($iIndex)
	Return Maps_GetField($iIndex, $eMAP_OUTPOST_ID)
EndFunc   ;==>Maps_GetOutpostId

Func Maps_GetOutpostName($iIndex)
	Return Maps_GetField($iIndex, $eMAP_OUTPOST_NAME)
EndFunc   ;==>Maps_GetOutpostName

Func Maps_SetOutpost($iIndex, $iOutpostId, $sOutpostName)
	Maps_SetField($iIndex, $eMAP_OUTPOST_ID, $iOutpostId)
	Return Maps_SetField($iIndex, $eMAP_OUTPOST_NAME, $sOutpostName)
EndFunc   ;==>Maps_SetOutpost

Func Maps_GetPartySize($iIndex)
	Return Maps_GetField($iIndex, $eMAP_PARTY_SIZE)
EndFunc   ;==>Maps_GetPartySize

Func Maps_SetPartySize($iIndex, $iPartySize)
	Return Maps_SetField($iIndex, $eMAP_PARTY_SIZE, $iPartySize)
EndFunc   ;==>Maps_SetPartySize

Func Maps_GetStatus($iIndex)
	If Not Maps_IsValidIndex($iIndex) Then Return SetError(1, 0, $eMAPSTATUS_UNKNOWN)
	Return $g_aMaps[$iIndex][$eMAP_STATUS]
EndFunc   ;==>Maps_GetStatus

Func Maps_SetStatus($iIndex, $iStatus)
	Return Maps_SetField($iIndex, $eMAP_STATUS, $iStatus)
EndFunc   ;==>Maps_SetStatus

Func Maps_GetAttempts($iIndex)
	If Not Maps_IsValidIndex($iIndex) Then Return SetError(1, 0, 0)
	Return $g_aMaps[$iIndex][$eMAP_ATTEMPTS]
EndFunc   ;==>Maps_GetAttempts

;~ Description: Counts one more attempt at a zone and returns the new total.
Func Maps_IncrementAttempts($iIndex)
	If Not Maps_IsValidIndex($iIndex) Then Return SetError(1, 0, 0)
	$g_aMaps[$iIndex][$eMAP_ATTEMPTS] += 1
	Return $g_aMaps[$iIndex][$eMAP_ATTEMPTS]
EndFunc   ;==>Maps_IncrementAttempts

Func Maps_GetLastResult($iIndex)
	Return Maps_GetField($iIndex, $eMAP_LAST_RESULT)
EndFunc   ;==>Maps_GetLastResult

Func Maps_SetLastResult($iIndex, $sText)
	Return Maps_SetField($iIndex, $eMAP_LAST_RESULT, $sText)
EndFunc   ;==>Maps_SetLastResult

Func Maps_StatusText($iStatus)
	Switch $iStatus
		Case $eMAPSTATUS_PENDING
			Return "Pending"
		Case $eMAPSTATUS_ACTIVE
			Return "In progress"
		Case $eMAPSTATUS_VANQUISHED
			Return "Vanquished"
		Case $eMAPSTATUS_FAILED
			Return "Failed"
		Case Else
			Return "Unknown"
	EndSwitch
EndFunc   ;==>Maps_StatusText

;~ Description: Which row, if any, describes this map id. Used while caravanning
;~              to notice that the zone we just walked into is one of ours.
Func Maps_FindByMapId($iMapId)
	If $iMapId <= 0 Then Return -1

	For $i = 0 To UBound($g_aMaps) - 1
		If $g_aMaps[$i][$eMAP_MAP_ID] = $iMapId Then Return $i
	Next
	Return -1
EndFunc   ;==>Maps_FindByMapId

Func Maps_CountByStatus($iStatus)
	Local $iCount = 0
	For $i = 0 To UBound($g_aMaps) - 1
		If $g_aMaps[$i][$eMAP_STATUS] = $iStatus Then $iCount += 1
	Next
	Return $iCount
EndFunc   ;==>Maps_CountByStatus

;~ Description: Clears the per-run fields, so a second run in the same session
;~              is not affected by the first.
Func Maps_ResetRuntimeState()
	For $i = 0 To UBound($g_aMaps) - 1
		$g_aMaps[$i][$eMAP_STATUS] = $eMAPSTATUS_UNKNOWN
		$g_aMaps[$i][$eMAP_ATTEMPTS] = 0
		$g_aMaps[$i][$eMAP_LAST_RESULT] = ""
		$g_aMaps[$i][$eMAP_OUTPOST_ID] = 0
		$g_aMaps[$i][$eMAP_OUTPOST_NAME] = ""
		$g_aMaps[$i][$eMAP_PARTY_SIZE] = 0
	Next
EndFunc   ;==>Maps_ResetRuntimeState
#EndRegion Accessors

#Region Vanquished status
;~ Description: Asks the game whether one zone is already vanquished and records
;~              the answer. An unreadable answer counts as "needs doing" -
;~              better to walk a finished zone than to silently skip one.
Func Maps_RefreshVanquishedStatus($iIndex)
	If Not Maps_IsValidIndex($iIndex) Then Return SetError(1, 0, False)

	Local $bVanquished = GW_IsMapVanquished(Maps_GetMapId($iIndex), Maps_GetName($iIndex))
	If @error Then
		VqLog_Warn("Could not read vanquished status for " & Maps_GetName($iIndex) & " - assuming it still needs doing.")
		$g_aMaps[$iIndex][$eMAP_STATUS] = $eMAPSTATUS_PENDING
		Return False
	EndIf

	$g_aMaps[$iIndex][$eMAP_STATUS] = ($bVanquished) ? $eMAPSTATUS_VANQUISHED : $eMAPSTATUS_PENDING
	Return $bVanquished
EndFunc   ;==>Maps_RefreshVanquishedStatus

;~ Description: Every zone that still needs vanquishing, as an array of indices
;~              into the database. This is what the work queue is built from.
Func GetUnvanquishedMaps()
	Local $aResult[UBound($g_aMaps)]
	Local $iFound = 0

	For $i = 0 To UBound($g_aMaps) - 1
		Switch $g_aMaps[$i][$eMAP_STATUS]
			Case $eMAPSTATUS_PENDING, $eMAPSTATUS_ACTIVE, $eMAPSTATUS_UNKNOWN
				$aResult[$iFound] = $i
				$iFound += 1
		EndSwitch
	Next

	ReDim $aResult[$iFound]
	Return $aResult
EndFunc   ;==>GetUnvanquishedMaps
#EndRegion Vanquished status
