-- Save the id of the slot that's loaded
awaitScs = GLOBAL.TheFrontEnd.gameinterface:DoPeriodicTask(0.25, function()
	local scs = GLOBAL.TheFrontEnd:GetOpenScreenOfType("ServerCreationScreen")
	if scs then
		awaitScs:Cancel()
		GLOBAL.TheSim:SetPersistentString("slotid", scs.save_slot, false, nil) --3rd param: should encode, 4th param: callback
		GLOBAL.TheSim:SetPersistentString("ismultilevel", scs.world_tabs[2] and scs.world_tabs[2]:CollectOptions() and "true" or "false", false, nil)
	end
end)