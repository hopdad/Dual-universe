local jsonenc = require("autoconf/custom/dufleet/jsonenc")
local json = require("dkjson")

describe("jsonenc", function()
    it("sorts object keys", function()
        local text = jsonenc.encode({ e = "x", a = 1, b = { d = false, c = true } })
        assert.are.equal('{"a":1,"b":{"c":true,"d":false},"e":"x"}', text)
    end)

    it("writes arrays, empty tables and numbers", function()
        assert.are.equal("[1,2.5,-3]", jsonenc.encode({ 1, 2.5, -3 }))
        assert.are.equal("{}", jsonenc.encode({}))
        assert.are.equal("42", jsonenc.encode(42.0))
        assert.are.equal("0.1", jsonenc.encode(0.1))
        assert.are.equal("1e-05", jsonenc.encode(0.00001))
        assert.are.equal("null", jsonenc.encode(0 / 0))
        assert.are.equal("null", jsonenc.encode(math.huge))
        assert.are.equal('{"1":2}', jsonenc.encode({ [1] = nil, ["1"] = 2 }))
    end)

    it("escapes quotes, backslashes and control characters", function()
        local s = 'a"b\\c\nd\te\1f|g\127'
        local text = jsonenc.encode({ s = s })
        assert.are.equal('{"s":"a\\"b\\\\c\\nd\\te\\u0001f|g\\u007f"}', text)
        assert.are.equal(s, json.decode(text).s)
    end)

    it("round-trips through a JSON decoder", function()
        local v = { w = { -123456.5, 98765.25, 42 }, st = "goto:travel", fuel = { atmo = 0.82 }, ok = true, msg = "日本" }
        assert.are.same(v, json.decode(jsonenc.encode(v)))
    end)

    it("refuses what JSON cannot hold", function()
        assert.has_error(function() jsonenc.encode({ [true] = 1 }) end)
        assert.has_error(function() jsonenc.encode(print) end)
        local t = {}
        t.self = t
        assert.has_error(function() jsonenc.encode(t) end)
    end)

    it("clips on UTF-8 character boundaries", function()
        assert.are.equal("abc", jsonenc.clip("abc", 5))
        assert.are.equal("ab", jsonenc.clip("abc", 2))
        assert.are.equal("a", jsonenc.clip("aé", 2)) -- é is two bytes
        assert.are.equal("aé", jsonenc.clip("aé", 3))
        assert.are.equal("", jsonenc.clip("日本", 2))
        assert.are.equal("日", jsonenc.clip("日本", 5))
    end)
end)
