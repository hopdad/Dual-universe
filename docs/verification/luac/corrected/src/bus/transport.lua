local T = {}
---@if transport "optical"
T.name = 'optical-frame'
---@else
T.name = 'log-print'
---@end
return T
