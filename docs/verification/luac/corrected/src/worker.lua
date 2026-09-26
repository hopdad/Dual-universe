local transport = require('bus/transport')
rx:onEvent('onReceived', function(self, channel, message) tx.send('dub-ack', message) end)
