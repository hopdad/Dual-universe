local transport = require('bus/transport')
local dbs = library.getLinksByClass('DataBankUnit')
system:onEvent('onInputText', function(self, text)
  if text:sub(1, 3) ~= '/b ' then return end
  system.print('@@DUB|1|bot01|A|1|1/1|0000|{"via":"' .. transport.name .. '"}')
end)
unit:onEvent('onTimer', function(self, tag) end)
unit.setTimer('bot', 0.25)
