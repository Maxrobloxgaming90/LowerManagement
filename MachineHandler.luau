--Connected czsashi / Maxrobloxgaming90
-- (Description of the Script and function) Machine room, machinehandler script that scans items, and highlights the surrounding items. 
--If scanned a special pickup, then it will error and if u scanned 5 pickups it will have a 10 seconds timer 
--until it fully shutdowns on where uppermanagement gives you 1000 performance points for being a proactive tester of the CBT3000


-- SERVICES
local ReplicatedStorage = game:GetService("ReplicatedStorage") 
local RunService = game:GetService("RunService") 
local CollectionService = game:GetService("CollectionService") 
local Debris = game:GetService("Debris") 
local TweenService = game:GetService("TweenService") 

-- MODULES
local ItemUtils = require(ReplicatedStorage.Utils.ItemUtils)
local SoundUtils = require(ReplicatedStorage.Utils.SoundUtils)
local StringUtils = require(ReplicatedStorage.Utils.StringUtils)
local ObjUtils = require(ReplicatedStorage.Utils.ObjUtils)
local LightModule = require(ReplicatedStorage.LightModule)
local ScreenMessage = require(ReplicatedStorage.ScreenMessage)
local RoundUtils = require(ReplicatedStorage.Utils.Round.RoundUtils)
local PhysicsUtils = require(ReplicatedStorage.Utils.TestPhysicsUtil)

-- REMOTES
local activateEvent = ReplicatedStorage.Remotes.ActivateMachine
local toggleEvent = ReplicatedStorage.Remotes.ToggleConveyor
local scanEvent = ReplicatedStorage.Remotes.ScanItem
local requestEvent = ReplicatedStorage.Remotes.RequestScannerAccess

-- BINDABLES
local toggleRidge = ReplicatedStorage.BindableEvent.ToggleRidge
local machineVisuals = ReplicatedStorage.BindableEvent.MachineVisuals

-- GAME SYSTEM REFERENCES
local roundInfo = ReplicatedStorage.RoundInfo
local missionItems = roundInfo.Mission.MissionItems

-- PHYSICAL MACHINE REFERENCES
local CBT = script.Parent
local CBT3001 = CBT["CBT 3001 Promotion Pack"]["CBT 3001"]
local scanner = CBT.Scanner
local destroyPart = CBT.DestroyPart
local destroyZone = CBT.DestroyZone
local conveyor = CBT.Conveyor
local conveyorZone = CBT.ConveyorZone
local slope = CBT.ConveyorSlope
local playerGate = {
	CBT.Gate.PlayerGate,
	CBT.Gate.PlayerGate2
}

-- SOUNDS
local ConveyorSound = CBT3001.ConveyorSound.ConveyorRunSound
local ConveyorEnd = CBT3001.ConveyorSound.End

-- PHYSICAL DISPOSAL CHUTE CFRAMES
local disposalChute = CBT.DisposalChute
local coverPart = disposalChute.Cover
local closedCF = coverPart.CFrame
local openCF = closedCF * CFrame.new(0, -5.884, 0)
local gateTweenInfo = TweenInfo.new(3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local neonParts = CBT3001.NeonParts
local orbs = CBT3001.Orbs
local terminal = script.Parent.Parent.Terminal

local CONVEYOR_SPEED = 3
local HIGHLIGHT_DURATION = 15
local OVERLOAD_THRESHOLD = 8
local OVERLOAD_WINDOW = 10
local SPECIAL_PICKUP_THRESHOLD = 5
local SLOPE_BOOST_DISTANCE = 3
local CHUTE_OPEN_BUFFER = 0.2
local CHUTE_CLOSE_DELAY = 3

local SCORE_BONUS = 1000
local SCORE_PENALTY = 500

local machineState = {
	active = false,
	broken = false,
	overloaded = false,
	conveyorOn = false,
	gateOpen = false,
	missionFailure = false,
	specialPickupCount = 0,
	lastItemTime = 0
}

local scannedItems = {}
local scanTimestamps = {}
local touchingPickups = {}
local killedCharacters = {}
local overloadRunning = false
local machineConn = nil

requestEvent.OnServerInvoke = function(player)
	return machineState.active
end

-- Helper to quickly retrieve all base parts representing light orbs
local function getAllOrbs()
	local list = {}
	for _, obj in ipairs(orbs:GetDescendants()) do
		if obj:IsA("BasePart") then
			table.insert(list, obj)
		end
	end
	return list
end

local allOrbs = getAllOrbs()

local function isMissionItem(pickup)
	return pickup:IsDescendantOf(missionItems)
end

local function getPickupImage(pickup)
	local tool = ItemUtils.getToolFromPickup(pickup); if not tool then return end
	local val_ImageId = tool:FindFirstChild('Values') and tool.Values:FindFirstChild('ImageId')
	if not val_ImageId or not val_ImageId.Value then return end

	return StringUtils.GetUsableAssetId(val_ImageId.Value)
end

local function startSoundFX() --plays the conveyor sound to indicate that the conveyor is active and running
	ConveyorSound:Stop()
	ConveyorSound.TimePosition = 0
	ConveyorSound.Volume = 0.2
	ConveyorSound:Play()
end

local function stopSoundFX() --stops the conveyor sound to show that the conveyor is no longer active
	SoundUtils.Fade(ConveyorSound, 'Out', 0.5, false, true)
	ConveyorEnd:Play()
end

local function toggleChute(open: boolean, duration)
	if not coverPart then return end
	if machineState.gateOpen == open then return end

	machineState.gateOpen = open
	local tweenInfo = TweenInfo.new(duration or 3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	TweenService:Create(coverPart, tweenInfo, {
		CFrame = open and openCF or closedCF
	}):Play()
end

--[[ 
    Changes the visuals of the machine to indicate its current state.
    @param enabled: true if the machine is active, false if broken.
]]
local function updateMachineVisuals(enabled)
	local color = enabled and Color3.fromRGB(215, 197, 154) or Color3.fromRGB(0,0,0)
	local material = enabled and Enum.Material.Neon or Enum.Material.SmoothPlastic

	for _, orb in ipairs(allOrbs) do
		orb.Color = color
		orb.Material = material
		local light = orb:FindFirstChildOfClass("SurfaceLight")
		if light then light.Enabled = enabled end
	end
end

--[[
    Handles visual changes specifically when the conveyor shifts states 
    (running vs stationary vs idle).
]]
local function updateConveyorStateVisuals()
	if machineState.active and machineState.conveyorOn then
		toggleRidge:Fire(true)
		conveyor.AssemblyLinearVelocity = conveyor.CFrame.LookVector * CONVEYOR_SPEED
		startSoundFX()
	elseif machineState.active then
		toggleRidge:Fire(false)
		stopSoundFX()
	else
		toggleRidge:Fire(false)
		stopSoundFX()

		for _, part in ipairs(neonParts:GetChildren()) do
			if part:IsA("BasePart") then
				part.Color = Color3.fromRGB(0,0,0)
				local light = part:FindFirstChildOfClass("SurfaceLight")
				if light then light.Enabled = false end
			end
		end

		for _, orb in ipairs(allOrbs) do
			orb.Color = Color3.fromRGB(0,0,0)
		end
	end
end

local function startOverloadCycle()
	overloadRunning = true

	task.spawn(function()
		while overloadRunning and not machineState.broken do
			for _, orb in ipairs(allOrbs) do
				orb.Color = Color3.fromRGB(255, 0, 0)
			end

			for _, part in ipairs(neonParts:GetChildren()) do
				if part:IsA("BasePart") then
					local newColor = Color3.fromHSV(math.random(), 1, 1)
					part.Color = newColor
					local light = part:FindFirstChildOfClass("SurfaceLight")
					if light then light.Color = newColor end
				end
			end

			task.wait(0.12)

			for _, orb in ipairs(allOrbs) do
				local props = ObjUtils.GetStoredProperties(orb, nil)
				if props and props.Color then
					orb.Color = props.Color
				end
			end

			task.wait(0.12)
		end
	end)
end

local function stopOverloadCycle()
	overloadRunning = false
end

local orb_Color_map = {
	FrontOrb = Color3.fromRGB(215, 197, 154),
	CenterOrb = Color3.fromRGB(248, 248, 248)
}


local function init()
	-- Initialize lights to 'off' to save on performance and signal the machine is dormant/off state.
	LightModule.ToggleAllLightsUnderParent(neonParts, false)

	-- Secure the gate area so players cannot walk inside the machinery.
	for _, part in ipairs(playerGate) do
		if part then
			PhysicsUtils.SetObjCollisionGroup(part, "Gate", true)
		end
	end

	updateMachineVisuals(false)
end

init()

--[[
    Calculates and applies precise linear physics to items on the conveyor.
    By separating this logic, we keep the game frame rate highly stable.
]]
local function handleItemPhysics(pickup)
	-- Guard Clause: Do not steal physics control of an item players are carrying.
	if pickup:GetAttribute("Held") then return end

	local root = pickup:IsA("Model") and (pickup.PrimaryPart or pickup:FindFirstChildWhichIsA("BasePart")) or pickup
	if not root then return end

	-- Network Ownership to server prevents laggy, teleporting items on the belt.
	if root:IsA("BasePart") and root:GetNetworkOwner() ~= nil then
		root:SetNetworkOwner(nil)
	end

	-- Apply standard linear velocity forward.
	root.AssemblyLinearVelocity = conveyor.CFrame.LookVector * CONVEYOR_SPEED

	-- Give items approaching the exit slope a dynamic push so they clear the gap.
	local dist = (root.Position - slope.Position).Magnitude
	if dist <= SLOPE_BOOST_DISTANCE then
		root.AssemblyLinearVelocity += slope.CFrame.LookVector * 1.5
	end
end

-- Controls dynamic door opening/closing to prevent jarring mechanical "flickering"
local function updateChuteState(hasItems)
	if hasItems then
		machineState.lastItemTime = tick()
	end

	if (tick() - machineState.lastItemTime) <= CHUTE_OPEN_BUFFER then
		if not machineState.gateOpen then
			toggleChute(true)
		end
	elseif machineState.gateOpen and (tick() - machineState.lastItemTime >= CHUTE_CLOSE_DELAY) then
		toggleChute(false)
	end
end

--[[
    Highlights items of the same type in the workspace to assist the players.
    Creates a highly readable and clean game environment feedback loops.
]]
local function highlightSimilar(targetPickup)
	local count = 0

	for _, obj in ipairs(CollectionService:GetTagged("Pickup")) do
		if not obj:IsDescendantOf(workspace) or obj.Name ~= targetPickup.Name or obj == targetPickup then continue end
		count += 1
		local highlight = Instance.new("Highlight")
		highlight.FillColor = Color3.fromRGB(255, 0, 0)
		highlight.FillTransparency = 1
		highlight.OutlineTransparency = 1
		highlight.Parent = obj

		local fadeIn = TweenService:Create(highlight, TweenInfo.new(0.1), {FillTransparency = 0})
		fadeIn:Play()
		fadeIn.Completed:Once(function()
			local fadeOut = TweenService:Create(highlight, TweenInfo.new(HIGHLIGHT_DURATION - 2), {FillTransparency = 1})
			fadeOut:Play()
		end)

		Debris:AddItem(highlight, HIGHLIGHT_DURATION)
	end

	return count
end

--[[
    Scanner engine processing items. Guard clauses stop calculations immediately
    if the machine is overloaded, preventing critical scanning exploits.
]]
local function processScan(pickup)
	-- Guard Clause: Do not process if system is offline or scanning is already handled.
	if machineState.overloaded or machineState.broken then return end
	if pickup:GetAttribute("Scanned") or pickup:GetAttribute("Held") then return end
	
	pickup:SetAttribute("Scanned", true)
	scannedItems[pickup] = true
	ItemUtils.TogglePickupInteractability(pickup, false)
	pickup:SetAttribute("Locked", true)

	-- Check if they are trying to process an essential story/mission item (instant penalty/overload)
	if CollectionService:HasTag(pickup, "MissionPickup") then
		machineState.missionFailure = true
		triggerOverload()
		return
	end

	-- Sliding window time check to catch spamming players and penalize them.
	table.insert(scanTimestamps, tick())
	for i = #scanTimestamps, 1, -1 do
		if tick() - scanTimestamps[i] > OVERLOAD_WINDOW then 
			table.remove(scanTimestamps, i) 
		end
	end

	if #scanTimestamps >= OVERLOAD_THRESHOLD then
		triggerOverload()
		return
	end

	-- Visual display updates
	local count = highlightSimilar(pickup)
	scanEvent:FireAllClients(pickup.Name, count, getPickupImage(pickup))
end

function activateMachine()
	-- Clean up old connections if they somehow still exist to avoid memory leaks.
	if machineConn then machineConn:Disconnect() end

	machineConn = RunService.Heartbeat:Connect(function()
		-- Performance Guard: Absolutely zero background processing occurs when machine is off.
		if machineState.broken or not machineState.active or not machineState.conveyorOn then return end

		local pickups = ItemUtils.getPickupsInBoundingBox(conveyorZone.CFrame, conveyorZone.Size)
		updateChuteState(#pickups > 0)

		-- Apply linear movement to belt items
		for _, pickup in ipairs(pickups) do
			handleItemPhysics(pickup)
		end

		-- Check for incoming items inside the scanning field of view
		for _, part in ipairs(workspace:GetPartBoundsInBox(scanner.CFrame, scanner.Size)) do
			local scanPickup = ItemUtils.getPickupFromPart(part)
			if scanPickup then processScan(scanPickup) end
		end
	end)
end

--[[
	This handles the physical state of the machine. We keep this separate 
	so it can be called during a normal power-down OR a total breakdown.
]]
local function resetMachineAppearance()
	-- Kill the physics and movement immediately to prevent item glitches
	conveyor.AssemblyLinearVelocity = Vector3.zero
	toggleRidge:Fire(false)
	stopOverloadCycle()

	-- Power down the neon elements. We set them to black and disable lights
	-- to give the player clear visual feedback that the machine is "dead."
	for _, part in ipairs(neonParts:GetChildren()) do
		if part:IsA("BasePart") then
			part.Color = Color3.fromRGB(0,0,0)
			local light = part:FindFirstChildOfClass("SurfaceLight")
			if light then light.Enabled = false end
		end
	end

	-- Orbs return to a non-emissive state to save on performance
	for _, orb in ipairs(allOrbs) do
		orb.Color = Color3.fromRGB(0, 0, 0)
		orb.Material = Enum.Material.SmoothPlastic
	end
end

--[[
	SCORE & NOTIFICATION LOGIC
	Handles the consequences of the machine's state. 
	Splitting this allows us to easily adjust rewards/penalties in the future.
]]
local function handlePostShutdownConsequences(isFailure)
	if isFailure then
		-- Management is unhappy about mission items being used to scan and eventually be disposed or destroyed.
		-- We apply a penalty to discourage players from using the machine as a trash can for objectives.
		ReplicatedStorage.RoundInfo.Score.Value -= SCORE_PENALTY

		RoundUtils.AddExtraToReview({
			Name = "CBTPenalty",
			DisplayName = "CBT 3001 Violation",
			Score = -SCORE_PENALTY,
		})

		ScreenMessage.ShowMessage(
			`Hmmm? We've detected a mission item within the CBT3001, you're supposed to sell that to us.\nPenalty applied. \npYour team will be deducted with the amount of <font color="rgb(179, 0, 3)">{SCORE_PENALTY}</font> performance score for violating our terms of service.`, 
			5, false, nil,
			{ Section = "UpperManagement"
			})
	else
		-- The team/player successfully "tested" the machine's limits without breaking rules.
		-- We reward this behavior with a performance bonus.
		ReplicatedStorage.RoundInfo.Score.Value += SCORE_BONUS

		RoundUtils.AddExtraToReview({
			Name = 'CBTTester',
			DisplayName = 'CBT 3001 Tester',
			Score = SCORE_BONUS,
		})

		task.wait(3)
		ScreenMessage.ShowMessage(
			`We finally know the limits of the machine.\nAwarding your team <font color="rgb(108, 255, 98)">{SCORE_BONUS}</font> performance score for being a proactive tester.\nNow to call up Arron...`, 
			5, false, nil, {
			Section = "UpperManagement"
		})
	end
end

--This is the brain that orchestrates the stop.
function shutdownMachine()
	-- If it's already broken, we don't need to run this logic again.
	if machineState.broken then return end
	machineState.broken = true

	-- Change the global state so other functions (like updateConveyor) stop running
	machineState.active = false
	machineState.conveyorOn = false

	-- Close the chute and reset visuals
	toggleChute(false, 0.3)
	resetMachineAppearance()
	stopSoundFX()

	-- Update the terminal so players can no longer interact with it
	terminal:SetAttribute("Broken", true)
	terminal.Screen.FocusPrompt.Enabled = false

	-- Clean up events and notify the UI
	if machineConn then machineConn:Disconnect() end
	scanner.CanQuery = false

	ReplicatedStorage.BindableEvent.DisableTerminal:Fire()
	ReplicatedStorage.Remotes.ShutdownUI:FireAllClients("broken")

	-- Finally, determine if the player gets a prize or a penalty
	handlePostShutdownConsequences(machineState.missionFailure)
end

-- triggers the overload AKA 10 second timer before shutdown
function triggerOverload()
	if machineState.overloaded or machineState.broken then return end

	machineState.overloaded = true
	print("Overloading")

	local duration = 10
	local endTime = tick() + duration

	ReplicatedStorage.Remotes.ShutdownUI:FireAllClients("overload", endTime)
	startOverloadCycle()

	task.spawn(function()
		while overloadRunning and not machineState.broken do
			for _, orb in ipairs(allOrbs) do
				orb.Color = Color3.fromRGB(255, 0, 0)

				local light = orb:FindFirstChildOfClass("SurfaceLight")
				if light then
					light.Color = Color3.fromRGB(255, 0, 0)
				end
			end

			task.wait(0.25)

			for _, orb in ipairs(allOrbs) do
				local props = ObjUtils.GetStoredProperties(orb, nil)
				if props and props.Color then
					orb.Color = props.Color
				end
			end

			task.wait(0.25)
		end
	end)

	task.delay(duration, function()
		shutdownMachine()
	end)
end

-- obj collision so that the player doesnt enter the machine
local function setupCharacter(char)
	PhysicsUtils.SetObjCollisionGroup(char, "Players", true)
end

game.Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(setupCharacter)
end)

for _, player in ipairs(game.Players:GetPlayers()) do
	if player.Character then
		setupCharacter(player.Character)
	end
end

-- Handles instantaneous player and hazard destruction inside internal machinery zones
destroyZone.Touched:Connect(function(part)
	local pickup = ItemUtils.getPickupFromPart(part)

	if pickup and not pickup:GetAttribute("Held") then
		if not touchingPickups[pickup] then
			touchingPickups[pickup] = true
			task.delay(1, function()
				if touchingPickups[pickup] and pickup.Parent then
					local thud = CBT.DestroyPart.ThudSound:Clone()
					thud.Parent = CBT.DestroyPart
					thud:Play()
					Debris:AddItem(thud, 3)

					local humanoid = pickup:FindFirstChildOfClass("Humanoid")
					if humanoid then humanoid.Health = 0 end

					pickup:Destroy()
					touchingPickups[pickup] = nil
				end
			end)
		end
	end

	local character = part:FindFirstAncestorOfClass("Model")
	if character and character:FindFirstChild("HumanoidRootPart") then
		if killedCharacters[character] then return end
		killedCharacters[character] = true

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then humanoid.Health = 0 end

		task.delay(2, function()
			killedCharacters[character] = nil
		end)
	end
end)

--[[ 
    Event Connections: 
    These act as the "ignition" for the machine when players interact with the terminal.
]]
activateEvent.OnServerEvent:Connect(function()
	-- Prevent starting if the machine is already running or destroyed
	if machineState.broken or machineState.active then return end

	machineState.active = true
	machineState.conveyorOn = true
	updateConveyorStateVisuals()
	activateMachine()
end)

toggleEvent.OnServerEvent:Connect(function()
	if machineState.broken or not machineState.active then return end

	machineState.conveyorOn = not machineState.conveyorOn
	updateConveyorStateVisuals()
end)
