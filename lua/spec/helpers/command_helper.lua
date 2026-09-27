-- command.build, loaded fresh after fake_archhud.install() clears the bus modules.
return {
    build = function(...)
        return require("autoconf/custom/dufleet/command").build(...)
    end,
}
