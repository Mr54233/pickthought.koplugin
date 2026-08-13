local Mixin = {}

function Mixin.apply(target, modules)
    for _i, methods in ipairs(modules) do
        for name, method in pairs(methods) do
            assert(rawget(target, name) == nil,
                "duplicate plugin method: " .. tostring(name))
            target[name] = method
        end
    end
    return target
end

return Mixin
