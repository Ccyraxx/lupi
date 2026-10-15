-- =====================================================================
-- FALHA NO SISTEMA — main.lua (console Lupi)
-- =====================================================================
-- Você é o último daemon de integridade de um sistema em colapso.
-- Blocos de dados chegam ao buffer de memória. Organize-os em setores
-- completos para processá-los antes que o buffer faça OVERFLOW.
--
-- Controles:
--   ← →  : mover pacote           ↑ : rotacionar CW
--   ↓    : soft drop              O : rotacionar CCW
--   X    : hard drop (commit)     X : reiniciar após KERNEL PANIC
-- =====================================================================

-- ---------------------------------------------------------------------
-- PALETA (RGB555) — terminal verde/âmbar com blocos coloridos
-- ---------------------------------------------------------------------
local function setup_palette()
    ui.palset(0,  0x0000)   -- preto           fundo do buffer
    ui.palset(1,  0x0320)   -- verde escuro    linhas de grade
    ui.palset(2,  0x001F)   -- azul            pacote J
    ui.palset(3,  0x03E0)   -- verde           pacote S
    ui.palset(4,  0x7C00)   -- vermelho        pacote Z / perigo
    ui.palset(5,  0x03FF)   -- ciano           pacote I
    ui.palset(6,  0x7FE0)   -- amarelo         pacote O
    ui.palset(7,  0x7C1F)   -- magenta         pacote T
    ui.palset(8,  0x7BE0)   -- laranja         pacote L
    ui.palset(9,  0x7FFF)   -- branco          brilho
    ui.palset(10, 0x0100)   -- verde muito esc painel
    ui.palset(11, 0x0B60)   -- verde médio     borda do painel
    ui.palset(12, 0x7BE0)   -- âmbar           texto do sistema
    ui.palset(13, 0x1084)   -- verde sombrio   sombra
    ui.palset(14, 0x7C00)   -- vermelho        alerta / borda crítica
end

-- ---------------------------------------------------------------------
-- LAYOUT
-- ---------------------------------------------------------------------
local COLS, ROWS = 10, 20
local CELL      = 12
local BX, BY    = 40, 15
local BW, BH    = COLS * CELL, ROWS * CELL

local SX, SY    = 190, BY
local SW, SH    = 250, BH

local PX, PY    = SX + 15, SY + 50
local PW, PH    = 120, 90

-- ---------------------------------------------------------------------
-- PACOTES DE DADOS (peças)
-- ---------------------------------------------------------------------
local SHAPES = {
    {{0,0,0,0},{1,1,1,1},{0,0,0,0},{0,0,0,0}, c = 5},  -- I
    {{0,0,0,0},{0,1,1,0},{0,1,1,0},{0,0,0,0}, c = 6},  -- O
    {{0,0,0,0},{0,1,0,0},{1,1,1,0},{0,0,0,0}, c = 7},  -- T
    {{0,0,0,0},{0,1,1,0},{1,1,0,0},{0,0,0,0}, c = 3},  -- S
    {{0,0,0,0},{1,1,0,0},{0,1,1,0},{0,0,0,0}, c = 4},  -- Z
    {{0,0,0,0},{1,0,0,0},{1,1,1,0},{0,0,0,0}, c = 2},  -- J
    {{0,0,0,0},{0,0,1,0},{1,1,1,0},{0,0,0,0}, c = 8},  -- L
}

local function copy4(m)
    return {
        { m[1][1], m[1][2], m[1][3], m[1][4] },
        { m[2][1], m[2][2], m[2][3], m[2][4] },
        { m[3][1], m[3][2], m[3][3], m[3][4] },
        { m[4][1], m[4][2], m[4][3], m[4][4] },
    }
end

local function rot_cw(m)
    local r = { {0,0,0,0}, {0,0,0,0}, {0,0,0,0}, {0,0,0,0} }
    for y = 1, 4 do
        for x = 1, 4 do
            r[x][5 - y] = m[y][x]
        end
    end
    return r
end

local PIECES = {}
for i, s in ipairs(SHAPES) do
    local rots = {}
    local cur = copy4(s)
    for r = 0, 3 do
        rots[r] = cur
        cur = rot_cw(cur)
    end
    PIECES[i] = { rots = rots, color = s.c }
end

-- ---------------------------------------------------------------------
-- ESTADO DO SISTEMA
-- ---------------------------------------------------------------------
local buffer          -- buffer de memória (tabuleiro)
local cur_packet      -- pacote em movimento
local next_type       -- próximo pacote
local processed       -- dados processados (pontos)
local sectors         -- setores processados (linhas)
local load            -- carga do sistema (nível)
local crash           -- kernel panic
local drop_timer, drop_interval
local lock_timer, lock_delay
local das_dir, das_timer
local soft_timer
local bag
local initialized = false
local alert_timer = 0   -- pisca a borda quando em perigo
local warning_msg = ""
local warning_timer = 0

local GRAVITY_BASE = 48
local LOCK_DELAY   = 30
local DAS_DELAY    = 10
local DAS_REPEAT   = 3
local SOFT_DELAY   = 3
local DANGER_LINE  = 5     -- topo do perigo (linha 5 do topo)

-- ---------------------------------------------------------------------
-- LÓGICA
-- ---------------------------------------------------------------------
local function new_buffer()
    local b = {}
    for y = 1, ROWS do
        b[y] = {}
        for x = 1, COLS do b[y][x] = 0 end
    end
    return b
end

local function refill_bag()
    local b = {1,2,3,4,5,6,7}
    for i = #b, 2, -1 do
        local j = math.random(i)
        b[i], b[j] = b[j], b[i]
    end
    bag = b
end

local function next_from_bag()
    if #bag == 0 then refill_bag() end
    return table.remove(bag, 1)
end

local function collides(shape, px, py)
    for y = 1, 4 do
        for x = 1, 4 do
            if shape[y][x] == 1 then
                local bx = px + x - 1
                local by = py + y - 1
                if bx < 1 or bx > COLS then return true end
                if by > ROWS then return true end
                if by >= 1 and buffer[by][bx] ~= 0 then return true end
            end
        end
    end
    return false
end

local function spawn_packet()
    local t = next_type
    next_type = next_from_bag()
    cur_packet = { type = t, rot = 0, x = 4, y = 1 }
    if collides(PIECES[t].rots[0], cur_packet.x, cur_packet.y) then
        crash = true
        warning_msg = "OVERFLOW"
        warning_timer = 999
    end
    drop_timer = 0
    lock_timer = 0
end

local function reset_system()
    buffer         = new_buffer()
    processed      = 0
    sectors        = 0
    load           = 1
    crash          = false
    drop_timer     = 0
    drop_interval  = GRAVITY_BASE
    lock_timer     = 0
    lock_delay     = LOCK_DELAY
    das_dir        = 0
    das_timer      = 0
    soft_timer     = 0
    bag            = {}
    alert_timer    = 0
    warning_msg    = ""
    warning_timer  = 0
    refill_bag()
    next_type = next_from_bag()
    spawn_packet()
end

local function stack_height()
    for y = 1, ROWS do
        for x = 1, COLS do
            if buffer[y][x] ~= 0 then
                return ROWS - y + 1
            end
        end
    end
    return 0
end

local function lock_packet()
    local shape = PIECES[cur_packet.type].rots[cur_packet.rot]
    local col   = PIECES[cur_packet.type].color

    for y = 1, 4 do
        for x = 1, 4 do
            if shape[y][x] == 1 then
                local bx = cur_packet.x + x - 1
                local by = cur_packet.y + y - 1
                if by >= 1 and by <= ROWS and bx >= 1 and bx <= COLS then
                    buffer[by][bx] = col
                end
            end
        end
    end

    -- processa setores completos (linhas)
    local cleared = 0
    local y = ROWS
    while y >= 1 do
        local full = true
        for x = 1, COLS do
            if buffer[y][x] == 0 then full = false; break end
        end
        if full then
            cleared = cleared + 1
            table.remove(buffer, y)
            local newrow = {}
            for x = 1, COLS do newrow[x] = 0 end
            table.insert(buffer, 1, newrow)
        else
            y = y - 1
        end
    end

    if cleared > 0 then
        local pts = { 0, 100, 300, 500, 800 }
        processed = processed + pts[cleared] * load
        sectors   = sectors + cleared
        load      = math.floor(sectors / 10) + 1
        drop_interval = math.max(6, GRAVITY_BASE - (load - 1) * 4)

        -- mensagens temáticas ao processar múltiplos setores
        if cleared == 4 then
            warning_msg = "SETOR LIMPO"
            warning_timer = 90
        elseif cleared == 3 then
            warning_msg = "DESFRAG OK"
            warning_timer = 60
        end
    end

    spawn_packet()
end

local function try_move(dx, dy)
    local shape = PIECES[cur_packet.type].rots[cur_packet.rot]
    if not collides(shape, cur_packet.x + dx, cur_packet.y + dy) then
        cur_packet.x = cur_packet.x + dx
        cur_packet.y = cur_packet.y + dy
        return true
    end
    return false
end

local function try_rotate(dir)
    local nr    = (cur_packet.rot + dir) % 4
    local shape = PIECES[cur_packet.type].rots[nr]
    local kicks = { 0, -1, 1, -2, 2 }
    for _, k in ipairs(kicks) do
        if not collides(shape, cur_packet.x + k, cur_packet.y) then
            cur_packet.rot = nr
            cur_packet.x   = cur_packet.x + k
            return true
        end
    end
    return false
end

local function hard_drop()
    local shape = PIECES[cur_packet.type].rots[cur_packet.rot]
    local dy = 0
    while not collides(shape, cur_packet.x, cur_packet.y + dy + 1) do
        dy = dy + 1
    end
    cur_packet.y = cur_packet.y + dy
    processed = processed + dy * 2
    lock_packet()
end

-- ---------------------------------------------------------------------
-- DESENHO
-- ---------------------------------------------------------------------
local function draw_cell(px, py, color)
    ui.rectfill(px, py, px + CELL - 1, py + CELL - 1, color)
    ui.line(px, py, px + CELL - 1, py, 9)
    ui.line(px, py, px, py + CELL - 1, 9)
    ui.line(px + CELL - 1, py, px + CELL - 1, py + CELL - 1, 13)
    ui.line(px, py + CELL - 1, px + CELL - 1, py + CELL - 1, 13)
end

local function draw_cell_outline(px, py, color)
    ui.line(px, py, px + CELL - 1, py, color)
    ui.line(px, py, px, py + CELL - 1, color)
    ui.line(px + CELL - 1, py, px + CELL - 1, py + CELL - 1, color)
    ui.line(px, py + CELL - 1, px + CELL - 1, py + CELL - 1, color)
end

local function piece_bounds(shape)
    local minx, maxx, miny, maxy = 5, 0, 5, 0
    for y = 1, 4 do
        for x = 1, 4 do
            if shape[y][x] == 1 then
                if x < minx then minx = x end
                if x > maxx then maxx = x end
                if y < miny then miny = y end
                if y > maxy then maxy = y end
            end
        end
    end
    return minx, maxx, miny, maxy
end

local function draw_buffer()
    -- moldura — pisca vermelho se o stack estiver em perigo
    local h = stack_height()
    local in_danger = (h >= (ROWS - DANGER_LINE))
    local frame_col = 11
    if in_danger then
        alert_timer = alert_timer + 1
        if math.floor(alert_timer / 15) % 2 == 0 then
            frame_col = 14
        end
    end

    ui.rectfill(BX - 3, BY - 3, BX + BW + 2, BY + BH + 2, frame_col)
    ui.rectfill(BX, BY, BX + BW - 1, BY + BH - 1, 0)

    -- grade
    for y = 0, ROWS do
        ui.line(BX, BY + y * CELL, BX + BW - 1, BY + y * CELL, 1)
    end
    for x = 0, COLS do
        ui.line(BX + x * CELL, BY, BX + x * CELL, BY + BH - 1, 1)
    end

    -- linha de perigo (marca o limite do overflow)
    local dy = BY + DANGER_LINE * CELL
    for x = 0, BW - 1, 4 do
        ui.line(BX + x, dy, BX + x + 1, dy, 14)
    end

    -- blocos fixos
    for y = 1, ROWS do
        for x = 1, COLS do
            if buffer[y][x] ~= 0 then
                draw_cell(BX + (x - 1) * CELL,
                          BY + (y - 1) * CELL, buffer[y][x])
            end
        end
    end

    -- pacote atual + ghost
    if cur_packet and not crash then
        local shape = PIECES[cur_packet.type].rots[cur_packet.rot]
        local col   = PIECES[cur_packet.type].color

        local gy = cur_packet.y
        while not collides(shape, cur_packet.x, gy + 1) do
            gy = gy + 1
        end
        if gy > cur_packet.y then
            for yy = 1, 4 do
                for xx = 1, 4 do
                    if shape[yy][xx] == 1 then
                        local bx = cur_packet.x + xx - 1
                        local by = gy + yy - 1
                        if by >= 1 then
                            draw_cell_outline(
                                BX + (bx - 1) * CELL,
                                BY + (by - 1) * CELL, col)
                        end
                    end
                end
            end
        end

        for yy = 1, 4 do
            for xx = 1, 4 do
                if shape[yy][xx] == 1 then
                    local bx = cur_packet.x + xx - 1
                    local by = cur_packet.y + yy - 1
                    if by >= 1 then
                        draw_cell(BX + (bx - 1) * CELL,
                                  BY + (by - 1) * CELL, col)
                    end
                end
            end
        end
    end
end

local function draw_sidebar()
    ui.rectfill(SX, SY, SX + SW, SY + SH, 10)
    ui.rectfill(SX, SY, SX + SW, SY + 18, 11)

    ui.print("SISTEMA", SX + 8, SY + 6, 9)
    ui.print("PROX BLOCO", SX + 8, SY + 30, 12)

    ui.rectfill(PX, PY, PX + PW, PY + PH, 0)

    if next_type then
        local shape = PIECES[next_type].rots[0]
        local minx, maxx, miny, maxy = piece_bounds(shape)
        local pw = (maxx - minx + 1) * CELL
        local ph = (maxy - miny + 1) * CELL
        local cx = PX + PW / 2
        local cy = PY + PH / 2
        local ox = cx - pw / 2 - (minx - 1) * CELL
        local oy = cy - ph / 2 - (miny - 1) * CELL

        for y = 1, 4 do
            for x = 1, 4 do
                if shape[y][x] == 1 then
                    draw_cell(ox + (x - 1) * CELL,
                              oy + (y - 1) * CELL,
                              PIECES[next_type].color)
                end
            end
        end
    end

    ui.print("PROCESSADOS", SX + 8, SY + 155, 12)
    ui.print(tostring(processed), SX + 8, SY + 170, 6)

    ui.print("CARGA", SX + 145, SY + 155, 12)
    ui.print(tostring(load), SX + 145, SY + 170, 3)

    ui.print("SETORES", SX + 8, SY + 200, 12)
    ui.print(tostring(sectors), SX + 8, SY + 215, 5)

    -- mensagem temporária (feedback de eventos)
    if warning_timer > 0 then
        warning_timer = warning_timer - 1
        ui.print(warning_msg, SX + 8, SY + 240, 14)
    else
        ui.print("STATUS: OK", SX + 8, SY + 240, 3)
    end
end

local function draw_crash()
    ui.rectfill(BX, BY + 80, BX + BW - 1, BY + 160, 0)
    ui.line(BX, BY + 80, BX + BW - 1, BY + 80, 14)
    ui.line(BX, BY + 160, BX + BW - 1, BY + 160, 14)

    ui.print("KERNEL PANIC", BX + 12, BY + 90, 14)
    ui.print("OVERFLOW", BX + 12, BY + 108, 4)
    ui.print("DADOS:" .. tostring(processed), BX + 12, BY + 126, 6)
    ui.print("X = REBOOT", BX + 12, BY + 144, 12)
end

-- ---------------------------------------------------------------------
-- INPUT
--   0 = esq, 1 = dir, 2 = cima, 3 = baixo, 4 = O, 5 = X
-- ---------------------------------------------------------------------
local function handle_input()
    if crash then
        if ui.btnp(5) then reset_system() end
        return
    end

    if ui.btnp(2) then try_rotate(1)  end
    if ui.btnp(4) then try_rotate(-1) end

    if ui.btnp(5) then
        hard_drop()
        return
    end

    local left  = ui.btn(0)
    local right = ui.btn(1)
    local dir = 0
    if left and not right then dir = -1
    elseif right and not left then dir = 1 end

    if dir ~= 0 then
        if dir ~= das_dir then
            try_move(dir, 0)
            das_dir   = dir
            das_timer = 0
        else
            das_timer = das_timer + 1
            if das_timer >= DAS_DELAY then
                if (das_timer - DAS_DELAY) % DAS_REPEAT == 0 then
                    try_move(dir, 0)
                end
            end
        end
    else
        das_dir   = 0
        das_timer = 0
    end

    if ui.btn(3) then
        soft_timer = soft_timer + 1
        if soft_timer >= SOFT_DELAY then
            soft_timer = 0
            if try_move(0, 1) then
                drop_timer = 0
                processed = processed + 1
            end
        end
    else
        soft_timer = 0
    end
end

-- ---------------------------------------------------------------------
-- GRAVIDADE
-- ---------------------------------------------------------------------
local function apply_gravity()
    if crash then return end
    local shape = PIECES[cur_packet.type].rots[cur_packet.rot]
    local on_ground = collides(shape, cur_packet.x, cur_packet.y + 1)

    if on_ground then
        lock_timer = lock_timer + 1
        if lock_timer >= lock_delay then
            lock_packet()
            lock_timer = 0
        end
    else
        lock_timer = 0
        drop_timer = drop_timer + 1
        if drop_timer >= drop_interval then
            drop_timer = 0
            try_move(0, 1)
        end
    end
end

-- ---------------------------------------------------------------------
-- UPDATE PRINCIPAL
-- ---------------------------------------------------------------------
function update(frame)
    setup_palette()

    if not initialized then
        math.randomseed(os.time())
        reset_system()
        initialized = true
    end

    handle_input()
    apply_gravity()

    ui.cls(0)
    draw_buffer()
    draw_sidebar()

    if crash then
        draw_crash()
    end
end