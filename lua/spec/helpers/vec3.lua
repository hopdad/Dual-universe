-- A small stand-in for the game's cpml vec3, enough for ArchHUD's atlas and autopilot code
-- in spec/archhud_contract_spec.lua: construction from numbers, lists or {x, y, z} tables,
-- arithmetic, and the methods ArchHUD calls. A vec3 is a table with fields x, y and z.

local vec3 = {}
local mt = { __index = vec3 }

local function new(x, y, z)
    if type(x) == "table" then
        x, y, z = x.x or x[1], x.y or x[2], x.z or x[3]
    end
    return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, mt)
end

local function isvec(v)
    return type(v) == "table" and getmetatable(v) == mt
end

mt.__add = function(a, b) return new(a.x + b.x, a.y + b.y, a.z + b.z) end
mt.__sub = function(a, b) return new(a.x - b.x, a.y - b.y, a.z - b.z) end
mt.__unm = function(a) return new(-a.x, -a.y, -a.z) end
mt.__mul = function(a, b)
    if isvec(a) and isvec(b) then return new(a.x * b.x, a.y * b.y, a.z * b.z) end
    if isvec(a) then return new(a.x * b, a.y * b, a.z * b) end
    return new(a * b.x, a * b.y, a * b.z)
end
mt.__div = function(a, b) return new(a.x / b, a.y / b, a.z / b) end
mt.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
mt.__tostring = function(a) return string.format("(%g,%g,%g)", a.x, a.y, a.z) end

function vec3.len2(a) return a.x * a.x + a.y * a.y + a.z * a.z end
function vec3.len(a) return math.sqrt(a:len2()) end
function vec3.dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
function vec3.cross(a, b) return new(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
function vec3.dist(a, b) return (a - b):len() end
function vec3.unpack(a) return a.x, a.y, a.z end
function vec3.clone(a) return new(a.x, a.y, a.z) end
function vec3.normalize(a)
    local l = a:len()
    if l == 0 then return new(0, 0, 0) end
    return a / l
end
function vec3.project_on(a, b) return b * (a:dot(b) / b:len2()) end
function vec3.project_on_plane(a, n) return a - a:project_on(n) end

vec3.new = new
vec3.zero = new(0, 0, 0)
vec3.unit_x = new(1, 0, 0)
vec3.unit_y = new(0, 1, 0)
vec3.unit_z = new(0, 0, 1)

return setmetatable(vec3, { __call = function(_, ...) return new(...) end })
