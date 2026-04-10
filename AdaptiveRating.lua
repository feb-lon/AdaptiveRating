local function AdaptiveRating()
	-- Define descriptive attributes of the custom extension that are displayed on the Tracker settings
	local self = {}
	self.version = "0.1"
	self.name = "AdaptiveRating"
	self.author = "Feblon"
	self.description = "Alternative to the default gachamon rating calculation."
	self.github = "feb-lon/AdaptiveRating"
	self.url = string.format("https://github.com/%s", self.github or "") -- Remove this attribute if no host website available for this extension
	self.RS = {}
	self.usedRuleset = {}

	function self.checkForUpdates()
		-- Update the pattern below to match your version. You can check what this looks like by visiting the latest release url on your repo
		local versionResponsePattern = '"tag_name":%s+"%w+(%d+%.%d+)"' -- matches "1.0" in "tag_name": "v1.0"
		local versionCheckUrl = string.format("https://api.github.com/repos/%s/releases/latest", self.github or "")
		local downloadUrl = string.format("%s/releases/latest", self.url or "")
		local compareFunc = function(a, b) return a ~= b and not Utils.isNewerVersion(a, b) end -- if current version is *older* than online version
		local isUpdateAvailable = Utils.checkForVersionUpdate(versionCheckUrl, self.version, versionResponsePattern, compareFunc)
		return isUpdateAvailable, downloadUrl
	end

	function self.startup()
		local data = FileManager.decodeJsonFile(FileManager.getCustomFolderPath() .. "RatingSystem.json")

		local RS = {
			Abilities = {},
			FixedRatingMove = {},
			Stats = {},
			ModifierAndRatings = {},
			Rulesets = {}
		}
		-- Abilities
		for idStr, rating in pairs(data.Abilities or {}) do
			local id = tonumber(idStr)
			if id then
				RS.Abilities[id] = rating
			end
		end
		-- FixedRatingMove
		for idStr, rating in pairs(data.FixedRatingMove or {}) do
			local id = tonumber(idStr)
			if id then
				RS.FixedRatingMove[id] = rating
			end
		end
		-- Stats
		for key, val in pairs(data.Stats or {}) do
			RS.Stats[key] = val
		end
		-- ModifierAndRatings
		for key, val in pairs(data.ModifierAndRatings or {}) do
			RS.ModifierAndRatings[key] = val
		end
		-- Rulesets
		for rulesetName, rulesetData in pairs(data.Rulesets or {}) do
			ruleset = {}
			ruleset["BannedAbilities"] = rulesetData.BannedAbilities or {}
			ruleset["BannedAbilityExceptions"] = rulesetData.BannedAbilityExceptions or {}
			ruleset["Changes"] = rulesetData.Changes or {}
			ruleset["BannedMoves"] = {}
			for idC, bannedMove in pairs(rulesetData["BannedMoves"] or {}) do
				if type(bannedMove) == "string" then
					for idM, move in pairs(self.MoveCategory[bannedMove] or {}) do 
						ruleset["BannedMoves"][move] = true
					end
				else
					ruleset["BannedMoves"][bannedMove] = true
				end
			end
			for id, bannedMoveException in pairs(rulesetData["BannedMoveException"] or {}) do
				for id, RsMoveName in ipairs(ruleset["BannedMoves"] or {}) do 
					if bannedMoveException == RsMoveName then 
						ruleset["BannedMoves"][RsMoveName] = false
					end
				end
			end
			RS.Rulesets[rulesetName] = ruleset
		end
		self.RS = RS
		local usedRuleset = GachaMonData.rulesetKey or "Standard"
		self.changeRuleset(RS.Rulesets[usedRuleset], usedRuleset)

		self.oldRef1 = GachaMonData.calculateRatingScore
		GachaMonData.calculateRatingScore = self.calculateRatingScore
		self.oldRef2 = GachaMonData.updateMainScreenViewedGachaMon
		GachaMonData.updateMainScreenViewedGachaMon = self.updateMainScreenViewedGachaMon
	end

	function self.unload()
		GachaMonData.calculateRatingScore = self.oldRef1
		GachaMonData.updateMainScreenViewedGachaMon = self.oldRef2
	end

	function self.updateMainScreenViewedGachaMon(needsRecalculating)
		needsRecalculating = needsRecalculating or false

		if not GachaMonData.isCompatibleWithEmulator() then
			return
		end

		local viewedPokemon = Battle.getViewedPokemon(true)
		if not viewedPokemon then
			GachaMonData.playerViewedMon = nil
			GachaMonData.playerViewedInitialStars = 0
			return
		end

		local prevGachamon = GachaMonData.playerViewedMon or {}
		-- Check if gachamon is new or different mon
		if not needsRecalculating then
			needsRecalculating = (prevGachamon.PokemonId ~= viewedPokemon.pokemonID) or (prevGachamon.Level ~= viewedPokemon.level)
		end

		-- Check if it learned any new moves
		if not needsRecalculating then
			local prevMoveIds = prevGachamon:getMoveIds() or {}
			local currentMoves = viewedPokemon.moves or {}
			for i = 1, 4, 1 do
				if currentMoves[i] and currentMoves[i].id ~= prevMoveIds[i] then
					needsRecalculating = true
					break
				end
			end
		end

		if not needsRecalculating then
			return
		end

		local viewedGachamon = GachaMonData.convertPokemonToGachaMon(viewedPokemon)
		local recentGachamon = GachaMonData.getAssociatedRecentMon(viewedGachamon)
		if recentGachamon then
			-- Always reset the initial stars to original card; do this every time the mon gets rerolled (in case the mon changes)
			GachaMonData.playerViewedMon = viewedGachamon
			GachaMonData.playerViewedInitialStars = recentGachamon:getStars() or 0
		end
	end

	function self.changeRuleset(ruleset, key)
		Utils.printDebug("changing Ruleset to " .. key)
		local usedRuleset = {
			Key = key,
			Abilities = self.RS.Abilities,
			FixedRatingMove = self.RS.FixedRatingMove,
			Stats = self.RS.Stats,
			ModifierAndRatings = self.RS.ModifierAndRatings,
			BannedAbilities = ruleset.BannedAbilities,
			BannedAbilityExceptions = ruleset.BannedAbilityExceptions,
			BannedMoves = ruleset.BannedMoves,
		}
		self.changeValues(usedRuleset, ruleset.Changes or {})
		self.usedRuleset = usedRuleset
	end

	function self.changeValues(standard, change) 
		for key, value in pairs(change or {}) do
			if type(value) == "table" then
				self.changeValues(standard[key], value)
			else
				standard[key] = change[key]
			end
		end
	end

	function self.calculateRatingScore(gachamon, baseStats)
		Utils.printDebug("---------------------start------------------------")

		local RS = self.usedRuleset

		local usedRulesetKey = GachaMonData.rulesetKey or "Standard"
		if usedRulesetKey ~= self.usedRuleset.Key then
			self.changeRuleset(self.RS.Rulesets[usedRulesetKey], usedRulesetKey)
		end

		local pokemonInternal = PokemonData.getNatDexCompatible(gachamon.PokemonId)
		local pokemonTypes = pokemonInternal.types or {}
		
		local ratingTotal = 0
		local physicalPowerRating = RS.ModifierAndRatings.ModifierPower
		local specialPowerRating = RS.ModifierAndRatings.ModifierPower

		local conditions = {
			hasShedCoverage = 1, 
			hasSleepMove = 2, 
			hasParaMove = 3, 
			hasPhysicalMove = 4, 
			hasSpecialMove = 5, 
			hasFullyAccurateDamagingMove = 6, 
			hasRest = 7
		}
		local conditionsAchieved = {
			[conditions.hasShedCoverage] = false,
			[conditions.hasSleepMove] = false,
			[conditions.hasParaMove] = false,
			[conditions.hasPhysicalMove] = false,
			[conditions.hasSpecialMove] = false,
			[conditions.hasFullyAccurateDamagingMove] = false,
			[conditions.hasRest] = false,
		}
		local resultingModifier = {
			[conditions.hasSleepMove] = RS.ModifierAndRatings.ModifierUselessFeature or 0,
		}
		local resultingRating = {
			[conditions.hasParaMove] = RS.ModifierAndRatings.RatingSmallBonus or 0,
		}


		-- ABILITY

		local ownAbility = gachamon.AbilityId or 0
		local abilityRating = RS.Abilities[ownAbility] or 0
		local physcialMovesBanned = false

		-- Remove rating if banned ability, unless it qualifies for an exception
		if RS.BannedAbilities[ownAbility or 0] then
			local bannedAbilityException = false
			for _, bae in pairs(RS.BannedAbilityExceptions or {}) do
				local bstOkay = pokemonInternal.bst < (bae.BSTLessThan or 0)
				local evoOkay = not bae.MustEvo or pokemonInternal.evolution ~= PokemonData.Evolutions.NONE
				local natdexOkay = not CustomCode.RomHacks.isPlayingNatDex() or bae.NatDexOnly
				if bstOkay and evoOkay and natdexOkay then
					bannedAbilityException = true
					break
				end
			end
			if not bannedAbilityException then
				abilityRating = 0
				if ownAbility == (AbilityData.Values.HugePowerId or 37) or ownAbility == (AbilityData.Values.PurePowerId or 74) then
					physcialMovesBanned = true
				end
			end
		end
		-- Check specific abilities generic to all rulesets
		if ownAbility == AbilityData.Values.SandStreamId then
			local safeSandTypes = {
				[PokemonData.Types.GROUND] = true,
				[PokemonData.Types.ROCK] = true,
				[PokemonData.Types.STEEL] = true
			}
			if safeSandTypes[pokemonTypes[1] or false] or safeSandTypes[pokemonTypes[2] or false] then
				abilityRating = abilityRating + (RS.ModifierAndRatings.RatingAbilitySandStreamSafe or 0)
			else
				abilityRating = abilityRating + (RS.ModifierAndRatings.RatingAbilitySandStreamUnsafe or 0)
			end
			conditionsAchieved[conditions.hasShedCoverage] = true
		end
		Utils.printDebug("Fixed Score for our Ability: " .. abilityRating)
		ratingTotal = ratingTotal + abilityRating


		-- STATS

		local nature = gachamon:getNature()
		local totalBST = pokemonInternal.bst

		local baseHP = baseStats.hp
		local baseATK = baseStats.atk
		local baseDEF = baseStats.def
		local baseSPA = baseStats.spa
		local baseSPD = baseStats.spd
		local baseSPE = baseStats.spe

		local phAtkRating = 0
		local spAtkRating = 0
		local speedRating = 0
		local phDefRating = 0
		local spDefRating = 0

		local speNature = Utils.getNatureMultiplier("spe", nature) or 1
		local atkNature = Utils.getNatureMultiplier("atk", nature) or 1
		local spaNature = Utils.getNatureMultiplier("spa", nature) or 1
		local defNature = Utils.getNatureMultiplier("def", nature) or 1
		local spdNature = Utils.getNatureMultiplier("spd", nature) or 1

		baseATK = math.floor(baseATK*atkNature + (atkNature-1)*10)
		baseSPA = math.floor(baseSPA*spaNature + (spaNature-1)*10)
		baseSPE = math.floor(baseSPE*speNature + (speNature-1)*10)
		baseDEF = math.floor(baseDEF*defNature + (defNature-1)*10)
		baseSPD = math.floor(baseSPD*spdNature + (spdNature-1)*10)

		local distanceToSpeedMinimum = 1
		local noDefenseAndNoSpeedModifier = 1
		local speedValue = 0.5

		-- SPEED

		if RS.Stats.Speed.Method.Name == "customTanh" then
			local minRating = RS.Stats.Speed.Method.MinRating or 0
			local maxRating = RS.Stats.Speed.Method.MaxRating or 0
			local centerAt = RS.Stats.Speed.Method.CenterAt or 0
			if RS.Stats.Speed.Method.CenterBSTdependent then
				centerAt = totalBST * centerAt
			end

			speedRating = self.calculateCustomTanh(centerAt, baseSPE) * (maxRating-minRating) + minRating
			distanceToSpeedMinimum = 1 - speedRating / minRating
			speedValue = (speedRating - minRating) / (maxRating - minRating)

		else
			Utils.printDebug("invalid speed evaluation method")
		end

		ratingTotal = ratingTotal + speedRating
		Utils.printDebug("speed rating: " .. speedRating)

		-- OFFENSE

		if ownAbility == (AbilityData.Values.HugePowerId or 37) or ownAbility == (AbilityData.Values.PurePowerId or 74) then
			if physcialMovesBanned then
				baseATK = 0
			else
				baseATK = baseATK * 2
			end
		elseif ownAbility == (AbilityData.Values.HustleId or 55) then
			baseATK = baseATK * 1.5
		end

		local phAtkRating = 0
		local spAtkRating = 0

		if RS.Stats.Offense.Method.Name == "tanh" then
			local centerAt = RS.Stats.Offense.Method.CenterAt or 0
			if RS.Stats.Offense.Method.CenterBSTdependent then
				centerAt = totalBST * (RS.Stats.Offense.Method.CenterAt or 0)
			end
			local stretchFactor = RS.Stats.Offense.Method.StretchFactor or 0
			local maxRating = RS.Stats.Offense.Method.MaxRating or 0

			phAtkRating = self.tanh((baseATK - centerAt) / stretchFactor) * maxRating
			spAtkRating = self.tanh((baseSPA - centerAt) / stretchFactor) * maxRating

			if RS.Stats.Penalties.BadOffenseInfluenceOnPowerRating then
				local maxPenaltyAt = RS.Stats.Penalties.BadOffenseInfluenceOnPowerRating.MinPowerRatingAt or 0
				local minModifier = RS.Stats.Penalties.BadOffenseInfluenceOnPowerRating.ModifierLowPowerMin or 0
				if phAtkRating < 0 then
					physicalPowerRating = physicalPowerRating * (minModifier + (baseATK - maxPenaltyAt) / (centerAt - maxPenaltyAt))
				end
				if spAtkRating < 0 then
					specialPowerRating = specialPowerRating * (minModifier + (baseSPA - maxPenaltyAt) / (centerAt - maxPenaltyAt))
				end
			end
			Utils.printDebug("atk rating: " .. phAtkRating)
			Utils.printDebug("spa rating: " .. spAtkRating)
		else
			Utils.printDebug("invalid offense evaluation method")
		end

		if (ownAbility == (AbilityData.Values.HugePowerId or 37) or ownAbility == (AbilityData.Values.PurePowerId or 74)) and phAtkRating > 0 then
			ratingTotal = ratingTotal + phAtkRating
			Utils.printDebug("Rating gain due to huge power: " .. phAtkRating)
		end



		-- DEFENSE

		local distanceToDefenseMinimum = 1
		local defenseRating = 0

		if RS.Stats.Defense.Method.Name == "customTanh" then

			local physicalDefenseNeeded = 0
			local specialDefenseNeeded = 0

			local abilityDefenseChanges = self.getAbilityTypeModifiers[ownAbility]
			local abilityTypingScore = 0

			for effectiveness, types in pairs(PokemonData.getEffectiveness(gachamon.PokemonId)) do

				for _, typing in pairs(types) do
					typeScariness = RS.ModifierAndRatings.EnemyMoveScariness[typing] or 1
					if abilityDefenseChanges then
						abilityModifier = abilityDefenseChanges[typing] or 1
						if abilityModifier ~= 1 then
							if abilityModifier == 0 then
								abilityTypingScore = abilityTypingScore + 3*effectiveness*typeScariness
							elseif abilityModifier < 1 then
								if effectiveness > 0.25 then
									abilityTypingScore = abilityTypingScore + 1.5*effectiveness*typeScariness
								end
							elseif abilityModifier > 1 then
								if effectiveness < 4 then
									abilityTypingScore = abilityTypingScore - 2*effectiveness*typeScariness
								end
							end
						end
					else
						abilityModifier = 1
					end
					if MoveData.TypeToCategory[typing] == MoveData.Categories.SPECIAL then
						specialDefenseNeeded = specialDefenseNeeded + typeScariness*effectiveness*effectiveness*abilityModifier*abilityModifier
					else
						physicalDefenseNeeded = physicalDefenseNeeded + typeScariness*effectiveness*effectiveness*abilityModifier*abilityModifier
					end
				end
			end
			
			ratingTotal = ratingTotal + abilityTypingScore
			Utils.printDebug("AbilityDefenseChangeScore: " .. abilityTypingScore)

			Utils.printDebug("physical defense needed: " .. physicalDefenseNeeded)
			Utils.printDebug("special defense needed: " .. specialDefenseNeeded)
			local totalDefenseNeeded = physicalDefenseNeeded + specialDefenseNeeded
			local spdPercentage = math.min(math.max(specialDefenseNeeded / totalDefenseNeeded, 0.34), 0.66)
			local defPercentage = 1 - spdPercentage

			-- compare with a flat-ish spread mon
			local compStatsTotal = RS.Stats.Defense.Method.DefenseWanted or 0
			if RS.Stats.Defense.Method.DefenseAmountBSTDependent then 
				compStatsTotal =  (totalBST) * (compStatsTotal or 0) / 100
			end
			local compHP = math.max(compStatsTotal / 3, 11)
			local compDef = compStatsTotal / 1.5 * defPercentage
			local compSpd = compStatsTotal / 1.5 * spdPercentage

			local compPhDefTotal = (compHP + 55) * compDef
			local compSpDefTotal = (compHP + 55) * compSpd

			local ownPhDefTotal = (baseHP + 55) * baseDEF
			local ownSpDefTotal = (baseHP + 55) * baseSPD

			local maxRating = RS.Stats.Defense.Method.MaxRating or 0
			local minRating = RS.Stats.Defense.Method.MinRating or 0

			local defRating = (self.calculateCustomTanh(compPhDefTotal, ownPhDefTotal) * (-minRating + maxRating)+minRating) * defPercentage
			local spdRating = (self.calculateCustomTanh(compSpDefTotal, ownSpDefTotal) * (-minRating + maxRating)+minRating) * spdPercentage
			Utils.printDebug("physical defense rating: " .. defRating)
			Utils.printDebug("special defense rating: " .. spdRating)

			if defRating < 0 or spdRating < 0 then
				defenseRating = math.min(defRating, 0) + math.min(spdRating, 0)
			else
				defenseRating = defRating + spdRating
			end
			distanceToDefenseMinimum = 1 - (defenseRating / minRating)
		else
			Utils.printDebug("invalid defense evaluation method")
		end

		ratingTotal = ratingTotal + defenseRating
		Utils.printDebug("defense rating: " .. defenseRating)

		if speedRating < 0 and defenseRating < 0 then
			--Utils.printDebug("Distance to Speed Min: -" .. distanceToSpeedMinimum)
			--Utils.printDebug("Distance to Def Min: -" .. distanceToDefenseMinimum)
			noSpeedNoDefPenalty = (RS.Stats.Penalties.NoSpeedAndNoDefense.PenaltyMax or 0) * (1-(distanceToDefenseMinimum*distanceToSpeedMinimum)^0.5)
			ratingTotal = ratingTotal - noSpeedNoDefPenalty
			Utils.printDebug("No Defense No Speed Penalty: -" .. noSpeedNoDefPenalty)
		end


		-- MOVES

		local iMoves = {}

		local debug = false
		local movesRating = 0

		local moves = gachamon.Temp.MoveIds or {}
		if debug then
			moves = {}
			for i=1, 354 do 
				moves[i] = i
			end
			pokemonTypes = {}
			ownAbility = 0
			file = io.open("ratings.txt", "w")
		end

		for i, id in ipairs(moves) do
			if id == 267 then
				id = 129 -- for nature power, evaluate swift 
			end
			iMoves[i] = {
				id = id,
				move = MoveData.getNatDexCompatible(id),
				ePower = self.getExpectedPowerForRating(id),
				conditionsToCheck = {},
				powerRating = 0,
				effectRating = 0,
				accuracyRating = 0,
				ppRating = 0,
				rating = 0
			}
			Utils.printDebug(MoveData.Moves[id].name)
			if RS.BannedMoves[id or 0] then -- Remove rating if banned move
				Utils.printDebug("banned move")
				iMoves[i].rating = 0
				if
					PokemonData.Types.FLYING == iMoves[i].move.type or PokemonData.Types.ROCK == iMoves[i].move.type or
						PokemonData.Types.GHOST == iMoves[i].move.type
				 then
					conditionsAchieved[conditions.hasShedCoverage] = true
				end
			elseif RS.FixedRatingMove[id] then -- Moves with fixed rating
				iMoves[i].rating = RS.FixedRatingMove[id]
				Utils.printDebug("fixed rating: " .. iMoves[i].rating)
				--Utils.printDebug(iMoves[i].rating)
				-- currently all weather moves have fixed rating
				if id == MoveData.Values.Sandstorm or id == MoveData.Values.Hail then
					conditionsAchieved[conditions.hasShedCoverage] = true
				end
			elseif physcialMovesBanned and iMoves[i].move.category == MoveData.Categories.PHYSICAL and iMoves[i].ePower > 0 then
				--Utils.printDebug("No Rating due to Huge/Pure Power")
				if
					PokemonData.Types.FLYING == iMoves[i].move.type or PokemonData.Types.ROCK == iMoves[i].move.type or
						PokemonData.Types.GHOST == iMoves[i].move.type
				 then
					-- can still use physical moves with huge power for shed coverage
					conditionsAchieved[conditions.hasShedCoverage] = true
				end
			else
				if IsOHKOMove[id] then
					--OHKOs
					iMoves[i].rating = RS.ModifierAndRatings.RatingOHKO or 0
					if iMoves[i].move.type ~= PokemonData.Types.ICE then
						-- only sheer cold does not have immune opponents
						iMoves[i].rating = iMoves[i].rating * (RS.ModifierAndRatings.ModifierMoveWithoutPowerHasImmuneOpponents or 1)
					end
					Utils.printDebug("OHKO move: " .. iMoves[i].rating)
				else
					local setupAdjustment = 1
					if iMoves[i].move.category == MoveData.Categories.STATUS then
						setupAdjustment = RS.ModifierAndRatings.ModifierMove.Setup or 1
						iMoves[i].ppRating = RS.ModifierAndRatings.ModifierPPStatus[iMoves[i].move.pp] or 0
						-- status move
					elseif iMoves[i].ePower > 0 then
						iMoves[i].ppRating = RS.ModifierAndRatings.ModifierPP[iMoves[i].move.pp] or 0
						iMoves[i].powerRating = iMoves[i].ePower

						-- rate the move based on how good it is at dealing damage
						if iMoves[i].move.category == MoveData.Categories.SPECIAL then
							iMoves[i].powerRating = iMoves[i].powerRating * specialPowerRating
							conditionsAchieved[conditions.hasSpecialMove] = true
						else
							iMoves[i].powerRating = iMoves[i].powerRating * physicalPowerRating
							conditionsAchieved[conditions.hasPhysicalMove] = true
						end
						if DoublesDmgOverTime[id] then
							iMoves[i].powerRating = iMoves[i].powerRating * (RS.ModifierAndRatings.ModifierDoublesDamageOverTimePower or 1)
						end
						--Utils.printDebug("Power Rating: " .. iMoves[i].powerRating)

						local moveType = iMoves[i].move.type or PokemonData.Types.UNKNOWN

						---- percentage modifiers 1

						--Weather
						if ownAbility == (AbilityData.Values.DrizzleId or 2) or ownAbility == (AbilityData.Values.DroughtId or 70) then
							iMoves[i].powerRating = (self.getAbilityTypeModifiers[moveType] or 1) * iMoves[i].powerRating
							--Utils.printDebug("Weather modifies rating: " .. iMoves[i].powerRating)
						end

						if not IsTypelessMove[id] then -- Type Rating for moves with type
							iMoves[i].powerRating = iMoves[i].powerRating * (RS.ModifierAndRatings.RatingMoveWithPowerType[moveType] or 1)
							--Utils.printDebug("Type Value: " .. iMoves[i].powerRating)
							if (not debug and Utils.isSTAB(iMoves[i].move, iMoves[i].move.type, pokemonTypes)) then
								iMoves[i].powerRating = iMoves[i].powerRating * 1.5
								--Utils.printDebug("STAB modifies rating: " .. iMoves[i].powerRating)
							end
							if
								PokemonData.Types.FLYING == iMoves[i].move.type or PokemonData.Types.ROCK == iMoves[i].move.type or
									PokemonData.Types.GHOST == iMoves[i].move.type or
									PokemonData.Types.FIRE == iMoves[i].move.type or
									PokemonData.Types.DARK == iMoves[i].move.type
							 then
								conditionsAchieved[conditions.hasShedCoverage] = true
							end
						else
							-- currently no type rating for "typeless"
							conditionsAchieved[conditions.hasShedCoverage] = true
						end
						if IsHighCritMove[id] then -- High Crit Chance
							iMoves[i].powerRating = iMoves[i].powerRating * (RS.ModifierAndRatings.ModifierHighCrit or 1)
							--Utils.printDebug("High Crit modifies rating: " .. iMoves[i].powerRating)
						end
						if IsRecoilMove[id] and ownAbility ~= 69 then -- recoil move and no rock head
							iMoves[i].powerRating = iMoves[i].powerRating * (RS.ModifierAndRatings.ModifierRecoil or 1)
							--Utils.printDebug("Move has recoil, but no rockhead.  New rating: " .. iMoves[i].powerRating)
						end

						---- flat ratings

						if IsBindMove[id] then -- binds enemy
							iMoves[i].powerRating = iMoves[i].powerRating + (RS.ModifierAndRatings.RatingWrapEnemy or 1)
							--Utils.printDebug("binding move: " .. iMoves[i].powerRating)
						end
						if IsItemStealMove[id] then -- steals item
							iMoves[i].powerRating = iMoves[i].powerRating + (RS.ModifierAndRatings.RatingItemSteal or 1)
							--Utils.printDebug("stealing item move: " .. iMoves[i].powerRating)
						end
						if IsDrainMove[id] then -- Drain Move
							iMoves[i].powerRating = iMoves[i].powerRating + (RS.ModifierAndRatings.RatingDrainMove or 1)
							--Utils.printDebug("drain move: " .. iMoves[i].powerRating)
						end
						if SmallBonus[id] then
							iMoves[i].powerRating = iMoves[i].powerRating + (RS.ModifierAndRatings.RatingSmallBonus or 1)
							--Utils.printDebug("Small Bonus: " .. iMoves[i].powerRating)
						end
						if SmallPositiveSideEffect[id] then
							iMoves[i].powerRating = iMoves[i].powerRating + (RS.ModifierAndRatings.RatingSmallPositiveSideEffect or 1)
							--Utils.printDebug("Small Positive Side Effect Bonus: " .. iMoves[i].powerRating)
						end

						---- percentage modifiers 2

						if MoveData.Moves[id].iscontact then -- contact
							local contactModifier = RS.ModifierAndRatings.ModifierContact or 1
							if self.MoveCategory.DoubleHitMoves[id] or self.MoveCategory.MultiHitMoves[id]  then
								contactModifier = contactModifier * contactModifier
							end
							iMoves[i].powerRating = iMoves[i].powerRating * contactModifier
							--Utils.printDebug("is contact: " .. iMoves[i].powerRating)
						end
						if IsLowPriorityMove[id] then -- Low Priority
							iMoves[i].powerRating = iMoves[i].powerRating * (1 - (RS.ModifierAndRatings.ModifierLowPriorityMin or 0)*speedValue)
							--Utils.printDebug("low prio: " .. iMoves[i].powerRating)
						elseif IsHighPriorityMove[id] then --High Priority
							iMoves[i].powerRating = iMoves[i].powerRating + (1-speedValue) * (RS.ModifierAndRatings.RatingHighPriorityMax or 1)
							--Utils.printDebug("high prio: " .. iMoves[i].powerRating)
						end

						Utils.printDebug("Final power rating: " .. iMoves[i].powerRating)
					else
						Utils.printDebug("Damaging Move without Power has no Rating")
					end

					-- rate the move's value regarding status infliction, needs loop due to tri attack
					for status, chance in pairs(StatusInflicted[id] or {}) do
						Utils.printDebug("status Rating: " .. status)
						local statusRating = RS.ModifierAndRatings.RatingOnHitEffect[status] or 0
						if status == Status.SLEEP then
							conditionsAchieved[conditions.hasSleepMove] = true
						end
						if status == Status.PARALYSIS then
							conditionsAchieved[conditions.hasParaMove] = true
						end
						if (status == Status.POISON
								or status == Status.TOXIC
								or status == Status.BURN
								or status == Status.CONFUSION)
							and iMoves[i].move.category == MoveData.Categories.STATUS
						 then
							conditionsAchieved[conditions.hasShedCoverage] = true
						end
						iMoves[i].effectRating = iMoves[i].effectRating + statusRating * math.min(chance * (ownAbility == AbilityData.Values.SereneGraceId and 2 or 1), 1)
						Utils.printDebug("new effect rating: " .. iMoves[i].effectRating)
					end

					-- rate the move's value regarding status drops on the opponent
					-- modifier and chance outside loop due to them always being the same for all effects
					-- currently, status raises on the opponent are not rated
					local modifier = (ModifiesEnemyStat[id] or {})["modifier"] or 0
					local chance = (ModifiesEnemyStat[id] or {})["chance"] or 0
					chance = math.min(chance * (ownAbility == AbilityData.Values.SereneGraceId and 2 or 1), 1)
					for _, stat in ipairs((ModifiesEnemyStat[id] or {})["stats"] or {}) do
						Utils.printDebug("opponent Stat mod: " .. stat)
						local statRating = 0
						if modifier < 0 then
							-- ignore enemy stat raises for now (only 2 moves -> swagger and flatter)
							statRating = RS.ModifierAndRatings.RatingOnHitEffect.RatingEnemyStatDrop or 0
						end
						iMoves[i].effectRating = iMoves[i].effectRating - chance * modifier * statRating
						Utils.printDebug("new effect rating: " .. iMoves[i].effectRating)
					end

					-- rate the move's value regarding status drops / increases on the user
					-- we put modifier and chance outside loop due to them always being the same for all effects
					modifier = (ModifiesOwnStat[id] or {})["modifier"] or 0
					chance = (ModifiesOwnStat[id] or {})["chance"] or 0
					chance = math.min(chance * (ownAbility == AbilityData.Values.SereneGraceId and 2 or 1), 1)
					for _, stat in ipairs((ModifiesOwnStat[id] or {})["stats"] or {}) do
						Utils.printDebug("own Stat mod: " .. stat)
						local statRating = 0
						if modifier > 0 and (stat == Stats.SPA or stat == Stats.ATK) then
							statRating = RS.ModifierAndRatings.RatingOnHitEffect.RatingOwnOffensiveStatIncrease or 0
						elseif modifier > 0 then
							statRating = RS.ModifierAndRatings.RatingOnHitEffect.RatingOwnOtherStatIncrease or 0
						else
							statRating = RS.ModifierAndRatings.RatingOnHitEffect.RatingLossOwnStatDrop or 0
						end
						iMoves[i].effectRating = iMoves[i].effectRating + chance * modifier * statRating * setupAdjustment
						Utils.printDebug("new effect rating: " .. iMoves[i].effectRating)
					end
					
					if MoveData.StatusMovesWillFail[i] then
						iMoves[i].statusRating = iMoves[i].statusRating * (RS.ModifierAndRatings.ModifierMoveWithoutPowerHasImmuneOpponents or 1)
					end

					-- Accuracy Modifier
					local accuracy = tonumber(iMoves[i].move.accuracy) or 0

					-- Abilities
					if ownAbility == (AbilityData.Values.CompoundeyesId or 14) then
						accuracy = math.min(math.floor(accuracy * 1.3), 100)
					elseif
						ownAbility == (AbilityData.Values.HustleId or 55) 
						and accuracy > 0 
						and MoveData.TypeToCategory[iMoves[i].move.type] == MoveData.Categories.PHYSICAL
					 then
						accuracy = math.floor(accuracy * 0.8)
					elseif
						iMoves[i].move == (MoveData.Values.ThunderId or 87) and
							ownAbility == (AbilityData.Values.DroughtId or 70)
					 then
						accuracy = 0.5
					end

					local perfectAccuracyModifier = 1
					if accuracy * 1 == 0 then
						accuracy = 100
						if not iMoves[i].move.category == MoveData.Categories.STATUS then
							perfectAccuracyModifier = RS.ModifierAndRatings.ModifierPerfectAccuracy or 1
						end
						Utils.printDebug("has perfect accuracy: " .. perfectAccuracyModifier)
					end
					accuracy = accuracy / 100
					if accuracy == 1 and iMoves[i].powerRating > 0 then conditionsAchieved[conditions.hasFullyAccurateDamagingMove] = true end

					-- we rate accuracy by rating the miss chance
					local accuracyPenaltyModifier = RS.ModifierAndRatings.ModifierAccuracyPenalty or 1
					if IsJumpKick[id] then
						accuracyPenaltyModifier = accuracyPenaltyModifier * (RS.ModifierAndRatings.ModifierJumpKickAccuracyPenalty or 1)
					elseif DoublesDmgOverTime[id] then
						accuracyPenaltyModifier = accuracyPenaltyModifier * (RS.ModifierAndRatings.ModifierDoublesDamageOverTimeAccuracyPenalty or 1)
					elseif id == (MoveData.Values.TripleKickId or 167) then
						accuracyPenaltyModifier = accuracyPenaltyModifier * (RS.ModifierAndRatings.ModifierTripleKickAccuracyPenalty or 1)
					end
					iMoves[i].accuracyRating = 1 - (1 - accuracy) * (accuracyPenaltyModifier or 1)
					Utils.printDebug("accuracy modifer: " .. iMoves[i].accuracyRating)
					Utils.printDebug("pp rating: " .. iMoves[i].ppRating)

					iMoves[i].rating = (iMoves[i].powerRating + iMoves[i].effectRating) * iMoves[i].accuracyRating * iMoves[i].ppRating
				end
				-- has preparation turn (like Solar Beam, razor wind)
				if HasPreparationTurn[id] or 0 > 0 then
					if HasPreparationTurn[id] > 2 then
						iMoves[i].rating = iMoves[i].rating * (RS.ModifierAndRatings.ModifierHasSemiInvinciblePreparationTurn or 1)
						Utils.printDebug("semi-invincible turn: " .. iMoves[i].rating)
					elseif (HasPreparationTurn[id] == 2) and (ownAbility == AbilityData.Values.DroughtId) then
						iMoves[i].rating = iMoves[i].rating * (RS.ModifierAndRatings.ModifierHasSkippedPreparationTurn or 1)
						Utils.printDebug("solar beam with drought: " .. iMoves[i].rating)
					else
						iMoves[i].rating = iMoves[i].rating * (RS.ModifierAndRatings.ModifierHasGenericPreparationTurn or 1)
						Utils.printDebug("generic preparation: " .. iMoves[i].rating)
					end
				end

				-- it move steals item, we give it a minimum rating of ItemStealMinimumRating
				if IsItemStealMove[id] then
					iMoves[i].rating = math.max(iMoves[i].rating, RS.ModifierAndRatings.RatingItemStealMinimum)
					Utils.printDebug("stealing item move: " .. iMoves[i].rating)
				end
				-- makes mon skip turn afterwards (like Hyper Beam) or the mon has no truant (we handle truant separately)
				if SkipsTurnAfterwards[id] and ownAbility ~= AbilityData.Values.TruantId then
					iMoves[i].rating = iMoves[i].rating * (RS.ModifierAndRatings.ModifierSkipTurnAfterwards or 1)
					Utils.printDebug("skips turn: " .. iMoves[i].rating)
				end
				-- for moves that hit after 3 turns (yawn, future sight, doom desire)
				if IsHitAfter3TurnsMove[id] then
					iMoves[i].rating = iMoves[i].rating * (RS.ModifierAndRatings.ModifierHitsAfter3Turns or 1)
					Utils.printDebug("hits after 3 turns: " .. iMoves[i].rating)
				end
				-- locking self in (like petal dance)
				if LockInMoves[id] and ownAbility ~= AbilityData.Values.TruantId then
					iMoves[i].rating = iMoves[i].rating * (RS.ModifierAndRatings.ModifierLockInMove or 1)
					Utils.printDebug("lock in move: " .. iMoves[i].rating)
				end
				-- for moves that confuse self (there is no move that confuses self while truant)
				if ConfusesSelf[id] and ownAbility ~= (AbilityData.Values.OwnTempoId or 20)
					and ownAbility ~= AbilityData.Values.TruantId then
					iMoves[i].rating = iMoves[i].rating * (RS.ModifierAndRatings.ModifierConfusesSelf or 1)
					Utils.printDebug("self confusion and no own tempo: " .. iMoves[i].rating)
				end
				-- moves with specific (json input) rating modifiers
				if RS.ModifierAndRatings.ModifierMove[tostring(id)] then
					iMoves[i].rating = iMoves[i].rating * (RS.ModifierAndRatings.ModifierMove[tostring(id)] or 1)
				end

				-- set flags for other moves / stats

				if RequiresOpponentAsleep[id] then
					iMoves[i].conditionsToCheck[conditions.hasSleepMove] = true
					Utils.printDebug("requires sleep move: " .. iMoves[i].rating)
				end
				if RequiresSelfSleep[id] then
					iMoves[i].conditionsToCheck[conditions.hasRest] = true
					Utils.printDebug("requires Rest: " .. iMoves[i].rating)
				end
				if BonusIfEnemyParalyzed[id] then
					iMoves[i].conditionsToCheck[conditions.hasParaMove] = true
					Utils.printDebug("requires para move: " .. iMoves[i].rating)
				end
			end
			
			if ownAbility == (AbilityData.Values.TruantId or 54) then
				iMoves[i].rating = iMoves[i].rating * (RS.ModifierAndRatings.ModifierSkipTurnAfterwards or 1) * (RS.ModifierAndRatings.ModifierTruantExtraPenalty or 1)
			end

			Utils.printDebug("preliminary move rating: " .. iMoves[i].rating or 0)
		end
		Utils.printDebug("---------")

		for i, id in ipairs(moves) do
			for condition, achieved in pairs(conditionsAchieved) do
				if iMoves[i].conditionsToCheck[condition] and not debug then
					Utils.printDebug("checking condition: " .. condition)
					iMoves[i].rating = iMoves[i].rating + (resultingRating[condition] or 0)
					iMoves[i].rating = iMoves[i].rating * (resultingModifier[condition] or 1)
				end
			end
			Utils.printDebug("final move rating: " .. iMoves[i].rating or 0)

			if debug then
				file:write(iMoves[i].rating, "\n")
			end
			movesRating = movesRating + math.max(iMoves[i].rating, 0)
		end
		Utils.printDebug("total final move Rating: " .. movesRating)
		ratingTotal = ratingTotal + movesRating

		-- checking various conditions, calculating total rating

		if conditionsAchieved[conditions.hasPhysicalMove] == false then
			phAtkRating = math.min(0, phAtkRating)
		end
		if conditionsAchieved[conditions.hasSpecialMove] == false then
			spAtkRating = math.min(0, spAtkRating)
		end

		if spAtkRating < 0 and phAtkRating < 0 then
			offenseRating = spAtkRating + phAtkRating
		else
			offenseRating = math.min(math.max(spAtkRating, 0) + math.max(phAtkRating, 0), RS.Stats.Offense.MaxTotalRating or 20)
		end
		ratingTotal = ratingTotal + offenseRating
		Utils.printDebug("offense rating: " .. offenseRating)

		if conditionsAchieved[conditions.hasShedCoverage] then
			ratingTotal = ratingTotal + RS.ModifierAndRatings.RatingShedCoverage or 0
			Utils.printDebug("shed coverage: " .. RS.ModifierAndRatings.RatingShedCoverage or 0)
		end
		if conditionsAchieved[conditions.hasFullyAccurateDamagingMove] then
			ratingTotal = ratingTotal + RS.ModifierAndRatings.RatingHasFullyAccurateDamagingMove or 0,
			Utils.printDebug("has fully accurate damaging move: " .. RS.ModifierAndRatings.RatingHasFullyAccurateDamagingMove or 0)
		end

		Utils.printDebug(".........................")
		Utils.printDebug("total Rating: " .. ratingTotal)
		if debug then
			file:close()
		end

		return math.floor(ratingTotal)
	end

	function self.calculateCustomTanh(center, value)
		result = self.tanh(value/center)^2.54514
		return result
	end

	function self.tanh(x)
  		if x == 0 then return 0.0 end
  		local neg = false
  		if x < 0 then x = -x; neg = true end
  		if x < 0.54930614433405 then
    		local y = x * x
    		x = x + x * y *
        		((-0.96437492777225469787e0  * y +
          			-0.99225929672236083313e2) * y +
          			-0.16134119023996228053e4) /
        		(((0.10000000000000000000e1  * y +
           			0.11274474380534949335e3) * y +
           			0.22337720718962312926e4) * y +
           			0.48402357071988688686e4)
  		else
    		x = math.exp(x)
    		x = 1.0 - 2.0 / (x * x + 1.0)
  		end
 		if neg then x = -x end
 		return x
	end

	self.getAbilityTypeModifiers = {
		[AbilityData.Values.DrizzleId or 2] = { [PokemonData.Types.FIRE] = 0.5, [PokemonData.Types.WATER] = 1.5 },
		[AbilityData.Values.VoltAbsorbId or 10] = { [PokemonData.Types.ELECTRIC] = 0 },
		[AbilityData.Values.WaterAbsorbId or 11] = { [PokemonData.Types.WATER] = 0 },
		[AbilityData.Values.FlashFireId or 18] = { [PokemonData.Types.FIRE] = 0 },
		[AbilityData.Values.LevitateId or 26] = { [PokemonData.Types.GROUND] = 0 },
		[AbilityData.Values.ThickFatId or 47] = { [PokemonData.Types.FIRE] = 0.5, [PokemonData.Types.ICE] = 0.5 },
		[AbilityData.Values.DroughtId or 70] = { [PokemonData.Types.FIRE] = 1.5, [PokemonData.Types.WATER] = 0.5 },
	}

	Status = {
		BURN = "burn",
		FREEZE = "freeze",
		PARALYSIS = "paralysis",
		SLEEP = "sleep",
		POISON = "poison",
		TOXIC = "toxic",
		INFATUATION = "infatuation",
		CONFUSION = "confusion",
		FLINCH = "flinch",
	}

	Stats = {
		ATK = "Attack",
		DEF = "Defense",
		SPA = "Special Attack",
		SPD = "Special Defense",
		SPE = "Speed",
		ACC = "Accuracy",
		EVA = "Evasion",
		CRT = "Critical Hit Chance",
	}

	StatusInflicted = {
		[7] = { [Status.BURN] = 0.1, }, -- Fire Punch
		[8] = { [Status.FREEZE] = 0.1, }, -- Ice Punch
		[9] = { [Status.PARALYSIS] = 0.1, }, -- Thunder Punch
		[23] = { [Status.FLINCH] = 0.3, }, -- Stomp
		[27] = { [Status.FLINCH] = 0.3, }, -- Rolling Kick
		[29] = { [Status.FLINCH] = 0.3, }, -- Headbutt
		[34] = { [Status.PARALYSIS] = 0.3, }, -- Body Slam
		[40] = { [Status.POISON] = 0.3, }, -- Poison Sting
		[41] = { [Status.POISON] = 0.2, }, -- Twineedle
		[44] = { [Status.FLINCH] = 0.2, }, -- Bite
		[47] = { [Status.SLEEP] = 1, }, -- Sing
		[48] = { [Status.CONFUSION] = 1, }, -- Supersonic
		[52] = { [Status.BURN] = 0.1, }, -- Ember
		[53] = { [Status.BURN] = 0.1, }, -- Flamethrower
		[58] = { [Status.FREEZE] = 0.1, }, -- Ice Beam
		[59] = { [Status.FREEZE] = 0.1, }, -- Blizzard
		[60] = { [Status.CONFUSION] = 0.1, }, -- Psybeam
		[77] = { [Status.POISON] = 1, }, -- Poison Powder
		[78] = { [Status.PARALYSIS] = 1, }, -- Stun Spore
		[79] = { [Status.SLEEP] = 1, }, -- Sleep Powder
		[84] = { [Status.PARALYSIS] = 0.1, }, -- Thunder Shock
		[85] = { [Status.PARALYSIS] = 0.1, }, -- Thunderbolt
		[86] = { [Status.PARALYSIS] = 1, }, -- Thunderwave
		[87] = { [Status.PARALYSIS] = 0.3, }, -- Thunder
		[92] = { [Status.TOXIC] = 1, }, -- Toxic
		[93] = { [Status.CONFUSION] = 0.1, }, -- Confusion
		[95] = { [Status.SLEEP] = 1, }, -- Hypnosis
		[109] = { [Status.CONFUSION] = 1, }, -- Confuse Ray
		[122] = { [Status.PARALYSIS] = 0.3, }, -- Lick
		[123] = { [Status.POISON] = 0.4, }, -- Smog
		[124] = { [Status.POISON] = 0.3, }, -- Sludge
		[125] = { [Status.FLINCH] = 0.1, }, -- Bone Club
		[126] = { [Status.BURN] = 0.1, }, -- Fire Blast
		[137] = { [Status.PARALYSIS] = 1, }, -- Glare
		[139] = { [Status.POISON] = 1, }, -- Poison Gas
		[142] = { [Status.SLEEP] = 1, }, -- Lovely Kiss
		[143] = { [Status.FLINCH] = 0.3, }, -- Sky Attack
		[146] = { [Status.CONFUSION] = 0.2, }, -- Dizzy Punch
		[147] = { [Status.SLEEP] = 1, }, -- Spore
		[157] = { [Status.FLINCH] = 0.3, }, -- Rock Slide
		[158] = { [Status.FLINCH] = 0.1, }, -- Hyper Fang
		[161] = { [Status.PARALYSIS] = 1/15, [Status.BURN] = 1/15, [Status.FREEZE] = 1/15, }, -- Tri Attack
		[172] = { [Status.BURN] = 0.1, }, -- FFlame Wheel
		[173] = { [Status.FLINCH] = 0.3, }, -- Snore
		[181] = { [Status.FREEZE] = 0.1, }, -- Powder Snow
		[186] = { [Status.CONFUSION] = 1, }, -- Sweet Kiss
		[188] = { [Status.POISON] = 0.3, }, -- Sludge Bomb
		[191] = { [Status.PARALYSIS] = 1, }, -- Zap Cannon
		[207] = { [Status.CONFUSION] = 1, }, -- Swagger
		[209] = { [Status.PARALYSIS] = 0.3, }, -- Spark
		[213] = { [Status.INFATUATION] = 1, }, -- Attract
		[221] = { [Status.BURN] = 0.5, }, -- Sacred Fire
		[223] = { [Status.CONFUSION] = 1, }, -- Dynamic Punch
		[225] = { [Status.PARALYSIS] = 0.3, }, -- Dragon Breath
		[239] = { [Status.FLINCH] = 0.2, }, -- Twister
		[252] = { [Status.FLINCH] = 1, }, -- Fake Out
		[257] = { [Status.BURN] = 0.1, }, -- Heat Wave
		[260] = { [Status.CONFUSION] = 1, }, -- Flatter
		[261] = { [Status.BURN] = 1, }, -- Will-O-Wisp
		[281] = { [Status.SLEEP] = 1, }, -- Yawn
		[290] = { [Status.PARALYSIS] = 0.3, }, -- Secret Power, technically other status as well but for simplicity only para here
		[298] = { [Status.CONFUSION] = 1, }, -- Teeter Dance
		[299] = { [Status.BURN] = 0.1, }, -- Blaze Kick
		[302] = { [Status.FLINCH] = 0.3, }, -- Needle Arm
		[305] = { [Status.TOXIC] = 0.3, }, -- Poison Fang
		[310] = { [Status.FLINCH] = 0.3, }, -- Astonish
		[320] = { [Status.SLEEP] = 1, }, -- Grass Whistle
		[324] = { [Status.CONFUSION] = 0.1, }, -- Signal Beam
		[326] = { [Status.FLINCH] = 0.1, }, -- Extrasensory
		[340] = { [Status.PARALYSIS] = 0.3, }, -- Bounce
		[342] = { [Status.POISON] = 0.1, }, -- Poison Tail
		[352] = { [Status.CONFUSION] = 0.2, }, -- Signal Beam
	}

	ModifiesEnemyStat = {
		[28] = {stats = {Stats.ACC}, modifier = -1, chance = 1}, -- Sand Attack
		[39] = {stats = {Stats.DEF}, modifier = -1, chance = 1}, -- Tail Whip
		[43] = {stats = {Stats.DEF}, modifier = -1, chance = 1}, -- Leer
		[45] = {stats = {Stats.ATK}, modifier = -1, chance = 1}, -- Growl
		[51] = {stats = {Stats.DEF}, modifier = -1, chance = 0.1}, -- Acid
		[61] = {stats = {Stats.SPE}, modifier = -1, chance = 0.1}, -- Bubble Beam
		[62] = {stats = {Stats.ATK}, modifier = -1, chance = 0.1}, -- Aurora Beam
		[81] = {stats = {Stats.SPE}, modifier = -1, chance = 1}, -- String Shot
		[94] = {stats = {Stats.SPD}, modifier = -1, chance = 0.1}, -- Psychic
		[103] = {stats = {Stats.DEF}, modifier = -2, chance = 1}, -- Screech
		[108] = {stats = {Stats.ACC}, modifier = -1, chance = 1}, -- Smokescreen
		[132] = {stats = {Stats.SPE}, modifier = -1, chance = 0.1}, -- Constrict
		[134] = {stats = {Stats.ACC}, modifier = -1, chance = 1}, -- Kinesis
		[145] = {stats = {Stats.SPE}, modifier = -1, chance = 0.1}, -- Bubble
		[148] = {stats = {Stats.ACC}, modifier = -1, chance = 1}, -- Flash
		[178] = {stats = {Stats.SPE}, modifier = -2, chance = 1}, -- Cotton Spore
		[184] = {stats = {Stats.SPE}, modifier = -2, chance = 1}, -- Scary Face
		[189] = {stats = {Stats.ACC}, modifier = -1, chance = 1}, -- Mud Slap
		[190] = {stats = {Stats.ACC}, modifier = -1, chance = 0.5}, -- Octazooka
		[196] = {stats = {Stats.SPE}, modifier = -1, chance = 1}, -- Icy Wind
		[204] = {stats = {Stats.ATK}, modifier = -2, chance = 1}, -- Charm
		[207] = {stats = {Stats.ATK}, modifier = 2, chance = 1}, -- Swagger
		[230] = {stats = {Stats.EVA}, modifier = -1, chance = 1}, -- Sweet Scent
		[231] = {stats = {Stats.DEF}, modifier = -1, chance = 0.3}, -- Iron Tail
		[242] = {stats = {Stats.SPD}, modifier = -1, chance = 0.2}, -- Crunch
		[247] = {stats = {Stats.SPD}, modifier = -1, chance = 0.2}, -- Shadow Ball
		[249] = {stats = {Stats.DEF}, modifier = -1, chance = 0.5}, -- Rock Smash
		[260] = {stats = {Stats.SPA}, modifier = 1, chance = 1}, -- Flatter
		[295] = {stats = {Stats.SPD}, modifier = -1, chance = 0.5}, -- Luster Purge
		[296] = {stats = {Stats.SPA}, modifier = -1, chance = 0.5}, -- Mist Ball
		[297] = {stats = {Stats.ATK}, modifier = -2, chance = 1}, -- Feather Dance
		[305] = {stats = {Stats.DEF}, modifier = -1, chance = 0.5}, -- Crush Claw
		[313] = {stats = {Stats.SPA}, modifier = -2, chance = 1}, -- Fake Tears
		[317] = {stats = {Stats.SPE}, modifier = -1, chance = 1}, -- Rock Tomb
		[319] = {stats = {Stats.SPD}, modifier = -2, chance = 1}, -- Metal Sound
		[321] = {stats = {Stats.ATK, Stats.DEF}, modifier = -1, chance = 1}, -- Tickle
		[330] = {stats = {Stats.ACC}, modifier = -1, chance = 0.3}, -- Muddy Water
		[341] = {stats = {Stats.SPE}, modifier = -1, chance = 1}, -- Mud Shot
	}

	ModifiesOwnStat = {
		[14] = {stats = {Stats.ATK}, modifier = 2, chance = 1}, -- Swords Dance
		[74] = {stats = {Stats.SPA}, modifier = 1, chance = 1}, -- Growth
		[96] = {stats = {Stats.ATK}, modifier = 1, chance = 1}, -- Meditate
		[97] = {stats = {Stats.SPE}, modifier = 2, chance = 1}, -- Agility
		[99] = {stats = {Stats.ATK}, modifier = 1, chance = 0.5}, -- Rage TODO impove rating method
		[104] = {stats = {Stats.EVA}, modifier = 1, chance = 1}, -- Double Team
		[106] = {stats = {Stats.DEF}, modifier = 1, chance = 1}, -- Harden
		[107] = {stats = {Stats.EVA}, modifier = 1, chance = 1}, -- Minimize
		[110] = {stats = {Stats.DEF}, modifier = 1, chance = 1}, -- Withdraw
		[111] = {stats = {Stats.DEF}, modifier = 1, chance = 1}, -- Defense Curl
		[112] = {stats = {Stats.DEF}, modifier = 2, chance = 1}, -- Barrier
		[113] = {stats = {Stats.SPD}, modifier = 2, chance = 1}, -- Light Screen TODO
		[115] = {stats = {Stats.DEF}, modifier = 2, chance = 1}, -- Reflect TODO
		[116] = {stats = {Stats.CRT}, modifier = 2, chance = 1}, -- Focus Energy
		[130] = {stats = {Stats.DEF}, modifier = 1, chance = 1}, -- Skull Bash
		[133] = {stats = {Stats.SPD}, modifier = 2, chance = 1}, -- Amnesia
		[151] = {stats = {Stats.DEF}, modifier = 2, chance = 1}, -- Acid Armor
		[159] = {stats = {Stats.ATK}, modifier = 1, chance = 1}, -- Sharpen TODO curse move 174
		[211] = {stats = {Stats.DEF}, modifier = 1, chance = 0.1}, -- Steel Wing
		[232] = {stats = {Stats.ATK}, modifier = 1, chance = 0.1}, -- Metal Claw
		[246] = {stats = {Stats.ATK, Stats.SPE, Stats.DEF, Stats.SPA, Stats.SPD}, modifier = 1, chance = 0.1}, -- Ancient Power
		[276] = {stats = {Stats.ATK, Stats.DEF}, modifier = -1, chance = 1}, -- Superpower
		[294] = {stats = {Stats.SPA}, modifier = 2, chance = 1}, -- Tail Glow
		[309] = {stats = {Stats.ATK}, modifier = 1, chance = 0.2}, -- Meteor Mash
		[315] = {stats = {Stats.SPA}, modifier = -2, chance = 1}, -- Overheat
		[318] = {stats = {Stats.ATK, Stats.SPE, Stats.DEF, Stats.SPA, Stats.SPD}, modifier = 1, chance = 0.1}, -- Silver Wind
		[322] = {stats = {Stats.SPD, Stats.DEF}, modifier = 1, chance = 1}, -- Cosmic Power
		[334] = {stats = {Stats.DEF}, modifier = 2, chance = 1}, -- Iron Defense
		[336] = {stats = {Stats.ATK}, modifier = 1, chance = 1}, -- Howl
		[339] = {stats = {Stats.ATK, Stats.DEF}, modifier = 1, chance = 1}, -- Bulk Up
		[347] = {stats = {Stats.SPA, Stats.SPD}, modifier = 1, chance = 1}, -- Calm Mind
		[349] = {stats = {Stats.ATK, Stats.SPE}, modifier = 1, chance = 1}, -- Dragon Dance
		[354] = {stats = {Stats.SPA}, modifier = -2, chance = 1}, -- Psycho Boost
	}

	IsHighCritMove = {
		[ 2] = true, -- Karate Chop
		[ 75] = true, -- Razor Leaf
		[ 143] = true, -- Sky Attack
		[ 152] = true, -- Crab Hammer
		[ 163] = true, -- Slash
		[ 177] = true, -- Aeroblast
		[ 238] = true, -- Cross Chop
		[ 299] = true, -- Blaze Kick
		[ 314] = true, -- Air Cutter
		[ 342] = true, -- Poison Tail
		[ 348] = true, -- Leaf Blade
	}

	IsTypelessMove = { -- Moves which inflict typeless damage (unaffected by STAB)
		[248] = true, -- Future Sight
		[251] = true, -- Beat Up
		[353] = true, -- Doom Desire
	}

	IsOHKOMove = {
		[ 12] = true, -- Guillotine
		[ 32] = true, -- Horn Drill
		[ 90] = true, -- Fissure
		[329] = true, -- Sheer Cold
	}

	IsRecoilMove = {
		[ 36] = true, -- Take Down
		[ 38] = true, -- Double-Edge
		[ 66] = true, -- Submission
		[344] = true, -- Volt Tackle
	}

	IsJumpKick = {
		[ 26] = true, -- Jump Kick
		[ 136] = true, -- High Jump Kick
	}

	IsBindMove = {
		[ 20] = true, -- Bind
		[ 35] = true, -- Wrap
		[ 83] = true, -- Fire Spin
		[ 128] = true, -- Clamp
		[ 250] = true, -- Whirlpool
		[ 328] = true, -- Sand Tomb
	}

	IsDrainMove = {
		[ 71] = true, -- Absorb
		[ 72] = true, -- Mega Drain
		[ 138] = true, -- Dream Eater
		[ 141] = true, -- Leech Life
		[ 202] = true, -- Giga Drain
	}

	IsHighPriorityMove = {
		[ 98] = true, -- Quick Attack
		[ 182] = true, -- Mach Punch
		[ 245] = true, -- Extreme Speed
		[ 252] = true, -- Fake Out
	}

	IsItemStealMove = {
		[ 168] = true, -- Thief
		[ 271] = true, -- Trick
		[ 343] = true, -- Covet
	}

	SkipsTurnAfterwards = {
		[ 63] = true, -- Hyper Beam
		[ 307] = true, -- Blast Burn
		[ 308] = true, -- Hydro Cannon
		[ 338] = true, -- Frenzy Plant
	}

	IsHitAfter3TurnsMove = {
		[ 248] = true, -- Future Sight
		[ 281] = true, -- Yawn
		[ 353] = true, -- Doom Desire
	}

	-- 1 = generic, 2 = skipped by sun, 3 = under ground, 4 = under water, 5 = flying
	HasPreparationTurn = {
		[ 13] = 1, -- Razor Wind
		[ 19] = 5, -- Fly
		[ 76] = 2, -- Solar Beam
		[ 91] = 3, -- Dig
		[ 130] = 1, -- Skull Bash
		[ 143] = 1, -- Sky Attack
		[ 291] = 4, -- Dive
		[ 340] = 5, -- Bounce
	}

	LockInMoves = {
		[ 37] = true, --Thrash
		[ 80] = true, --Petal Dance
		[ 200] = true, --Outrage
		[ 205] = true, --Rollout
		[ 253] = true, --Uproar
		[ 301] = true, --Ice Ball
	}

	ConfusesSelf = {
		[ 37] = true, --Thrash
		[ 80] = true, --Petal Dance
		[ 200] = true, --Outrage
	}

	DoublesDmgOverTime = {
		[ 205] = true, --Rollout 		90% acc
		[ 210] = true, --Fury Cutter 	95% acc
		[ 301] = true, --Ice Ball 		90% acc
	}

	IsLowPriorityMove = {
		[ 233] = true, -- Vital Throw
		[ 264] = true, -- Focus Punch
		[ 279] = true, -- Revenge
	}

	RequiresOpponentAsleep = {
		[ 138] = true, -- Dream Eater
		[ 171] = true, -- Nightmare
	}

	BonusIfEnemyParalyzed = {
		[ 265] = true, -- Smelling Salts
	}

	-- TODO move this to json to enable moving moves between groups in the json
	SmallPositiveSideEffect = {
		[ 172] = true, -- Flame Wheel (thaws)
		[ 221] = true, -- Sacred Fire (thaws)
		[ 229] = true, -- Rapid Spin (removes binds / leech seed)
		[ 253] = true, --	Uproar (prevents sleep)
		[ 280] = true, -- Brick Break (removes Barrier / Light Screen)
	}

	-- TODO should use this section to the rating json long term
	SmallBonus = {
		[ 16] = true, -- Gust 				(double dmg vs flying target)
		[ 23] = true, -- Stomp 				(double dmg vs minimized target)
		[ 87] = true, -- Thunder 			(hits flying targets)
		[ 89] = true, -- Earthquake 		(double dmg vs digging target)
		[ 222] = true, -- Magnitude 		(double dmg vs digging target)
		[ 228] = true, -- Pursuit 			(double dmg vs switching mon)
		[ 239] = true, -- Twister 			(double dmg vs flying target)
		[ 263] = true, -- Facade 			(double dmg if own non-volile status)
		[ 265] = true, -- Smelling Salt 	(double dmg vs paralyzed targets, but cures)
		[ 302] = true, -- Needle Arm 		(double dmg vs minimized target)
		[ 310] = true, -- Astonish 			(double dmg vs minimized target)
		[ 326] = true, -- Extrasensory 		(double dmg vs minimized target)
		[ 327] = true, -- Sky Uppercut 		(hits flying targets)
	}

	-- handled as specific move -> not used
	IsFirstTurnOnlyMove = {
		[ 252] = true, -- Fake Out
	}

	-- handled as specific move -> not used
	FailsIfDamaged = {
		[ 264] = true, -- Focus Punch
	}

	-- 1 = Clear, 2 = Hail, 3 = Rain, 4 = Sunny, 5 = Sandstorm, not used
	DmgModifiedByWeather = {
		[ 76] = {[2]=0.5,[3]=0.5,[5]=0.5}, -- Solar Beam
	}

	-- 1 = Clear, 2 = Hail, 3 = Rain, 4 = Sunny, 5 = Sandstorm, not used
	AccuracySetByWeather = {
		[ 87] = {[3]=1, [4]=0.5}, -- Thunder
	}

	-- not used
	SetsUpMove = {
		[ 111] = true, --Defense Curl (sets up rollout / ice ball)
	}

	-- not used
	IsRemoveItemMove = {
		[ 282] = true, -- Knock Off
	}

	-- enemy using metronome -> dive not likely enough, not used
	NoBonusAsNotLikely = {
		[ 57] = true, -- Surf 			(double dmg vs diving target)
		[ 250] = true, -- Whirlpool 		(double dmg vs diving target)
	}

	-- not used
	RequiresSelfSleep = {
		[ 173] = true, -- Snore
		[ 214] = true, -- Sleep Talk
	}


	---Determines (guesses) at the expected numerical power of a given move. For example, average power for multi-hit moves, or max power for HP based moves.
	---@param moveId number
	---@return number
	function self.getExpectedPowerForRating(moveId)
		if not MoveData.isValid(moveId) then
			return 0

		elseif moveId == MoveData.Values.EruptionId or moveId == MoveData.Values.WaterSpoutId then
			return 120
		elseif moveId == MoveData.Values.FrustrationId then
			return 40
		elseif moveId == MoveData.Values.FlailId or moveId == MoveData.Values.ReversalId then
			return 60
		elseif moveId == MoveData.Values.LowKickId then
			return 80
		elseif moveId == MoveData.Values.ReturnId then
			return 102
		elseif moveId == MoveData.Values.FrustrationId then
			return 50
		elseif moveId == MoveData.Values.TripleKickId then
			return 60
		end

		local power = tonumber(MoveData.Moves[moveId].power) or 0
		if self.MoveCategory.DoubleHitMoves[moveId] then
			return (power * 2)
		elseif self.MoveCategory.MultiHitMoves[moveId] then
			-- Average of 3 hits
			return (power * 3)
		end

		return power
	end

	self.MoveCategory = {

	-- https://bulbapedia.bulbagarden.net/wiki/Multi-strike_move#Variable_number_of_strikes
	["MultiHitMoves"] = {
		[292] = true, [140] = true, [198] = true, [331] = true, [4] = true, [3] = true,
		[31] = true, [154] = true, [333] = true, [42] = true, [350] = true, [131] = true
	},
	-- https://bulbapedia.bulbagarden.net/wiki/Multi-strike_move#Fixed_number_of_multiple_strikes
	["DoubleHitMoves"] = {
		[155] = true, [41] = true, [24] = true
	},
	["HealMove"] = {
		105, -- recover
		135, -- softboiled
		156, -- rest
		208, -- milk drink
		220, -- pain split
		234, -- morning sun
		235, -- synthesis
		236, -- moonlight
		256, -- swallow
		273, -- wish
		275, -- ingrain
		303 -- slack off
	},
	["StatusHealMove"] = {
		215, -- heal bell
		287, -- refresh
		312 -- aromatherapy
	},
	["DrainMove"] = {
		71, -- absorb
		72, -- mega drain
		138, -- dream eater
		141, -- leech life
		202, -- giga drain
		356 -- <fairy drain move>
	},
	["HM"] = {
		15, 	-- cut 
		19, 	-- fly
		57, 	-- surf
		70, 	-- strength
		127, 	-- waterfall
		148, 	-- flash
		249, 	-- rock smash
		291 	-- dive
	}
	}
	self.SporeId = 147
	self.LeechSeedId = 73

	return self
end
return AdaptiveRating