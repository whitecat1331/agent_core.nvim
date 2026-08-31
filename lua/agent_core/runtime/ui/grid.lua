---@mod agent_core.runtime.ui.grid Pure grid layout math for the Agents Window.
---@brief [[
--- Computes a rows×cols grid for N panes that best fills a container, plus
--- per-pane geometry and focus-cycling helpers. No Neovim window API here — the
--- layout is a pure function of (pane count, container width, container height)
--- so it can be unit-tested headlessly and reused by any renderer.
---@brief ]]

local M = {}

--- Clamp an integer into [min, max].
---@param n number
---@param min number
---@param max number
---@return integer
local function clamp(n, min, max)
  return math.floor(math.max(min, math.min(max, n)))
end

--- Compute the grid dimensions (cols, rows) for N panes in a container.
--- Uses a roughly square layout: cols = ceil(sqrt(N)), rows = ceil(N / cols),
--- with any empty trailing row dropped. `width`/`height` are reserved for a
--- future minimum-cell-size policy and do not affect the shape.
---@param panes integer number of panes
---@param width number container width in columns (reserved)
---@param height number container height in rows (reserved)
---@return integer cols
---@return integer rows
function M.dimensions(panes, width, height)
  panes = math.max(1, math.floor(panes or 1))

  local cols = clamp(math.ceil(math.sqrt(panes)), 1, panes)
  local rows = clamp(math.ceil(panes / cols), 1, panes)

  -- Drop an empty trailing row.
  while (rows - 1) * cols >= panes do
    rows = rows - 1
  end
  return cols, rows
end

--- Compute per-pane geometry for N panes given container dimensions. Each pane
--- gets equal width/height; the remainder is dropped (cells are integer).
---@param panes integer
---@param width number
---@param height number
---@return {index:integer,col:integer,row:integer,width:integer,height:integer}[]
function M.layout(panes, width, height)
  panes = math.max(1, math.floor(panes or 1))
  width = math.max(1, math.floor(width or 80))
  height = math.max(1, math.floor(height or 24))

  local cols, rows = M.dimensions(panes, width, height)
  local cell_w = math.max(1, math.floor(width / cols))
  local cell_h = math.max(1, math.floor(height / rows))

  local out = {}
  for i = 1, panes do
    local col = (i - 1) % cols
    local row = math.floor((i - 1) / cols)
    out[i] = {
      index = i,
      col = col,
      row = row,
      width = cell_w,
      height = cell_h,
    }
  end
  return out
end

--- Next pane index in a round-robin cycle (1-based), wrapping at the end.
---@param current integer|nil
---@param panes integer
---@return integer
function M.next_index(current, panes)
  panes = math.max(1, math.floor(panes or 1))
  current = math.floor(current or 0)
  if current >= panes then
    return 1
  end
  return current + 1
end

--- Previous pane index in a round-robin cycle (1-based), wrapping at the start.
---@param current integer|nil
---@param panes integer
---@return integer
function M.prev_index(current, panes)
  panes = math.max(1, math.floor(panes or 1))
  current = math.floor(current or 1)
  if current <= 1 then
    return panes
  end
  return current - 1
end

--- The grid cell (row, col) a given pane index occupies.
---@param index integer 1-based pane index
---@param cols integer
---@return integer row
---@return integer col
function M.cell(index, cols)
  cols = math.max(1, math.floor(cols or 1))
  index = math.max(1, math.floor(index or 1))
  return math.floor((index - 1) / cols), (index - 1) % cols
end

return M
