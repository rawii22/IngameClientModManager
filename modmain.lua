local ServerCreationScreen = GLOBAL.require("screens/redux/servercreationscreen")
local ModsScreen = GLOBAL.require("screens/redux/modsscreen")
local ModsTab = GLOBAL.require("widgets/redux/modstab")
local TEMPLATES = GLOBAL.require("widgets/redux/templates")
local io = GLOBAL.io
local json = GLOBAL.json
local pcall = GLOBAL.pcall
local KEY = GetModConfigData("KEY")
local HOST_SERVER_LISTING
local modDebugPrefix = "[IN-GAME MOD MANAGER]"

--later used when recreating the custom modstab widget
local settings = {
	is_configuring_server = false, -- must be able to detect config changes before turning this on. If they are not detected, Create() will not run and will cause mismatching mod configs between hosts and clients.
	details_width = 505,
	are_servermods_readonly = false,
}

-- Save master shard server listing to a file accessible by secondary shards (currently not in use)
HOST_SERVER_LISTING = GLOBAL.TheNet:GetServerListing()
if not GLOBAL.TheNet:GetIsClient() then
	local r, result = pcall(json.encode, GLOBAL.TheNet:GetServerListing())
	if not r then print("Could not encode all items: "..tostring(GLOBAL.TheNet:GetServerListing())) end
	if result then
		local serverListingFile = io.open("serverlisting.txt", "w")
		serverListingFile:write(result)
		serverListingFile:close()
	end
end

---===============
---  Key Handler
---===============
local modkey = KEY
--The key will activate the modsscreen screen in-game
GLOBAL.TheInput:AddKeyUpHandler(
	modkey:lower():byte(), 
	function()
		if not GLOBAL.TheNet:GetIsClient() then --Probably need RPC when we expand this to client hosts.
			GLOBAL.TheNet:SetAllowIncomingConnections(false)
		end
		if not GLOBAL.IsPaused() and IsDefaultScreen() and not GLOBAL.ThePlayer.player_classified._isSecondaryShard:value() then  -- Doesn't work in caves yet
			local ms = ModsScreen()
			ms.mods_page:Kill() --Kill the modstab so we can customize it later
			for k,v in pairs(ms.mods_page.subscreener.menu.items) do
				v:Kill() --Kills duplicated buttons that appear when the modstab is created again later
			end
			
			-- Server mods are only configurable by admin of a non-dedicated, non-caves server (to be expanded)
			if not GLOBAL.TheNet:GetIsServerAdmin() or GLOBAL.TheNet:GetServerIsDedicated() then
				settings.are_servermods_readonly = true
			end
			
			ms.mods_page.tooltip:Kill()
			ms.mods_page = ms.optionspanel:InsertWidget(ModsTab(ms, settings))
			ms.mods_page.slotnum = GLOBAL.ShardGameIndex:GetSlot() --This satisfies a condition in ModsTab:Apply() that ensures the Sim does not reset
			ms.bg:Kill() --Kill the default background
			ms.bg = ms.root:AddChild(TEMPLATES.BackgroundTint(0.5, {0,0,0})) --Add custom background
			ms.bg:MoveToBack()
			ms.enabled_server_mods = GLOBAL.ModManager:GetEnabledServerModNames() --this is later used to detect changes to server mods
			
			GLOBAL.TheFrontEnd:PushScreen(ms) --Finally make the screen appear
		end
	end
)

function IsDefaultScreen()
	if GLOBAL.TheFrontEnd:GetActiveScreen() and GLOBAL.TheFrontEnd:GetActiveScreen().name and type(GLOBAL.TheFrontEnd:GetActiveScreen().name) == "string" and GLOBAL.TheFrontEnd:GetActiveScreen().name == "HUD" then
		return true
	else
		return false
	end
end

local function serverModsChanged(oldMods, newMods)
	--if the lists differ in size, then just return true
	local oldModsSize = 0
	local newModsSize = 0
	for _ in pairs(oldMods) do oldModsSize = oldModsSize + 1 end
	for _ in pairs(newMods) do newModsSize = newModsSize + 1 end
	if oldModsSize ~= newModsSize then
		return true
	end
	
	--in case the lists are the same size, do a more thorough check
	table.sort(oldMods)
	table.sort(newMods)
	for k, v in pairs(oldMods) do
		if oldMods[k] ~= newMods[k] then --check for differences
			return true
		end
	end
	
	return false
end

--What happens when the Apply button is clicked
local function ApplyToGame(modsscreen)
	local OldApply = modsscreen.Apply
	modsscreen.Apply = function(self)
		if GLOBAL.TheWorld ~= nil and GLOBAL.ThePlayer ~= nil then
			local slot = GLOBAL.ShardGameIndex:GetSlot()
			local isSecondary = GLOBAL.ThePlayer.player_classified._isSecondaryShard:value()
			if GLOBAL.TheNet:GetServerIsClientHosted() and GLOBAL.TheNet:GetIsServerAdmin() and not GLOBAL.TheNet:GetIsClient() then --for non-dedicated non-caves server host
				if serverModsChanged(self.enabled_server_mods, GLOBAL.ModManager:GetEnabledServerModNames()) then --figured out how to modify server mods on 8/6/2021
					local scs = ServerCreationScreen(GLOBAL.TheFrontEnd:GetActiveScreen(), slot) -- This call is made possible by OverrideUpdateSlot()
					scs:Hide()
					local server_data = GLOBAL.ShardGameIndex:GetServerData(slot)
					-- The Create() function on servercreationscreen requires filling in world settings, so use settings from current world (changes to settings will be reflected in world after executing Create())
					if server_data ~= nil then
						scs.server_settings_tab.game_mode.spinner:SetSelected(server_data.game_mode ~= nil and server_data.game_mode or GLOBAL.DEFAULT_GAME_MODE )
						scs.server_settings_tab.pvp.spinner:SetSelected(server_data.pvp)
						scs.server_settings_tab.max_players.spinner:SetSelected(server_data.max_players)
						scs.server_settings_tab.server_name.textbox:SetString(server_data.name)
						scs.server_settings_tab.server_pw.textbox:SetString(server_data.password)
						scs.server_settings_tab.server_desc.textbox:SetString(server_data.description)
						scs.server_settings_tab.privacy_type.buttons:SetSelected(server_data.privacy_type)
						scs.server_settings_tab.encode_user_path = server_data.encode_user_path == true
						scs.server_settings_tab.use_legacy_session_path = server_data.use_legacy_session_path == true

						if scs.server_settings_tab.privacy_type.buttons:GetSelectedData() == GLOBAL.PRIVACY_TYPE.CLAN then
							local claninfo = server_data.clan
							scs.server_settings_tab.clan_id.textbox:SetString(claninfo and claninfo.id or "")
							scs.server_settings_tab.clan_only.spinner:SetSelected(claninfo and claninfo.only or false)
							scs.server_settings_tab.clan_admins.spinner:SetSelected(claninfo and claninfo.admins or false)
						end

						scs.server_settings_tab:SetServerIntention(server_data.intention)
						scs.server_settings_tab:SetOnlineWidgets(server_data.online_mode)
					end
					
					-- Recreate the world
					print(modDebugPrefix.." Apply: Requires world re-creation.")
					GLOBAL.c_save()
					GLOBAL.TheWorld:DoTaskInTime(7, function()
						for i, player in ipairs(GLOBAL.AllPlayers) do
							player:OnDespawn()
						end
						GLOBAL.TheSystemService:EnableStorage(true)
						GLOBAL.ShardGameIndex:SaveCurrent(function() end, true)
						scs:Create(true,true,true)
					end)
				else
					print(modDebugPrefix.." Apply: Requires local world reset.")
					OldApply(self)
					GLOBAL.c_save()
					GLOBAL.TheWorld:DoTaskInTime(3, function() GLOBAL.c_reset() end) --give time for c_save to work
				end
			elseif GLOBAL.TheNet:GetServerIsClientHosted() and GLOBAL.TheNet:GetIsServerAdmin() and GLOBAL.TheNet:GetIsClient() then --for non-dedicated caves-enabled server hosts (RPC used since console is remote)
				print(modDebugPrefix.." Apply: Requires remote world reset.")
				SendModRPCToServer(MOD_RPC[modname]["saveandresetworld"])
			--elseif GLOBAL.TheShard:IsMaster() then
			elseif isSecondary then --if you're in the caves (currently not working)
				--for clients/dedicated servers, and on any other non-master shard (caves)
				print(modDebugPrefix.." Apply: Requires client restart from secondary shard.")
				--[[local serverListingFile = io.open("serverlisting.txt", "r")
				if serverListingFile then
					local serverListingStr = serverListingFile:read("l")
					serverListingFile:close()

					local r, result = pcall(json.decode, serverListingStr)
					if not r then print("Could not decode all items: "..tostring(serverListingStr)) end
					if result then
						print("SERVER LISTING FROM FILE DECODED: ")
						GLOBAL.dumptable(result)
						GLOBAL.TheSim:SetSetting("misc", "warn_mods_enabled", "false")
						GLOBAL.JoinServer(result)
					end
				end]]
				local r, listing = pcall(json.decode, GLOBAL.ThePlayer.player_classified._masterShardServerListing:value())
				if not r then print(modDebugPrefix.." Could not decode JSON: "..GLOBAL.ThePlayer.player_classified._masterShardServerListing:value()) end
				if listing then
					print(modDebugPrefix.." Server listing from netvar: ")
					GLOBAL.dumptable(listing)
					GLOBAL.TheSim:SetSetting("misc", "warn_mods_enabled", "false")
					GLOBAL.JoinServer(listing)
				end
				-- TODO: Potentially abandon netvar, search servers by name instead
			else --if you're just a client (including hosts for dedicated servers)
				--for clients/dedicated servers, and on master shard (overworld)
				print(modDebugPrefix.." Apply: Requires client restart from master shard.")
				GLOBAL.TheSim:SetSetting("misc", "warn_mods_enabled", "false") --disables the mod warning screen when joining servers
				local listing = GLOBAL.TheNet:GetServerListing()
				GLOBAL.TheNet:Disconnect(true)
				GLOBAL.ThePlayer.isApplyingModChanges = true
				GLOBAL.ThePlayer:DoPeriodicTask(4, function()
					GLOBAL.JoinServer(listing)
				end)
			end
		else
			OldApply(self)
		end
	end
end
AddClassPostConstruct("screens/redux/modsscreen", ApplyToGame)

local function ReAllowIncomingConnections(modsscreen)
	local OldCancel = modsscreen.Cancel
	modsscreen.Cancel = function(self)
		OldCancel(self)
		GLOBAL.TheNet:SetAllowIncomingConnections(true)
	end
end
AddClassPostConstruct("screens/redux/modsscreen", ReAllowIncomingConnections)

function OverrideUpdateSlot(serversettingstab)
	serversettingstab.UpdateSlot = function() end --This allows us to safely ignore the reference to GetCharacterPortraits in serversaveslot.lua's SetSaveSlot function
end
AddClassPostConstruct("widgets/redux/serversettingstab", OverrideUpdateSlot)

function OverrideDisconnectDialog(popupdialog)
	if popupdialog.dialog and popupdialog.dialog.title:GetString() == GLOBAL.STRINGS.UI.NETWORKDISCONNECT.TITLE.ID_ALREADY_CONNECTED and GLOBAL.ThePlayer and GLOBAL.ThePlayer.isApplyingModChanges then
		popupdialog.dialog.title:SetString("Reconnecting to server...")
		popupdialog.dialog.body:SetString("Don't panic. We've got everything under control.")
		popupdialog.dialog.actions:Kill()
	end
end
AddClassPostConstruct("screens/redux/popupdialog", OverrideDisconnectDialog)

---===================
---   Net Variables
---===================
AddPrefabPostInit("player_classified", function(inst)
	inst._isSecondaryShard = GLOBAL.net_bool(inst.GUID, "_isSecondaryShard", "_isSecondaryShardDirty")
	inst._masterShardServerListing = GLOBAL.net_string(inst.GUID, "_masterShardServerListing", "_masterShardServerListingDirty")

	-- Initialize netvars on the master shard (Originally for sending server listing to cave shard)
	if not GLOBAL.TheNet:GetIsClient() then
		-- Give time for master shard to create serverlisting.txt
		inst:DoTaskInTime(3, function(inst)
			local isSecondary = GLOBAL.TheShard:IsSecondary()
			inst._isSecondaryShard:set(isSecondary)

			local serverListingFile = io.open("serverlisting.txt", "r")
			if serverListingFile then
				local serverListingStr = serverListingFile:read("*l")
				serverListingFile:close()

				-- Since server listing of a cave server is not same as listing for master shard,
				-- Broadcast master shard's listing to all clients, so they can reconnect from a secondary shard via "TheNet:JoinServer"
				inst._masterShardServerListing:set(serverListingStr)
			end
		end)
	end
end)

---==================
---   RPC Handlers
---==================
AddModRPCHandler(modname, "saveandresetworld", function(player)
	GLOBAL.c_save()
	GLOBAL.TheWorld:DoTaskInTime(3, function() GLOBAL.c_reset() end) --give time for c_save to work
end)