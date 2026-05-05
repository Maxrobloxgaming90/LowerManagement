-- (Description of the Script and function) Machine room, machinehandler script that scans items, and highlights the surrounding items. 
--If scanned a special pickup, then it will error and if u scanned 5 pickups it will have a 10 seconds timer 
--until it fully shutdowns on where uppermanagement gives you 1000 performance points for being a proactive tester of the CBT3000


--Services
local ReplicatedStorage = game:GetService("ReplicatedStorage") 
local RunService = game:GetService("RunService") 
local CollectionService = game:GetService("CollectionService") 
local Debris = game:GetService("Debris") 
local TweenService = game:GetService("TweenService") 

--Modules
local ItemUtils = require(ReplicatedStorage.Utils.ItemUtils)
local SoundUtils = require(ReplicatedStorage.Utils.SoundUtils)
local StringUtils = require(ReplicatedStorage.Utils.StringUtils)
local ObjUtils = require(ReplicatedStorage.Utils.ObjUtils)
local LightModule = require(ReplicatedStorage.LightModule)
local ScreenMessage = require(ReplicatedStorage.ScreenMessage)
local RoundUtils = require(ReplicatedStorage.Utils.Round.RoundUtils)
local PhysicsUtils = require(ReplicatedStorage.Utils.TestPhysicsUtil)

--Remotes
local activateEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ActivateMachine")
local toggleEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ToggleConveyor")
local scanEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ScanItem")
local requestEvent = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RequestScannerAccess")

--Bindable
local toggleRidge = ReplicatedStorage:WaitForChild("BindableEvent"):WaitForChild("ToggleRidge")
local machineVisuals = ReplicatedStorage:WaitForChild("BindableEvent"):WaitForChild("MachineVisuals")

--MachineRefs
local CBT = script.Parent
local CBT3001 = CBT["CBT 3001 Promotion Pack"]["CBT 3001"]
local scanner = CBT.Scanner
local destroyPart = CBT.DestroyPart
local destroyZone = CBT.DestroyZone
local conveyor = CBT.Conveyor
local conveyorZone = CBT.ConveyorZone
local playerGate = {
	CBT.Gate.PlayerGate,
	CBT.Gate.PlayerGate2
}

--Sounds
local ConveyorSound = CBT3001:WaitForChild("ConveyorSound"):WaitForChild("ConveyorRunSound")
local ConveyorEnd = CBT3001:WaitForChild("ConveyorSound"):WaitForChild("End")
--local ConveyorLoop = CBT:WaitForChild("CBT 3001 Promotion Pack"):WaitForChild("CBT 3001"):WaitForChild("ConveyorSound"):WaitForChild("Loop")

local disposalChute = CBT:WaitForChild("DisposalChute")
local coverPart = disposalChute:WaitForChild("Cover")

local closedCF = coverPart.CFrame
local openCF = closedCF * CFrame.new(0, -5.884, 0)
local gateTweenInfo = TweenInfo.new(3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local neonParts = CBT3001.NeonParts
local orbs = CBT3001.Orbs
local terminal = script.Parent.Parent.Terminal



local speed = 3
local highlightDuration = 15
local overload_threshold = 8
local overload_window = 10
local specialCount = 0
local special_threshold = 5
local lastItemTime = 0

local scoreBonus = 1000

--States
local overloaded = false
local broken = false
local active = false
local conveyorOn = false
local gateOpen = false
local gateClosing = nil

local isStarting = false
local isStopping = false

local scanned = {}
local inConveyor = {}
local scanTimestamps = {}
local destroyQueue = {}

requestEvent.OnServerInvoke = function(player)
	return active
end

local function getAllOrbs()
	local list = {}

	for _, obj in ipairs(orbs:GetDescendants()) do
		if obj:IsA("BasePart") then
			table.insert(list, obj)
		end
	end

	return list
end

local function init()
	LightModule.ToggleAllLightsUnderParent(neonParts, false)
	
	for _, part in ipairs(playerGate) do
		if part then
			PhysicsUtils.SetObjCollisionGroup(part, "Gate", true)
		end
	end
	
	for _, orb in ipairs(getAllOrbs()) do
		ObjUtils.StoreProperties(orb, nil, {"Material", "Color"})
		orb.Material = Enum.Material.SmoothPlastic
		orb.Color = Color3.fromRGB(0,0,0) -- start black
	end

	for _, part in ipairs(neonParts:GetChildren()) do
		if part:IsA("BasePart") then
			ObjUtils.StoreProperties(part, nil, {"Color"})
			part.Color = Color3.fromRGB(0,0,0)
		end
	end
end
init()

local overloadRunning = false

local function startOverloadCycle()
	overloadRunning = true

	task.spawn(function()
		local allOrbs = getAllOrbs()

		while overloadRunning and not broken do
			for _, orb in ipairs(allOrbs) do
				orb.Color = Color3.fromRGB(255, 0, 0)
			end

			for _, part in ipairs(neonParts:GetChildren()) do
				if part:IsA("BasePart") then
					local newColor = Color3.fromHSV(math.random(), 1, 1)

					part.Color = newColor

					local light = part:FindFirstChildOfClass("SurfaceLight")
					if light then
						light.Color = newColor
					end
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

local function getPickupImage(pickup)
	local tool = ItemUtils.getToolFromPickup(pickup); if not tool then return end
	local val_ImageId = tool:FindFirstChild('Values') and tool.Values:FindFirstChild('ImageId')
	if not val_ImageId or not val_ImageId.Value then return end

	return StringUtils.GetUsableAssetId(val_ImageId.Value)
end

local function startSoundFX()
	ConveyorSound:Stop()
	ConveyorSound.TimePosition = 0

	ConveyorSound.Volume = 0.2
	ConveyorSound:Play()
end

local function stopSoundFX()
	SoundUtils.Fade(ConveyorSound, 'Out', 0.5, false, true)
	ConveyorEnd:Play()
end

local function toggleChute(open: boolean, duration)
	if not coverPart then return end
	if gateOpen == open then return end

	gateOpen = open
	coverPart.CanCollide = not open

	local tweenInfo = TweenInfo.new(duration or 3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	TweenService:Create(coverPart, tweenInfo, {
		CFrame = open and openCF or closedCF
	}):Play()
end
	
function updateConveyor()
	if active and conveyorOn then
		toggleRidge:Fire(true)
		conveyor.AssemblyLinearVelocity = conveyor.CFrame.LookVector * speed

		startSoundFX()

	elseif active then
		toggleRidge:Fire(false)
		stopSoundFX()
	else
		toggleRidge:Fire(false)
		stopSoundFX()

		for _, part in ipairs(neonParts:GetChildren()) do
			if part:IsA("BasePart") then
				part.Color = Color3.fromRGB(0,0,0)

				local light = part:FindFirstChildOfClass("SurfaceLight")
				if light then
					light.Enabled = false
				end
			end
		end

		for _, orb in ipairs(getAllOrbs()) do
			orb.Color = Color3.fromRGB(0,0,0)
		end
	end
end

local orb_Color_map = {
	FrontOrb = Color3.fromRGB(215, 197, 154),
	CenterOrb = Color3.fromRGB(248, 248, 248)
}

machineVisuals.Event:Connect(function()
	for _, orb in ipairs(getAllOrbs()) do
		local color = orb_Color_map[orb.Name]

		if color then
			orb.Material = Enum.Material.Neon
			orb.Color = color

			local light = orb:FindFirstChildOfClass("SurfaceLight")
			if light then
				light.Enabled = true
				light.Color = color
			end
		end
	end
end)

-- ActivateMachine
activateEvent.OnServerEvent:Connect(function()
	if broken then return end
	if not active then
		active = true
		conveyorOn = true
		updateConveyor()
		activateMachine()
	end
end)

toggleEvent.OnServerEvent:Connect(function()
	if broken then return end
	if not active then return end
	conveyorOn = not conveyorOn
	updateConveyor()
end)

--Highlights similar items
local function highlightSimilar(targetPickup)
	local count = 0

	for _, obj in ipairs(CollectionService:GetTagged("Pickup")) do --not sure yet w/ this
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
			local fadeOut = TweenService:Create(highlight, TweenInfo.new(highlightDuration - 2), {FillTransparency = 1})
			fadeOut:Play()
		end)

		Debris:AddItem(highlight, highlightDuration)
	end

	return count
end

local machineConn

-- shutdowns the machine
function shutdownMachine()
	if broken then return end
	broken = true

	print("machine broken")

	active = false
	conveyorOn = false
	toggleChute(false, 0.3)
	
	conveyor.AssemblyLinearVelocity = Vector3.zero
	toggleRidge:Fire(false)

	stopOverloadCycle()

	for _, part in ipairs(neonParts:GetChildren()) do
		if part:IsA("BasePart") then
			part.Color = Color3.fromRGB(0,0,0)

			local light = part:FindFirstChildOfClass("SurfaceLight")
			if light then
				light.Color = Color3.fromRGB(0,0,0)
			end
		end
	end

	for _, orb in ipairs(getAllOrbs()) do
		orb.Color = Color3.fromRGB(0, 0, 0)
		orb.Material = Enum.Material.SmoothPlastic

		local light = orb:FindFirstChildOfClass("SurfaceLight")
		if light then
			light.Enabled = false
		end
	end

	stopSoundFX()
	terminal:SetAttribute("Broken", true)
	terminal.Screen.FocusPrompt.Enabled = false

	for _, orb in ipairs(getAllOrbs()) do
		orb.Color = Color3.fromRGB(0, 0, 0)
		orb.Material = Enum.Material.SmoothPlastic
	end

	if machineConn then
		machineConn:Disconnect()
	end

	LightModule.ToggleAllLightsUnderParent(neonParts, false)



	scanner.CanQuery = false

	ReplicatedStorage.BindableEvent.DisableTerminal:Fire()
	ReplicatedStorage.Remotes.ShutdownUI:FireAllClients("broken")

	ReplicatedStorage.RoundInfo.Score.Value += scoreBonus
	RoundUtils.AddExtraToReview({
		Name = 'CBTTester';
		DisplayName = 'CBT 3001 Tester';
		Score = scoreBonus;
	})
	
	task.wait(3)
	--announces for being a proactive tester
	ScreenMessage.ShowMessage(`We finally know the limits of the machine.\nAwarding your team <font color="rgb(108, 255, 98)">{scoreBonus}</font> performance score for being a proactive tester.\nNow to call up Arron...`, 5, false, nil, {
		Section = "UpperManagement"
	})
end

-- triggers the overload AKA 10 second timer before shutdown
function triggerOverload()
	if overloaded or broken then return end

	overloaded = true
	print("Overloading")

	local duration = 10
	local endTime = tick() + duration

	ReplicatedStorage.Remotes.ShutdownUI:FireAllClients("overload", endTime)
	startOverloadCycle()

	task.spawn(function()
		local allOrbs = getAllOrbs()

		while overloadRunning and not broken do
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

local touchingPickups = {}
local killedCharacters = {}

-- destroys any parts that touches the zone and kills the player, plays a sound aswell
destroyZone.Touched:Connect(function(part)
	local pickup = ItemUtils.getPickupFromPart(part)

	if pickup and not pickup:GetAttribute("Held") then
		if not touchingPickups[pickup] then
			touchingPickups[pickup] = true
			print("Entered zone:", pickup.Name)
			task.delay(1, function()
				if touchingPickups[pickup] and pickup.Parent then
					print("DESTROYING:", pickup.Name)

					local thud = CBT.DestroyPart.ThudSound:Clone()
					thud.Parent = CBT.DestroyPart
					thud:Play()
					Debris:AddItem(thud, 3)
					print("Playing thud for:", pickup.Name)

					local humanoid = pickup:FindFirstChildOfClass("Humanoid")
					if humanoid then
						humanoid.Health = 0
					end

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
		if humanoid then
			print("Player killed:", character.Name)
			humanoid.Health = 0
		end

		task.delay(2, function()
			killedCharacters[character] = nil
		end)
	end
end)

for _, player in ipairs(game.Players:GetPlayers()) do
	if player.Character then
		setupCharacter(player.Character)
	end
end

-- activates the machine and most stuff is done here(scan, chute, collision, error, etc)
function activateMachine() 
	if broken then return end 

	if machineConn then 
		machineConn:Disconnect() 
	end 

	-- FX 
	LightModule.ToggleAllLightsUnderParent(neonParts, true) 

	machineConn = RunService.Heartbeat:Connect(function() 
		if broken then return end 
		if not active or not conveyorOn then return end 

		local pickups = ItemUtils.getPickupsInBoundingBox(conveyorZone.CFrame, conveyorZone.Size) 
		local currentPickups = {} 
		
		local slope = CBT:WaitForChild("ConveyorSlope")		
		local zoneParts = workspace:GetPartBoundsInBox(conveyorZone.CFrame, conveyorZone.Size)

		local hasItems = false

		for _, pickup in ipairs(pickups) do
			if not pickup:GetAttribute("Held") then
				hasItems = true
				break
			end
		end

		if hasItems then
			lastItemTime = tick()
		end

		if (tick() - lastItemTime) <= 0.2 then
			if not gateOpen then
				toggleChute(true)
			end
		else
			if gateOpen and (tick() - lastItemTime >= 3) then
				toggleChute(false)
			end
		end

		for _, pickup in ipairs(pickups) do 
			local root = pickup:IsA("Model") and (pickup.PrimaryPart or pickup:FindFirstChildWhichIsA("BasePart")) or pickup 
			if not root then continue end 
			if pickup:GetAttribute("Held") then continue end
			
			
			local phys = PhysicalProperties.new(0.7, 0.1, 0.5)
			root.CustomPhysicalProperties = phys
			
			local dist = (root.Position - slope.Position).Magnitude

			if dist <= 3 then
				local slopeDir = slope.CFrame.LookVector
				local targetVel = conveyor.CFrame.LookVector * speed

				root.AssemblyLinearVelocity = Vector3.new(
					targetVel.X + slopeDir.X * 1,
					root.AssemblyLinearVelocity.Y,
					targetVel.Z + slopeDir.Z * 1
				)
			end
			
			root.Anchored = false 
			root.CanCollide = true 
			
			if root:IsA("BasePart") and not root.Anchored then
				root:SetNetworkOwner(nil)
			end
			
			if not pickup:GetAttribute("CollisionSet") then
				PhysicsUtils.SetObjCollisionGroup(pickup, "Pickups", true)
				pickup:SetAttribute("CollisionSet", true)
			end

			currentPickups[pickup] = true 
			if not pickup:GetAttribute("Locked") and not pickup:GetAttribute("Held") then
				ItemUtils.TogglePickupInteractability(pickup, true)
			end

			local scannerParts = workspace:GetPartBoundsInBox(scanner.CFrame, scanner.Size) 

			for _, part in ipairs(scannerParts) do 
				local pickup = ItemUtils.getPickupFromPart(part) 
				if not pickup then continue end
				if pickup:GetAttribute("Held") then continue end
				if scanned[pickup] then continue end 
				
				lastItemTime = tick()
				scanned[pickup] = true 
				ItemUtils.TogglePickupInteractability(pickup, false)
				pickup:SetAttribute("Locked", true)
				
				local now = tick() 
				table.insert(scanTimestamps, now) 

				for i = #scanTimestamps, 1, -1 do 
					if now - scanTimestamps[i] > overload_window then 
						table.remove(scanTimestamps, i) 
					end 
				end 

				if #scanTimestamps >= overload_threshold and not overloaded then 
					triggerOverload() 
				end 

				if CollectionService:HasTag(pickup, "SpecialPickup") then 
					print("special item:", pickup.Name) 
					if not pickup:GetAttribute("Counted") then 
						pickup:SetAttribute("Counted", true) 
						specialCount += 1 
						print("Special count:", specialCount) 

						if specialCount >= special_threshold and not overloaded then 
							triggerOverload() 
						end 
					end 

					local imageId = getPickupImage(pickup) 

					scanEvent:FireAllClients("ERROR", nil, imageId) 

					continue 
				end 

				local count = highlightSimilar(pickup) 
				local imageId = getPickupImage(pickup) 

				scanEvent:FireAllClients(pickup.Name, count, imageId) 
				task.delay(1.5, function()
					scanned[pickup] = nil 
				end) 
			end 
		end 

		for pickup in pairs(inConveyor) do 
			if not currentPickups[pickup] then
				inConveyor[pickup] = nil 
				if pickup and pickup.Parent then
					if not pickup:GetAttribute("Locked") and not pickup:GetAttribute("Held") then
						ItemUtils.TogglePickupInteractability(pickup, true)
					end		
				end 
			end 
		end 
	end) 
end
