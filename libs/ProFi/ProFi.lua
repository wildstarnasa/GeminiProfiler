--[[
	###############################################################################################################
	#####  ProFi is created by Luke Perkin 2012 under the MIT Licence, www.locofilm.co.uk
	#####  Version 1.3. Get the most recent version at this gist: https://gist.github.com/2838755
	###############################################################################################################
	ProFi v1.3, by Luke Perkin 2012. MIT Licence http://www.opensource.org/licenses/mit-license.php.
	Modified for WildStar by Sinaloit 2014

	Example:
		ProFi = require 'ProFi'
		ProFi:start()
		some_function()
		another_function()
		coroutine.resume( some_coroutine )
		ProFi:stop()
		table = ProFi:createReport()
 
	API:
	*Arguments are specified as: type/name/default.
		ProFi:start( string/param/nil )
		ProFi:stop()
		ProFi:checkMemory( number/interval/0, string/note/'' )
		ProFi:createReport()
		ProFi:reset()
		ProFi:setHookCount( number/hookCount/0 )
		ProFi:setGetTimeMethod( function/getTimeMethod/os.clock )
		ProFi:setInspect( string/methodName, number/levels/1 )
]]
 
-----------------------
-- Locals:
-----------------------
 
local MAJOR, MINOR = "Gemini:ProFi-1.3", 4
local ProFi = {}
local onDebugHook, sortByDurationDesc, sortByCallCount, getTime
local DEFAULT_DEBUG_HOOK_COUNT = 0
local DEFAULT_DEBUG_MASK	   = "cr"
local FORMAT_TITLE             = "%-50.50s: %-40.40s: %-20s"
local FORMAT_LINENUM           = "%4i"
-----------------------
-- Public Methods:
-----------------------
 
--[[
	Starts profiling any method that is called between this and ProFi:stop().
	Pass the parameter 'once' to so that this methodis only run once.
	Example: 
		ProFi:start( 'once' )
]]
function ProFi:start( param )
	if param == 'once' then
		if self:shouldReturn() then
			return
		else
			self.should_run_once = true
		end
	end
	self.has_started  = true
	self.has_finished = false
	self:resetReports( self.reports )
	self:startHooks()
	self.startTime = getTime()
end
 
--[[
	Stops profiling.
]]
function ProFi:stop()
	if self:shouldReturn() then 
		return
	end
	self.stopTime = getTime()
	self:stopHooks()
	self.has_finished = true
end
 
function ProFi:checkMemory( interval, note )
	local time = getTime()
	local interval = interval or 0
	if self.lastCheckMemoryTime and time < self.lastCheckMemoryTime + interval then
		return
	end
	self.lastCheckMemoryTime = time
	local memoryReport = {
		['time']   = time;
		['memory'] = collectgarbage('count');
		['note']   = note or '';
	}
	table.insert( self.memoryReports, memoryReport )
	self:setHighestMemoryReport( memoryReport )
	self:setLowestMemoryReport( memoryReport )
end
 
--[[
	Writes the profile report to a table that this function returns.
]]
function ProFi:createReport()
	local tOutput = {}
	if #self.reports > 0 or #self.memoryReports > 0 then
		self:sortReportsWithSortMethod( self.reports, self.sortMethod )
		self:writeReportsToTable( tOutput )
	end
	return tOutput
end

--[[
	Resets any profile information stored.
]]
function ProFi:reset()
	self.reports = {}
	self.reportsByFunc  = {}
	self.memoryReports  = {}
	self.highestMemoryReport = nil
	self.lowestMemoryReport  = nil
	self.has_started  = false
	self.has_finished = false
	self.should_run_once = false
	self.lastCheckMemoryTime = nil
	self.debugMask = self.debugMask or DEFAULT_DEBUG_MASK
	self.hookCount = self.hookCount or DEFAULT_DEBUG_HOOK_COUNT
	self.sortMethod = self.sortMethod or sortByDurationDesc
	self.inspect = nil
end
 
--[[
	Set how often a hook is called.
	See http://pgl.yoyo.org/luai/i/debug.sethook for information.
	Param: [hookCount:number] if 0 ProFi counts every time a function is called.
	if 2 ProFi counts every other 2 function calls.
	
	(that's not true btw)
]]
function ProFi:setHookCount( hookCount )
	self.hookCount = tonumber(hookCount)
end 

--[[
	Set the debug mask.
	See http://pgl.yoyo.org/luai/i/debug.sethook for information.
	Param: [debugMask:string] where string can be any of the letters c r or l
	or combination thereof
]]
function ProFi:setDebugMask( debugMask )
	self.debugMask = debugMask
end
 
--[[
	Set how the report is sorted when written to file.
	Param: [sortType:string] either 'duration' or 'count'.
	'duration' sorts by the time a method took to run.
	'count' sorts by the number of times a method was called.
]]
function ProFi:setSortMethod( sortType )
	if sortType == 'duration' then
		self.sortMethod = sortByDurationDesc
	elseif sortType == 'count' then
		self.sortMethod = sortByCallCount
	end
end
 
--[[
	By default the getTime method is os.clock (CPU time),
	If you wish to use other time methods pass it to this function.
	Param: [getTimeMethod:function]
]]
function ProFi:setGetTimeMethod( getTimeMethod )
	getTime = getTimeMethod
end
 
--[[
	Allows you to inspect a specific method.
	Will write to the report a list of methods that
	call this method you're inspecting, you can optionally
	provide a levels parameter to traceback a number of levels.
	Params: [methodName:string] the name of the method you wish to inspect.
	        [levels:number:optional] the amount of levels you wish to traceback, defaults to 1.
]]
function ProFi:setInspect( methodName, levels )
	if self.inspect then
		self.inspect.methodName = methodName
		self.inspect.levels = levels or 1
	else
		self.inspect = {
			['methodName'] = methodName;
			['levels'] = levels or 1;
		}
	end
end
 
-----------------------
-- Package methods:
-----------------------
 
function ProFi:OnLoad()
	ProFi:reset()
end

function ProFi:OnDependencyError(strDep, strError)
	-- if you don't care about this dependency, return true.
	-- if you return false, or don't define this function
	-- any Addons/Packages that list you as a dependency
	-- will also receive a dependency error
	return false
end
 
-----------------------
-- Implementations methods:
-----------------------
 
function ProFi:shouldReturn( )
	return self.should_run_once and self.has_finished
end
 
function ProFi:getFuncReport( funcInfo )
	local funcReport = self.reportsByFunc[ funcInfo.func ]
	if not funcReport then
		funcReport = self:createFuncReport( funcInfo )
		self.reportsByFunc[ funcInfo.func ] = funcReport
		table.insert( self.reports, funcReport )
	end
	return funcReport
end

function ProFi:createFuncReport( funcInfo )
	local tDetailedInfo = debug.getinfo(5, 'nS')
	local funcReport = {
		['name']        = tDetailedInfo.name or 'anonymous';
		['namewhat']	= tDetailedInfo.namewhat;
		['source']		= tDetailedInfo.short_src or 'C_FUNC';
		['lineDefined']	= tDetailedInfo.linedefined or 0;
		['count'] 		= 0;
		['timer']       = 0;
	}
	return funcReport
end
 
function ProFi:startHooks()
	if self.debugMask ~= nil and self.debugMask ~= "" then
		debug.sethook( onDebugHook, self.debugMask )
	elseif self.hookCount > 0 then
		-- "count" event hook
		debug.sethook( onDebugHook, '', self.hookCount )
	end
end
 
function ProFi:stopHooks()
	debug.sethook()
end
 
function ProFi:sortReportsWithSortMethod( reports, sortMethod )
	if reports then
		table.sort( reports, sortMethod )
	end
end
 
function ProFi:writeReportsToTable( tOutput )
	if #self.reports > 0 then
		self:writeProfilingReportsToTable( self.reports, tOutput )
	end
	if #self.memoryReports > 0 then
		self:writeMemoryReportsToTable( self.memoryReports, tOutput )
	end
end
 
function ProFi:writeProfilingReportsToTable( reports, tOutput )
	tOutput.totalTime = self.stopTime - self.startTime
	tOutput.reports = {}
 	for i, funcReport in ipairs( reports ) do
 		tOutput.reports[i] = funcReport
 		tOutput.reports[i].relTime = (funcReport.timer / tOutput.totalTime) * 100
		if funcReport.inspections then
			tOutput.reports[i].inspections = self:sortInspectionsIntoList( funcReport.inspections )
		end
	end
end
 
function ProFi:writeMemoryReportsToTable( reports, tOutput )
	self:writeHighestMemoryReportToTable( tOutput )
	self:writeLowestMemoryReportToTable( tOutput )
	tOutput.memoryReports = {}
	for i, memoryReport in ipairs( reports ) do
		tOutput.memoryReports[i] = {}
		tOutput.memoryReports[i].time = memoryReport.time
		tOutput.memoryReports[i].kbytes = memoryReport.memory
		tOutput.memoryReports[i].mbytes = memoryReport.memory/1024
		tOutput.memoryReports[i].note = memoryReport.note
	end
end
 
function ProFi:writeHighestMemoryReportToTable( tOutput )
	tOutput.highestMemoryReport = {}
	tOutput.highestMemoryReport.time = self.highestMemoryReport.time
	tOutput.highestMemoryReport.kbytes = self.highestMemoryReport.memory
	tOutput.highestMemoryReport.mbytes = self.highestMemoryReport.memory/1024
	tOutput.highestMemoryReport.note = self.highestMemoryReport.note
end
 
function ProFi:writeLowestMemoryReportToTable( tOutput )
	tOutput.lowestMemoryReport = {}
	tOutput.lowestMemoryReport.time = self.lowestMemoryReport.time
	tOutput.lowestMemoryReport.kbytes = self.lowestMemoryReport.memory
	tOutput.lowestMemoryReport.mbytes = self.lowestMemoryReport.memory/1024
	tOutput.lowestMemoryReport.note = self.lowestMemoryReport.note
end
 
function ProFi:sortInspectionsIntoList( inspections )
	local inspectionsList = {}
	for k, inspection in pairs(inspections) do
		inspectionsList[#inspectionsList+1] = inspection
		if inspection.children ~= nil then
			inspectionsList[#inspectionsList].children = self:sortInspectionsIntoList(inspection.children)
		end
	end
	table.sort( inspectionsList, sortByCallCount )
	return inspectionsList
end
 
function ProFi:resetReports( reports )
	for i, report in ipairs( reports ) do
		report.timer = 0
		report.count = 0
		report.inspections = nil
	end
end
 
function ProFi:shouldInspect( funcReport )
	return self.inspect and self.inspect.methodName == funcReport.name
end
 
function ProFi:getInspectionsFromReport( funcReport )
	local inspections = funcReport.inspections
	if not inspections then
		inspections = {}
		funcReport.inspections = inspections
	end
	return inspections
end
 
function ProFi:getInspectionWithKeyFromInspections( key, inspections )
	local inspection = inspections[key]
	if not inspection then
		inspection = {
			['count']  = 0;
		}
		inspections[key] = inspection
	end
	return inspection
end
 
function ProFi:doInspection( inspect, funcReport )
	local tInspections = self:getInspectionsFromReport( funcReport )
	local levels = 5 + inspect.levels
	local currentLevel = 5
	while currentLevel < levels do
		local tFuncRef = debug.getinfo( currentLevel, 'f' )
		if tFuncRef then
			-- If this function has exemptions and it is exempt from profiling during inspection break out
			if ProFi.profilingExempt[tFuncRef.func] and ProFi.profilingExempt[tFuncRef.func] > 1 then
				break
			end
			local inspection = self:getInspectionWithKeyFromInspections( tFuncRef.func, tInspections )
			if inspection.count == 0 then -- New inspection, get more detailed information
				local funcInfo = debug.getinfo( currentLevel, 'nS' )
				inspection.source = funcInfo.short_src or 'C_FUNC'
				inspection.name = funcInfo.name or 'anonymous'
				inspection.lineDefined = funcInfo.linedefined
				inspection.children = {}
			end
			inspection.count = inspection.count + 1
			tInspections = inspection.children
			currentLevel = currentLevel + 1
		else
			break
		end
	end
end

function ProFi:onInstructionCall( funcInfo )
	local funcReport = ProFi:getFuncReport( funcInfo )
	funcReport.callTime = getTime()
	funcReport.count = funcReport.count + 1
	if self:shouldInspect( funcReport ) then
		self:doInspection( self.inspect, funcReport )
	end
end

function ProFi:onFunctionCall( funcInfo )
	local funcReport = ProFi:getFuncReport( funcInfo )
	funcReport.callTime = getTime()
	funcReport.count = funcReport.count + 1
	if self:shouldInspect( funcReport ) then
		self:doInspection( self.inspect, funcReport )
	end
end
 
function ProFi:onFunctionReturn( funcInfo )
	local funcReport = ProFi:getFuncReport( funcInfo )
	if funcReport.callTime then
		funcReport.timer = funcReport.timer + (getTime() - funcReport.callTime)
	end
end
 
function ProFi:setHighestMemoryReport( memoryReport )
	if not self.highestMemoryReport then
		self.highestMemoryReport = memoryReport
	else
		if memoryReport.memory > self.highestMemoryReport.memory then
			self.highestMemoryReport = memoryReport
		end
	end
end
 
function ProFi:setLowestMemoryReport( memoryReport )
	if not self.lowestMemoryReport then
		self.lowestMemoryReport = memoryReport
	else
		if memoryReport.memory < self.lowestMemoryReport.memory then
			self.lowestMemoryReport = memoryReport
		end
	end
end


function ProFi:addExemption(funcRef, bInspection)
	if bInspection == true then
		ProFi.profilingExempt[funcRef] = 2
	else
		ProFi.profilingExempt[funcRef] = 1
	end
end

function ProFi:removeExemption(funcRef)
	if ProFi.profilingExempt[funcRef] and ProFi.profilingExempt[funcRef] < 3 then
		ProFi.profilingExempt[funcRef] = nil
	end
end
-----------------------
-- Local Functions:
-----------------------
 
getTime = os.clock
 
onDebugHook = function( hookType )
	local funcInfo = debug.getinfo( 2, 'f')
	if ProFi.profilingExempt[funcInfo.func] then return end
	if hookType == "call" then
		ProFi:onFunctionCall( funcInfo )
	elseif hookType == "return" then
		ProFi:onFunctionReturn( funcInfo )
	elseif hookType == "count" then
		ProFi:onInstructionCall( funcInfo )
	end
end
 
sortByDurationDesc = function( a, b )
	return a.timer > b.timer
end
 
sortByCallCount = function( a, b )
	return a.count > b.count
end

--[[ 
	Functions that will not be profiled:
		1 - not profiled
		2 - not profiled on inspections
		3 - as above but this exemption cannot be removed
]]
ProFi.profilingExempt = {
	[onDebugHook] 		= 3,
	[debug.sethook] 	= 3,
}
-----------------------
-- Return Module:
-----------------------
Apollo.RegisterPackage(ProFi, MAJOR, MINOR, {})
--ProFi = nil