--[[
This file is part of Courseplay (https://github.com/Courseplay/courseplay)
Copyright (C) 2018 Peter Vajko

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
]]

Waypoint = {}
Waypoint.__index = Waypoint

-- constructor from the legacy Courseplay waypoint
function Waypoint:new(cpWp, cpIndex)
	local newWp = {}
	setmetatable( newWp, self )
	newWp:set(cpWp, cpIndex)
	return newWp
end

function Waypoint:set(cpWp, cpIndex)
	-- we initialize explicitly, no table copy as we want to have
	-- full control over what is used in this object
	-- can use course waypoints with cx/cz or turn waypoints with posX/posZ
	self.x = cpWp.cx or cpWp.posX or 0
	self.z = cpWp.cz or cpWp.posZ or 0
	self.angle = cpWp.angle or nil
	self.rev = cpWp.rev or false
	self.speed = cpWp.speed
	self.cpIndex = cpIndex or 0
end

function Waypoint:getPosition()
	local y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, self.x, 0, self.z)
	return self.x, y, self.z
end

function Waypoint:getDistanceFromPoint(x, z)
	return courseplay:distance(x, z, self.x, self.z)
end

function Waypoint:getDistanceFromVehicle(vehicle)
	local vx, vy, vz = getWorldTranslation(vehicle.cp.DirectionNode or vehicle.rootNode)
	return self:getDistanceFromPoint(vx, vz)
end

-- a node related to a waypoint
WaypointNode = {}
WaypointNode.MODE_NORMAL = 1
WaypointNode.MODE_LAST_WP = 2
WaypointNode.MODE_SWITCH_DIRECTION = 3
WaypointNode.MODE_SWITCH_TO_FORWARD = 4

WaypointNode.__index = WaypointNode

function WaypointNode:new(name, logChanges)
	local newWaypointNode = {}
	setmetatable( newWaypointNode, self )
	newWaypointNode.logChanges = logChanges
	newWaypointNode.node = courseplay.createNode(name, 0, 0, 0)
	return newWaypointNode
end

function WaypointNode:destroy()
	courseplay.destroyNode(self.node)
end

function WaypointNode:setToWaypoint(course, ix, suppressLog)
	local newIx = math.min(ix, #course.waypoints)
	if newIx ~= self.ix and self.logChanges and not suppressLog then
		courseplay.debugVehicle(12, course.vehicle, 'PPC: %s waypoint index %d', getName(self.node), ix)
	end
	self.ix = newIx
	local x, y, z = course:getWaypointPosition(self.ix)
	setTranslation(self.node, x, y, z)
	setRotation(self.node, 0, math.rad(course.waypoints[self.ix].angle), 0)
end


-- Allow ix > #Waypoints, in that case move the node lookAheadDistance beyond the last WP
function WaypointNode:setToWaypointOrBeyond(course, ix, distance)
	--if self.ix and self.ix > ix then return end
	if ix > #course.waypoints then
		-- beyond the last, so put it on the last for now
		-- but use the direction of the one before the last as the last one's is bogus
		self:setToWaypoint(course, #course.waypoints)
		setRotation(self.node, 0, math.rad(course.waypoints[#course.waypoints - 1].angle), 0)
		-- And now, move ahead a bit.
		local nx, ny, nz = localToWorld(self.node, 0, 0, distance)
		setTranslation(self.node, nx, ny, nz)
		if self.logChanges and self.mode and self.mode ~= WaypointNode.MODE_LAST_WP then
			courseplay.debugVehicle(12, course.vehicle, 'PPC: last waypoint reached, moving node beyond last: %s', getName(self.node))
		end
		self.mode = WaypointNode.MODE_LAST_WP
	elseif course:switchingToReverseAt(ix) or course:switchingToForwardAt(ix) then
		-- just like at the last waypoint, if there's a direction switch, we want to drive up
		-- to the waypoint so we move the goal point beyond it
		-- the angle of ix is already pointing to reverse here
		self:setToWaypoint(course, ix)
		-- turn node back as this is the one before the first reverse, already pointing to the reverse direction.
		local _, yRot, _ = getRotation(self.node)
		setRotation(self.node, 0, yRot + math.pi, 0)
		-- And now, move ahead a bit.
		local nx, ny, nz = localToWorld(self.node, 0, 0, distance)
		setTranslation(self.node, nx, ny, nz)
		if self.logChanges and self.mode and self.mode ~= WaypointNode.MODE_SWITCH_DIRECTION then
			courseplay.debugVehicle(12, course.vehicle, 'PPC: switching direction at %d, moving node beyond it: %s', ix, getName(self.node))
		end
		self.mode = WaypointNode.MODE_SWITCH_DIRECTION
	else
		if self.logChanges and self.mode and self.mode ~= WaypointNode.MODE_NORMAL then
			courseplay.debugVehicle(12, course.vehicle, 'PPC: normal waypoint (not last, no direction change: %s', getName(self.node))
		end
		self.mode = WaypointNode.MODE_NORMAL
		self:setToWaypoint(course, ix)
	end
end

Course = {}
Course.__index = Course

function Course:new(waypoints)
	local newCourse = {}
	setmetatable(newCourse, self)
	-- add waypoints from current vehicle course
	newCourse.waypoints = {}
	for i = 1, #waypoints do
		table.insert(newCourse.waypoints, Waypoint:new(waypoints[i], i))
	end
	newCourse:addWaypointAngles()
	print('course ' .. tostring(#newCourse.waypoints))
	return newCourse
end

-- add missing angles from one waypoint to the other
-- PPC relies on waypoint angles, we need them
function Course:addWaypointAngles()
	for i = 1, #self.waypoints - 1 do
		if not self.waypoints[i].angle then
			local cx, _, cz = self:getWaypointPosition(i)
			local nx, _, nz = self:getWaypointPosition( i + 1)
			-- TODO: fix this weird coordinate system transformation from x/z to x/y
			local dx, dz = nx - cx, -nz - (-cz)
			local angle = toPolar(dx, dz)
			-- and now back to x/z
			self.waypoints[i].angle = courseGenerator.toCpAngle(angle)
		end
	end
	if not self.waypoints[#self.waypoints].angle then
		self.waypoints[#self.waypoints].angle = self.waypoints[#self.waypoints - 1].angle
	end
end

function Course:setCurrentWaypointIx(ix)
	self.currentWaypoint = ix
end

function Course:getCurrentWaypointIx()
	return self.currentWaypoint
end

function Course:isReverseAt(ix)
	return self.waypoints[ix].rev
end

function Course:switchingDirectionAt(ix) 
	return self:switchingToForwardAt(ix) or self:switchingToReverseAt(ix)
end

function Course:switchingToReverseAt(ix)
	return (not self:isReverseAt(ix)) and self:isReverseAt(math.min(ix + 1, #self.waypoints))
end

function Course:switchingToForwardAt(ix)
	--print( tostring(self.waypoints[ix].rev) .. tostring(math.min(ix + 1, #self.waypoints)))
	return self:isReverseAt(ix) and not self:isReverseAt(math.min(ix + 1, #self.waypoints))
end

function Course:getWaypointPosition(ix)
	local x, z = self.waypoints[ix].x, self.waypoints[ix].z
	local y = 0
	if g_currentMission then
		y = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, x, 0, z)
	end
	return x, y, z
end

-- distance between (px,pz) and the ix waypoint
function Course:getDistanceBetweenPointAndWaypoint(px, pz, ix)
	return self.waypoints[ix]:getDistanceFromPoint(px, pz)
end

function Course:getDistanceBetweenVehicleAndWaypoint(vehicle, ix)
	return self.waypoints[ix]:getDistanceFromVehicle(vehicle)
end

function Course:getWaypointAngleDeg(ix)
	return self.waypoints[ix].angle
end

--- Get the average speed setting across n waypoints starting at ix
function Course:getAverageSpeed(ix, n)
	local total, count = 0, 0
	for i = ix - 1, ix + n -1 do
		local index = self:getIxRollover(i)
		if self.waypoints[index].speed ~= nil then
			total = total + self.waypoints[index].speed
			count = count + 1
		end
	end
	return count > 0 and (total / count) or nil
end

function Course:getIxRollover(ix)
	if ix > #self.waypoints then
		return ix - #self.waypoints
	elseif ix < 1 then
		return #self.waypoints - ix
	end
	return ix
end

function Course:print()
	for i = 1, #self.waypoints do
		local p = self.waypoints[i]
		print(string.format('%d: x=%.1f y=%.1f a=%.1f r=%s', i, p.x, p.z, p.angle, tostring(p.rev)))
	end
end