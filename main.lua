--------------------------------------------------------------------------------
-- Pixel Normal Generator — Aseprite extension entry point.
-- Registers the menu command and loads the sibling modules.
--------------------------------------------------------------------------------

local NM, UI

local function loadModules(plugin)
  local base = plugin.path
  NM = dofile(app.fs.joinPath(base, "normalmap.lua"))
  UI = dofile(app.fs.joinPath(base, "ui.lua"))
end

function init(plugin)
  loadModules(plugin)

  plugin:newCommand{
    id = "PixelNormalGenerator",
    title = "Pixel Normal Generator...",
    group = "edit_fx",
    onenabled = function() return app.sprite ~= nil end,
    onclick = function()
      if app.apiVersion < 21 then
        app.alert{ title = "Pixel Normal Generator",
          text = { "This extension needs Aseprite v1.3 or newer",
                   "(canvas preview / GraphicsContext API)." } }
        return
      end
      if not app.sprite then
        app.alert{ title = "Pixel Normal Generator", text = "Open a sprite first." }
        return
      end
      UI.open(plugin, NM)
    end,
  }
end

function exit(plugin) end -- nothing to clean up
