OrganizeItemsThroughBagSyncExportDB = OrganizeItemsThroughBagSyncExportDB or { items = {}, meta = {} }

local function nowUTC()
  return date("!%Y-%m-%dT%H:%M:%SZ")
end

local function safeGetItemInfo(itemID)
  return GetItemInfo(itemID)
end

local function detectBindingType(itemID)
  -- Get tooltip data for binding info
  local data = C_TooltipInfo.GetItemByID(itemID)
  if not data or not data.lines then return nil, nil, nil end

  -- Safely surface args if available
  if TooltipUtil and TooltipUtil.SurfaceArgs then
    TooltipUtil.SurfaceArgs(data)
  end

  local bindText = nil
  local bindCategory = "Unknown"
  local tooltipBonding = nil

  for _, line in ipairs(data.lines) do
    -- Safely surface line args if available
    if TooltipUtil and TooltipUtil.SurfaceArgs then
      TooltipUtil.SurfaceArgs(line)
    end
    
    -- Check for binding line type
    if line.type == Enum.TooltipDataLineType.ItemBinding then
      bindText = line.leftText
      tooltipBonding = line.bonding
    end
    
    -- Parse binding text for classification
    if line.leftText then
      local text = line.leftText
      
      -- Warbound detection
      if text:find("Warbound") then
        if text:find("until equipped") then
          bindCategory = "Warbound-BoE"
          bindText = text
        else
          bindCategory = "Warbound"
          bindText = text
        end
      
      -- Account-bound detection
      elseif text:find("Account Bound") or text:find("Blizzard Account Bound") then
        bindCategory = "Account-Bound"
        bindText = text
      
      -- Bind on Pickup (Soulbound)
      elseif text:find("Soulbound") or text:find("Binds when picked up") then
        bindCategory = "Bind-on-Pickup"
        bindText = text
      
      -- Bind on Equip
      elseif text:find("Binds when equipped") then
        bindCategory = "Bind-on-Equip"
        bindText = text
      
      -- Bind on Use
      elseif text:find("Binds when used") then
        bindCategory = "Bind-on-Use"
        bindText = text
      
      -- Quest Item
      elseif text:find("Quest Item") then
        bindCategory = "Quest-Item"
        bindText = text
      end
    end
  end

  -- If no binding found, it's likely tradeable
  if not bindText then
    bindCategory = "Tradeable"
  end

  return bindText, tooltipBonding, bindCategory
end

local function exportOne(itemID)
  local name, link, quality, ilvl, minLvl, itemType, subType, maxStack, equipLoc, icon,
        sellPrice, classID, subClassID, bindType, expacID, setID, isCraftingReagent = safeGetItemInfo(itemID)
  
  local bindText, tooltipBonding, bindCategory = detectBindingType(itemID)

  OrganizeItemsThroughBagSyncExportDB.items[itemID] = {
    item_id = itemID,
    name = name,
    link = link,
    quality = quality,
    item_level = ilvl,
    min_level = minLvl,
    item_type = itemType,
    item_subtype = subType,
    max_stack = maxStack,
    equip_loc = equipLoc,
    class_id = classID,
    subclass_id = subClassID,
    bind_type = bindType,              -- from GetItemInfo (numeric)
    bind_text = bindText,              -- from tooltip lines
    bind_category = bindCategory,      -- our classification
    tooltip_bonding = tooltipBonding,  -- numeric binding from tooltip
    expac_id = expacID,
    set_id = setID,
    is_crafting_reagent = isCraftingReagent,
    exported_at = nowUTC(),
  }
end

local function exportAll()
  if type(OrganizeItemsThroughBagSyncIDs) ~= "table" then
    print("OrganizeItemsThroughBagSyncExport: OrganizeItemsThroughBagSyncIDs table missing.")
    return
  end

  OrganizeItemsThroughBagSyncExportDB.meta = {
    exported_at = nowUTC(),
    interface = select(4, GetBuildInfo()),
    count = #OrganizeItemsThroughBagSyncIDs,
  }
  
  local i = 1
  local function step()
    if i > #OrganizeItemsThroughBagSyncIDs then
      print("OrganizeItemsThroughBagSyncExport: export done (" .. #OrganizeItemsThroughBagSyncIDs .. " items). Now /reload to write SavedVariables.")
      return
    end

    local itemID = OrganizeItemsThroughBagSyncIDs[i]
    local item = Item:CreateFromItemID(itemID)
    item:ContinueOnItemLoad(function()
      exportOne(itemID)
      i = i + 1
      C_Timer.After(0.02, step)
    end)
  end
  step()
end

SLASH_ORGANIZEITEMSTHROUGHBAGSYNCEXPORT1 = "/cie"
SlashCmdList["ORGANIZEITEMSTHROUGHBAGSYNCEXPORT"] = function(msg)
  msg = (msg or ""):lower()
  if msg == "export" then
    exportAll()
  else
    print("OrganizeItemsThroughBagSyncExport: use /cie export")
  end
end
