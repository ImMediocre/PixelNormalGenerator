--------------------------------------------------------------------------------
-- Pixel Normal Generator — dialog, live movable-light preview, generation.
-- Loaded by main.lua via dofile; returns a module with UI.open(plugin, NM).
--------------------------------------------------------------------------------

local UI = {}

local pc = app.pixelColor
local rgba = pc.rgba
local rgbaR, rgbaG, rgbaB, rgbaA = pc.rgbaR, pc.rgbaG, pc.rgbaB, pc.rgbaA
local floor, sqrt, max, min = math.floor, math.sqrt, math.max, math.min

local MODE_ALPHA = "Normal from Alpha (silhouette)"
local MODE_LUMA  = "Normal from Luminance / Channel"
local MODE_PAINT = "Paint Height Layer"

local OUT_LAYER  = "New layer"
local OUT_SPRITE = "New sprite"
local FR_CURRENT = "Current frame"
local FR_ALL     = "All frames"
local CONTENT_NORMAL = "Normal map"
local CONTENT_HEIGHT = "Height map"
local CONTENT_BOTH   = "Normal + Height"

local PREVIEW_MAX = 128 -- preview is relit on every mouse move; cap its resolution

local function clampi(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi else return v end
end

local function frameNumber(fr)
  if type(fr) == "number" then return fr end
  return fr.frameNumber
end

-- Per-color-mode RGBA reader so we can flatten a single layer's cel correctly.
local function makeReader(image, palette)
  local mode = image.colorMode
  if mode == ColorMode.RGB then
    return function(px) return rgbaR(px), rgbaG(px), rgbaB(px), rgbaA(px) end
  elseif mode == ColorMode.GRAYSCALE then
    return function(px) local v = pc.grayaV(px); return v, v, v, pc.grayaA(px) end
  else -- INDEXED
    local transparent = image.spec.transparentColor
    return function(px)
      if px == transparent then return 0, 0, 0, 0 end
      local c = palette:getColor(px)
      return c.red, c.green, c.blue, c.alpha
    end
  end
end

local function findCel(layer, fr)
  local n = frameNumber(fr)
  for _, c in ipairs(layer.cels) do
    if c.frameNumber == n then return c end
  end
  return nil
end

-- Collect all image layers (recursively through groups) as {name=, layer=}.
local function collectImageLayers(sprite)
  local list = {}
  local function walk(layers)
    for _, ly in ipairs(layers) do
      if ly.isGroup then
        walk(ly.layers)
      elseif ly.isImage then
        list[#list + 1] = ly
      end
    end
  end
  walk(sprite.layers)
  return list
end

function UI.open(plugin, NM)
  local sprite = app.sprite
  if not sprite then return end

  -- Display names of the layers we generate.
  local OUTPUT_NORMAL = "Normal Map"
  local OUTPUT_HEIGHT = "Height Map"
  -- We identify OUR layers by a plugin-scoped custom property (a TAG), never by
  -- name — so a user's own layer that happens to be called "Normal Map" is never
  -- adopted or overwritten. The tag persists in the file, so reuse works across
  -- runs and reopens; looking it up each time avoids stale Layer references.
  local PLUGIN_KEY = "immediocre/pixel-normal-generator"

  local function tagKind(ly) -- "normal" | "height" | nil (only layers we made)
    local ok, v = pcall(function() return ly.properties(PLUGIN_KEY).output end)
    return ok and v or nil
  end

  local function markOurs(ly, kind)
    pcall(function() ly.properties(PLUGIN_KEY).output = kind end)
  end

  -- Find the layer WE generated for `kind` anywhere in the sprite (nil if none).
  local function findOurLayer(kind)
    local found
    local function walk(layers)
      for _, ly in ipairs(layers) do
        if ly.isGroup then walk(ly.layers)
        elseif ly.isImage and tagKind(ly) == kind then found = ly end
      end
    end
    pcall(function() walk(sprite.layers) end)
    return found
  end

  -- Our existing output layers — excluded from the height composite so a prior
  -- result never feeds back into a new one.
  local function outputLayers()
    local t = {}
    local n = findOurLayer("normal"); if n then t[#t + 1] = n end
    local h = findOurLayer("height"); if h then t[#t + 1] = h end
    return t
  end

  local prefs = plugin.preferences
  local function getp(k, d)
    local v = prefs[k]
    if v == nil then return d end
    return v
  end

  -- ----- frame rendering helpers --------------------------------------------
  -- Render the frame composite into a fresh RGB image with `hideList` layers
  -- temporarily hidden. Visibility is ALWAYS restored, even if drawSprite throws.
  local function renderHiding(fr, hideList)
    local saved = {}
    local img = Image(sprite.width, sprite.height, ColorMode.RGB)
    local ok, err = pcall(function()
      for i = 1, #hideList do
        saved[i] = hideList[i].isVisible
        hideList[i].isVisible = false
      end
      img:drawSprite(sprite, fr)
    end)
    for i = 1, #hideList do -- always restore what we changed, even on error
      if saved[i] ~= nil then pcall(function() hideList[i].isVisible = saved[i] end) end
    end
    if not ok then error(err) end
    return img
  end

  local function renderFrame(fr) -- composite of visible layers, minus our outputs
    return renderHiding(fr, outputLayers())
  end

  local function renderCompositeExcluding(excludeLayer, fr) -- composite minus a layer (+ our outputs)
    local hide = outputLayers()
    hide[#hide + 1] = excludeLayer
    return renderHiding(fr, hide)
  end

  local function renderLayerToRGB(layer, fr) -- one layer's cel, palette-aware, RGB
    local img = Image(sprite.width, sprite.height, ColorMode.RGB)
    local cel = findCel(layer, fr)
    if not cel then return img end
    local ci = cel.image
    local px, py = cel.position.x, cel.position.y
    -- Single-palette sprites (and RGB/grayscale height layers) are exact here;
    -- an indexed sprite with multiple frame-range palettes falls back to [1].
    local reader = makeReader(ci, sprite.palettes[1])
    local W, H = sprite.width, sprite.height
    for it in ci:pixels() do
      local r, g, b, a = reader(it())
      if a > 0 then
        local x, y = px + it.x, py + it.y
        if x >= 0 and x < W and y >= 0 and y < H then
          img:drawPixel(x, y, rgba(r, g, b, a))
        end
      end
    end
    return img
  end

  -- ----- state ---------------------------------------------------------------
  local imageLayers = {} -- never offer OUR OWN generated layers as a height source
  for _, ly in ipairs(collectImageLayers(sprite)) do
    if not tagKind(ly) then imageLayers[#imageLayers + 1] = ly end
  end
  local layerNames, layerByLabel = {}, {}
  for i, ly in ipairs(imageLayers) do
    local label = i .. ": " .. ly.name -- index prefix keeps duplicate names distinct
    layerNames[i] = label
    layerByLabel[label] = ly
  end

  local dlg
  local normalImg                 -- preview-resolution normal map for the current frame
  local litImg                    -- downscaled, relit preview image
  local NX, NY, NZ, PA            -- decoded preview-resolution normal + alpha
  local pw, ph = 1, 1             -- preview-cache dimensions
  local lx, ly                    -- light position in preview-pixel space
  local pvOx, pvOy, pvDs          -- last canvas layout (set in onpaint)
  local shown = false

  local function currentHeightLayer()
    return layerByLabel[dlg.data.heightLayer] or imageLayers[1]
  end

  local function currentOpts()
    local d = dlg.data
    local mode = d.mode
    local source, alphaAware
    if mode == MODE_ALPHA then
      source, alphaAware = "Alpha", false
    elseif mode == MODE_PAINT then
      source, alphaAware = "Luminance", true
    else
      source, alphaAware = d.source, true
    end
    return {
      source        = source,
      alphaAware    = alphaAware,
      denoise       = d.denoise,
      blurRadius    = d.blur,
      blurPasses    = d.passes,
      strength      = d.strength / 10,
      step          = d.step,
      posterize     = d.posterize,
      invertX       = d.invertX,
      invertY       = d.invertY,
      preserveAlpha = d.preserveAlpha,
      rim           = d.rim,
      rimStrength   = d.rimStrength / 50,
      rimWidth      = d.rimWidth,
    }
  end

  -- Build height + alpha inputs for a frame according to the active mode.
  local function inputsFor(fr)
    if dlg.data.mode == MODE_PAINT then
      local hl = currentHeightLayer()
      if hl then
        local alphaImg = renderCompositeExcluding(hl, fr)
        return renderLayerToRGB(hl, fr), alphaImg
      end
      local img = renderFrame(fr)
      return img, img
    end
    local img = renderFrame(fr)
    return img, img
  end

  -- ----- preview cache + lighting -------------------------------------------
  local function buildPreviewCache(nimg, aimg)
    local w, h = nimg.width, nimg.height
    local sf = 1
    local m = max(w, h)
    if m > PREVIEW_MAX then sf = PREVIEW_MAX / m end
    pw = max(1, floor(w * sf))
    ph = max(1, floor(h * sf))
    local scaleX, scaleY = w / pw, h / ph
    NX, NY, NZ, PA = {}, {}, {}, {}
    for py = 0, ph - 1 do
      local sy = min(h - 1, floor((py + 0.5) * scaleY))
      for px = 0, pw - 1 do
        local sx = min(w - 1, floor((px + 0.5) * scaleX))
        local nv = nimg:getPixel(sx, sy)
        local i = py * pw + px + 1
        NX[i] = (rgbaR(nv) - 128) / 127
        NY[i] = (rgbaG(nv) - 128) / 127
        NZ[i] = (rgbaB(nv) - 128) / 127
        PA[i] = rgbaA(aimg:getPixel(sx, sy)) -- silhouette from the art alpha
      end
    end
    if (not litImg) or litImg.width ~= pw or litImg.height ~= ph then
      litImg = Image(pw, ph, ColorMode.RGB)
    end
    if (not lx) or lx > pw - 1 or ly > ph - 1 then
      lx, ly = pw * 0.5, ph * 0.35
    end
  end

  local function relight()
    if not litImg then return end
    local lz = dlg.data.lightHeight
    local ambient = 0.14
    local lcr, lcg, lcb = 255, 238, 204 -- warm "lantern" tint
    for it in litImg:pixels() do
      local px, py = it.x, it.y
      local i = py * pw + px + 1
      if PA[i] == 0 then
        local c = (((px // 8) + (py // 8)) % 2 == 0) and 38 or 52
        it(rgba(c, c, c, 255))
      else
        local nx, ny, nz = NX[i], NY[i], NZ[i]
        local dx = lx - px
        local dy = -(ly - py) -- screen y is down; normals are y-up
        local dz = lz
        local ll = sqrt(dx * dx + dy * dy + dz * dz)
        if ll < 1e-6 then ll = 1 end
        local d = (nx * dx + ny * dy + nz * dz) / ll
        if d < 0 then d = 0 end
        local lit = ambient + (1 - ambient) * d
        local r = floor(lit * lcr); if r > 255 then r = 255 end
        local g = floor(lit * lcg); if g > 255 then g = 255 end
        local b = floor(lit * lcb); if b > 255 then b = 255 end
        it(rgba(r, g, b, 255))
      end
    end
  end

  -- Nearest-neighbour downscale of an RGB image so its long edge <= maxDim.
  local function downscaleRGB(img, maxDim)
    local w, h = img.width, img.height
    if max(w, h) <= maxDim then return img end
    local sf = maxDim / max(w, h)
    local nw, nh = max(1, floor(w * sf)), max(1, floor(h * sf))
    local out = Image(nw, nh, ColorMode.RGB)
    local sx, sy = w / nw, h / nh
    for it in out:pixels() do
      it(img:getPixel(min(w - 1, floor((it.x + 0.5) * sx)),
                      min(h - 1, floor((it.y + 0.5) * sy))))
    end
    return out
  end

  -- Always resolve the working frame against the CAPTURED sprite, never a
  -- foreign sprite's app.frame (the dialog is non-modal; the active sprite can
  -- change, e.g. after a New-sprite generate).
  local function workFrame()
    local f = app.frame
    local n = (f and f.frameNumber) or 1
    return sprite.frames[clampi(n, 1, #sprite.frames)]
  end

  -- Cached preview inputs. The flattened height/alpha composite depends only on
  -- the frame, mode and height layer — NOT on the numeric slider params — so we
  -- rebuild it only when that key changes and reuse it for pure-param tweaks.
  local cacheKey, cacheH, cacheA, cacheSf

  local function rebuild(doRepaint)
    if app.sprite ~= sprite then return end -- preview only while our sprite is active
    local fr = workFrame()
    local key = table.concat({ fr.frameNumber, dlg.data.mode, tostring(dlg.data.heightLayer) }, "|")
    if key ~= cacheKey or not cacheH then
      local heightImg, alphaImg = inputsFor(fr)
      -- The preview only needs <= PREVIEW_MAX px; downscale the inputs so the
      -- interpreted-Lua pipeline never runs at full sheet resolution here.
      local sf = 1
      local m = max(heightImg.width, heightImg.height)
      if m > PREVIEW_MAX then
        sf = PREVIEW_MAX / m
        heightImg = downscaleRGB(heightImg, PREVIEW_MAX)
        alphaImg = downscaleRGB(alphaImg, PREVIEW_MAX)
      end
      cacheH, cacheA, cacheSf, cacheKey = heightImg, alphaImg, sf, key
    end

    local opts = currentOpts()
    if cacheSf < 1 then
      -- The Sobel gradient is per-pixel; downscaling by sf makes the preview
      -- gradient ~1/sf steeper, so compensate to match the full-res output.
      opts.strength    = opts.strength * cacheSf
      opts.rimStrength = opts.rimStrength * cacheSf
      if opts.blurRadius > 0 then opts.blurRadius = max(1, floor(opts.blurRadius * cacheSf + 0.5)) end
      opts.step = max(1, floor(opts.step * cacheSf + 0.5))
    end

    normalImg = NM.generate(cacheH, cacheA, opts)
    buildPreviewCache(normalImg, cacheA)
    relight()
    if doRepaint and shown then dlg:repaint() end
  end

  -- ----- generation ----------------------------------------------------------
  local function framesToProcess()
    if dlg.data.frames == FR_ALL then return sprite.frames end
    return { workFrame() }
  end

  -- Generate the requested map(s) for one source frame.
  local function genFrame(fr, opts, doNormal, doHeight)
    local hi, ai = inputsFor(fr)
    if doNormal and doHeight then return NM.generateBoth(hi, ai, opts) end
    if doNormal then return NM.generate(hi, ai, opts), nil end
    return nil, NM.heightImage(hi, ai, opts)
  end

  local function setCel(spr, layer, fr, img)
    if not img then return end
    local existing = findCel(layer, fr)
    if existing then
      existing.image = img
      existing.position = Point(0, 0)
    else
      spr:newCel(layer, fr, img, Point(0, 0))
    end
  end

  local function getOrCreateLayer(kind, name) -- find-or-create OUR layer across runs/reopens
    local ly = findOurLayer(kind)
    if not ly then
      ly = sprite:newLayer()
      ly.name = name
      markOurs(ly, kind)
    end
    return ly
  end

  local function doGenerate()
    if app.sprite ~= sprite then
      app.alert{ title = "Pixel Normal Generator",
        text = "Switch back to the original sprite before generating." }
      return
    end
    local opts = currentOpts()
    local output = dlg.data.output
    local content = dlg.data.content
    local doNormal = content ~= CONTENT_HEIGHT
    local doHeight = content ~= CONTENT_NORMAL

    if output == OUT_LAYER and sprite.colorMode ~= ColorMode.RGB then
      app.alert{ title = "Pixel Normal Generator",
        text = { "The sprite is not RGB, so the map can't live as a layer in it.",
                 "Creating the result as a new RGB sprite instead." } }
      output = OUT_SPRITE
    end

    local frames = framesToProcess()
    local count = 0

    if output == OUT_LAYER then
      app.transaction("Generate Normal / Height Map", function()
        -- Find-or-create our layers; they are excluded from the height composite
        -- (by name) so a previous result never feeds back into a new one.
        local nLayer = doNormal and getOrCreateLayer("normal", OUTPUT_NORMAL) or nil
        local hLayer = doHeight and getOrCreateLayer("height", OUTPUT_HEIGHT) or nil
        for _, fr in ipairs(frames) do
          local nimg, himg = genFrame(fr, opts, doNormal, doHeight)
          if nLayer then setCel(sprite, nLayer, fr, nimg) end
          if hLayer then setCel(sprite, hLayer, fr, himg) end
          count = count + 1
        end
      end)
      app.refresh()
    else
      -- Snapshot from the SOURCE first (Sprite() below activates a new document).
      local snap = {}
      for i, fr in ipairs(frames) do
        local nimg, himg = genFrame(fr, opts, doNormal, doHeight)
        snap[i] = { normal = nimg, height = himg }
        count = count + 1
      end
      local nspr = Sprite(sprite.width, sprite.height, ColorMode.RGB)
      local nLayer, hLayer
      if doNormal then
        nLayer = nspr.layers[1]; nLayer.name = OUTPUT_NORMAL
        pcall(function() nLayer.properties(PLUGIN_KEY).output = "normal" end)
      end
      if doHeight then
        hLayer = doNormal and nspr:newLayer() or nspr.layers[1]
        hLayer.name = OUTPUT_HEIGHT
        pcall(function() hLayer.properties(PLUGIN_KEY).output = "height" end)
      end
      app.transaction("Normal / Height Map", function()
        for i = 1, #snap do
          if i > #nspr.frames then nspr:newEmptyFrame() end
          setCel(nspr, nLayer, i, snap[i].normal)
          setCel(nspr, hLayer, i, snap[i].height)
        end
      end)
      app.refresh()
    end

    app.alert{ title = "Pixel Normal Generator",
      text = "Generated " .. string.lower(content) .. " for " .. count ..
             (count == 1 and " frame." or " frames.") }
  end

  local function savePrefs()
    local d = dlg.data
    prefs.mode          = d.mode
    prefs.source        = d.source
    prefs.denoise       = d.denoise
    prefs.blur          = d.blur
    prefs.passes        = d.passes
    prefs.strength      = d.strength
    prefs.step          = d.step
    prefs.posterize     = d.posterize
    prefs.invertX       = d.invertX
    prefs.invertY       = d.invertY
    prefs.preserveAlpha = d.preserveAlpha
    prefs.rim           = d.rim
    prefs.rimStrength   = d.rimStrength
    prefs.rimWidth      = d.rimWidth
    prefs.lightHeight   = d.lightHeight
    prefs.content       = d.content
    prefs.output        = d.output
    prefs.frames        = d.frames
  end

  -- ----- dialog --------------------------------------------------------------
  dlg = Dialog{ title = "Pixel Normal Generator", onclose = function() savePrefs() end }

  local hasHeightCombo = #layerNames > 0
  local function updateModeWidgets()
    local mode = dlg.data.mode
    dlg:modify{ id = "source", visible = (mode == MODE_LUMA) }
    if hasHeightCombo then
      dlg:modify{ id = "heightLayer", visible = (mode == MODE_PAINT) }
    end
  end

  local function onParam() rebuild(true) end

  dlg:combobox{
    id = "mode", label = "Mode", option = getp("mode", MODE_LUMA),
    options = { MODE_ALPHA, MODE_LUMA, MODE_PAINT },
    onchange = function() updateModeWidgets(); rebuild(true) end,
  }
  dlg:combobox{
    id = "source", label = "Height source", option = getp("source", "Luminance"),
    options = NM.SOURCES, onchange = onParam,
  }
  if #layerNames > 0 then
    dlg:combobox{
      id = "heightLayer", label = "Height layer",
      option = layerNames[1], options = layerNames, onchange = onParam,
    }
  end

  dlg:separator{ text = "Heightmap (smoothed BEFORE Sobel)" }
  dlg:check{ id = "denoise", text = "Denoise (3x3 median)",
             selected = getp("denoise", false), onclick = onParam }
  dlg:slider{ id = "blur", label = "Blur radius", min = 0, max = 8,
              value = getp("blur", 1), onchange = onParam }
  dlg:slider{ id = "passes", label = "Blur passes", min = 1, max = 3,
              value = getp("passes", 2), onchange = onParam }

  dlg:separator{ text = "Normal" }
  dlg:slider{ id = "strength", label = "Strength (x0.1)", min = 1, max = 100,
              value = getp("strength", 20), onchange = onParam }
  dlg:slider{ id = "step", label = "Pixel step", min = 1, max = 4,
              value = getp("step", 1), onchange = onParam }
  dlg:slider{ id = "posterize", label = "Posterize steps", min = 0, max = 16,
              value = getp("posterize", 5), onchange = onParam }
  dlg:check{ id = "invertX", text = "Invert X",
             selected = getp("invertX", false), onclick = onParam }
  dlg:check{ id = "invertY", text = "Invert Y (DirectX)",
             selected = getp("invertY", false), onclick = onParam }
  dlg:newrow{}
  dlg:check{ id = "preserveAlpha", text = "Preserve alpha",
             selected = getp("preserveAlpha", true), onclick = onParam }

  dlg:separator{ text = "Rim / edge normals (from alpha)" }
  dlg:check{ id = "rim", text = "Add rim from alpha",
             selected = getp("rim", false), onclick = onParam }
  dlg:slider{ id = "rimStrength", label = "Rim strength (x0.02)", min = 0, max = 100,
              value = getp("rimStrength", 30), onchange = onParam }
  dlg:slider{ id = "rimWidth", label = "Rim width", min = 1, max = 4,
              value = getp("rimWidth", 1), onchange = onParam }

  dlg:separator{ text = "Preview — hover/click = move the light" }
  dlg:canvas{
    id = "preview", width = 240, height = 240, autoscaling = false,
    onpaint = function(ev)
      local gc = ev.context
      local cw, ch = gc.width, gc.height
      gc.color = Color{ r = 24, g = 24, b = 28 }
      gc:fillRect(Rectangle(0, 0, cw, ch))
      if not litImg then return end
      local ds = max(1, min(cw // pw, ch // ph))
      local dw, dh = pw * ds, ph * ds
      local ox, oy = (cw - dw) // 2, (ch - dh) // 2
      pvOx, pvOy, pvDs = ox, oy, ds
      gc:drawImage(litImg, 0, 0, pw, ph, ox, oy, dw, dh)
      -- light indicator
      gc.color = Color{ r = 255, g = 230, b = 160 }
      gc.strokeWidth = 1
      gc:strokeRect(Rectangle(ox + floor(lx * ds) - 3, oy + floor(ly * ds) - 3, 6, 6))
    end,
    onmousemove = function(ev)
      if not pvDs then return end
      lx = clampi((ev.x - pvOx) / pvDs, 0, pw - 1)
      ly = clampi((ev.y - pvOy) / pvDs, 0, ph - 1)
      relight()
      dlg:repaint()
    end,
    onmousedown = function(ev)
      if not pvDs then return end
      lx = clampi((ev.x - pvOx) / pvDs, 0, pw - 1)
      ly = clampi((ev.y - pvOy) / pvDs, 0, ph - 1)
      relight()
      dlg:repaint()
    end,
  }
  dlg:slider{ id = "lightHeight", label = "Light height", min = 5, max = 120,
              value = getp("lightHeight", 40),
              onchange = function() relight(); if shown then dlg:repaint() end end }

  dlg:separator{ text = "Output" }
  dlg:combobox{ id = "content", label = "Generate", option = getp("content", CONTENT_NORMAL),
                options = { CONTENT_NORMAL, CONTENT_HEIGHT, CONTENT_BOTH } }
  dlg:combobox{ id = "output", label = "Target", option = getp("output", OUT_LAYER),
                options = { OUT_LAYER, OUT_SPRITE } }
  dlg:combobox{ id = "frames", label = "Frames", option = getp("frames", FR_CURRENT),
                options = { FR_CURRENT, FR_ALL } }

  dlg:separator{}
  dlg:button{ id = "generate", text = "&Generate", focus = true,
              onclick = function() doGenerate() end }
  dlg:button{ id = "close", text = "&Close", onclick = function() dlg:close() end }

  updateModeWidgets()
  rebuild(false)
  shown = true
  dlg:show{ wait = false }
end

return UI
