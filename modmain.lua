local ModsScreen = GLOBAL.require("screens/redux/modsscreen") 
local ModsTab = GLOBAL.require("widgets/redux/modstab")
local TEMPLATES = GLOBAL.require("widgets/redux/templates")
local io = GLOBAL.io
local json = GLOBAL.json
local pcall = GLOBAL.pcall
local KEY = GetModConfigData("KEY")

--later used when recreating the custom modstab widget
local settings = {
	is_configuring_server = false,
	details_width = 505,
	are_servermods_readonly = true,
}

-- Save master shard server listing to a file accessible by secondary shards (currently not in use)
if GLOBAL.TheNet:GetIsHosting() and GLOBAL.TheShard and GLOBAL.TheShard:IsMaster() then
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
		if not GLOBAL.IsPaused() and IsDefaultScreen() and not GLOBAL.ThePlayer.player_classified._isSecondaryShard:value() then
			local ms = ModsScreen()
			ms.mods_page:Kill() --Kill the modstab so we can customize it later
			for k,v in pairs(ms.mods_page.subscreener.menu.items) do
				v:Kill() --Kills duplicated buttons that appear when the modstab is created again later
			end
			
			ms.mods_page.tooltip:Kill()
			ms.mods_page = ms.optionspanel:InsertWidget(ModsTab(ms, settings))
			ms.mods_page.slotnum = GLOBAL.SaveGameIndex.current_slot --This satisfies a condition in ModsTab:Apply() that ensures the Sim does not reset
			ms.bg:Kill() --Kill the default background
			ms.bg = ms.root:AddChild(TEMPLATES.BackgroundTint(0.5, {0,0,0})) --Add custom background
			ms.bg:MoveToBack()
			
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

--What happens when the Apply button is clicked
local function ApplyToGame(modsscreen)
	local OldApply = modsscreen.Apply
	modsscreen.Apply = function(self)
		if GLOBAL.TheWorld ~= nil and GLOBAL.ThePlayer ~= nil then
			local isSecondary = GLOBAL.ThePlayer.player_classified._isSecondaryShard:value()
			if GLOBAL.TheNet:GetServerIsClientHosted() and GLOBAL.TheNet:GetIsServerAdmin() and not GLOBAL.TheNet:GetIsClient() then --for non-dedicated non-caves server host.
				print("APPLY: Requires local world reset.")
				OldApply(self)
				GLOBAL.c_save()
				GLOBAL.TheWorld:DoTaskInTime(3, function() GLOBAL.c_reset() end) --give time for c_save to work
			elseif GLOBAL.TheNet:GetServerIsClientHosted() and GLOBAL.TheNet:GetIsServerAdmin() and GLOBAL.TheNet:GetIsClient() then --for non dedicated caves-enabled server hosts. (RPC used since console is remote)
				print("APPLY: Requires remote world reset.")
				SendModRPCToServer(MOD_RPC[modname]["saveandresetworld"])
			--elseif GLOBAL.TheShard:IsMaster() then
			elseif isSecondary then --if you're in the caves (currently not working)
				--for clients/dedicated servers, and on any other non-master shard (caves)
				print("APPLY: Requires client restart from secondary shard.")
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
				local r, result = pcall(json.decode, GLOBAL.ThePlayer.player_classified._masterShardServerListing:value())
				if not r then print("Could not decode JSON: "..GLOBAL.ThePlayer.player_classified._masterShardServerListing:value()) end
				if result then
					print("SERVER LISTING FROM NETVAR DECODED: ")
					GLOBAL.dumptable(result)
					GLOBAL.TheSim:SetSetting("misc", "warn_mods_enabled", "false")
					GLOBAL.JoinServer(result)
				end
			else --if you're just a client (including hosts for dedicated servers)
				--for clients/dedicated servers, and on master shard (overworld)
				print("APPLY: Requires client restart from master shard.")
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

function OverrideDuplicateConnectionDialog(popupdialog)
	if popupdialog.dialog and popupdialog.dialog.title:GetString() == GLOBAL.STRINGS.UI.NETWORKDISCONNECT.TITLE.ID_ALREADY_CONNECTED and GLOBAL.ThePlayer and GLOBAL.ThePlayer.isApplyingModChanges then
		popupdialog.dialog.title:SetString("Reconnecting to server...")
		popupdialog.dialog.body:SetString("Don't panic. We've got everything under control.")
		popupdialog.dialog.actions:Kill()
	end
end
AddClassPostConstruct("screens/redux/popupdialog", OverrideDuplicateConnectionDialog)

---===================
---   Net Variables
---===================
AddPrefabPostInit("player_classified", function(inst)
	print("player_classified: "..tostring(inst))
	inst._isSecondaryShard = GLOBAL.net_bool(inst.GUID, "_isSecondaryShard", "_isSecondaryShardDirty")
	inst._masterShardServerListing = GLOBAL.net_string(inst.GUID, "_masterShardServerListing", "_masterShardServerListingDirty")

	-- Initialize netvars on a secondary, hosting shard (caves server)
	if GLOBAL.TheNet:GetIsHosting() and GLOBAL.TheShard:IsSecondary() then
		-- Give time for master shard to create serverlisting.txt
		inst:DoTaskInTime(3, function(inst)
			print("INITIALIZING NETVAR's")
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