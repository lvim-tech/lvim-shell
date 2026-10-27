-- The addon registry, held to its own cross-field rules.
--
-- Each entry is a small spec, and the parts have to agree with each other or the launcher works
-- and the RESULT never comes back. Three agreements matter:
--
--   * a FILE-RETURNING addon has to write somewhere Neovim reads -- "$LVIM_SHELL_FILE" for a
--     picked path, or "$LVIM_SHELL_QF" for a grep→quickfix tool, which also has to say
--     `edit_cmd = "qf"` or its rows would be opened as if they were one filename;
--   * `cmd` has to invoke the binary that `bin` gates on, or the availability check guards the
--     wrong program;
--   * every extra tool a pipeline needs belongs in `needs`, because that is what the gate reads.
--
-- 59 entries is well past the point of checking by eye.

local addons = require("lvim-shell.addons")

describe("lvim-shell: the addon registry")

it("there is a registry worth checking", function()
    local n = vim.tbl_count(addons.registry)
    truthy(n > 40, "the registry is the plugin's value; it should be big (" .. n .. ")")
end)

it("every addon declares a binary, a command and a description", function()
    for name, a in pairs(addons.registry) do
        truthy(type(a.bin) == "string" and a.bin ~= "", name .. " has no bin to gate on")
        truthy(type(a.cmd) == "string" and a.cmd ~= "", name .. " has no command to run")
        truthy(type(a.desc) == "string" and a.desc ~= "", name .. " has no description for completion")
    end
end)

it("every command invokes the binary its availability is gated on", function()
    for name, a in pairs(addons.registry) do
        truthy(
            a.cmd:find(a.bin, 1, true),
            ("%s gates on %q but its command never mentions it: %s"):format(name, a.bin, a.cmd)
        )
    end
end)

it("a file-returning addon writes where Neovim will read", function()
    for name, a in pairs(addons.registry) do
        if a.returns_files then
            local file = a.cmd:find("LVIM_SHELL_FILE", 1, true)
            local qf = a.cmd:find("LVIM_SHELL_QF", 1, true)
            truthy(
                file or qf,
                ("%s claims to return files but writes to neither $LVIM_SHELL_FILE nor $LVIM_SHELL_QF: %s"):format(
                    name,
                    a.cmd
                )
            )
        end
    end
end)

it("a grep-to-quickfix addon opens its result as a quickfix list", function()
    for name, a in pairs(addons.registry) do
        if a.cmd:find("LVIM_SHELL_QF", 1, true) then
            eq(
                "qf",
                (a.config or {}).edit_cmd,
                ("%s writes a quickfix file, so its rows must be opened as one"):format(name)
            )
            eq(true, a.returns_files, name .. " writes a result, so it returns one")
        end
    end
end)

it("an addon that writes nowhere does not claim to return files", function()
    for name, a in pairs(addons.registry) do
        local writes = a.cmd:find("LVIM_SHELL_FILE", 1, true) or a.cmd:find("LVIM_SHELL_QF", 1, true)
        if writes then
            eq(true, a.returns_files, name .. " writes a result file but is treated as a pure TUI")
        end
    end
end)

it("every extra tool a pipeline needs is declared, so the gate can check it", function()
    for name, a in pairs(addons.registry) do
        for _, extra in ipairs(a.needs or {}) do
            truthy(type(extra) == "string" and extra ~= "", name .. " has an empty entry in needs")
        end
        -- A command that pipes through another program has to declare it, or the addon offers
        -- itself on a machine where half the pipeline is missing.
        if a.cmd:find("| rg ", 1, true) or a.cmd:find("rg --", 1, true) then
            local declared = a.bin == "rg" or vim.tbl_contains(a.needs or {}, "rg")
            truthy(declared, name .. " runs rg but does not declare it")
        end
    end
end)

it("a mode, where given, is one the launcher understands", function()
    for name, a in pairs(addons.registry) do
        if a.mode ~= nil then
            truthy(a.mode == "float" or a.mode == "split", ("%s has mode %q"):format(name, tostring(a.mode)))
        end
    end
end)

describe("lvim-shell: looking an addon up")

it("a known name resolves and an unknown one does not", function()
    local name = next(addons.registry)
    truthy(addons.get(name))
    eq(nil, addons.get("definitely-not-an-addon"))
end)

it("the available list is sorted and holds only names that exist", function()
    local available = addons.available()
    for i, name in ipairs(available) do
        truthy(addons.registry[name], name .. " is offered but is not in the registry")
        if i > 1 then
            truthy(available[i - 1] < name, "the list has to be sorted: " .. vim.inspect(available))
        end
    end
end)

it("availability needs every declared tool, not just the first", function()
    local was = addons.registry["lvim-shell-spec-addon"]
    addons.registry["lvim-shell-spec-addon"] = {
        bin = "sh", -- certainly present
        needs = { "definitely-not-a-program-xyz" },
        desc = "spec",
        cmd = "sh -c true",
    }
    eq(false, vim.tbl_contains(addons.available(), "lvim-shell-spec-addon"), "a half-present pipeline is not available")
    addons.registry["lvim-shell-spec-addon"] = was
end)

it("running an unknown addon declines instead of raising", function()
    local notified
    local real = vim.notify
    vim.notify = function(msg)
        notified = msg
    end
    local ok = pcall(addons.run, "definitely-not-an-addon")
    vim.notify = real
    truthy(ok, "an unknown name is a message, not an error")
    truthy(notified and notified:match("unknown addon"), tostring(notified))
end)

it("running an addon whose tools are missing names every one of them", function()
    local was = addons.registry["lvim-shell-spec-addon"]
    addons.registry["lvim-shell-spec-addon"] = {
        bin = "definitely-not-a-program-xyz",
        needs = { "also-not-a-program-xyz" },
        desc = "spec",
        cmd = "definitely-not-a-program-xyz",
    }
    local notified
    local real = vim.notify
    vim.notify = function(msg)
        notified = msg
    end
    local ok = pcall(addons.run, "lvim-shell-spec-addon")
    vim.notify = real
    addons.registry["lvim-shell-spec-addon"] = was

    truthy(ok, "a missing binary is a message, not an error")
    truthy(notified, "the refusal has to say something")
    truthy(
        notified:find("definitely-not-a-program-xyz", 1, true) and notified:find("also-not-a-program-xyz", 1, true),
        "a half-reported toolchain sends the user looking for the wrong thing: " .. tostring(notified)
    )
end)
