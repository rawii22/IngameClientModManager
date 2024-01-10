local ServerCreationScreen = GLOBAL.require("screens/redux/servercreationscreen")
local ModsScreen = GLOBAL.require("screens/redux/modsscreen")
local PlayerHud = GLOBAL.require("screens/playerhud") 
local ModsTab = GLOBAL.require("widgets/redux/modstab")
local TEMPLATES = GLOBAL.require("widgets/redux/templates")
local io = GLOBAL.io
local json = GLOBAL.json
local pcall = GLOBAL.pcall
local KEY = GetModConfigData("KEY")
local HOST_SERVER_LISTING
local modDebugPrefix = "[IN-GAME MOD MANAGER]"

--===== KNOWN BUGS =====
-- Random crash after temp disabling all mods, temp enabling server mods, running ModIndex:SetTempModConfigData for each server mod, then showing below logs:
	-- Mods are setup for server, save the mod index and proceed.
	-- Downloading [1] From: server_temp
	-- ...
	-- Download complete[1] Files: 1 Size: 287963
	-- APP:Klei//DoNotStarveTogether/donotstarvetogether_client.dmp written.
-- Keeping modsscreen open for extended period disconnects you from server?


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
	if not r then print(modDebugPrefix.." Could not encode server listing: "..tostring(GLOBAL.TheNet:GetServerListing())) end
	if result then
		local serverListingFile = io.open("serverlisting.txt", "w")
		serverListingFile:write(result)
		serverListingFile:close()
	end
end

-- Retrieve the slot that was loaded (saved by modservercreationmain)
SLOT = 0
GLOBAL.TheSim:GetPersistentString("slotid", function(success, data)
	if success then
		SLOT = GLOBAL.tonumber(data)
	end
end)

-- Retrieve the flag indicating if server has caves (saved by modservercreationmain); SaveGameIndex and ShardSaveGameIndex don't appear to consistently return correct answer via "IsSlotMultiLevel"
IS_MULTI_LEVEL = false
GLOBAL.TheSim:GetPersistentString("ismultilevel", function(success, data)
	if success then
		IS_MULTI_LEVEL = data == "true"
	end
end)

function OpenModsScreen()
	if not GLOBAL.TheNet:GetIsClient() then  --TODO: Use RPC to prohibit incoming connections if multi-level or dedicated server
		GLOBAL.TheNet:SetAllowIncomingConnections(false)
	end
	if not GLOBAL.IsPaused() and IsDefaultScreen() and not GLOBAL.ThePlayer.player_classified._isSecondaryShard:value() then --Doesn't work in caves yet (might have been fixed when we started setting the netvar from host server instead of local)
		local ms = ModsScreen()
		ms.mods_page:Kill() --Kill the modstab so we can customize it later
		for k,v in pairs(ms.mods_page.subscreener.menu.items) do
			v:Kill() --Kills duplicated buttons that appear when the modstab is created again later
		end
		
		-- Server mods are only configurable by admin of a non-dedicated server (to be expanded)
		if not GLOBAL.TheNet:GetIsServerAdmin() then
			settings.are_servermods_readonly = true
		end
		
		ms.mods_page.tooltip:Kill()
		ms.mods_page = ms.optionspanel:InsertWidget(ModsTab(ms, settings))
		ms.mods_page.slotnum = SLOT --This satisfies a condition in ModsTab:Apply() that ensures the Sim does not reset
		ms.bg:Kill() --Kill the default background
		ms.bg = ms.root:AddChild(TEMPLATES.BackgroundTint(0.5, {0,0,0})) --Add custom background
		ms.bg:MoveToBack()
		ms.enabled_server_mods = GLOBAL.ModManager:GetEnabledServerModNames() --This is later used to detect changes to server mods
		
		GLOBAL.TheFrontEnd:PushScreen(ms) --Finally make the screen appear
	end
end

---===============
---  Key Handler
---===============
local modkey = KEY
--The key will activate the modsscreen screen in-game
GLOBAL.TheInput:AddKeyUpHandler(
	modkey:lower():byte(), OpenModsScreen)

function IsDefaultScreen()
	if GLOBAL.TheFrontEnd:GetActiveScreen() and GLOBAL.TheFrontEnd:GetActiveScreen().name and type(GLOBAL.TheFrontEnd:GetActiveScreen().name) == "string" and GLOBAL.TheFrontEnd:GetActiveScreen().name == "HUD" then
		return true
	else
		return false
	end
end

local function serverModsChanged(oldMods, newMods)
	-- If the lists differ in size, then just return true
	local oldModsSize = 0
	local newModsSize = 0
	for _ in pairs(oldMods) do oldModsSize = oldModsSize + 1 end
	for _ in pairs(newMods) do newModsSize = newModsSize + 1 end
	if oldModsSize ~= newModsSize then  --why didn't we use the table size operator: #oldMods ~= #newMods?
		return true
	end
	
	-- In case the lists are the same size, do a more thorough check
	table.sort(oldMods)
	table.sort(newMods)
	for k, v in pairs(oldMods) do
		if oldMods[k] ~= newMods[k] then --check for differences
			return true
		end
	end
	
	return false
end

local function restartServerInSlot(slot, server_data, isMultiLevel, isDedicated)
	print(modDebugPrefix.." restartServerInSlot")
	print(modDebugPrefix.."   > slot: "..tostring(slot))
	print(modDebugPrefix.."   > server_data:")
	GLOBAL.dumptable(server_data)
	print(modDebugPrefix.."   > isMultiLevel: "..tostring(isMultiLevel))
	print(modDebugPrefix.."   > isDedicated: "..tostring(isDedicated))
	
	local scs = ServerCreationScreen(GLOBAL.TheFrontEnd:GetOpenScreenOfType("HUD"), slot)
	scs:Hide()
	-- The Create() function on servercreationscreen requires filling in world settings, so use settings from current world (changes to settings will be reflected in world after executing Create())
	if server_data ~= nil then
		scs.server_settings_tab.game_mode.spinner:SetSelected(server_data.game_mode ~= nil and server_data.game_mode or GLOBAL.DEFAULT_GAME_MODE)
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

		scs.server_settings_tab:SetOnlineWidgets(server_data.online_mode)
	end
	
	-- Maybe use TheNet:StopBroadcastingServer?

	-- Save world, pause, clear updating entities, then restart server via servercreationscreen
	print(modDebugPrefix.." World restart is needed to change server mods.")
	GLOBAL.c_save()  --maybe use TheNet:SendWorldSaveRequestToMaster if player is in caves?
	GLOBAL.TheSystemService:EnableStorage(true)  --not sure if this is needed

	if not isMultiLevel and not isDedicated then
		GLOBAL.ShardGameIndex:SaveCurrent(function() end, true)  --not sure if this is needed
	end
	if isMultiLevel then
		-- Black magic to ensure server mod changes are applied on server restart
		GLOBAL.KnownModIndex:ClearAllTempModFlags()
		scs.world_tabs[2]:AddMultiLevel()
		--GLOBAL.KnownModIndex:ClearTempModFlags("workshop-816057392")
	end

	-- Save changes on servercreationscreen
	scs:MakeDirty()
	scs:SaveChanges()

	GLOBAL.TheWorld:DoTaskInTime(7, function()
		if not isMultiLevel and not isDedicated then  --TODO: Use RPC to pause if multi-level or dedicated server
			print(modDebugPrefix.." Pausing...")
			GLOBAL.SetPause(true, "pause")
			GLOBAL.SetAutopaused(true)
		end
		if isMultiLevel then
			print(modDebugPrefix.." Disconnecting...")
			GLOBAL.TheNet:Disconnect(true)
			GLOBAL.TheSystemService:StopDedicatedServers()
		end
		
		local restartDelay = isMultiLevel and 5 or 2  --wait for game to pause or dedicated servers to stop

		-- Static task is not affected by pausing
		GLOBAL.TheWorld:DoStaticTaskInTime(restartDelay, function()
			print(modDebugPrefix.." Restarting server in slot "..tostring(slot).." (\""..tostring(server_data.name).."\")...")
			-- The literal embodiment of despair...
			-- Manually clear all updating entities, since starting a new world was interfering with entities from the previous world that were still updating ('px' and 'v1' errors)
			GLOBAL.PhysicsCollisionCallbacks = {}
			GLOBAL.Ents = {}
			GLOBAL.UpdatingEnts = {}
			GLOBAL.StaticUpdatingEnts = {}
			GLOBAL.WallUpdatingEnts = {}
			scs:Create(true,true,true)
			print(modDebugPrefix.." Server restarted.")
		end)
	end)
end

-- When the Apply button is clicked
local function ApplyToGame(modsscreen)
	local OldApply = modsscreen.Apply
	modsscreen.Apply = function(self)
		if GLOBAL.TheWorld ~= nil and GLOBAL.ThePlayer ~= nil then
			local isDedicated = GLOBAL.TheNet:IsDedicated()  --not sure why, but TheNet:GetServerIsDedicated returns true on a caves-enabled, non-dedicated server
			local isSecondary = GLOBAL.ThePlayer.player_classified._isSecondaryShard:value()
			-- Rephrase "caves" references to "multi_level"
			if not IS_MULTI_LEVEL and not isDedicated and GLOBAL.TheNet:GetIsServerAdmin() then --for non-caves, non-dedicated server host
				if serverModsChanged(self.enabled_server_mods, GLOBAL.ModManager:GetEnabledServerModNames()) then --figured out how to modify server mods on 8/6/2021
					-- Tell all players that server mods are being changed
					for k, player in pairs(GLOBAL.AllPlayers) do
						player.player_classified._serverModsChanging:set(true)
					end

					-- Restart server
					restartServerInSlot(SLOT, GLOBAL.ShardGameIndex:GetServerData(SLOT), IS_MULTI_LEVEL, isDedicated)
				else
					print(modDebugPrefix.." Apply: Requires local world reset.")
					OldApply(self)
					GLOBAL.c_save()
					GLOBAL.TheWorld:DoTaskInTime(3, function() GLOBAL.c_reset() end) --give time for c_save to work
				end
			elseif IS_MULTI_LEVEL and not isDedicated and GLOBAL.TheNet:GetIsServerAdmin() then --for caves-enabled, non-dedicated server hosts (RPC used since mod is executed locally)
				-- Send request to host server, as that is where server data and AllPlayers list reside
				SendModRPCToServer(GetModRPC(modname, "enableservermods"))
			--elseif GLOBAL.TheShard:IsMaster() then
			elseif isSecondary then --if you're in the caves (currently not working)
				--for clients/dedicated servers, and on any other non-master shard (caves)
				print(modDebugPrefix.." Apply: Requires client restart from secondary shard.")
				--[[local serverListingFile = io.open("serverlisting.txt", "r")
				if serverListingFile then
					local serverListingStr = serverListingFile:read("l")
					serverListingFile:close()

					local r, result = pcall(json.decode, serverListingStr)
					if not r then print(modDebugPrefix.." Could not decode server listing: "..tostring(serverListingStr)) end
					if result then
						print(modDebugPrefix.." SERVER LISTING FROM FILE DECODED:")
						GLOBAL.dumptable(result)
						GLOBAL.TheSim:SetSetting("misc", "warn_mods_enabled", "false")
						GLOBAL.JoinServer(result)
					end
				end]]
				local r, listing = pcall(json.decode, GLOBAL.ThePlayer.player_classified._masterShardServerListing:value())
				if not r then print(modDebugPrefix.." Could not decode JSON: "..GLOBAL.ThePlayer.player_classified._masterShardServerListing:value()) end
				if listing then
					print(modDebugPrefix.." Server listing from netvar:")
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

-- Add the "Manage Mods" button on the pause screen
AddClassPostConstruct("screens/redux/pausescreen", function(self)
    local extra_menu_height
    if GLOBAL.TheNet:GetIsServerAdmin() then
        extra_menu_height = 50 -- should be an even number (I think)
    else
        extra_menu_height = 50
    end

    --throw up the background
    local w, h = self.bg:GetSize()
    h = math.clamp(h + extra_menu_height or 200, 90, 500)
    self.bg:SetSize(w, h)
    --self:UpdateText()

    local managemodsstring = "Manage Mods"
    if managemodsstring then
        self.managemods = self.menu:AddItem(managemodsstring, function() self:Hide() self:unpause() OpenModsScreen() end)
        table.removearrayvalue(self.menu.items, self.managemods)
        table.insert(self.menu.items, 3, self.managemods)
        for i, v in ipairs(self.menu.items) do
            local pos = GLOBAL.Vector3(0,0,0)
            if self.horizontal then
                pos.x = pos.x + self.menu.offset * (i - 1)
            else
                pos.y = pos.y + self.menu.offset * (i - 1)
            end
            v:SetPosition(pos)
            v:SetScale(0.7)
        end
        self.menu:DoFocusHookups()
    end

    local point = self.menu:GetPosition()
    point.y = point.y + extra_menu_height / 2
    self.menu:SetPosition(point)

    --self.inst:ListenForEvent("pausestatedirty", function() self:UpdateText() end, TheWorld.net);
end)

-- Modify the back button in modsscreen
local function ReAllowIncomingConnections(modsscreen)
	local OldCancel = modsscreen.Cancel
	modsscreen.Cancel = function(self)
		OldCancel(self)
		GLOBAL.TheNet:SetAllowIncomingConnections(true)  --TODO: Use RPC to allow incoming connections if multi-level or dedicated server
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
		popupdialog.dialog.actions:EditItem(1, "Disconnect", nil, function() GLOBAL.SimReset() end)
	end
	if popupdialog.dialog and popupdialog.dialog.title:GetString() == GLOBAL.STRINGS.UI.NETWORKDISCONNECT.TITLE.DEFAULT and GLOBAL.ThePlayer and GLOBAL.ThePlayer.player_classified._serverModsChanging:value() then
		popupdialog.dialog.title:SetString("Reconnecting to server...")
		popupdialog.dialog.body:SetString("Don't panic. We've got everything under control.\nAn admin has changed server mods.")
		popupdialog.dialog.actions:EditItem(1, "Disconnect", nil, function() GLOBAL.SimReset() end)
		
		-- Periodically attempt to rejoin server
		GLOBAL.TheSim:SetSetting("misc", "warn_mods_enabled", "false")
		GLOBAL.ThePlayer:DoStaticPeriodicTask(10, function()
			AttemptToRejoinServer()
		end, 0)  --3rd param: initial delay
	end
end
AddClassPostConstruct("screens/redux/popupdialog", OverrideDisconnectDialog)

function OverrideLaunchingServerPopup(launchingserverpopup)
	if GLOBAL.ThePlayer and GLOBAL.ThePlayer.player_classified._serverModsChanging:value() then
		launchingserverpopup.OnCancel = function()
			GLOBAL.SimReset()
		end
	end
end
AddClassPostConstruct("screens/redux/launchingserverpopup", OverrideLaunchingServerPopup)

function OverrideConnectingToGamePopup(connectingtogamepopup)
	if GLOBAL.ThePlayer and GLOBAL.ThePlayer.player_classified._serverModsChanging:value() then
		connectingtogamepopup.OnCancel = function()
			GLOBAL.SimReset()
		end
	end
end
AddClassPostConstruct("screens/redux/connectingtogamepopup", OverrideConnectingToGamePopup)

-- Attempt to rejoin server by using the ip address or name of the current server. Wait until the server is back online.
function AttemptToRejoinServer()
	local servers
	GLOBAL.TheNet:SearchServers()
	-- Wait for search of online servers to finish, hopefully 2 seconds is enough...
	GLOBAL.ThePlayer:DoStaticTaskInTime(2, function()
		servers = GLOBAL.TheNet:GetServerListings()
		GLOBAL.TheNet:SearchLANServers(HOST_SERVER_LISTING.offline)
		-- Wait for search of LAN servers to finish
		GLOBAL.ThePlayer:DoStaticTaskInTime(2, function()
			local lanServers = GLOBAL.TheNet:GetServerListings()
			for i, server in ipairs(lanServers) do
				table.insert(servers, server)
			end
			
			-- Get search criteria
			--local gameData = HOST_SERVER_LISTING.game_data  --For some reason, game_data is not always populated when you run TheNet:GetServerListing()
			--print(modDebugPrefix.." Game data: "..gameData)
			--local dayNumber = GLOBAL.tonumber(gameData:match("day=(%d+),")) or 1
			--local nextDay = "day="..(dayNumber+1)..","
			
			-- Join server if it's found
			for i, server in ipairs(servers) do
				if (server.ip and server.ip == HOST_SERVER_LISTING.ip) or server.name == HOST_SERVER_LISTING.name then --This (searching by server name) is wretched, but we have no other data to reliably search for from TheNet:GetServerListing()
					print(modDebugPrefix.." Attempting to rejoin server \""..server.name.."\" ("..server.guid..")")
					GLOBAL.JoinServer(server)
				end
			end
		end)
	end)
end

---===================
---   Net Variables
---===================
AddPrefabPostInit("player_classified", function(inst)
	inst._isSecondaryShard = GLOBAL.net_bool(inst.GUID, "_isSecondaryShard", "_isSecondaryShardDirty")
	inst._masterShardServerListing = GLOBAL.net_string(inst.GUID, "_masterShardServerListing", "_masterShardServerListingDirty")
	inst._serverModsChanging = GLOBAL.net_bool(inst.GUID, "_serverModsChanging", "_serverModsChangingDirty")

	-- Initialize netvars on the master shard (Originally for sending server listing to cave shard)
	if not GLOBAL.TheNet:GetIsClient() then
		-- Give time for master shard to create serverlisting.txt
		inst:DoTaskInTime(3, function(inst)
			local isSecondary = GLOBAL.TheShard:IsSecondary()
			inst._isSecondaryShard:set(isSecondary)
			inst._serverModsChanging:set(false)

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

-- First paramater for "AddModRPCHandler" is always the requesting player?
AddModRPCHandler(modname, "enableservermods", function(player)
	-- Tell all players that server mods are being changed
	for k, player in pairs(GLOBAL.AllPlayers) do
		player.player_classified._serverModsChanging:set(true)
	end

	local serverData = GLOBAL.ShardGameIndex:GetServerData()
	local status, serverDataJson = pcall(json.encode, serverData)
	if not status then print(modDebugPrefix.." Could not encode server data: "..tostring(serverData)) end
	if serverDataJson then
		-- First parameter after client mod identifier is not passed to RPC as a parameter?
		SendModRPCToClient(GetClientModRPC(modname, "enableservermodsonclient"), nil, serverDataJson, player)
	end
end)
 
AddClientModRPCHandler(modname, "enableservermodsonclient", function(serverDataJson, player)
	-- Only run on client (for some reason, RPC also gets sent to host server)
	if GLOBAL.TheNet:GetIsClient() and GLOBAL.ThePlayer.GUID == player.GUID then
		print(modDebugPrefix.." Received server data. Now parsing...")
		print(modDebugPrefix.."   > Server data (JSON): "..tostring(serverDataJson))
		
		-- Parse server data sent from server
		local status, serverData = pcall(json.decode, serverDataJson)
		if not status then print(modDebugPrefix.." Could not decode server data: "..tostring(serverDataJson)) return end
		if serverData then
			print(modDebugPrefix.." Server data parsed.")
		end

		-- Restart server
		restartServerInSlot(SLOT, serverData, IS_MULTI_LEVEL, GLOBAL.TheNet:IsDedicated())
	end  -- TheNet:GetIsClient()
end)