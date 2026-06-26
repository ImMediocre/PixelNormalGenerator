--------------------------------------------------------------------------------
-- Pixel Normal Generator — core pipeline (pure, no UI).
--
--   heightmap → denoise → blur → Sobel → normal → rim → posterize → encode
--
-- The golden rule for pixel art: smooth the HEIGHTMAP before Sobel, then
-- posterize the NORMAL. Never blur the finished normal map.
--
-- Sign convention is OpenGL / Godot (green points UP, normals point OUT of the
-- surface). Invert X / Y to match DirectX-style engines (Unity / Unreal).
--------------------------------------------------------------------------------

local M = {}

local pc = app.pixelColor
local rgba  = pc.rgba
local rgbaR, rgbaG, rgbaB, rgbaA = pc.rgbaR, pc.rgbaG, pc.rgbaB, pc.rgbaA
local floor, sqrt = math.floor, math.sqrt

-- Height-source options shown in the UI (kept here so UI and pipeline agree).
M.SOURCES = { "Luminance", "Red", "Green", "Blue", "Alpha" }

local function clampi(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi else return v end
end

-- Read the chosen scalar height (0..1) from RGBA components.
local function heightOf(source, r, g, b, a)
  if source == "Alpha" then return a / 255
  elseif source == "Red" then return r / 255
  elseif source == "Green" then return g / 255
  elseif source == "Blue" then return b / 255
  else -- Luminance (Rec. 601)
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255
  end
end

-- Build the height array H (0..1) from heightImg and the alpha array A (0..255)
-- from alphaImg. Both images must be RGB and the same size.
local function extract(heightImg, alphaImg, source, w, h)
  local H, A = {}, {}
  for it in alphaImg:pixels() do
    A[it.y * w + it.x + 1] = rgbaA(it())
  end
  for it in heightImg:pixels() do
    local v = it()
    H[it.y * w + it.x + 1] =
      heightOf(source, rgbaR(v), rgbaG(v), rgbaB(v), rgbaA(v))
  end
  return H, A
end

-- 3x3 median denoise on the heightmap (kills lone noisy pixels). Edge = clamp.
local function median3(H, w, h)
  local out, t = {}, {}
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local k = 0
      for dy = -1, 1 do
        local sy = clampi(y + dy, 0, h - 1)
        for dx = -1, 1 do
          local sx = clampi(x + dx, 0, w - 1)
          k = k + 1
          t[k] = H[sy * w + sx + 1]
        end
      end
      table.sort(t)
      out[y * w + x + 1] = t[5]
    end
  end
  return out
end

-- Separable box blur (radius r), applied `passes` times to approximate a
-- Gaussian. Operates on the heightmap BEFORE Sobel. Edge = clamp.
local function boxBlur(H, w, h, r, passes)
  if r < 1 or passes < 1 then return H end
  local src = H
  local inv = 1 / (2 * r + 1)
  for _ = 1, passes do
    local tmp = {}
    -- horizontal
    for y = 0, h - 1 do
      local base = y * w
      for x = 0, w - 1 do
        local s = 0
        for k = -r, r do
          s = s + src[base + clampi(x + k, 0, w - 1) + 1]
        end
        tmp[base + x + 1] = s * inv
      end
    end
    -- vertical
    local out = {}
    for x = 0, w - 1 do
      for y = 0, h - 1 do
        local s = 0
        for k = -r, r do
          s = s + tmp[clampi(y + k, 0, h - 1) * w + x + 1]
        end
        out[y * w + x + 1] = s * inv
      end
    end
    src = out
  end
  return src
end

--------------------------------------------------------------------------------
-- M.generate(heightImg, alphaImg, opts) -> RGB Image (the normal map)
--
-- heightImg : RGB image the height is read from (selected channel/luminance).
-- alphaImg  : RGB image whose ALPHA is the silhouette (preserve-alpha + rim).
--             For the Alpha and Luminance modes this is the same image.
-- opts fields:
--   source        "Luminance"|"Red"|"Green"|"Blue"|"Alpha"
--   alphaAware    bool  - transparent neighbours reuse centre height (luma/paint
--                         modes) so the silhouette itself adds NO bevel.
--                         false for Alpha mode (we WANT the alpha edge slope).
--   denoise       bool  - 3x3 median pre-pass
--   blurRadius    int   - heightmap blur radius (0 = off)
--   blurPasses    int   - blur repetitions
--   strength      number- gradient scale
--   step          int   - Sobel sample distance (pixel step)
--   posterize     int   - quantization levels (<=1 = off)
--   invertX       bool
--   invertY       bool
--   preserveAlpha bool  - copy source alpha onto the normal map
--   rim           bool  - blend alpha-edge normals near the silhouette
--   rimStrength   number
--   rimWidth      int   - alpha Sobel step for the rim (reach inward)
--------------------------------------------------------------------------------
function M.generate(heightImg, alphaImg, opts)
  local w, h = alphaImg.width, alphaImg.height
  local H, A = extract(heightImg, alphaImg, opts.source, w, h)

  if opts.denoise then H = median3(H, w, h) end
  H = boxBlur(H, w, h, opts.blurRadius, opts.blurPasses)

  local alphaAware = opts.alphaAware
  local strength   = opts.strength
  local step       = math.max(1, opts.step)
  local invX       = opts.invertX and -1 or 1
  local invY       = opts.invertY and -1 or 1
  local rim        = opts.rim
  local rimStr     = opts.rimStrength or 0
  local rimStep    = math.max(1, opts.rimWidth or 1)
  local steps      = opts.posterize or 0
  local doPost     = steps and steps > 1
  local keepAlpha  = opts.preserveAlpha

  -- Divide the central difference by the sampling distance so `step` widens the
  -- baseline WITHOUT secretly scaling bump strength (0.25 is the 1+2+1 weight sum).
  local invS   = 0.25 / step
  local invRim = 0.25 / rimStep

  -- Sample height with edge clamp. In alpha-aware modes a transparent neighbour
  -- returns the centre height `ch`, so the alpha cut adds no gradient.
  local function sampleH(x, y, ch)
    x = clampi(x, 0, w - 1)
    y = clampi(y, 0, h - 1)
    local idx = y * w + x + 1
    if alphaAware and A[idx] == 0 then return ch end
    return H[idx]
  end

  -- Sample the alpha silhouette as a 0..1 height (for the rim), edge clamp.
  local function sampleA(x, y)
    return A[clampi(y, 0, h - 1) * w + clampi(x, 0, w - 1) + 1] / 255
  end

  local function post(v)
    local q = floor(v / 255 * (steps - 1) + 0.5)
    return floor(q / (steps - 1) * 255 + 0.5)
  end

  local out = Image(w, h, ColorMode.RGB)
  local neutralA = keepAlpha and 0 or 255
  local neutral = rgba(128, 128, 255, neutralA)

  for it in out:pixels() do
    local x, y = it.x, it.y
    local idx = y * w + x + 1
    local a = A[idx]
    if a == 0 then
      it(neutral)
    else
      local ch = H[idx]

      -- Sobel (kernel weights 1,2,1) sampled at `step`.
      local tl = sampleH(x - step, y - step, ch)
      local tc = sampleH(x,        y - step, ch)
      local tr = sampleH(x + step, y - step, ch)
      local lc = sampleH(x - step, y,        ch)
      local rc = sampleH(x + step, y,        ch)
      local bl = sampleH(x - step, y + step, ch)
      local bc = sampleH(x,        y + step, ch)
      local br = sampleH(x + step, y + step, ch)

      local gx = ((tr + 2 * rc + br) - (tl + 2 * lc + bl)) * invS -- east - west
      local gy = ((bl + 2 * bc + br) - (tl + 2 * tc + tr)) * invS -- south - north

      -- Outward normal of z=H, converted to OpenGL/Godot (Y up):
      --   nx = -dH/dx  ,  ny = +(south-north)  ,  nz = 1
      local nx = -gx * strength
      local ny =  gy * strength
      local nz =  1.0

      -- Rim: blend alpha-edge normals. The interior alpha gradient is ~0, so
      -- this only bends normals near the silhouette (outward = rim light).
      if rim and rimStr > 0 then
        local agx = ((sampleA(x + rimStep, y - rimStep) + 2 * sampleA(x + rimStep, y) + sampleA(x + rimStep, y + rimStep))
                   - (sampleA(x - rimStep, y - rimStep) + 2 * sampleA(x - rimStep, y) + sampleA(x - rimStep, y + rimStep))) * invRim
        local agy = ((sampleA(x - rimStep, y + rimStep) + 2 * sampleA(x, y + rimStep) + sampleA(x + rimStep, y + rimStep))
                   - (sampleA(x - rimStep, y - rimStep) + 2 * sampleA(x, y - rimStep) + sampleA(x + rimStep, y - rimStep))) * invRim
        nx = nx + (-agx) * rimStr
        ny = ny + ( agy) * rimStr
      end

      nx = nx * invX
      ny = ny * invY

      local len = sqrt(nx * nx + ny * ny + nz * nz)
      if len < 1e-6 then len = 1 end
      nx, ny, nz = nx / len, ny / len, nz / len

      local R = clampi(floor(nx * 127.5 + 128), 0, 255)
      local G = clampi(floor(ny * 127.5 + 128), 0, 255)
      local B = clampi(floor(nz * 127.5 + 128), 0, 255)

      if doPost then R = post(R); G = post(G); B = post(B) end

      it(rgba(R, G, B, keepAlpha and a or 255))
    end
  end

  return out
end

return M
