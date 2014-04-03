-----------------------------------------------------------------------------------------------
-- Client Lua Script for GeminiProfiler
-- Copyright (c) NCsoft. All rights reserved
-----------------------------------------------------------------------------------------------
 
require "Window"

-----------------------------------------------------------------------------------------------
-- GeminiProfiler Module Definition
-----------------------------------------------------------------------------------------------
local GeminiProfiler = {} 
 
-----------------------------------------------------------------------------------------------
-- Constants
-----------------------------------------------------------------------------------------------
-- e.g. local kiExampleVariableMax = 999
local ProfLib = nil

-- Default Inspection depth is 1 (only go back up the function tree 1 level)
local kiDefaultInspectionDepth = 1
-- Default value for number of instructions between polls for count type debug
local kiDefaultHookCount = 300

-- Constant Enum to convert fields to grid row number for standard reports
local keReportFields = {
    ['addon']       = 1,
    ['file']        = 2,
    ['name']        = 3,
    ['line']        = 4,
    ['time']        = 5,
    ['relative']    = 6,
    ['count']       = 7,
}

-- Constant enum of starting field widths
--  Note: name, file, and addon are fractions of the remaining size
local keDefaultReportWidths = {
    ['count']      =  80,
    ['relative']   =  62,
    ['time']       =  65,
    ['line']       =  50,
    ['name']       = 0.4,
    ['file']       = 0.3,
    ['addon']      = 0.3,
}

-- Constant enum of inspection report fields to columns
--  Name goes first here because trees only return the 1st column for some reason
local keInspectionFields = {
    ['name']      = 1,
    ['addon']     = 2,
    ['file']      = 3,
    ['line']      = 4,
    ['count']     = 5,
}

-- Constant enum of Default width for Inspection Trees.
--  Note: name, file, and addon are fractions of the remaining size
local keDefaultInspectionWidths = {
    ['name']    = 0.4,
    ['addon']   = 0.3,
    ['file']    = 0.3,
    ['line']    =  50,
    ['count']   =  80,
}

-- Constant Enum of memory report fields to columns
local keMemoryReportFields = {
    ['time']      = 1,
    ['kbytes']    = 2,
    ['mbytes']    = 3,
    ['note']      = 4,
}

-- Constant Enum of the offsets for the options pane.  Used for shrink/grow when changing profiling type.
local keOptionsOffsets = {
    ['left']    = -16,
    ['top']     =  10,
    ['right']   = 200,
    ['bottom']  = 360,
}
-----------------------------------------------------------------------------------------------
-- Initialization
-----------------------------------------------------------------------------------------------
function GeminiProfiler:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self 

    -- initialize variables here

    return o
end

function GeminiProfiler:Init()
    Apollo.RegisterAddon(self, false, "", {"Gemini:ProFi-1.3"})
end
 
-----------------------------------------------------------------------------------------------
-- GeminiProfiler OnLoad
-----------------------------------------------------------------------------------------------
function GeminiProfiler:OnLoad()
    ProfLib = Apollo.GetPackage("Gemini:ProFi-1.3").tPackage
    
    self.xmlDoc = XmlDoc.CreateFromFile("GeminiProfiler.xml")
    self.xmlDoc:RegisterCallback("OnDocLoaded", self)    
end

function GeminiProfiler:OnDocLoaded()
    -- Load our form and hide it
    self.wndMain = Apollo.LoadForm(self.xmlDoc, "GeminiProfilerWindow", nil, self)
    self.wndMain:Show(false)
    if self.wndMain == nil then
        Apollo.AddAddonErrorText(self, "Could not load the main window for some reason.")
        return
    end

    -- Register handlers for events, slash commands and timer, etc.
    -- e.g. Apollo.RegisterEventHandler("KeyDown", "OnKeyDown", self)
    Apollo.RegisterSlashCommand("profiler", "OnGeminiProfilerOn", self)

    -- Store a reference to the Profile Grid
    self.wndGrid = self.wndMain:FindChild("ProfileGrid")
    -- Previous Displayed Tab is the main Grid
    self.wndOldTabData = self.wndGrid
    -- Profile Results are selected by default
    self.wndMain:FindChild("ProfileBtn"):SetCheck(true)
    -- ProfileBtn is linked to the main profile display
    self.wndMain:FindChild("ProfileBtn"):SetData(self.wndGrid)

    -- Setup options with no settings
	self.options = {}
    -- Initialize filters with none set
    self.options.filters = {}

    -- Default Inspect Depth
    self.options.nInspectDepth = kiDefaultInspectionDepth
    -- Default number of instructions between hooks when doing call based
	self.options.nHookCount = kiDefaultHookCount
    -- Change setting inside ProfLib
    ProfLib:setHookCount(self.options.nHookCount)

    -- Default is time based so hide count slider
    self.nHookCountHeight = self.wndMain:FindChild("HookCountContainer"):GetHeight()
    self:OnDebugTypeToggle()
    --self.wndMain:FindChild("HookCountContainer"):Show(false)
	
    -- Carbine On/Off button shows off when checked so we set the check
	self.wndMain:FindChild("ProfilingButton"):SetCheck(true)
end

-----------------------------------------------------------------------------------------------
-- GeminiProfiler Public use methods
-----------------------------------------------------------------------------------------------

--[[
    Starts Profiling, this erases all previous profiling data

    Example:
        local GeminiProfiler = Apollo.GetAddon("GeminiProfiler")
        GeminiProfiler:StartProfiling()
]]
-- Begin a profiling session
function GeminiProfiler:StartProfiling()
    -- Empty all Profile grid results
    self.wndGrid:DeleteAll()
    -- Delete collected reports
    self.tReportData = nil

    -- Empty previous results, if any
    ProfLib:reset()

    if self.options.strInspectName then
        ProfLib:setInspect(self.options.strInspectName, self.options.nInspectDepth)
    end
    -- Initiate a profiling session
    ProfLib:start()
end

--[[
    Stops profiling and generates a report

    Example:
        local GeminiProfiler = Apollo.GetAddon("GeminiProfiler")
        GeminiProfiler:StopProfiling()
]]
-- Stops profiling session
function GeminiProfiler:StopProfiling()
    -- Halt profiling session
    ProfLib:stop()
    -- Gather profiling results
    self.tReportData = ProfLib:createReport()

    -- Parse gathered data
    self:ProcessReports()

    -- Display gathered data in the grid
    self:GenerateGrid()
end

--[[
    Arguments:                          Description:
        bExcludeCarbine = boolean           This field indicates if we should ignore all carbine addons
        tFilters = table                    Table of filters

    tFilters options:                   Description:
        name                                Function name
        namewhat                            Type of function one of: "global", "local", "method", "field", or ""
        addon                               Name of Addon the function exists in
        file                                Name of File the function exists in
        lineDefined                         Line number the function is defined on
        timer                               How long the function ran
        relTime                             Amount of time used by function divided by the time profiling was ran
        count                               How many times the function was called

    If there is no filter for a given field in the passed table that field will not be filtered on.
    Pass an empty table or nil to clear out all filters

    Example:
        local GeminiProfiler = Apollo.GetAddon("GeminiProfiler")
        GeminiProfiler:SetFilters(false, { name = "MyFunc", addon = "MyAddon" })
]]
function GeminiProfiler:SetFilters(bExcludeCarbine, tFilters)
    -- Ensure we are getting a proper boolean for our first value
    if type(bExcludeCarbine) ~= "boolean" then return end
    self.options.bExcludeCRB = bExcludeCarbine
    -- Set the filters options, we blindly assume you passed good info, hey this is a developer addon
    self.options.filters = tFilters or {}
    -- Update displays and redraw grid
    self:UpdateFilters()
end

--[[
    Arguments:                          Effect on the debug:
        nHookCount = integer                Sets the hook count, which determine how many instructions must pass before being called

    Default is 300 so that it runs every 300 instructions.  This setting only has an effect if the type is Count

    Example:
        local GeminiProfiler = Apollo.GetAddon("GeminiProfiler")
        GeminiProfiler:SetHookCount(100)
]]
function GeminiProfiler:SetHookCount(nHookCount)
    -- Update stored value
    self.options.nHookCount = nHookCount
    -- Set the Hook Count
    ProfLib:setHookCount(self.options.nHookCount)
    -- Update the slider
    self.wndMain:FindChild("HookCountSlider"):SetValue(nHookCount)
    -- Update the text field
    self.wndMain:FindChild("HookCountEditBox"):SetText(nHookCount)
end

--[[
    Arguments:                          Effect on the debug hook:
        bCount  = boolean                   Use function call count only no time records

    Default is bCount = false.  This means that time is available (This is a higher load though)

    Example:
        local GeminiProfiler = Apollo.GetAddon("GeminiProfiler")
        GeminiProfiler:SetDebugType(true)
]]
function GeminiProfiler:SetDebugType(bCount)
    -- If a boolean wasn't passed return
    if type(bCount) ~= boolean then return end
    -- Locate the button and set its state
    self.wndMain:FindChild("DebugTypeBtn"):SetCheck(bCount)
    -- Use the button handler to set everything else
    self:OnDebugTypeToggle()
end

-----------------------------------------------------------------------------------------------
-- GeminiProfiler Functions
-----------------------------------------------------------------------------------------------
-- Define general functions here

-- on SlashCommand "/profiler"
function GeminiProfiler:OnGeminiProfilerOn()
	self.wndMain:Show(true) -- show the window
end

-- Processes a report into something more easily displayed.
--  Currently changes the source line into the addon and file fields then nils it
function GeminiProfiler:ConvertSource(tFuncReport)
    local strCRBPrefix = 'ui'
    local strAddonMatch = nil

    -- If there is no source we must have already proccessed this report, so exit.
    if not tFuncReport.source then return end

    --  Carbine addons source file all start with ui, lets check for that.
    if string.sub(tFuncReport.source, 1, string.len(strCRBPrefix)) == strCRBPrefix then
        -- Set the boolean to indicate this is a carbine addon (Used for filtering)
        tFuncReport.bCRBAddon = true
        -- Example Pattern: ui\Death\Death.lua
        strAddonMatch = "ui[\\/](.-)[\\/]"
    else
        -- Example Pattern: C:\Users\<username>\AppData\Roaming\NCSOFT\WildStar\Addons\GeminiProfiler\GeminiProfiler.lua
        --  source will not contain this full path it chops off some from the start as it is too long.
        --  this match does not care about the casing of the addons folder as that may be user created and not be "Addons"
        --  file name match is done seperately because addons can contain sub folders.
        --      Example: C:\Users\<username>\AppData\Roaming\NCSOFT\WildStar\Addons\GeminiProfiler\libs\GeminiPackages\GeminiPackages.lua
        -- Match looks for: end of WildStar, followed by \ or / (path can be either direction in toc) a case insensistive addons another \ or /
        --  followed by anything before the next \ or /
        strAddonMatch = ".*tar[\\/][Aa][Dd][Dd][Oo][Nn][Ss][\\/](.-)[\\/]"
    end
    tFuncReport.addon = string.match(tFuncReport.source, strAddonMatch)
 
    -- If there is no addon this must be a C Function, they have no lua files
    if not tFuncReport.addon then
        tFuncReport.addon = "C Func"
        tFuncReport.file = "N/A"
    else
        -- Looks for the filename.lua
        tFuncReport.file = string.match(tFuncReport.source, ".*[\\/](.+)%.lua$")
        -- Append .lua or set to 'Unknown' if no file match
        if not tFuncReport.file then
            tFuncReport.file = "Unknown"
        else
            tFuncReport.file = tFuncReport.file .. ".lua"
        end
    end

    -- source is parsed, nil it out
    tFuncReport.source = nil
end

-- Function to convert Inspections, is called recursivly to convert all children too
function GeminiProfiler:ConvertInspection(tInspectionReport)
    -- Convert this report
    self:ConvertSource(tInspectionReport)

    -- If we have children we need to process those
    if tInspectionReport.children then
        -- Iterate through the child reports
        for funcRef, tChildReport in pairs(tInspectionReport.children) do
            -- Recursively call the ConvertInspection function to process all children and their children
            self:ConvertInspection(tChildReport)
        end
    end
end

-- Sorted Pairs function, pass in the sort function
local function spairs(t, order)
    -- Collect keys
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end

    -- If order function given, sort by passing the table and keys a, b,
    -- otherwise just sort keys
    if order then
        table.sort(keys, function(a,b) return order(t, a, b) end)
    else
        table.sort(keys)
    end
    
    -- Return the iterator function
    local i = 0
    return function()
        i = i + 1
        if keys[i] then
            return keys[i], t[keys[i]]
        end
    end
end
-- Sort by number of calls, used with spairs above.
local function sortByCallCount(t, a, b)
    return t[a].count > t[b].count
end

-- Convert all reports into easily processed data
function GeminiProfiler:ProcessReports()
    -- No reports means no processing!
    if not self.tReportData or not self.tReportData.reports then return end
    -- No Tree to begin with
    local wndTree = nil
    local tInspections = {}
    -- Iterate through the standard reports
    for i, tFuncReport in pairs(self.tReportData.reports) do
        -- Process source file name first
        self:ConvertSource(tFuncReport)

        -- If this function has its callers listed we need to handle that
        if tFuncReport.inspections then
            -- Generate (or re-use) a display grid for this report, this is done here
            --  because multiple function reports could have inspections so we want
            --  to re-use the same tree and see them all.  Option: add all to table
            --  then sort?
            wndTree = wndTree or self:GenerateInspectionTree(tFuncReport.name)

            -- Iterate through the inspections and clean them up into the standard
            for k, tInspectionReport in pairs(tFuncReport.inspections) do
                -- Call recursive conversion function
                self:ConvertInspection(tInspectionReport)
                -- Add all function reports to the tree, recursively
                table.insert(tInspections, tInspectionReport)
            end
        end
    end
    for k, tInspectionReport in spairs(tInspections, sortByCallCount) do
        self:AddTreeValue(wndTree, tInspectionReport, 0)
    end
end

-- Adds a tree element, this will call itself to add children passing the parent node id
function GeminiProfiler:AddTreeValue(wndTree, tFuncReport, hParent)
    -- Create new node, store a reference to this specific report in it (Not used currently)
    local hNewNode = wndTree:AddNode(hParent, tFuncReport.name, "", tFuncReport)
    
    -- 2nd Column, Addon Name
    wndTree:SetNodeText(hNewNode, keInspectionFields.addon, tFuncReport.addon)

    -- 3rd Column, File Name
    wndTree:SetNodeText(hNewNode, keInspectionFields.file, tFuncReport.file)

    -- 4th Column, line number
    wndTree:SetNodeText(hNewNode, keInspectionFields.line, tFuncReport.lineDefined)

    -- 5th Column, number of calls
    wndTree:SetNodeText(hNewNode, keInspectionFields.count, tFuncReport.count)

    -- Does this report have child reports?
    if tFuncReport.children then
        -- Yes, iterate through the reports
        for funcRef, tChildReport in pairs(tFuncReport.children) do
            -- Add them to the tree with this report as the parent (Note: Recursive)
            self:AddTreeValue(wndTree, tChildReport, hNewNode)
        end
        -- We have at least 1 child so we need to collapse the node.
        wndTree:CollapseNode(hNewNode)
    end
end

-- Generate a Tree Tab for filling in with Inspection data
function GeminiProfiler:GenerateInspectionTree(strFuncName)
    -- Format string used for finding tree control
    local treeFormat = "_%sTree"
    -- Name of this specific tree
    local strTreeName = string.format(treeFormat, strFuncName)
    -- Locate the tree control container
    local wndTreeContainer = self.wndMain:FindChild(strTreeName)
    local wndTree = nil

    -- No tree container found, need to create a new one
    if not wndTreeContainer then
        -- Load a new Tree Container from the xml file
        wndTreeContainer = Apollo.LoadForm(self.xmlDoc, "TreeFormTemplate", self.wndMain:FindChild("TabsDataContainer"), self)
        -- Set its unique name
        wndTreeContainer:SetName(string.format(treeFormat, strFuncName))

        -- Load the button template
        local wndTabBtn = Apollo.LoadForm(self.xmlDoc, "BtnTemplate", self.wndMain:FindChild("TabsBtnContainer"), self)
        -- Set the correct button name
        wndTabBtn:SetName(string.format("_%sBtn",strFuncName))
        -- Store a reference to the Tree container
        wndTabBtn:SetData(wndTreeContainer)
        -- Set the tooltip to the function name,
        wndTabBtn:SetTooltip(strFuncName)
        -- Set the label on the Tab to the function name
        wndTabBtn:FindChild("BtnTemplateText"):SetText(strFuncName)
        -- Order all the tabs horizontally
        self.wndMain:FindChild("TabsBtnContainer"):ArrangeChildrenHorz()
        -- Ensure the tree is the correct size
        self:ResizeTree(wndTreeContainer)
        -- Get a reference to the actual tree in the container
        wndTree = wndTreeContainer:FindChild("InspectTree")
        -- Hide the tab we just added
        wndTreeContainer:Show(false)
    else
        -- found a Tree Container, get a reference to the actual tree
        wndTree = wndTreeContainer:FindChild("InspectTree")
        -- Clear out all the old nodes
        wndTree:DeleteAll()
    end

    -- Return the reference to the Tree we found or created
    return wndTree
end

-- Checks passed function report against existing filters
--  NOTE: This can be used to filter on fields not even displayed
function GeminiProfiler:ShouldFilter(tFuncReport)
    -- First check if we are excluding carbine addons and this is one, if it is we should filter it out
    if self.options.bExcludeCRB and tFuncReport.bCRBAddon then return true end

    -- Iterate through the filters
    for strFilterName, strFilterString in pairs(self.options.filters) do
        -- If we don't find a match we need to filter this report out
        --  we use string.find as it does not create a string
        if tFuncReport[strFilterName] and not string.find(tFuncReport[strFilterName], strFilterString) then
            return true
        end
    end

    -- No reason found to filter report out, return false
    return false
end

-- Function to populate Grid Data
function GeminiProfiler:GenerateGrid()
    -- Double check we have data here
    local tReports = self.tReportData and self.tReportData.reports

    -- No reports means no grid!
	if not tReports then return	end
    -- Iterate through the standard reports
    for i, tFuncReport in pairs(tReports) do
        -- Check for filtering, we only filter the ProfileGrid
        if not self:ShouldFilter(tFuncReport) then
            -- Add a row save the reference for adding data
            local iPos = self.wndGrid:AddRow("")
        
            -- Store report data in the first column
            self.wndGrid:SetCellLuaData(iPos, 1, tFuncReport)

            -- First row is addon name no special sort information required
            self.wndGrid:SetCellText(iPos, keReportFields.addon, tFuncReport.addon)
            -- Second row is file name, again no special sort information
            self.wndGrid:SetCellText(iPos, keReportFields.file, tFuncReport.file)
            -- Third row is the function name, still no special sort information
            self.wndGrid:SetCellText(iPos, keReportFields.name, tFuncReport.name)
        
            local strLine
            -- Line number of -1 means no line number found, report N/A for that
            if tFuncReport.lineDefined == -1 then
                strLine = "N/A"
            else
                -- Otherwise we report the line number
                strLine = tFuncReport.lineDefined
            end

            -- Fourth row is the line number sort field is a left padded 0 string, to ensure that when sorting 1, 21, 3 descending
            --  you get 21, 3, 1 not 3, 21, 1
            self.wndGrid:SetCellText(iPos, keReportFields.line, strLine)
            self.wndGrid:SetCellSortText(iPos, keReportFields.line, string.format("%04d",tFuncReport.lineDefined))
        
            -- Fifth row is the time in function sort field is a left padded 0 string, to ensure that when sorting 1, 21, 3 descending
            --  you get 21, 3, 1 not 3, 21, 1
            self.wndGrid:SetCellText(iPos, keReportFields.time, string.format("%.3f",tFuncReport.timer or 0))
            self.wndGrid:SetCellSortText(iPos, keReportFields.time, string.format("%010.4f",tFuncReport.timer or 0))
      
            -- Sixth row is the relative time in function sort field is a left padded 0 string, to ensure that when sorting 1, 21, 3
            --  descending you get 21, 3, 1 not 3, 21, 1
            self.wndGrid:SetCellText(iPos, keReportFields.relative, string.format("%.3f",tFuncReport.relTime or 0))
            self.wndGrid:SetCellSortText(iPos, keReportFields.relative, string.format("%010.4f",tFuncReport.relTime or 0))
        
            -- Seventh row is the number of times the function was called sort field is a left padded 0 string, to ensure that when sorting
            --  1, 21, 3 descending you get 21, 3, 1 not 3, 21, 1
            self.wndGrid:SetCellText(iPos, keReportFields.count, tFuncReport.count)
            self.wndGrid:SetCellSortText(iPos, keReportFields.count, string.format("%015d", tFuncReport.count))
        end
    end

    -- Sort by Descending time
    self.wndGrid:SetSortColumn(keReportFields.time, false)
end

---------------------------------------------------------------------------------------------------
-- GeminiProfiler Main window XML Event handlers
---------------------------------------------------------------------------------------------------
-- This is the On/Off button near the Title
function GeminiProfiler:OnProfilingToggle( wndHandler, wndControl, eMouseButton )
    -- Reverse logic as the default state for the Carbine On/Off button is On, which is not what we want
    if not self.wndMain:FindChild("ProfilingButton"):IsChecked() then
        self:StartProfiling()
    else
        self:StopProfiling()
    end
end

-- Gear button in upper right opens options menu
function GeminiProfiler:OnOptionsMenuToggle( wndHandler, wndControl, eMouseButton )
    self.wndMain:FindChild("OptionsContainer"):Show(self.wndMain:FindChild("OptionsBtn"):IsChecked())
end

-- Close button in upper right of options pane
function GeminiProfiler:OnOptionsCloseClick( wndHandler, wndControl, eMouseButton )
    -- Set the options button to not show checked
    self.wndMain:FindChild("OptionsBtn"):SetCheck(false)
    -- Hides options pane
    self:OnOptionsMenuToggle(wndHandler, wndControl, eMouseButton)
end

function GeminiProfiler:OnToggleVisibility( wndHandler, wndControl, eMouseButton )
    self.wndMain:Show(not self.wndMain:IsShown())
end

---------------------------------------------------------------------------------------------------
-- GeminiProfiler Profile Grid Event Handlers
---------------------------------------------------------------------------------------------------
-- Captures clicks on the Grid, pops a context menu with Filter and Inspect (if its a function you right clicked)
function GeminiProfiler:OnProfileGridItemClick(wndControl, wndHandler, iRow, iCol, eClick)
    -- Not a right click, nothing interesting to do
    if eClick ~= 1 then return end

    -- No filtering on columns after name
    if iCol > keReportFields.name then return end

    -- If we already have a context menu, destroy it
    if self.wndContext and self.wndContext:IsValid() then
        self.wndContext:Destroy()
    end

    -- Create a context menu and bring it to front
    self.wndContext = Apollo.LoadForm(self.xmlDoc, "ProfileContextMenuForm", self.wndMain, self)
    self.wndContext:ToFront()

    -- Move context menu to the mouse
    local tCursor= self.wndMain:GetMouse()
    self.wndContext:Move(tCursor.x + 4, tCursor.y + 4, self.wndContext:GetWidth(), self.wndContext:GetHeight())

    -- Save the text is in this row/column so we can use it for whatever action we choose
    self.wndContext:SetData(self.wndMain:FindChild("ProfileGrid"):GetCellText(iRow,iCol))
    -- For Filtering we need to know what we are filtering on
    self.wndContext:FindChild("ContextFilterBtn"):SetData(iCol)

    -- You can only inspect on the function name, and only if it isn't 'anonymous'
    if iCol ~= keReportFields.name or self.wndMain:FindChild("ProfileGrid"):GetCellText(iRow,iCol) == "anonymous" then
        self.wndContext:FindChild("InspectBtnText"):SetTextColor("UI_BtnTextGrayListDisabled")
        self.wndContext:FindChild("ContextInspectBtn"):Enable(false)
    end
end

-----------------------------------------------------------------------------------------------
-- GeminiProfiler Resizing of Display Forms
-----------------------------------------------------------------------------------------------

-- Function used to resize Trees when the profiler window size is changed
function GeminiProfiler:ResizeTree(wndTreeContainer)
    -- Determine width of the container
    local nCurrWidth = wndTreeContainer:GetWidth()
    -- Initialize array for correct widths
    local tColWidths = {}

    -- Start at the right edge and go left, set the field to the default width for most fields
    --  Subtract used width from the total width after each field
    tColWidths[keInspectionFields.count] = keDefaultInspectionWidths.count
    nCurrWidth = nCurrWidth - keDefaultInspectionWidths.count
    tColWidths[keInspectionFields.line] = keDefaultInspectionWidths.line
    nCurrWidth = nCurrWidth - keDefaultInspectionWidths.line

    -- Fields that actually change size are below.
    --  Take remaining size and multiply by the default size (should be a fraction), use this for each
    --  column width except for the last one where we just use the remaining width.
    local nRemainingSize = nCurrWidth
    local nFractionSize = math.floor(nRemainingSize * keDefaultInspectionWidths.file)
    tColWidths[keInspectionFields.file] = nFractionSize
    nCurrWidth = nCurrWidth - nFractionSize
    nFractionSize = math.floor(nRemainingSize * keDefaultInspectionWidths.addon)
    tColWidths[keInspectionFields.addon] = nFractionSize
    nCurrWidth = nCurrWidth - nFractionSize
    tColWidths[keInspectionFields.name] = nCurrWidth

    -- Reset current Width to 0, now we will use it to count up instead of down
    nCurrWidth = 0
    -- Find the Tree inside this container
    local wndTree = wndTreeContainer:FindChild("InspectTree")
    for nLabelNumber = 1,5 do
        -- Find the label we will be modifying
        local wndLabel = wndTreeContainer:FindChild(string.format("s_Column%d", nLabelNumber))
        -- Get its current offsets we will use the top and bottom ones on the new position
        local nLeft, nTop, nRight, nBottom = wndLabel:GetAnchorOffsets()
        -- Retreive the width we determined earlier
        local nWidth = tColWidths[nLabelNumber]
        -- Set the new width to the current width plus the size determined
        local nNewWidth = nCurrWidth + nWidth
        -- Label gets set to current width on the left and that plus label size on the right
        wndLabel:SetAnchorOffsets(nCurrWidth, nTop, nNewWidth, nBottom)
        -- Current width is now the right most edge of the label
        nCurrWidth = nNewWidth

        -- If this is the first or last label we need to offset stuff (Note: Not sure this is true)
        if nLabelNumber == 1 or nLabelNumber == 5 then
            -- Adjust column width to account for TreeControl's left and right borders
            nWidth = nWidth - 7
        end

        -- Set the width of the tree column to the width of the label, plus 7 because otherwise it looks odd
        wndTree:SetColumnWidth(nLabelNumber, nWidth + 7)
    end
end

function GeminiProfiler:ResizeGrid( wndGrid )
    -- Get current width of the Grid
    local nGridWidth = wndGrid:GetWidth()
    
    -- Start at the right edge and go left, set the field to the default width for most fields
    --  Subtract used width from the total width after each field
    wndGrid:SetColumnWidth(keReportFields.count, keDefaultReportWidths.count)
    nGridWidth = nGridWidth - keDefaultReportWidths.count
    wndGrid:SetColumnWidth(keReportFields.relative, keDefaultReportWidths.relative)
    nGridWidth = nGridWidth - keDefaultReportWidths.relative
    wndGrid:SetColumnWidth(keReportFields.time, keDefaultReportWidths.time)
    nGridWidth = nGridWidth - keDefaultReportWidths.time
    wndGrid:SetColumnWidth(keReportFields.line, keDefaultReportWidths.line)
    nGridWidth = nGridWidth - keDefaultReportWidths.line

    -- Fields that actually change size are below.
    --  Take remaining size and multiply by the default size (should be a fraction), use this for each
    --  column width except for the last one where we just use the remaining width.
    local nRemainingSize = nGridWidth
    local nFractionSize = math.floor(nRemainingSize * keDefaultReportWidths.name)
    wndGrid:SetColumnWidth(keReportFields.name, nFractionSize)
    nGridWidth = nGridWidth - nFractionSize
    nFractionSize = math.floor(nRemainingSize * keDefaultReportWidths.file)
    wndGrid:SetColumnWidth(keReportFields.file, nFractionSize)
    nGridWidth = nGridWidth - nFractionSize
    wndGrid:SetColumnWidth(keReportFields.addon, nGridWidth)
end

-- Resize handler for GeminiProfiler window
function GeminiProfiler:OnGeminiProfilerSizeChanged( wndHandler, wndControl )
    if wndHandler ~= wndControl then
        return
    end
    -- Resize the Profile Grid
    self:ResizeGrid(self.wndGrid)

    -- Iterate through all Inspect Trees we have and resize them too
    for k, wndTree in pairs(self.wndMain:FindChild("TabsDataContainer"):GetChildren()) do
        self:ResizeTree(wndTree)
    end
end

-----------------------------------------------------------------------------------------------
-- GeminiProfiler Filter Settings
-----------------------------------------------------------------------------------------------

function GeminiProfiler:On_fileFilterEnter( wndHandler, wndControl, strText )
	-- Blank line means remove any existing filter
    if strText == "" then
		self.options.filters.file = nil
	else
        -- Otherwise set the filter to the strText
		self.options.filters.file = strText
	end
    -- Filters have been changed, we need to regenerate the grid with the new filters
    self.wndGrid:DeleteAll()
    self:GenerateGrid()
end

function GeminiProfiler:On_nameFilterEnter( wndHandler, wndControl, strText )
    -- Blank line means remove any existing filter
	if strText == "" then
		self.options.filters.name = nil
	else
        -- Otherwise set the filter to StrText
		self.options.filters.name = strText
	end
    -- Filters have been changed, we need to regenerate the grid with the new filters
    self.wndGrid:DeleteAll()
    self:GenerateGrid()
end

-- Exclude Carbine addons checkbox
function GeminiProfiler:OnExcludeFilterToggle( wndHandler, wndControl, eMouseButton )
	self.options.bExcludeCRB = wndControl:IsChecked()
    -- Filtering changed, regenerate the grid
    self.wndGrid:DeleteAll()
    self:GenerateGrid()
end

-- Reset filters button
function GeminiProfiler:OnResetFiltersBtnSignal( wndHandler, wndControl, eMouseButton )
    -- Set Filter to Defaults
    self.options.bExcludeCRB = false
    self.options.filters = {}
    -- Set Displayed filters to nothing
    self.wndMain:FindChild("nameFilterInput"):SetText("")
    self.wndMain:FindChild("fileFilterInput"):SetText("")
    -- Redraw Grid with these filters
    self:UpdateFilters()
end

-- The filters have been updated change what options pane displays then regenerate the Grid
function GeminiProfiler:UpdateFilters()
    -- Set the exclude carbine options checkbox correctly
    self.wndMain:FindChild("FilterExcludeBtn"):SetCheck(self.options.bExcludeCRB)

    -- Iterate through the filters that have been set and make sure we display correct settings
    for strFilterName, strFilterString in pairs(self.options.filters) do
        -- Build the object name
        local strInputName = strFilterName .. "FilterInput"
        -- Attempt to locate the object
        local txtBox = self.wndMain:FindChild(strInputName)
        -- Did we find the object?
        if txtBox ~= nil then
            -- Set the display to our filter
            txtBox:SetText(strFilterString)
        end
    end

    -- Now regenerate the grid with the new filters
    self.wndGrid:DeleteAll()
    self:GenerateGrid()
end

-----------------------------------------------------------------------------------------------
-- GeminiProfiler Debug Type Settings
-----------------------------------------------------------------------------------------------

function GeminiProfiler:OnHookCountEditBoxEnter( wndHandler, wndControl, strText )
	-- Look for the numeric value in the string
	local nNewValue = tonumber(string.match(strText,"%d+"))
	-- No numeric or a value less than 1 means we stick with the old value
	if not nNewValue or nNewValue < 1 then
		wndControl:SetText(self.options.nHookCount)
		return
	end
	-- Update the Hook Count slider
	self.wndMain:FindChild("HookCountSlider"):SetValue(nNewValue)
    -- Update stored value
    self.options.nHookCount = nNewValue
    -- Set the Hook Count
    ProfLib:setHookCount(nNewValue)
end

function GeminiProfiler:OnHookCountSliderBarChanged( wndHandler, wndControl, fNewValue, fOldValue )
	-- Use math.floor to convert from a float to int
    local nNewValue = math.floor(fNewValue)
    -- Set displayed information to the new value
	self.wndMain:FindChild("HookCountEditBox"):SetText(nNewValue)
    -- Update stored value
    self.options.nHookCount = nNewValue
    -- Set the Hook Count
    ProfLib:setHookCount(nNewValue)
end

function GeminiProfiler:OnDebugTypeToggle( wndHandler, wndControl, eMouseButton )
    local nCellPadding = 4
    local wndOpt = self.wndMain:FindChild("OptionsContainer")
    -- Store a reference to the Hook Container
    local wndHookContainer = self.wndMain:FindChild("HookCountContainer")
    -- Get the current offsets for the Options window
    local nLeft, nTop, nRight, nBottom = wndOpt:GetAnchorOffsets()
    -- Determine if we need to hide/show the hook count options
    if self.wndMain:FindChild("DebugTypeBtn"):IsChecked() then
        self.wndMain:FindChild("DebugTypeBtnText"):SetText("Calls")
        -- Show the Hook Count Container
        wndHookContainer:Show(true)
        -- Expand the window size by the size of the hook count container + padding
        wndOpt:SetAnchorOffsets(nLeft, nTop, nRight, nBottom + (self.nHookCountHeight + nCellPadding))
        -- Set the correct debug mask
        ProfLib:setDebugMask("")
    else
        self.wndMain:FindChild("DebugTypeBtnText"):SetText("Time")
        -- Shrink the window size by the size of the hook count container + padding
        wndOpt:SetAnchorOffsets(nLeft, nTop, nRight, nBottom - (self.nHookCountHeight + nCellPadding))
        -- Hide the Hook Count Container
        wndHookContainer:Show(false)
        -- Set the correct debug mask
        ProfLib:setDebugMask("cr")
    end
end

-----------------------------------------------------------------------------------------------
-- GeminiProfiler Inspection Settings
-----------------------------------------------------------------------------------------------

-- Function to Choose the function name to inspect
function GeminiProfiler:SetInspectName(strInspect)
    -- store the function name for when we start profiling
    self.options.strInspectName = strInspect
    -- Set the display to the value or clear it if we are clearing
    self.wndMain:FindChild("InspectNameInput"):SetText(strInspect or "")

    -- Change Icon to gold if we will inspect, blue if no inspection pending
    if strInspect == nil or strInspect == "" then
        self.wndMain:FindChild("InspectIcon"):SetSprite("CRB_Basekit:kitIcon_Holo_HazardObserver")
    else
        self.wndMain:FindChild("InspectIcon"):SetSprite("CRB_Basekit:kitIcon_Gold_HazardObserver")
    end
end

-- Slider has moved to a new position
function GeminiProfiler:OnDepthSliderChanged( wndHandler, wndControl, fNewValue, fOldValue )
    -- Use math.floor to convert from a float to int
    local nNewValue = math.floor(fNewValue)
    -- Set the text to the selected value
    self.wndMain:FindChild("DepthCountEditBox"):SetText(nNewValue)

    -- Update the stored value
    self.options.nInspectDepth = nNewValue
end

-- Clicked the reset button
function GeminiProfiler:OnResetDepthBtnSignal( wndHandler, wndControl, eMouseButton )
    -- Clear the name of the function we are inspecting
    self:SetInspectName(nil)
    -- Set Inspection Depth to the default
    self.options.nInspectDepth = kiDefaultInspectionDepth
    -- Update the slider and text box with the default values
    self.wndMain:FindChild("DepthCountEditBox"):SetText(self.options.nInspectDepth)
    self.wndMain:FindChild("DepthSlider"):SetValue(self.options.nInspectDepth)
end

-- Typed in a new depth value and hit enter
function GeminiProfiler:OnDepthCountEditBoxEnter( wndHandler, wndControl, strText )
	-- Look for the numeric value in the string
	local nNewValue = tonumber(string.match(strText,"%d+"))
	-- No numeric or a value less than 1 means we stick with the old value
	if not nNewValue or nNewValue < 1 then
		wndControl:SetText(self.options.nInspectDepth)
		return
	end
	-- Update the Depth slider's value
	self.wndMain:FindChild("DepthSlider"):SetValue(nNewValue)
    -- Update stored value
    self.options.nInspectDepth = nNewValue
end

-- Typed in a new function name to inspect (or cleared existing) and hit enter
function GeminiProfiler:OnInspectNameInputEnter( wndHandler, wndControl, strText )
	self:SetInspectName(strText)
end

---------------------------------------------------------------------------------------------------
-- GeminiProfiler Context Menu Functions
---------------------------------------------------------------------------------------------------

function GeminiProfiler:OnContextInspectBtnSignal( wndHandler, wndControl, eMouseButton )
    -- We stored the function name in the Inspect button
    local strFuncName = self.wndContext:GetData()
    -- Inspecting nothing is counter-productive, so if we have nothing lets do nothing
    if not strFuncName then return end    -- Set name for use in start function
    self:SetInspectName(strFuncName)
    -- No need to set inspect depth here, it would get cleared out when we reset prior to profile start
    --  so instead it gets set in the Start function
    
    -- Get rid of the context menu
    self.wndContext:Destroy()
end

function GeminiProfiler:OnContextFilterBtnSignal( wndHandler, wndControl, eMouseButton )
    -- Get the stored column we clicked on
    local iCol = wndControl:GetData()
    -- Get the stored text from the location we clicked
    local strFilterString = self.wndContext:GetData()
    -- This will be the filter name, if we find one
    local strFilterName = nil

    -- Iterate through the fields, looking for the one we clicked on
    for strFilter, nColumn in pairs(keReportFields) do
        if nColumn == iCol then
            -- The name of the selected field is the name of the filter
            strFilterName = strFilter
            break
        end
    end

    -- If we didn't find a filter then we're done
    if not strFilterName then return end
    -- Set the filter we found with the exact string we clicked on I.E. is at both the start and end
    self.options.filters[strFilterName] = string.format("^%s$",strFilterString)
    -- Get rid of the context menu
    self.wndContext:Destroy()
    -- Update all UI accessible filters and redraw the grid
    self:UpdateFilters()
end

---------------------------------------------------------------------------------------------------
-- GeminiProfiler Tab functions
---------------------------------------------------------------------------------------------------

-- Clicking on a Tab
function GeminiProfiler:OnTabBtnCheck( wndHandler, wndControl, eMouseButton )
    -- Tabs have references to the thing they display
    local wndTabData = wndControl:GetData()
    -- Hide the Grid we were showing before
    self.wndOldTabData:Show(false)
    -- Save a reference to the current Grid
    self.wndOldTabData = wndTabData
    -- Display the current Grid
    wndTabData:Show(true)
end

-- Clicking a selected tab to "uncheck" it
function GeminiProfiler:OnTabBtnUncheck( wndHandler, wndControl, eMouseButton )
    -- You can't uncheck a tab...
    wndControl:SetCheck(true)
end

-- Clicked the Close button for the tab
function GeminiProfiler:OnTabCloseBtnSignal( wndHandler, wndControl, eMouseButton )
    -- If we are showing this tab, show the profile grid
    if wndControl:GetParent():GetData() == self.wndOldTabData then
        local wndProfileBtn = self.wndMain:FindChild("ProfileBtn")
        wndProfileBtn:SetCheck(true)
        self:OnTabBtnCheck(nil, wndProfileBtn)
    end
    -- The Parent of the close button is the tab, its data is the associated data
    --  So we destroy the associated data container
    wndControl:GetParent():GetData():Destroy()
    -- Then we destroy the Tab
    wndControl:GetParent():Destroy()
    -- Then we re-sort the tab container
    self.wndMain:FindChild("TabsBtnContainer"):ArrangeChildrenHorz()
end

-----------------------------------------------------------------------------------------------
-- GeminiProfiler Instance
-----------------------------------------------------------------------------------------------
local GeminiProfilerInst = GeminiProfiler:new()
GeminiProfilerInst:Init()